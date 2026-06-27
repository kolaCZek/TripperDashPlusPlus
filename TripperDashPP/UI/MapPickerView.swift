//
//  MapPickerView.swift
//  TripperDashPP
//
//  Phase 7 (full) — top-level navigation experience.
//
//  Architecture: the picker has THREE mutually exclusive UI phases:
//
//    • .picking     — live MKMapView + sticky search bar + quick access
//                      tiles, "Navigate" CTA, no stream running.
//                      feat/route-waypoints: when a plan is being built
//                      (status.plannedRoute != nil) the picking phase
//                      shows the PLANNING UI instead (PlanningMapView +
//                      WaypointListView). Both live in .picking with the
//                      stream OFF, so the GPU-pool mutual-exclusion rule
//                      is preserved.
//    • .navigating  — NavigationHUD on phone (ETA/turn/distance),
//                      MapViewSource pushing frames to dash.
//    • .transitioning — brief blank state (~500 ms) between the above
//                      so Apple Maps' shared GPU pool drains before we
//                      swap the live MKMapView <-> the BG tile renderer.
//
//  See CLAUDE.md → "Architecture summary" and the `royal-enfield-tripper-dash`
//  skill's `references/ios-map-renderer.md` for the GPU-pool rationale.
//

import CoreLocation
import MapKit
import SwiftUI

struct MapPickerView: View {
    @Environment(AppStatus.self) private var status
    @Environment(\.scenePhase) private var scenePhase

    @State private var locationToken: UUID?
    @State private var transitioning = false
    @State private var showSettings = false
    @State private var showSavedRoutes = false

    /// Armed when the rider taps "Connect to dash to start" while a plan
    /// is laid out — i.e. they intend to ride, not just connect. When the
    /// link then reaches `.connected`, we auto-start navigation instead of
    /// making them tap a second button. Cleared on start, on a failed/
    /// cancelled connect, or if the plan disappears. Deliberately NOT set
    /// by the plain "Connect to dash" (no plan) path, nor by reconnects.
    @State private var pendingAutoStart = false

    /// Tile pre-render progress (0.0 = idle/done, 0…<1 = in flight).
    /// We use a single shared sheet that watches `prerenderActive`.
    @State private var prerenderActive = false
    @State private var prerenderProgress: Double = 0

    // Sheet flags
    @State private var showSearch = false
    @State private var showFavoriteEditor = false
    @State private var favoriteEditorSeed: Destination?
    /// The destination currently selected on the home map: drives both
    /// the red pin and the compact preview card. Replaces the old
    /// `droppedPin` + `previewDestination` (modal sheet) pair — the card
    /// is now an inline overlay so the map stays live underneath and the
    /// rider can tap a neighbouring point to retarget.
    @State private var selectedDestination: Destination?
    /// One-shot camera focus request handed to InteractiveMapView. Set
    /// when a search result / favorite is picked, or the recenter button
    /// is tapped. A plain map tap deliberately does NOT set it, so the
    /// camera holds still while the rider drops pins around.
    @State private var focusRequest: MapFocusRequest?
    /// Whether the "center on me" button should be shown — reported by
    /// the map when the user puck drifts out of the central region.
    @State private var showRecenterButton = false
    /// When set, the next destination picked in DestinationSearchSheet
    /// is committed straight into this quick-access slot instead of
    /// going through the preview/route flow.
    @State private var slotToFill: QuickAccessSlot?

    // feat/route-waypoints planning state
    /// True when the search sheet result should be ADDED to the active
    /// plan as a via-stop, rather than starting a fresh plan.
    @State private var addingStopToPlan = false
    /// Coordinate from a long-press, pending the add/destination dialog.
    @State private var longPressCoord: CLLocationCoordinate2D?
    @State private var showLongPressDialog = false
    @State private var showRoutePreferences = false

    private enum DisplayMode { case picking, navigating, transitioning }
    private var mode: DisplayMode {
        if transitioning { return .transitioning }
        return status.activeNavigator.isNavigating ? .navigating : .picking
    }

    /// Whether the picking phase should show the multi-stop planning UI.
    private var isPlanning: Bool { status.plannedRoute != nil }

    var body: some View {
        VStack(spacing: 0) {
            StatusBanner(state: status.connectionState, ssid: status.bikeSsid)

            ZStack {
                switch mode {
                case .picking:       pickingBody
                case .navigating:    navigatingBody
                case .transitioning: transitioningBody
                }

                if case .error = status.bikeLink.state, let err = status.lastError {
                    VStack {
                        Spacer()
                        Text(err)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial)
                            .clipShape(.rect(cornerRadius: 8))
                            .padding(.bottom, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlButton
        }
        .toolbar {
            // The saved-routes shortcut only belongs in the idle browsing
            // state ("where do I want to go?"). Once a route is being
            // planned for navigation — or navigation is already running —
            // it has no logical place in the top bar, so hide it there.
            if mode == .picking && !isPlanning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSavedRoutes = true } label: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .accessibilityLabel("Saved routes")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { StreamingView() }
                .environment(status)
        }
        .sheet(isPresented: $showSavedRoutes) {
            SavedRoutesListView()
                .environment(status)
                .environment(status.savedRoutesStore)
        }
        .fullScreenCover(isPresented: $prerenderActive) {
            PrerenderProgressView(progress: prerenderProgress)
        }
        .sheet(isPresented: $showSearch) {
            DestinationSearchSheet { dest in
                handlePickedDestination(dest)
            }
            .environment(status)
            .environment(status.navigationStore)
        }
        .sheet(isPresented: $showFavoriteEditor) {
            FavoriteEditorSheet(existing: nil, seed: favoriteEditorSeed)
                .environment(status.navigationStore)
        }
        .sheet(isPresented: $showRoutePreferences, onDismiss: {
            // Preferences (avoid highways/tolls) changed → every leg
            // must be recomputed against the new constraints.
            if let plan = status.plannedRoute {
                Task { await status.recomputeDirtyLegs(plan.allLegIndices, in: plan) }
            }
        }) {
            NavigationStack {
                RoutePreferencesView()
                    .environment(status.navigationStore)
            }
        }
        .confirmationDialog("Add to route", isPresented: $showLongPressDialog, titleVisibility: .visible) {
            Button("Add as stop") { commitLongPress(asDestination: false) }
            Button("Set as destination") { commitLongPress(asDestination: true) }
            Button("Cancel", role: .cancel) { longPressCoord = nil }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                if !status.isStreaming, !status.activeNavigator.isNavigating, let token = locationToken {
                    status.locationService.stop(token: token)
                    locationToken = nil
                }
            case .active:
                if mode == .picking, locationToken == nil {
                    locationToken = status.locationService.start(mode: .mapping)
                }
            @unknown default:
                break
            }
        }
        .onChange(of: status.bikeLink.state) { _, newState in
            handleLinkStateForAutoStart(newState)
        }
        .onChange(of: status.plannedRoute?.isComputed) { _, _ in
            // The plan just finished (re)computing. If the rider armed
            // auto-start and we're already connected, this is the trigger
            // that was waiting on the route — fire it now.
            tryAutoStartNavigation()
        }
        .onChange(of: isPlanning) { _, planning in
            // Rider tore down the plan (cleared destination) while waiting
            // to connect → cancel the armed auto-start so a later manual
            // connect doesn't unexpectedly launch into nothing.
            if !planning { pendingAutoStart = false }
        }
        .onChange(of: status.requestDismissSavedRoutes) { _, request in
            // A saved route was staged for navigation from inside the
            // Saved Routes sheet — tear the sheet down so the picker's
            // planning UI (the staged plan) is visible. One-shot: reset.
            if request {
                showSavedRoutes = false
                status.requestDismissSavedRoutes = false
            }
        }
    }

    /// Reacts to link-state transitions for the auto-start feature.
    private func handleLinkStateForAutoStart(_ newState: BikeLink.LinkState) {
        switch newState {
        case .connected:
            tryAutoStartNavigation()
        case .idle, .error:
            // Connect failed or the rider cancelled → drop the intent so it
            // can't silently fire on a future connect.
            pendingAutoStart = false
        case .connecting, .handshaking, .reconnecting:
            break
        }
    }

    /// Fires the armed auto-start iff every precondition holds. Safe to
    /// call from multiple triggers (link reached `.connected`, or the plan
    /// finished computing) — it's idempotent via the `pendingAutoStart`
    /// flag, which it clears before starting.
    ///
    /// Intentionally inert for:
    ///   - mid-ride reconnects: `mode` is `.navigating`, not `.picking`;
    ///   - idle connects with no plan: `pendingAutoStart` was never armed
    ///     (the no-plan "Connect to dash" path doesn't set it);
    ///   - connects where the route isn't computed yet: we wait for the
    ///     plan-computed trigger to call us again.
    private func tryAutoStartNavigation() {
        guard pendingAutoStart else { return }
        guard status.bikeLink.state == .connected else { return }
        guard mode == .picking,
              let plan = status.plannedRoute,
              plan.isComputed else { return }
        pendingAutoStart = false
        startNavigation(plan: plan)
    }

    // MARK: - Phase bodies

    @ViewBuilder
    private var pickingBody: some View {
        if isPlanning, let plan = status.plannedRoute {
            planningBody(plan: plan)
        } else {
            browsingBody
        }
    }

    /// The pre-plan map: live interactive map + search + quick access.
    @ViewBuilder
    private var browsingBody: some View {
        ZStack(alignment: .top) {
            InteractiveMapView(
                userCoordinate: status.locationService.lastFix?.coordinate,
                selectedPin: selectedDestination?.coordinate,
                focusRequest: focusRequest,
                onTap: { coord in
                    // Tapping the map (re)selects a raw pin at that point.
                    // The camera deliberately stays put — no focusRequest —
                    // so the rider can nudge to a neighbouring point while
                    // the card is up. Reverse-geocode in the background to
                    // upgrade the "Pin x, y" name to a real address.
                    selectRawPin(at: coord)
                },
                onRecenterVisibilityChange: { visible in
                    showRecenterButton = visible
                }
            )
            .ignoresSafeArea(edges: .horizontal)
            .onAppear {
                if locationToken == nil {
                    locationToken = status.locationService.start(mode: .mapping)
                }
            }
            .onDisappear {
                if let token = locationToken {
                    status.locationService.stop(token: token)
                    locationToken = nil
                }
            }

            VStack(spacing: 10) {
                searchPill
                QuickAccessTiles(
                    onPick: { fav in
                        // Favorite tap: select it AND recenter the camera
                        // on it (an explicit focus request).
                        selectFavorite(fav)
                    },
                    onFillSlot: { slot in
                        slotToFill = slot
                        showSearch = true
                    }
                )
                .environment(status.navigationStore)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 10)
            }
            .padding(.top, 6)

            // Recenter FAB (bottom-right) + the compact preview card
            // (bottom, full-width) share the bottom overlay region.
            VStack(spacing: 10) {
                Spacer()
                if showRecenterButton {
                    HStack {
                        Spacer()
                        recenterButton
                            .padding(.trailing, 14)
                    }
                }
                if let dest = selectedDestination {
                    DestinationPreviewCard(
                        destination: dest,
                        onCalculateRoutes: { d in
                            selectedDestination = nil
                            status.beginPlanning(to: d)
                        },
                        onAddToFavorites: { d in
                            favoriteEditorSeed = d
                            showFavoriteEditor = true
                        },
                        onClose: {
                            selectedDestination = nil
                        }
                    )
                    .environment(status.navigationStore)
                }
            }
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.2), value: selectedDestination)
            .animation(.easeInOut(duration: 0.2), value: showRecenterButton)
        }
    }

    /// Round "center on me" button, bottom-right. Issues an explicit
    /// focus request to the current GPS fix (the only thing that ever
    /// re-frames the user after the one-shot initial center).
    private var recenterButton: some View {
        Button {
            if let c = status.locationService.lastFix?.coordinate {
                focusRequest = MapFocusRequest(coordinate: c)
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Center on my location")
    }

    // MARK: - Home-map selection helpers

    /// Select a raw tapped point. Holds the pin synchronously, then
    /// reverse-geocodes in the background to give it a real name/address.
    private func selectRawPin(at coord: CLLocationCoordinate2D) {
        let dest = Destination.fromTap(coord)
        selectedDestination = dest
        Task { await upgradeTapName(dest.id, coord) }
    }

    /// Select a favorite and recenter the camera on it.
    private func selectFavorite(_ fav: Favorite) {
        selectedDestination = fav.asDestination
        focusRequest = MapFocusRequest(coordinate: fav.coordinate)
    }

    /// Best-effort reverse geocode for a tapped pin. Updates the live
    /// selection in place iff it's still the same pin. Silent on failure
    /// (the "Pin lat, lon" fallback stays).
    ///
    /// `@MainActor` because it mutates `selectedDestination` (`@State`)
    /// after the `await`; the geocoder suspension still frees the main
    /// thread while the network round-trip is in flight.
    @MainActor
    private func upgradeTapName(_ id: UUID, _ coord: CLLocationCoordinate2D) async {
        let geocoder = CLGeocoder()
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(loc).first else { return }
        let name = placemark.name ?? placemark.thoroughfare ?? "Dropped pin"
        let addr = [placemark.thoroughfare, placemark.locality].compactMap { $0 }.joined(separator: ", ")
        // Only apply if the selection is still this exact pin (the rider
        // may have tapped elsewhere or cleared the card meanwhile).
        guard selectedDestination?.id == id else { return }
        selectedDestination = Destination(id: id,
                                          name: name,
                                          addressLine: addr.isEmpty ? nil : addr,
                                          coordinate: coord)
    }

    /// The multi-stop planning UI: PlanningMapView (top) + waypoint list
    /// (bottom). Lives in .picking with the stream off.
    @ViewBuilder
    private func planningBody(plan: PlannedRoute) -> some View {
        VStack(spacing: 0) {
            PlanningMapView(
                plan: plan,
                onPickAlternative: { legIndex, optionIndex in
                    plan.setSelectedOption(legIndex: legIndex, optionIndex: optionIndex)
                },
                onAddWaypoint: { coord in
                    longPressCoord = coord
                    showLongPressDialog = true
                },
                onTapWaypoint: { _ in
                    // Tapping a pin currently just surfaces the list;
                    // remove/reorder happen there. Hook reserved for a
                    // future per-pin context menu.
                }
            )
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) { planningBanner }

            Divider()

            WaypointListView(
                plan: plan,
                onRecompute: { dirty in
                    Task { await status.recomputeDirtyLegs(dirty, in: plan) }
                },
                onAddStop: {
                    addingStopToPlan = true
                    showSearch = true
                },
                recomputingLegs: status.recomputingLegs
            )
            .frame(maxHeight: 260)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { status.cancelPlanning() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showRoutePreferences = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }

    @ViewBuilder
    private var planningBanner: some View {
        if !status.recomputingLegs.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Calculating routes…").font(.footnote)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
        } else if let err = status.planError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    private var searchPill: some View {
        Button { showSearch = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                Text("Where to?").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var navigatingBody: some View {
        NavigationHUD(isReconnecting: status.bikeLink.state == .reconnecting)
            .environment(status.activeNavigator)
            .onAppear {
                forwardFixesToNavigator()
            }
            .onChange(of: status.activeNavigator.hasArrived) { _, arrived in
                guard arrived else { return }
                // Rider confirmed: auto-dismiss the arrival card after a
                // few seconds (both hands busy on the bike).
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    finishArrival()
                }
            }
    }

    @ViewBuilder
    private var transitioningBody: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(status.activeNavigator.isNavigating ? "Starting navigation…" : "Stopping navigation…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Control button

    @ViewBuilder
    private var controlButton: some View {
        switch (mode, status.bikeLink.state) {
        case (.transitioning, _):
            HStack { ProgressView(); Text("Switching…") }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.gray.opacity(0.15))

        case (.navigating, _):
            Button(role: .destructive) { stopNavigation() } label: {
                Label("Stop navigation", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.red.opacity(0.15))
            }
            .buttonStyle(.plain)

        // Connection-in-progress takes precedence over the planning UI:
        // a rider who tapped "Connect to dash" from the plan screen must
        // still see progress + Cancel.
        case (.picking, .connecting), (.picking, .handshaking):
            connectingControl

        case (.picking, .reconnecting):
            reconnectingControl

        // Connect-first: the real "Start navigation" CTA only appears once
        // the dash is connected. Planning without a link falls through to
        // `connectControl` below — you must connect before you can start.
        case (.picking, .connected) where isPlanning:
            startPlanButton

        case (.picking, .connected):
            connectedIdleControl

        case (.picking, .idle), (.picking, .error):
            connectControl
        }
    }

    /// "Connect to dash" CTA — shown while idle/errored. When a plan is
    /// already laid out, tapping this arms `pendingAutoStart`: the rider
    /// has signalled intent to ride, so navigation auto-starts the moment
    /// the link reaches `.connected` (no second tap on "Start").
    @ViewBuilder
    private var connectControl: some View {
        Button {
            if isPlanning { pendingAutoStart = true }
            status.bikeLink.connect()
        } label: {
            Label(isPlanning ? "Connect & start navigation" : "Connect to dash",
                  systemImage: "antenna.radiowaves.left.and.right")
                .frame(maxWidth: .infinity).padding()
                .background(Color.accentColor.opacity(0.15))
        }
        .buttonStyle(.plain)
    }

    /// Connecting / handshaking progress + Cancel. When auto-start is
    /// armed the caption says so, so the rider knows navigation will kick
    /// off by itself the moment the handshake completes.
    @ViewBuilder
    private var connectingControl: some View {
        let base = status.bikeLink.state == .connecting ? "Connecting…" : "Handshaking…"
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                Text(pendingAutoStart ? "\(base) navigation will start automatically" : base)
            }
            .frame(maxWidth: .infinity).padding()
            .background(Color.orange.opacity(0.15))

            Button(role: .destructive) {
                pendingAutoStart = false
                status.bikeLink.disconnect()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
    }

    /// Auto-reconnect progress + Cancel (idle drop, not mid-navigation).
    @ViewBuilder
    private var reconnectingControl: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                Text("Reconnecting to dash…")
            }
            .frame(maxWidth: .infinity).padding()
            .background(Color.yellow.opacity(0.15))

            Button(role: .destructive) { status.bikeLink.disconnect() } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
    }

    /// Connected but idle (no plan yet) — prompt to pick + Disconnect.
    @ViewBuilder
    private var connectedIdleControl: some View {
        VStack(spacing: 6) {
            Text("Dash connected — pick a destination above")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.12))

            Button(role: .destructive) { status.bikeLink.disconnect() } label: {
                Text("Disconnect")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var startPlanButton: some View {
        let plan = status.plannedRoute
        let ready = plan?.isComputed ?? false
        Button {
            if let plan, ready { startNavigation(plan: plan) }
        } label: {
            Label(ready ? "Start navigation" : "Calculating route…",
                  systemImage: ready ? "play.circle.fill" : "hourglass")
                .frame(maxWidth: .infinity).padding()
                .background((ready ? Color.red : Color.gray).opacity(0.15))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
    }

    // MARK: - Destination pick routing

    /// Route a destination picked in the search sheet to the right
    /// place: a quick-access slot, an add-to-plan, or a fresh preview.
    private func handlePickedDestination(_ dest: Destination) {
        if let slot = slotToFill {
            status.navigationStore.setQuickAccess(slot, from: dest)
            slotToFill = nil
            return
        }
        if addingStopToPlan, let plan = status.plannedRoute {
            addingStopToPlan = false
            let wp = Waypoint.from(destination: dest)
            let dirty = plan.insertBeforeDestination(wp)
            Task { await status.recomputeDirtyLegs(dirty, in: plan) }
            return
        }
        // Default: select on the home map (pin + compact card) and
        // recenter the camera on the picked point.
        selectedDestination = dest
        focusRequest = MapFocusRequest(coordinate: dest.coordinate)
    }

    /// Commit a long-pressed coordinate as either a via-stop or the new
    /// destination of the active plan.
    private func commitLongPress(asDestination: Bool) {
        guard let coord = longPressCoord, let plan = status.plannedRoute else {
            longPressCoord = nil
            return
        }
        longPressCoord = nil
        let wp = Waypoint(name: String(format: "Pin %.4f, %.4f", coord.latitude, coord.longitude),
                          addressLine: nil,
                          coordinate: coord)
        let dirty: Set<Int>
        if asDestination {
            dirty = plan.appendWaypoint(wp)
        } else {
            dirty = plan.insertBeforeDestination(wp)
        }
        Task {
            await reverseGeocodeAndName(wp.id, coord, in: plan)
            await status.recomputeDirtyLegs(dirty, in: plan)
        }
    }

    /// Best-effort reverse geocode to give a long-pressed pin a real
    /// name. Failure is silent — the "Pin lat, lon" fallback stays.
    private func reverseGeocodeAndName(_ id: UUID, _ coord: CLLocationCoordinate2D, in plan: PlannedRoute) async {
        let geocoder = CLGeocoder()
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        if let placemark = try? await geocoder.reverseGeocodeLocation(loc).first {
            let name = placemark.name ?? placemark.thoroughfare ?? "Stop"
            let addr = [placemark.thoroughfare, placemark.locality].compactMap { $0 }.joined(separator: ", ")
            plan.renameWaypoint(id: id, name: name, addressLine: addr.isEmpty ? nil : addr)
        }
    }

    // MARK: - Navigation transitions

    /// Push the route geometry into the renderer + bake fresh tiles.
    /// Called both at navigation start AND on every reroute / leg
    /// advance (via the `onActiveRouteChanged` callback).
    private func installRouteGeometry(_ route: MKRoute) async {
        status.mapViewSource.setRoutePolyline(route.polyline)
        // Bake in the renderer's current palette. `currentStyle` is set by
        // the Auto resolver / manual picker before navigation starts (see
        // AppStatus), so the ride opens in the right Light/Dark style.
        status.mapViewSource.setCurrentRoute(route)
        let cache = RouteTileCache(style: status.mapViewSource.currentStyle)
        prerenderProgress = 0
        prerenderActive = true
        await cache.prerender(route: route) { p in
            prerenderProgress = p
        }
        status.mapViewSource.setTileCache(cache)
        prerenderActive = false
    }

    /// Wire the shared route-changed hook (covers initial bake, reroute,
    /// AND multi-stop leg advance — all funnel through here).
    private func installRouteChangedHook() {
        status.activeNavigator.onActiveRouteChanged = { [weak status] newRoute in
            guard let status else { return }
            // (1) Polyline first — pure CPU CGContext path, BG/lock safe.
            status.mapViewSource.setRoutePolyline(newRoute.polyline)
            // (2) Tile re-bake — scheduled so it runs on the next
            //     foreground tick (MKMapSnapshotter is GPU-bound).
            status.mapViewSource.scheduleTileCacheRebuild(for: newRoute)
        }
    }

    /// Start navigation from a multi-stop plan. Bakes the first leg's
    /// selected option; subsequent legs re-bake via the changed hook.
    private func startNavigation(plan: PlannedRoute) {
        guard plan.isComputed, let firstLeg = plan.legs.first?.selected?.route else { return }
        // Connect-first invariant: navigation is projection onto the dash,
        // so starting it with no link is meaningless. The UI only shows
        // "Start navigation" while `.connected`, but guard here too in case
        // the link dropped in the gap between render and tap.
        guard status.bikeLink.state == .connected else {
            status.bikeLink.connect()
            return
        }
        transitioning = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            installRouteChangedHook()
            // Resolve Light/Dark/Auto for the current position+time before
            // the first bake, so the ride opens in the right palette.
            status.primeMapStyleForStart()
            await installRouteGeometry(firstLeg)
            await status.activeNavigator.start(plan: plan)
            // Planning UI is consumed — drop it so picking returns to
            // browsing after navigation ends.
            status.plannedRoute = nil
            if !status.isStreaming {
                status.startStreaming()
            }
            transitioning = false
        }
    }

    /// Legacy single-route entry point removed: navigation now always
    /// starts from a PlannedRoute (the n=2 case covers a single
    /// destination). Reroute does not go through here — it's wired via
    /// `AppStatus.activeNavigator.onRerouteRequested`.

    private func stopNavigation() {
        status.activeNavigator.stop()
        status.activeNavigator.onActiveRouteChanged = nil
        if status.isStreaming {
            status.stopStreaming()
        }
        // Drop the tile cache + polyline so the next route gets a fresh build.
        status.mapViewSource.setTileCache(nil)
        status.mapViewSource.setRoutePolyline(nil)
        status.stagedDestination = nil
        status.plannedRoute = nil
        selectedDestination = nil
        transitioning = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            transitioning = false
        }
    }

    /// Finalize an arrival. `AppStatus.onArrived` already tore down the
    /// stream + route artefacts the moment we arrived (so the dash left
    /// projection promptly); here we only flip the navigator out of its
    /// `hasArrived` display state and slide back to the picker. Calling
    /// `stop()` sets `isNavigating = false`, so `mode` returns `.picking`.
    private func finishArrival() {
        status.activeNavigator.stop()
        selectedDestination = nil
        transitioning = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            transitioning = false
        }
    }

    /// Forward LocationService updates into ActiveNavigator while
    /// navigation is active.
    private func forwardFixesToNavigator() {
        Task { @MainActor in
            withObservationTracking {
                _ = status.locationService.lastFix
            } onChange: {
                Task { @MainActor in
                    if let fix = status.locationService.lastFix {
                        status.navigatorIngest(fix)
                    }
                    if status.activeNavigator.isNavigating {
                        forwardFixesToNavigator()
                    }
                }
            }
        }
    }
}

// MARK: - Status banner

private struct StatusBanner: View {
    let state: BikeConnectionState
    let ssid: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.subheadline.weight(.medium))
            Spacer()
            if let ssid {
                Text(ssid).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var color: Color {
        switch state {
        case .disconnected: .gray
        case .wifiJoining:  .yellow
        case .handshaking:  .orange
        case .reconnecting: .yellow
        case .connected:    .blue
        case .streaming:    .green
        case .error:        .red
        }
    }

    private var label: String {
        switch state {
        case .disconnected: "Not connected"
        case .wifiJoining:  "Join the Tripper Wi-Fi…"
        case .handshaking:  "Handshaking with dash…"
        case .reconnecting: "Reconnecting to dash…"
        case .connected:    "Connected — idle"
        case .streaming:    "Streaming"
        case .error:        "Error — see settings"
        }
    }
}

#Preview {
    NavigationStack { MapPickerView() }
        .environment(AppStatus())
}
