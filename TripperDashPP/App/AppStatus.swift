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
import Observation
import UIKit

/// High-level connection lifecycle as seen by the UI. Mirrors the
/// `BikeLink` state machine that lands in Phase 3.
enum BikeConnectionState: String, Sendable {
    case disconnected
    case wifiJoining       // Waiting for the user to join the Tripper AP
    case handshaking       // RSA exchange in flight
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
                // If the link dropped while we were streaming, kill the
                // RTP pipeline — RtpStreamer doesn't watch the link
                // itself and would happily keep encoding into the void.
                if self.isStreaming && self.bikeLink.state != .connected {
                    self.stopStreaming()
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
        Task { @MainActor in
            await activeNavigator.ingest(fix: fix)
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
}
