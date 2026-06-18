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
//    • .navigating  — NavigationHUD on phone (ETA/turn/distance),
//                      MapSnapshotSource pushing frames to dash.
//    • .transitioning — brief blank state (~500 ms) between the above
//                      so Apple Maps' shared GPU pool drains before we
//                      swap MKMapView <-> MKMapSnapshotter.
//
//  See `docs/PHASE_7_NAVIGATION_PLAN.md` for the full spec.
//

import CoreLocation
import MapKit
import SwiftUI

struct MapPickerView: View {
    @Environment(AppStatus.self) private var status
    @Environment(\.scenePhase) private var scenePhase

    @State private var locationToken: UUID?
    @State private var transitioning = false
    @State private var showDiagnostics = false

    // Sheet flags
    @State private var showSearch = false
    @State private var showFavoriteEditor = false
    @State private var favoriteEditorSeed: Destination?
    @State private var previewDestination: Destination?
    @State private var showRoutePreview = false
    /// When set, the next destination picked in DestinationSearchSheet
    /// is committed straight into this quick-access slot instead of
    /// going through the preview/route flow.
    @State private var slotToFill: QuickAccessSlot?

    /// Pin dropped on the map (via long-press / tap) before user chose
    /// to either save it or calculate a route.
    @State private var droppedPin: CLLocationCoordinate2D?

    private enum DisplayMode { case picking, navigating, transitioning }
    private var mode: DisplayMode {
        if transitioning { return .transitioning }
        return status.activeNavigator.isNavigating ? .navigating : .picking
    }

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
            ToolbarItem(placement: .topBarTrailing) {
                Button { showDiagnostics = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Diagnostics")
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack { StreamingView() }
                .environment(status)
        }
        .sheet(isPresented: $showSearch) {
            DestinationSearchSheet { dest in
                if let slot = slotToFill {
                    // Empty-tile path: drop the result straight into
                    // the pinned slot, no preview, no editor.
                    store.setQuickAccess(slot, from: dest)
                    slotToFill = nil
                } else {
                    droppedPin = dest.coordinate
                    previewDestination = dest
                }
            }
            .environment(status)
            .environment(status.navigationStore)
        }
        .sheet(isPresented: $showFavoriteEditor) {
            FavoriteEditorSheet(existing: nil, seed: favoriteEditorSeed)
                .environment(status.navigationStore)
        }
        .sheet(item: $previewDestination) { dest in
            DestinationPreviewSheet(destination: dest) { d in
                status.stagedDestination = d
                showRoutePreview = true
            }
            .environment(status.navigationStore)
        }
        .sheet(isPresented: $showRoutePreview) {
            if let dest = status.stagedDestination {
                RoutePreviewSheet(destination: dest) { route, finalDest in
                    startNavigation(route: route, destination: finalDest)
                }
                .environment(status)
                .environment(status.navigationStore)
            }
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
    }

    // MARK: - Phase bodies

    @ViewBuilder
    private var pickingBody: some View {
        ZStack(alignment: .top) {
            InteractiveMapView(
                coordinate: status.locationService.lastFix?.coordinate,
                followsUser: droppedPin == nil,
                destinationPin: droppedPin,
                onTapPin: { coord in
                    let pin = Destination(name: "Dropped pin",
                                          addressLine: nil,
                                          coordinate: coord)
                    droppedPin = coord
                    previewDestination = pin
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
                        let dest = Destination(name: fav.name,
                                               addressLine: fav.addressLine,
                                               coordinate: fav.coordinate)
                        droppedPin = fav.coordinate
                        previewDestination = dest
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
        NavigationHUD(onStop: stopNavigation)
            .environment(status.activeNavigator)
            .padding()
            .onAppear {
                // Pipe GPS into the navigator while it's active.
                // LocationService is observable; subscribe lazily.
                forwardFixesToNavigator()
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

        case (.picking, .idle), (.picking, .error):
            Button { status.bikeLink.connect() } label: {
                Label("Connect to dash", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.accentColor.opacity(0.15))
            }
            .buttonStyle(.plain)

        case (.picking, .connecting), (.picking, .handshaking):
            VStack(spacing: 8) {
                HStack {
                    ProgressView()
                    Text(status.bikeLink.state == .connecting ? "Connecting…" : "Handshaking…")
                }
                .frame(maxWidth: .infinity).padding()
                .background(Color.orange.opacity(0.15))

                Button(role: .destructive) { status.bikeLink.disconnect() } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }

        case (.picking, .connected):
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
    }

    // MARK: - Navigation transitions

    private func startNavigation(route: MKRoute, destination: Destination) {
        transitioning = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            status.activeNavigator.start(route: route, destination: destination)
            // Stream only if dash is connected. Pre-flight mode (no
            // dash) just runs NavigationHUD on the phone.
            if status.bikeLink.state == .connected, !status.isStreaming {
                status.startStreaming()
            }
            transitioning = false
        }
    }

    private func stopNavigation() {
        status.activeNavigator.stop()
        if status.isStreaming {
            status.stopStreaming()
        }
        status.stagedDestination = nil
        droppedPin = nil
        transitioning = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            transitioning = false
        }
    }

    /// Forward LocationService updates into ActiveNavigator while
    /// navigation is active. The navigator does on-route detection,
    /// step advance, and reroute triggering.
    private func forwardFixesToNavigator() {
        Task { @MainActor in
            // Observation tracking pattern: register, wait for change,
            // re-register. Loop terminates when nav stops because the
            // navigating phase unmounts this view body.
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
        case .connected:    "Connected — idle"
        case .streaming:    "Streaming"
        case .error:        "Error — see diagnostics"
        }
    }
}

#Preview {
    NavigationStack { MapPickerView() }
        .environment(AppStatus())
}
