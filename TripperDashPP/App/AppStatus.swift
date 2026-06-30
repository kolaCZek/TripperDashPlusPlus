//
//  AppStatus.swift
//  TripperDashPP
//
//  Shared application state — observable, injected as @Environment.
//
//  Phase 1: minimal placeholders so the UI compiles. Real implementations
//  arrive incrementally in Phases 3 (BikeLink → connectionState),
//  4 (encoder → fps / kbps), and 6 (Nav → currentDestination, route).
//

import CoreLocation
import Foundation
import MapKit
import Observation
import UIKit

/// High-level connection lifecycle as seen by the UI. Mirrors the
/// `BikeLink` state machine that lands in Phase 3.
enum BikeConnectionState: String, Sendable {
    case disconnected
    case wifiJoining       // Waiting for the user to join the Tripper AP
    case handshaking       // RSA exchange in flight
    case reconnecting      // Link dropped after being connected; retrying
    case connected         // Heartbeats flowing, no video yet
    case streaming         // RTP video in flight
    case error             // See AppStatus.lastError
}

/// Live counters from the encoder + RTP packetizer (Phase 4).
struct StreamMetrics: Sendable, Equatable {
    var encodedFps: Double = 0
    var kbpsOut: Double = 0
    var packetsSent: UInt64 = 0
    var packetsDropped: UInt64 = 0
    var nalsEmitted: UInt64 = 0
    var idrCount: UInt64 = 0
    var lastError: String?

    static let zero = StreamMetrics()
}

// Phase 7: `Destination` lives in Navigation/Models/Destination.swift —
// the old placeholder here was removed when the real model arrived.

@MainActor
@Observable
final class AppStatus {

    // MARK: - Connection

    /// Live K1G control-plane orchestrator. Phase 3+ reads `bikeLink.state`
    /// and mirrors it into `connectionState` for the UI.
    let bikeLink: BikeLink = BikeLink()

    /// Computed view of the link state in UI-friendly terms.
    var connectionState: BikeConnectionState {
        if streamer?.state == .running { return .streaming }
        switch bikeLink.state {
        case .idle:         return .disconnected
        case .connecting:   return .wifiJoining
        case .handshaking:  return .handshaking
        case .reconnecting: return .reconnecting
        case .connected:    return .connected
        case .error:        return .error
        }
    }

    var bikeSsid: String? { bikeLink.ssid }
    var lastError: String? { bikeLink.lastError ?? metrics.lastError }

    // MARK: - Streaming

    var metrics: StreamMetrics = .zero
    private(set) var streamer: RtpStreamer?
    var isStreaming: Bool { streamer?.state == .running }

    // MARK: - Background keep-alive (Phase 6)

    /// User-controlled: when true, we hold a CoreLocation Always +
    /// silent-audio wakelock while streaming so the iPhone screen can
    /// lock without iOS suspending the app (which kills the
    /// VTCompressionSession with `kVTInvalidSessionErr` / -12903).
    /// Defaults to ON — the whole point of Phase 6 is that this is the
    /// supported default mode of operation.
    var keepAwakeWhileStreaming: Bool = true {
        didSet { applyKeepAwake() }
    }

    /// Reflects whether the location + audio wakelocks are active right
    /// now. Used by the UI to show a "Background mode active" badge.
    var backgroundKeepAliveActive: Bool {
        wakelockToken != nil || audioKeeper.isRunning
    }

    /// Shared CLLocationManager: serves the wakelock, the Phase 5 map
    /// source, and (Phase 7+) the nav engine. Single owner avoids racing
    /// two managers for the same authorization + indicator pill.
    let locationService = LocationService()

    private let audioKeeper = SilentAudioKeeper()
    private var wakelockToken: UUID?

    init() {
        // Wire BikeLink → DashNavSettings so the wire-encoding helpers
        // (units, decimal separator, clock format, bottom-line mutex)
        // are reachable from inside the connection flow. Both objects
        // exist as inline stored properties, so this is the first
        // moment we can connect them.
        bikeLink.settings = dashNavSettings

        // Watch `bikeLink.state` so the wakelock follows the link, not
        // just the streamer. When the bike disconnects mid-ride, we
        // tear the keepers (and the now-pointless streamer) down within
        // one observation tick — no point burning battery and shoving
        // UDP into a black hole.
        observeBikeLink()
        wireNavigation()
        wireCallObserver()
        wireDeviceTelemetry()
        wireMessageFeed()
        wireRideAlerts()
    }

    /// Re-registers itself on every state change — that's the standard
    /// iOS 17 `withObservationTracking` idiom for "watch this property
    /// continuously", since the closure fires exactly once per trigger.
    private func observeBikeLink() {
        withObservationTracking {
            _ = bikeLink.state
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let state = self.bikeLink.state
                if self.isStreaming && state != .connected {
                    // Link left .connected (dropped → reconnecting) while
                    // streaming — kill the RTP pipeline; RtpStreamer doesn't
                    // watch the link itself and would keep encoding into the
                    // void. The stream re-arms below once we're back.
                    self.stopStreaming()
                } else if state == .connected
                            && self.activeNavigator.isNavigating
                            && !self.isStreaming {
                    // Reconnected mid-ride → bring the dash projection back
                    // automatically so navigation reappears without the
                    // rider touching the phone (e.g. walked back from the
                    // petrol-station till). The tile cache survived the drop
                    // (never released on stop), so there's no re-bake.
                    self.startStreaming()
                } else {
                    self.applyKeepAwake()
                }
                self.observeBikeLink()
            }
        }
    }

    /// Strong reference to the live MKMapView source. Created lazily
    /// on first access. Lives for the duration of the app session so
    /// the FG-baked tile cache and the location subscription persist
    /// across start/stop streaming cycles.
    @ObservationIgnored private var _mapViewSource: MapViewSource?
    var mapViewSource: MapViewSource {
        if let s = _mapViewSource { return s }
        let s = MapViewSource(locationService: locationService,
                              activeNavigator: activeNavigator)
        _mapViewSource = s
        return s
    }
    /// Spin up the RTP pipeline pointed at the currently-connected dash.
    /// No-op if the link isn't connected yet.
    func startStreaming() {
        guard streamer == nil, let host = bikeLink.dashHost else { return }

        let source = mapViewSource   // shared instance, lazily created
        let s = RtpStreamer(bikeHost: host, source: source)
        s.bikeLink = bikeLink
        s.onMetrics = { [weak self] m in
            guard let self else { return }
            self.metrics = StreamMetrics(
                encodedFps: m.encodedFps,
                kbpsOut: m.kbpsOut,
                packetsSent: m.packetsSent,
                packetsDropped: m.packetsDropped,
                nalsEmitted: m.nalsEmitted,
                idrCount: m.idrCount,
                lastError: m.lastError
            )
        }
        streamer = s
        // Kick the dash into nav projection BEFORE starting the RTP
        // stream — without q3c.z2 + q3c.q the dash never switches off
        // the home widgets and treats UDP/5000 as noise.
        let link = bikeLink
        Task { await link.sendNavStart() }
        s.start()
        // Latch the "projection on" flag shortly after start so the
        // dash has the q3c.w hint while the first frames are landing.
        // 250 ms gives the encoder time to emit its first NAL and the
        // RTP UDP connection to reach .ready.
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await link.sendProjectionOn()
        }

        // Regular 1 Hz active-nav pump — feeds maneuver glyph + distance
        // + road name overlay onto the streamed map frames and sends
        // the K1G active-nav TLV bursts to the dash bubble.
        let loop = ActiveNavLoop(
            bikeLink: bikeLink,
            navigator: activeNavigator,
            mapSource: mapViewSource,
            settings: dashNavSettings
        )
        loop.start()
        activeNavLoop = loop
        applyKeepAwake()
    }

    func stopStreaming() {
        // Tell the dash to leave nav projection BEFORE we yank the
        // encoder — it expects (h, x) before the frames stop, otherwise
        // it sometimes wedges on the last bitmap until the next reboot.
        let link = bikeLink
        activeNavLoop?.stop()
        activeNavLoop = nil
        Task { await link.sendNavStop() }
        streamer?.stop()
        streamer = nil
        // mapViewSource is intentionally NOT released — its tile cache
        // + location subscription should survive stop/start cycles so
        // the next ride doesn't have to re-bake.
        metrics = .zero
        applyKeepAwake()
    }

    /// Re-evaluate whether the wakelocks should be active. Called any
    /// time `keepAwakeWhileStreaming` toggles, the streaming state
    /// changes, or `bikeLink.state` flips. The keepers only burn
    /// battery while ALL three preconditions hold:
    ///   1. user wants screen-off survival,
    ///   2. we're actively streaming,
    ///   3. the bike link is up — otherwise we'd be shoving UDP into a
    ///      black hole and holding the app alive for no reason.
    private func applyKeepAwake() {
        let shouldRun = keepAwakeWhileStreaming
            && isStreaming
            && bikeLink.state == .connected
        if shouldRun {
            if wakelockToken == nil {
                wakelockToken = locationService.start(mode: .wakelock)
            }
            audioKeeper.start()
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            if let token = wakelockToken {
                locationService.stop(token: token)
                wakelockToken = nil
            }
            audioKeeper.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Navigation (Phase 7)

    /// Persisted favorites + route preferences. UI binds the search
    /// sheet / favorites tiles / preferences panel to this directly.
    let navigationStore = NavigationStore()

    /// Persisted library of imported GPX routes (feat/saved-routes-gpx).
    /// The "Saved routes" sheet binds to this; navigating one builds a
    /// fresh `PlannedRoute` via `beginPlanningFromSavedRoute`.
    let savedRoutesStore = SavedRoutesStore()

    /// One-shot signal from the saved-route detail screen asking the
    /// picker to tear down the (possibly multi-level) Saved Routes sheet
    /// after a route was staged for navigation, so the planning UI is
    /// visible underneath. The picker observes this, dismisses, and
    /// resets it to false.
    var requestDismissSavedRoutes = false

    /// Active turn-by-turn session. `start(route:destination:)` flips
    /// `isNavigating` true; stop() resets. Reroute requests are wired
    /// through `onRerouteRequested` in init below.
    let activeNavigator = ActiveNavigator()

    /// User-facing dash display preferences (units, decimal separator,
    /// clock format, ETA-vs-distance bottom row). Persisted, observable.
    let dashNavSettings = DashNavSettings()

    /// User-facing map appearance preference (Light / Dark / Auto).
    /// Persisted, observable. `MapStyleResolver` maps this + the live GPS
    /// fix + clock onto `effectiveMapStyle`.
    let mapStyleSettings = MapStyleSettings()

    /// The concrete palette currently driving the renderer. Mirrors
    /// `mapViewSource.currentStyle`; kept here so the settings UI can show
    /// "Currently: Dark" under the Auto picker.
    private(set) var effectiveMapStyle: MapStyle = .light

    /// When the effective palette last changed — feeds the resolver's
    /// dwell lock so Auto can't strobe.
    @ObservationIgnored private var lastStyleSwitchAt: Date?

    /// Throttle for the solar re-evaluation: the sun moves ~0.25°/min, so
    /// re-checking once a minute is ample and keeps us off the per-fix
    /// hot path.
    @ObservationIgnored private var lastStyleEvalAt: Date?

    /// Active-nav 1 Hz pump. Created on demand when streaming starts
    /// (we need a live `mapSource` and `bikeLink.connected` first). Held
    /// here so we can stop it from `stopStreaming()`.
    @ObservationIgnored private var activeNavLoop: ActiveNavLoop?

    /// One-shot route calculator used by the route preview sheet and
    /// by the navigator's reroute callback.
    let routingService = RoutingService()

    /// Currently-staged destination (chosen but not yet navigating).
    /// The route preview sheet keys off this; clearing it dismisses
    /// the preview.
    var stagedDestination: Destination? = nil

    // MARK: - Multi-stop planning (feat/route-waypoints)

    /// The live multi-stop plan being built in the picker's planning
    /// mode. nil when not planning. The PlanningMapView + WaypointList
    /// both bind to this same instance; mutating it redraws both.
    var plannedRoute: PlannedRoute? = nil

    /// Leg indices currently being recomputed — surfaced to the
    /// waypoint list so it can show per-row spinners.
    var recomputingLegs: Set<Int> = []

    /// Begin planning from a single destination (the n=2 case): origin
    /// = current location, destination = `dest`. Builds the plan and
    /// kicks off the initial leg computation. Returns immediately; the
    /// plan fills in asynchronously.
    func beginPlanning(to dest: Destination) {
        let originCoord = locationService.lastFix?.coordinate
            ?? CLLocationCoordinate2D(latitude: dest.coordinate.latitude,
                                      longitude: dest.coordinate.longitude)
        let origin = Waypoint.currentLocation(originCoord)
        let destination = Waypoint.from(destination: dest)
        let plan = PlannedRoute(origin: origin, destination: destination)
        plannedRoute = plan
        Task { await recomputeDirtyLegs(plan.allLegIndices, in: plan) }
    }

    /// Begin planning from a saved (imported) route. Builds a
    /// `PlannedRoute` whose origin is the live GPS fix and whose via /
    /// destination waypoints are the saved route's points (truncated to
    /// the chosen start mode), then kicks off leg computation.
    ///
    /// This produces the SAME `PlannedRoute` shape the manual planner
    /// makes, so everything downstream — the connect-first "Start
    /// navigation" CTA, auto-start on connect, per-leg recompute,
    /// reroute, arrival teardown, and the dash maneuver-glyph pump — is
    /// reused with zero changes. A saved route is just a pre-seeded plan.
    ///
    /// `.fromNearest` drops the leading points before `nearestIndex` so
    /// the rider joins the route at the closest point; `.fromFirst` keeps
    /// the whole route. The origin is ALWAYS the live location (so
    /// MKDirections has a real source and the first leg routes the rider
    /// onto the saved geometry).
    func beginPlanningFromSavedRoute(_ route: SavedRoute,
                                     mode: RouteStartMode,
                                     nearestIndex: Int) {
        let navPoints = RouteStartPlanner.navigablePoints(route.points,
                                                          mode: mode,
                                                          nearestIndex: nearestIndex)
        guard navPoints.count >= 1 else { return }

        let originCoord = locationService.lastFix?.coordinate
            ?? navPoints[0].coordinate
        let origin = Waypoint.currentLocation(originCoord)

        // Map saved RoutePoints → Waypoints. First/last get friendly
        // fallback names; named GPX points keep their label.
        let routeWaypoints: [Waypoint] = navPoints.enumerated().map { idx, p in
            let fallback = idx == navPoints.count - 1 ? "Route end"
                         : (route.kind == .waypoints ? "Stop \(idx + 1)" : "Via \(idx + 1)")
            return Waypoint(name: p.name ?? fallback,
                            addressLine: nil,
                            coordinate: p.coordinate,
                            isCurrentLocation: false)
        }

        let plan = PlannedRoute(waypoints: [origin] + routeWaypoints)
        plannedRoute = plan
        Task { await recomputeDirtyLegs(plan.allLegIndices, in: plan) }
    }

    /// Recompute the given dirty legs of `plan` (defaults to the live
    /// `plannedRoute`). Tracks `recomputingLegs` for the UI spinner and
    /// surfaces failures into `planError`.
    func recomputeDirtyLegs(_ dirty: Set<Int>, in plan: PlannedRoute? = nil) async {
        guard let plan = plan ?? plannedRoute, !dirty.isEmpty else { return }
        recomputingLegs.formUnion(dirty)
        defer { recomputingLegs.subtract(dirty) }
        do {
            try await routingService.recompute(
                plan,
                dirtyLegIndices: dirty,
                preferences: navigationStore.routePreferences
            )
            planError = nil
        } catch {
            planError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Last planning/recompute error, surfaced in the planning UI.
    var planError: String? = nil

    /// Exit planning mode and drop the staged plan.
    func cancelPlanning() {
        plannedRoute = nil
        recomputingLegs = []
        planError = nil
    }

    /// Wire ActiveNavigator's reroute callback to our RoutingService
    /// and NavigationStore preferences. Done lazily after init.
    private func wireNavigation() {
        activeNavigator.onRerouteRequested = { [weak self] origin, dest in
            guard let self else { return nil }
            do {
                let opts = try await self.routingService.calculate(
                    from: origin,
                    to: dest,
                    preferences: self.navigationStore.routePreferences
                )
                return opts.first?.route
            } catch {
                return nil
            }
        }

        // Final-destination arrival: tear the stream + route artefacts
        // down the instant we arrive (so the dash leaves projection
        // promptly), but DON'T call activeNavigator.stop() here — the HUD
        // needs `hasArrived == true` for the dismiss beat. MapPickerView
        // calls stop() after its auto-dismiss delay.
        activeNavigator.onArrived = { [weak self] in
            guard let self else { return }
            if self.isStreaming { self.stopStreaming() }
            self.mapViewSource.setTileCache(nil)
            self.mapViewSource.setRoutePolyline(nil)
            self.activeNavigator.onActiveRouteChanged = nil
            self.stagedDestination = nil
            self.plannedRoute = nil
        }
    }

    // MARK: - Call-state observer (incoming-call card on the dash)

    /// Owns the CallKit bridge for the app's lifetime. Held here (not a
    /// local) so the `CXCallObserver` inside keeps its delegate alive — a
    /// dropped observer silently stops delivering call events.
    @ObservationIgnored private var callObserver: CallStateObserver?

    // MARK: - Ride alerts (weather pill + speed cameras)

    /// Keyless weather provider for the dash weather pill. Owned for the
    /// app's lifetime so its throttle state + URLSession persist across
    /// start/stop streaming. Polled (throttled) from `navigatorIngest`
    /// using the rider's live position + route-ahead look-ahead point.
    @ObservationIgnored private let weatherService = WeatherAlertService()

    /// Guards against overlapping speed-camera prefetches when several
    /// route installs land close together (start + immediate reroute).
    @ObservationIgnored private var speedCameraPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var speedLimitPrefetchTask: Task<Void, Never>?

    /// Start observing system call state and forwarding it to the dash.
    /// Mirrors `km3.u()` in the stock app: call changes become K1G
    /// `05 21`/`05 4D` bursts over the existing nav control plane. No-op
    /// when not connected (handled inside `BikeLink.sendCallState`), so it's
    /// safe to start once at launch and leave running for the whole session.
    private func wireCallObserver() {
        let obs = CallStateObserver(link: bikeLink)
        callObserver = obs
        obs.start()
        observeCallStateToggle()
    }

    /// Watch the `callStateEnabled` preference so that turning the card OFF
    /// while one is lit clears it on the dash immediately. We push a `.none`
    /// (which `BikeLink.sendCallState` lets through even when disabled) on
    /// the OFF transition. Turning it back ON does nothing here — the next
    /// real CallKit event re-syncs the live state. Same self-re-registering
    /// `withObservationTracking` idiom as `observeBikeLink()`.
    private func observeCallStateToggle() {
        withObservationTracking {
            _ = dashNavSettings.callStateEnabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.dashNavSettings.callStateEnabled == false {
                    await self.bikeLink.sendCallState(.none)
                }
                self.observeCallStateToggle()
            }
        }
    }

    // MARK: - Device telemetry (phone status → dash heartbeat)

    /// Owns the live phone-status provider for the app's lifetime. Held
    /// here (not a local) so its battery-notification observers and the
    /// `NWPathMonitor` inside keep running — a dropped provider silently
    /// stops sampling and the heartbeat would freeze on stale values.
    @ObservationIgnored private var deviceTelemetry: DeviceTelemetry?

    /// Stand up the phone-status provider and hand `BikeLink` a `@Sendable`
    /// snapshot closure it can call once per heartbeat tick. Mirrors the
    /// Begin streaming the phone's own status into the dash heartbeat,
    /// mirroring the stock app's `REForeGroundService` 1 Hz status timer
    /// (battery / GPS / charging / signal). Always on — the stock app
    /// reports unconditionally and so do we; there's no user setting.
    /// Safe to call once at launch: the provider runs for the whole session
    /// and `BikeLink` only consults it while the heartbeat loop is alive
    /// (i.e. while connected).
    private func wireDeviceTelemetry() {
        let tele = DeviceTelemetry(location: locationService)
        deviceTelemetry = tele
        tele.start()
        // `snapshot()` is main-actor isolated; the closure stays valid for
        // the whole session.
        bikeLink.telemetryProvider = { @Sendable [weak tele] in
            guard let tele else { return .placeholder }
            return await tele.snapshot()
        }
    }

    // MARK: - Incoming-message feed (message cards on the dash)

    /// Owns the rolling 5-deep message list for the app's lifetime. Held
    /// here (not a local) so observers / the source feed stay attached.
    /// `@ObservationIgnored` because the UI doesn't render it directly — the
    /// dash does, via `BikeLink.sendMessageNotification`.
    @ObservationIgnored private(set) var messageFeed: MessageFeed = MessageFeed()

    /// Stand up the message feed. There is no automatic iOS source for
    /// arbitrary incoming SMS/RCS (unlike Android's `SMS_RECEIVED`), so this
    /// only initialises the model + toggle observer; actual messages arrive
    /// via `ingestMessage(...)` from whatever source the app wires up later
    /// (its own push Notification-Service-Extension, or a user/test entry).
    private func wireMessageFeed() {
        observeMessageNotifyToggle()
    }

    /// Push one incoming message to the dash: record it in the rolling feed,
    /// then send the whole list as the OEM `km3.z()` burst. No-op on the
    /// wire when the toggle is off or the link is down (both handled inside
    /// `BikeLink.sendMessageNotification`), but we still keep the local feed
    /// up to date so re-enabling / reconnecting can replay the latest cards.
    func ingestMessage(_ message: MessageNotification) {
        let snapshot = messageFeed.push(message)
        let unread = messageFeed.unreadCount
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bikeLink.sendMessageNotification(snapshot, unreadCount: unread)
        }
    }

    /// Watch `messageNotifyEnabled`: when the rider turns message cards OFF
    /// we clear the rolling feed so a later re-enable doesn't replay stale
    /// cards, and (best-effort) zero the dash's unread count. The dash has no
    /// explicit "clear all messages" opcode, so turning OFF simply stops new
    /// pushes; the existing cards age out on the dash side. Same
    /// self-re-registering `withObservationTracking` idiom as the others.
    private func observeMessageNotifyToggle() {
        withObservationTracking {
            _ = dashNavSettings.messageNotifyEnabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.dashNavSettings.messageNotifyEnabled == false {
                    self.messageFeed.clear()
                }
                self.observeMessageNotifyToggle()
            }
        }
    }

    /// Forward GPS fixes into ActiveNavigator. Called from the picker
    /// once per LocationService update.
    func navigatorIngest(_ fix: Fix) {
        // Top up the rolling tile-bake window. Throttled inside
        // MapViewSource so we don't hammer URLSession on every fix.
        mapViewSource.extendTileCache(near: fix.coordinate)
        // Re-evaluate the Auto map style (sun position). Throttled to
        // ~60 s — far coarser than the GPS fix rate, fine for the sun.
        maybeUpdateMapStyle(fix)
        // Ride-relevant weather, throttled inside the service (≥5 min /
        // ≥~100 m). Off entirely when the toggle is disabled, and the
        // pill is cleared so a stale warning doesn't linger.
        refreshWeather(at: fix.coordinate)
        Task { @MainActor in
            await activeNavigator.ingest(fix: fix)
        }
    }

    /// Poll the weather service (throttled) and push the result into the
    /// renderer's weather pill. No-op + cleared pill when the rider has
    /// turned Weather alerts off.
    private func refreshWeather(at position: CLLocationCoordinate2D) {
        guard dashNavSettings.weatherAlertsEnabled else {
            if mapViewSource.weatherAlert != nil {
                mapViewSource.setWeatherAlert(nil)
            }
            return
        }
        let ahead = activeNavigator.routeAheadCoordinates
        Task { @MainActor [weak self] in
            guard let self else { return }
            let alert = await self.weatherService.refresh(position: position, routeAhead: ahead)
            // Re-check the toggle: the rider may have flipped it OFF during
            // the await, in which case we must NOT paint a stale pill.
            self.mapViewSource.setWeatherAlert(
                self.dashNavSettings.weatherAlertsEnabled ? alert : nil
            )
        }
    }

    /// Prefetch speed cameras along the freshly-installed route and hand
    /// them to the renderer. Called from `MapPickerView.installRouteGeometry`
    /// on nav start + every reroute / leg advance. Best-effort: a failed
    /// or empty fetch just leaves the map without markers. No-op (and the
    /// existing markers cleared) when the toggle is off.
    func prefetchSpeedCameras(for route: MKRoute) {
        speedCameraPrefetchTask?.cancel()
        guard dashNavSettings.speedCamerasEnabled else {
            mapViewSource.setSpeedCameras([])
            return
        }
        let coords = route.polyline.coordinateList()
        guard coords.count >= 2 else { return }
        speedCameraPrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cams = await SpeedCameraService.shared.camerasAlong(route: coords)
            guard !Task.isCancelled else { return }
            // Re-check the toggle after the network await.
            self.mapViewSource.setSpeedCameras(
                self.dashNavSettings.speedCamerasEnabled ? cams : []
            )
        }
    }

    /// Prefetch OSM `maxspeed` ways along the freshly-installed route so
    /// the renderer can map-match the rider's position to a posted limit.
    /// Same lifecycle as `prefetchSpeedCameras`. No-op (and the sign
    /// cleared) when the display mode is `.off`. Always pushes the current
    /// display config first so the renderer's mode/units are fresh even if
    /// the fetch returns nothing.
    func prefetchSpeedLimits(for route: MKRoute) {
        speedLimitPrefetchTask?.cancel()
        pushSpeedLimitConfig()
        guard dashNavSettings.speedLimitDisplay != .off else {
            mapViewSource.setSpeedLimits([])
            return
        }
        let coords = route.polyline.coordinateList()
        guard coords.count >= 2 else { return }
        speedLimitPrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ways = await SpeedLimitService.shared.limitsAlong(route: coords)
            guard !Task.isCancelled else { return }
            // Re-check the mode after the network await.
            self.mapViewSource.setSpeedLimits(
                self.dashNavSettings.speedLimitDisplay != .off ? ways : []
            )
        }
    }

    /// Push the speed-limit display policy (mode + tolerance + units) to
    /// the renderer. Cheap; safe to call on prefetch and whenever settings
    /// change. Units are derived from the same `units` setting the camera
    /// labels use.
    func pushSpeedLimitConfig() {
        mapViewSource.setSpeedLimitConfig(
            mode: dashNavSettings.speedLimitDisplay.rawValue,
            toleranceKmh: dashNavSettings.speedLimitOverToleranceKmh,
            imperial: dashNavSettings.units == .imperial
        )
    }

    /// Watch the two ride-alert toggles so flipping either OFF mid-ride
    /// clears its overlay immediately (rather than waiting for the next
    /// fix / route install). Turning back ON does nothing here — the next
    /// fix re-polls weather, and the next route install re-prefetches
    /// cameras. Same self-re-registering `withObservationTracking` idiom
    /// as the call-state / message observers.
    private func wireRideAlerts() {
        observeWeatherToggle()
        observeSpeedCameraToggle()
        observeSpeedLimitMode()
    }

    private func observeWeatherToggle() {
        withObservationTracking {
            _ = dashNavSettings.weatherAlertsEnabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.dashNavSettings.weatherAlertsEnabled == false {
                    self.mapViewSource.setWeatherAlert(nil)
                }
                self.observeWeatherToggle()
            }
        }
    }

    private func observeSpeedCameraToggle() {
        withObservationTracking {
            _ = dashNavSettings.speedCamerasEnabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.dashNavSettings.speedCamerasEnabled == false {
                    self.speedCameraPrefetchTask?.cancel()
                    self.mapViewSource.setSpeedCameras([])
                } else if self.dashNavSettings.speedCamerasEnabled,
                          self.activeNavigator.isNavigating,
                          let route = self.activeNavigator.activeRoute {
                    // Re-enabled mid-ride → backfill markers for the
                    // current route without waiting for the next reroute.
                    self.prefetchSpeedCameras(for: route)
                }
                self.observeSpeedCameraToggle()
            }
        }
    }

    /// Observe the speed-limit display mode + tolerance. Any change pushes
    /// fresh config to the renderer. `.off` clears the sign + cancels the
    /// fetch; flipping back to a visible mode mid-ride backfills the ways
    /// for the current route. Self-re-registering, same idiom as the
    /// camera toggle.
    private func observeSpeedLimitMode() {
        withObservationTracking {
            _ = dashNavSettings.speedLimitDisplay
            _ = dashNavSettings.speedLimitOverToleranceKmh
            _ = dashNavSettings.units
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pushSpeedLimitConfig()
                if self.dashNavSettings.speedLimitDisplay == .off {
                    self.speedLimitPrefetchTask?.cancel()
                    self.mapViewSource.setSpeedLimits([])
                } else if self.mapViewSource.speedLimitWaysEmpty,
                          self.activeNavigator.isNavigating,
                          let route = self.activeNavigator.activeRoute {
                    // Turned on mid-ride with no ways loaded → backfill.
                    self.prefetchSpeedLimits(for: route)
                }
                self.observeSpeedLimitMode()
            }
        }
    }

    /// Throttled Auto-style re-evaluation. For manual modes the resolver
    /// is a pass-through (still cheap). When the effective palette changes
    /// we drive `MapViewSource.setMapStyle`, which holds the old tile
    /// cache visible until the new palette finishes its first bake.
    private func maybeUpdateMapStyle(_ fix: Fix) {
        let now = Date()
        if let last = lastStyleEvalAt, now.timeIntervalSince(last) < 60 { return }
        lastStyleEvalAt = now
        let next = MapStyleResolver.resolve(
            mode: mapStyleSettings.mode,
            coord: fix.coordinate,
            date: fix.timestamp,
            current: effectiveMapStyle,
            lastSwitch: lastStyleSwitchAt
        )
        guard next != effectiveMapStyle else { return }
        effectiveMapStyle = next
        lastStyleSwitchAt = now
        mapViewSource.setMapStyle(next)
    }

    /// Resolve the effective palette right now (used at navigation start,
    /// before the first prerender, so the ride opens in the correct
    /// Light/Dark style) and push it to the renderer's `currentStyle`
    /// WITHOUT triggering a re-bake (there's no cache yet — the imminent
    /// prerender will use it).
    func primeMapStyleForStart() {
        let coord = locationService.lastFix?.coordinate
        let next = MapStyleResolver.resolve(
            mode: mapStyleSettings.mode,
            coord: coord,
            date: Date(),
            current: effectiveMapStyle,
            lastSwitch: lastStyleSwitchAt
        )
        effectiveMapStyle = next
        lastStyleSwitchAt = Date()
        lastStyleEvalAt = Date()
        mapViewSource.setMapStyle(next)
    }

    /// Apply a manual change of the appearance picker (Light/Dark/Auto).
    /// Persists the mode and re-resolves immediately (no 60 s throttle —
    /// the rider just tapped, they expect an instant response). For Auto
    /// this resolves against the current sun position.
    func setMapStyleMode(_ mode: MapStyleSettings.Mode) {
        mapStyleSettings.mode = mode
        let coord = locationService.lastFix?.coordinate
        let next = MapStyleResolver.resolve(
            mode: mode,
            coord: coord,
            date: Date(),
            current: effectiveMapStyle,
            lastSwitch: nil   // manual action bypasses the dwell lock
        )
        lastStyleEvalAt = Date()
        guard next != effectiveMapStyle else { return }
        effectiveMapStyle = next
        lastStyleSwitchAt = Date()
        mapViewSource.setMapStyle(next)
    }

    // MARK: - Build info (handy in the diagnostics overlay)

    let buildVersion: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let buildNumber: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    /// Short git commit SHA the build was produced from. Stamped into the
    /// Info.plist at build time by `tools/stamp-git-sha.sh` (a Run Script
    /// build phase). Falls back to "dev" for the unstamped source plist or
    /// "unknown" if the stamp script could not reach git.
    let buildCommitSHA: String = Bundle.main
        .object(forInfoDictionaryKey: "GitCommitSHA") as? String ?? "unknown"
}
