//
//  MapViewSource.swift
//  TripperDashPP
//
//  Phase 8d — Pre-rendered route tile cache as the BG frame source.
//
//  History:
//  --------
//  Phase 8b: live MKMapView.layer.render(in:) every frame. FAILS in BG —
//            MapKit's Metal renderer is paused once the app is no longer
//            .active, so layer.render returns black pixels.
//
//  Phase 8c: MKMapSnapshotter on a 1 Hz cache + dot overlay. FAILS in
//            BG — the snapshotter completion handler is silently
//            suspended on the lock screen too. Confirmed by telemetry.
//
//  Phase 8d (THIS): pre-render every tile we'll need DURING foreground
//            (when the GPU is awake), JPEG-compress them in memory, then
//            in BG do CPU-only CGContext composition: crop a tile around
//            the current fix, rotate to heading-up, draw the polyline,
//            draw the user dot. CGContext is BG-safe.
//
//  Output:
//  -------
//  526×300 BGRA pixel buffer at 6 fps emitted to the encoder. PiP keeps
//  the encoder pipeline + Swift Concurrency executor alive on lock
//  screen; the tile cache supplies the visual content.

import CoreLocation
import CoreMedia
import CoreText
import CoreVideo
import MapKit
import OSLog
import QuartzCore
import UIKit

@MainActor
final class MapViewSource: NSObject, FrameSource {

    // MARK: - FrameSource contract

    let frameSize = CGSize(width: 526, height: 300)
    let targetFps = 6

    // MARK: - State

    private let mapView = MKMapView()
    private weak var locationService: LocationService?
    private weak var activeNavigator: ActiveNavigator?
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "MapViewSource")

    private var locationToken: UUID?
    private var fixSubscription: LocationSubscription?
    private var headingSubscription: LocationSubscription?
    private var lastFix: Fix?

    /// Effective heading used to rotate the rendered frame (degrees,
    /// CW from north). Lerped per-tick toward `targetHeading`.
    ///
    /// Field-test 2026-06-21 confirmed: on a motorcycle the magnetic
    /// compass is unusable — frame vibrations, the steel skeleton, the
    /// ignition coil and bar-end LEDs all skew `CLHeading.trueHeading`
    /// by tens of degrees, and the dash sometimes rotates backwards
    /// when the rider is moving forward. The robust signal is
    /// `CLLocation.course` (true GPS course over ground) — but that's
    /// `-1` when stationary, so we fall back to the compass at low
    /// speed.
    private var lastHeading: CLLocationDirection = 0

    /// Smoothed target for `lastHeading`. Computed in `recomputeHeading()`
    /// from the latest fix + compass; the render tick lerps toward it.
    private var targetHeading: CLLocationDirection = 0

    /// Last raw compass reading (kept around so we can fall back to it
    /// when the bike stops at a light).
    private var lastCompassHeading: CLLocationDirection = 0
    private var lastCompassValid: Bool = false

    private let queue = DispatchQueue(label: "TripperDashPP.MapViewSource", qos: .userInitiated)
    private var renderTask: Task<Void, Never>?
    private var frameIndex: UInt64 = 0
    private var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    // MARK: - Adaptive frame cadence (battery saver)
    //
    // The render Task still *ticks* at `targetFps` (6 Hz) so heading/zoom
    // lerps stay smooth and we react to motion within ~166 ms — but the
    // EXPENSIVE work (CGContext composite → VideoToolbox encode → RTP send,
    // plus the per-frame q3c.g projection kick) only runs when the emit gate
    // below says the picture actually changed. Two independent savings:
    //   1. Adaptive fps: at a standstill with a settled view we drop to a
    //      1 Hz keep-alive; the instant the rider moves OR the map rotates/
    //      zooms (e.g. turning the bars at a red light) we snap back to the
    //      full 6 Hz so the animation stays fluid.
    //   2. Skip-identical: even nominally "active" ticks whose fingerprint
    //      matches the last emitted frame are suppressed until the keep-alive
    //      falls due.
    // Moving (city/highway) → fingerprint changes every fix → full 6 fps,
    // exactly as before. The win is concentrated in stop-and-go time.

    /// Heading (0.5°) + zoom (0.02) quantised so a settled view yields a
    /// stable fingerprint while an in-progress rotation/zoom keeps changing
    /// it (and thus holds 6 fps until it lands). Everything else that can
    /// change at a standstill (weather pill, cameras, maneuver glyph, style)
    /// is picked up by the ≤1 s keep-alive, so it's deliberately excluded
    /// to keep the fingerprint cheap and jitter-proof.
    private struct RenderFingerprint: Equatable {
        var headingHalfDeg: Int
        var zoomCenti: Int
    }

    /// GPS speed at/above which we treat the rider as "moving" and force the
    /// full cadence regardless of fingerprint. 0.7 m/s ≈ 2.5 km/h — above
    /// walking-the-bike noise, below any real ride speed. Uses CoreLocation
    /// `speed` (not position deltas) so a stationary GPS jitter can't fake
    /// motion and pin us at 6 fps over a red light.
    private static let motionThresholdMPS: Double = 0.7

    /// Standstill keep-alive ceiling. With nothing moving we still emit one
    /// frame per second so the dash projection surface + q3c.g refresh tick
    /// stays alive (the OEM app streams continuously; 1 fps is the floor we
    /// trust the firmware to hold the last bitmap through).
    private static let idleKeepAliveInterval: CFTimeInterval = 1.0

    private var lastEmittedFingerprint: RenderFingerprint?
    /// Monotonic (CACurrentMediaTime) timestamp of the last emitted frame.
    private var lastEmitMediaTime: CFTimeInterval = 0
    /// Stream start on the same monotonic clock — PTS base so RTP 90 kHz
    /// timestamps stay real-time-correct under a variable cadence.
    private var streamStartMediaTime: CFTimeInterval = 0

    private var pixelBufferPool: CVPixelBufferPool?
    private var routePolyline: MKPolyline?
    private var routePolylineCoords: [CLLocationCoordinate2D] = []

    /// Latest active-nav overlay state pushed in by ActiveNavLoop.
    /// `nil` while not navigating → drawNavOverlay short-circuits.
    fileprivate var navOverlayState: MapViewSource.NavOverlayState?

    /// Latest ride-relevant weather alert, pushed in by the nav pump from
    /// `WeatherAlertService`. `nil` → no pill drawn (clear weather, the
    /// common case). Rendered bottom-right so it never overlaps the route
    /// or the centred puck. See the "Ride-alerts overlay" extension below.
    var weatherAlert: WeatherAlert?

    /// Speed cameras to plot on the map, prefetched along the active route
    /// by `SpeedCameraService`. Empty → nothing drawn. Each is rendered as
    /// an upright camera pictograph at its geographic position (rotates
    /// WITH the map for position, but the icon itself stays upright and
    /// constant-size, like a proper POI marker).
    var speedCameras: [SpeedCamera] = []

    /// Speed-limit ways map-matched against the rider's position to derive
    /// the posted limit for the current road. Fed by `AppStatus` after a
    /// route install (same prefetch lifecycle as the cameras). Empty → no
    /// sign. The map-match runs in `handleFix`, not per frame, so the
    /// geometry loop happens at ~1 Hz GPS cadence, not 30 fps.
    private var speedLimitWays: [SpeedLimitWay] = []

    /// Whether no limit ways are currently loaded — lets `AppStatus` decide
    /// if a mid-ride re-enable needs a backfill fetch.
    var speedLimitWaysEmpty: Bool { speedLimitWays.isEmpty }

    /// Currently map-matched posted limit (km/h), or `nil` when no way is
    /// close enough. Derived in `handleFix`; read by `drawSpeedLimitSign`.
    private var currentLimitKmh: Int?

    /// Whether the rider is currently over `currentLimitKmh` by more than
    /// the configured tolerance. Drives the `.overOnly` display mode.
    private var isOverSpeedLimit: Bool = false

    /// Display policy + tolerance + units for the limit sign, pushed from
    /// settings (via `AppStatus` on prefetch and `ActiveNavLoop` per tick).
    /// Stored as the raw enum string to avoid importing the settings type
    /// into the renderer.
    private var speedLimitMode: String = "always"   // off | always | overOnly
    private var speedLimitToleranceKmh: Double = 3
    private var speedLimitImperial: Bool = false

    /// Snap + hysteresis thresholds (m) for the map-match. A way must come
    /// within `snapMeters` to ACQUIRE the limit; once shown, the sign holds
    /// until the nearest way is further than `releaseMeters` away, so it
    /// doesn't blink off in the gaps between tagged segments or when GPS
    /// jitter nudges the match distance across a single threshold.
    private static let limitSnapMeters: Double = 35
    private static let limitReleaseMeters: Double = 80

    /// Pre-rendered tile cache — built from the active route in FG.
    private var routeTileCache: RouteTileCache?
    private var lastTileHintIndex: Int = 0

    /// Timestamp of the most recent `extendTileCache(near:)` invocation
    /// that actually triggered work. Used to throttle the rolling
    /// extender — GPS fixes arrive at ~1 Hz which is more often than
    /// we want to re-evaluate the bake window.
    private var lastTileExtendAt: Date?

    /// Minimum interval between rolling-extend evaluations. At 130
    /// km/h that's ~72 m between calls — fine granularity given the
    /// rolling lookahead is 5 km.
    private static let tileExtendThrottle: TimeInterval = 2.0
    /// Route that needs a fresh tile bake but couldn't run yet (app
    /// in BG/lock). Drained on `didBecomeActiveNotification`. Most
    /// recent value wins — if a second reroute arrives before the
    /// first bakes, the older route is discarded.
    private var pendingRebakeRoute: MKRoute?
    private var pendingRebakeInFlight: Bool = false
    private var appStateObserver: NSObjectProtocol?

    /// The map palette the renderer is currently painting. Tile caches,
    /// the void/vector fallback colours, and every fresh `RouteTileCache`
    /// are bound to this. Changed only via `setMapStyle(_:)`.
    private(set) var currentStyle: MapStyle = .light

    /// The active route, remembered so a mid-ride style switch can re-bake
    /// the new palette around the rider without the caller re-supplying it.
    /// Set by `setRoutePolyline`/`prerender` wiring; cleared on stop.
    private var currentRoute: MKRoute?

    /// A style re-bake that couldn't run yet (app backgrounded / locked).
    /// Drained on `didBecomeActive`, same pattern as `pendingRebakeRoute`.
    /// Most recent value wins.
    private var pendingStyleRebake: (route: MKRoute, style: MapStyle)?
    /// Speed-adaptive zoom factor applied to the rendered tile composite
    /// and polyline. 1.0 = native scale (~0.85 m/px at 1024 px tile).
    /// Lerped each frame toward `targetZoom(forSpeed:)` so the view
    /// transitions smoothly between speed regimes (no flicker).
    private var currentZoom: CGFloat = 1.0

    /// Vertical offset of the user puck from the geometric centre of
    /// the frame, expressed as a fraction of the frame height. Positive
    /// values push the puck *down* on the dash screen, which exposes
    /// more map ahead of the rider. 0.0 = dead-center (legacy behaviour);
    /// 0.28 ≈ puck at 78% from the top, 22% above the bottom edge.
    ///
    /// Authority: rider feedback from real-bike runs 2026-06 ("shift the
    /// current position a bit lower toward the bottom edge", then "still
    /// too high, push it further down so we see more ahead"). Capped at
    /// ~0.30 — beyond that the puck feels like it's falling off the
    /// bottom and the rider loses the sense of where they are.
    private let forwardBiasFraction: CGFloat = 0.28

    /// Scale factor for the user puck (blue dot + chevron). 1.0 = the
    /// original 28 px ring. Bumped to make the rider's position pop more
    /// against a busier, more-zoomed-in city map (2026-06 rider feedback:
    /// "make the chevron a touch bigger so it's easier to spot"). Bumped
    /// again 1.35 → 1.7 on a follow-up request to enlarge the position
    /// chevron further so it's unmistakable at a glance on the bike dash.
    private let puckScale: CGFloat = 1.7

    /// On-screen thickness (px) of the drawn route polyline, held CONSTANT
    /// across zoom levels. The line is stroked inside the `currentZoom`
    /// scale, so each draw path divides this by `currentZoom` to cancel
    /// the scale out. Bumped 5 → 7 px on rider feedback ("make the route a
    /// bit thicker so it's easier to follow on the map") — still well under
    /// the old fixed width 8 that rendered "as thick as the road" at city
    /// zoom, but with a clearer, more legible track.
    private let routeLineScreenPx: CGFloat = 7.0

    /// PiP wrapper.
    /// Phase 8d removed — tile cache + CGContext composite is BG-safe
    /// without PiP. AVAudioSession (SilentAudioKeeper) keeps the
    /// process awake on lock screen.

    init(locationService: LocationService, activeNavigator: ActiveNavigator) {
        self.locationService = locationService
        self.activeNavigator = activeNavigator
        super.init()
        configureMapView()
        installAppStateObserver()
    }

    deinit {
        if let obs = appStateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    var hostView: MKMapView { mapView }

    private func configureMapView() {
        mapView.frame = CGRect(origin: .zero, size: frameSize)
        mapView.bounds = CGRect(origin: .zero, size: frameSize)
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = false
        mapView.showsBuildings = true
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .followWithHeading
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        mapView.delegate = self
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
    }

    // MARK: - FrameSource

    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.onFrame = onFrame
        self.frameIndex = 0
        // Reset the adaptive-cadence clock + gate state for a fresh stream.
        self.streamStartMediaTime = CACurrentMediaTime()
        self.lastEmitMediaTime = 0
        self.lastEmittedFingerprint = nil
        preparePool()
        subscribeLocation()
        startTimer()
        log.info("MapViewSource started (prerendered tiles + CGContext, adaptive \(self.targetFps) fps, \(Int(self.frameSize.width))x\(Int(self.frameSize.height)))")
    }

    func stop() {
        renderTask?.cancel()
        renderTask = nil
        if let service = locationService, let token = locationToken {
            service.stop(token: token)
        }
        locationToken = nil
        fixSubscription = nil
        headingSubscription = nil
        onFrame = nil
        log.info("MapViewSource stopped after \(self.frameIndex) frames")
    }

    // MARK: - Tile cache wiring

    /// Install a pre-rendered tile cache produced by `RouteTileCache.prerender`.
    /// Once installed, the BG render path will composite from these tiles
    /// instead of asking MapKit to draw anything.
    func setTileCache(_ cache: RouteTileCache?) {
        routeTileCache = cache
        lastTileHintIndex = 0
        lastTileExtendAt = nil
        log.info("Tile cache installed: \(cache?.tiles.count ?? 0, privacy: .public) tiles")
    }

    /// Remember the active route so a mid-ride style switch can re-bake
    /// the new palette around the rider. Called by the picker right after
    /// it builds the initial tile cache for `route`, and by the reroute
    /// path. Pass nil when navigation stops.
    func setCurrentRoute(_ route: MKRoute?) {
        currentRoute = route
    }

    /// Switch the map palette (manual Light/Dark toggle, or Auto at
    /// dusk/dawn). Builds a FRESH style-bound `RouteTileCache`, bakes the
    /// fast-start window around the rider's current position, then swaps
    /// it in — holding the OLD cache installed and visible until the new
    /// bake's first batch lands, so the dash never flashes to the vector
    /// fallback mid-switch. Deferred to `didBecomeActive` when the app is
    /// backgrounded (the rider can't see the map on the lock screen, and
    /// Auto flips are purely cosmetic, so there's nothing to lose).
    func setMapStyle(_ style: MapStyle) {
        guard style != currentStyle else { return }
        currentStyle = style
        log.info("Map style → \(style.tileCacheNamespace, privacy: .public)")

        // Not navigating yet: nothing to re-bake. The next prerender (when
        // navigation starts) will pick up `currentStyle`. We still flip
        // the vector-fallback colours immediately via currentStyle.
        guard let route = currentRoute, let fix = lastFix else { return }

        guard UIApplication.shared.applicationState == .active else {
            pendingStyleRebake = (route, style)
            log.info("Style re-bake deferred — app not active; will run on didBecomeActive")
            return
        }
        Task { @MainActor in await performStyleRebake(route: route, style: style, around: fix.coordinate) }
    }

    /// Bake `route` in `style` around `coord` and atomically swap the
    /// cache. The previous cache stays installed (and visible) right up
    /// until the reassignment, so there's no dark gap.
    private func performStyleRebake(route: MKRoute, style: MapStyle, around coord: CLLocationCoordinate2D) async {
        // The style may have changed again while we were waiting; bake the
        // most recent requested style only.
        guard style == currentStyle else { return }
        let fresh = RouteTileCache(style: style)
        await fresh.prerender(route: route, around: coord) { _ in }
        // Re-check: a newer style switch may have landed during the bake.
        guard style == currentStyle else { return }
        routeTileCache = fresh   // atomic swap; old cache was visible until now
        lastTileHintIndex = 0
        lastTileExtendAt = nil
        log.info("Style re-bake installed: \(style.tileCacheNamespace, privacy: .public), \(fresh.tiles.count, privacy: .public) tiles")
    }

    /// Extend the rolling tile-bake window around `coord`. Called from
    /// `AppStatus.navigatorIngest` for every GPS fix. Throttled here
    /// so the underlying URLSession isn't asked to re-evaluate the
    /// rolling window faster than `tileExtendThrottle` (default 2 s).
    ///
    /// Idempotent: `RouteTileCache.extend` skips anchors already baked
    /// or in flight, so calling more often than necessary is wasteful
    /// but not incorrect. The throttle is for log noise + battery.
    ///
    /// Runs in `.background` too — and that is the WHOLE POINT. A
    /// motorbike rider has the phone locked in a pocket for the entire
    /// ride, so the app is `.background` the moment they pull away. The
    /// bake is pure URLSession + CGContext (see
    /// `ios-background-rendering-and-state-changes.md`): BG-safe, no GPU.
    /// The old `applicationState == .active` guard meant the rolling
    /// window NEVER extended in the only state that matters, so once the
    /// fast-start window ran out (~8 km) the dash fell back to vector-only
    /// for the rest of the trip — exactly the field report of "map tiles
    /// vanished halfway, only the pre-cached ones showed" (Zvoleneves →
    /// Terezín, 2026-06). Data/battery cost is bounded by the same
    /// throttle + idempotent bake set; a usable map outweighs it.
    func extendTileCache(near coord: CLLocationCoordinate2D) {
        guard let cache = routeTileCache else { return }
        let now = Date()
        if let last = lastTileExtendAt,
           now.timeIntervalSince(last) < Self.tileExtendThrottle {
            return
        }
        lastTileExtendAt = now
        Task { @MainActor in
            await cache.extend(near: coord)
        }
    }

    /// Request a fresh tile cache for `route`. If the app is `.active`
    /// (foreground, screen on), the bake runs immediately and replaces
    /// the current cache when done. Otherwise the route is parked in
    /// `pendingRebakeRoute` and the bake fires on the next
    /// `didBecomeActiveNotification` — preserving the OLD cache in the
    /// meantime so the rider keeps seeing real map tiles (just stale
    /// ones) instead of a vector-only black-on-grey fallback while
    /// the lock screen is on.
    ///
    /// Calling twice quickly (e.g. two reroutes in 30 s) coalesces:
    /// only the latest `route` is baked when the app wakes.
    func scheduleTileCacheRebuild(for route: MKRoute) {
        pendingRebakeRoute = route
        let state = UIApplication.shared.applicationState
        if state == .active {
            log.info("Tile re-bake triggered immediately (app .active)")
            Task { @MainActor in await performPendingRebake() }
        } else {
            log.info("Tile re-bake deferred — app state=\(state.rawValue, privacy: .public); will run on next didBecomeActive")
            // Keep the existing cache intact. The polyline already
            // got updated by setRoutePolyline; the vector fallback
            // and the stale (but still partially valid) tile cache
            // overlap to keep the dash usable.
        }
    }

    /// Bake `pendingRebakeRoute` (if any) and atomically swap the
    /// cache. MUST run on main and only when app is `.active`.
    private func performPendingRebake() async {
        guard let route = pendingRebakeRoute else { return }
        // Re-check state — between schedule time and now the app may
        // have re-backgrounded (user tapped lock during bake start).
        guard UIApplication.shared.applicationState == .active else {
            log.warning("performPendingRebake aborted — app no longer .active")
            return
        }
        // Take a local snapshot of the route id we're baking so we can
        // tell whether a newer route landed mid-bake.
        let bakingFor = ObjectIdentifier(route)
        pendingRebakeInFlight = true
        currentRoute = route
        let fresh = RouteTileCache(style: currentStyle)
        await fresh.prerender(route: route) { _ in }
        pendingRebakeInFlight = false
        // If a newer route was scheduled while we were baking, throw
        // this one away and recurse — fresh data wins.
        if let latest = pendingRebakeRoute, ObjectIdentifier(latest) != bakingFor {
            log.info("Newer reroute landed during bake — re-baking with latest")
            await performPendingRebake()
            return
        }
        pendingRebakeRoute = nil
        setTileCache(fresh)
    }

    /// Wire up the `didBecomeActiveNotification` observer that fires
    /// any deferred bake when the user unlocks / returns to fg.
    /// Called once from init.
    private func installAppStateObserver() {
        let center = NotificationCenter.default
        appStateObserver = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Drain a deferred style re-bake first (most recent style
            // wins). Independent of the reroute re-bake below.
            if let pending = self.pendingStyleRebake {
                self.pendingStyleRebake = nil
                if let fix = self.lastFix {
                    self.log.info("App became active — draining pending style re-bake")
                    Task { @MainActor in
                        await self.performStyleRebake(route: pending.route,
                                                      style: pending.style,
                                                      around: fix.coordinate)
                    }
                }
            }
            // Then any deferred reroute tile re-bake.
            guard self.pendingRebakeRoute != nil, !self.pendingRebakeInFlight else { return }
            self.log.info("App became active — draining pending tile re-bake")
            Task { @MainActor in await self.performPendingRebake() }
        }
    }
}

// MARK: - Location wiring

extension MapViewSource {
    private func subscribeLocation() {
        guard let service = locationService else { return }
        locationToken = service.start(mode: .mapping)
        fixSubscription = service.subscribeFixes { [weak self] fix in
            Task { @MainActor in self?.handleFix(fix) }
        }
        headingSubscription = service.subscribeHeading { [weak self] heading in
            Task { @MainActor in self?.handleHeading(heading) }
        }
    }

    private func handleFix(_ fix: Fix) {
        lastFix = fix
        recomputeHeading()
        recomputeSpeedLimit(for: fix)
        let region = MKCoordinateRegion(
            center: fix.coordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )
        mapView.setRegion(region, animated: false)
    }

    private func handleHeading(_ heading: Heading) {
        // Stash the raw compass value — we'll use it as a fallback when
        // the bike is stationary. We DON'T blindly drive the camera off
        // it any more; see `recomputeHeading()` for the policy.
        if heading.trueHeading >= 0 {
            lastCompassHeading = heading.trueHeading
            lastCompassValid = true
        }
        recomputeHeading()
    }

    /// Decide which heading to point the rendered frame at.
    ///
    /// Policy (field-test 2026-06-21):
    ///   - `speed > 3 m/s` (~11 km/h) AND `course >= 0` → trust GPS course
    ///   - otherwise → fall back to the compass (last valid value)
    ///   - lerp `lastHeading → targetHeading` in `tickRender()` so the
    ///     view doesn't snap when the source flips between course and
    ///     compass.
    ///
    /// Why 3 m/s: below that the GPS course-over-ground is dominated by
    /// fix jitter and swings wildly. Above it, the bike is definitely
    /// moving and the course is the true direction of travel — robust
    /// against any electromagnetic noise around the chassis.
    private func recomputeHeading() {
        let speedThresholdMPS: Double = 3.0  // ~11 km/h
        var newTarget: CLLocationDirection = targetHeading

        if let fix = lastFix,
           fix.speed >= speedThresholdMPS,
           fix.course >= 0 {
            newTarget = fix.course
        } else if lastCompassValid {
            newTarget = lastCompassHeading
        }

        targetHeading = newTarget
        // Seed `lastHeading` on the very first sample so the map doesn't
        // do a 180° spin on startup.
        if lastHeading == 0 && !lastCompassValid {
            lastHeading = newTarget
        }
    }
}

// MARK: - Render tick

extension MapViewSource {
    /// Render loop via Swift Concurrency Task + Task.sleep.
    /// Same scheduler pattern as HeartbeatLoop, which we've confirmed
    /// keeps ticking on locked screen with PiP active.
    private func startTimer() {
        renderTask?.cancel()
        let intervalNs: UInt64 = UInt64(1_000_000_000) / UInt64(targetFps)
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickOnMain()
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    @MainActor
    private func tickOnMain() async {
        guard onFrame != nil else { return }

        // 1. Advance the cheap per-tick animation state EVERY tick (6 Hz),
        //    even when we end up skipping the expensive emit below. This is
        //    what keeps a rotation/zoom in-progress dribbling forward and,
        //    crucially, keeps the fingerprint *changing* while it settles —
        //    so the gate holds the full cadence until the animation lands,
        //    then naturally relaxes to the keep-alive once it's still.
        updateHeading()
        updateZoom()

        // 2. Emit gate. Force the full cadence whenever the rider is moving
        //    (GPS speed), otherwise emit only when the view fingerprint
        //    changed or the ≤1 s keep-alive falls due.
        let now = CACurrentMediaTime()
        let moving = (lastFix?.speed ?? -1) >= Self.motionThresholdMPS
        let fingerprint = currentFingerprint()
        let changed = (fingerprint != lastEmittedFingerprint)
        let keepAliveDue = (now - lastEmitMediaTime) >= Self.idleKeepAliveInterval

        guard moving || changed || keepAliveDue else {
            // Standstill, settled view, keep-alive not yet due → skip the
            // CGContext composite + encode + RTP send entirely. The heartbeat
            // loop (separate 1 Hz task) keeps the K1G link up meanwhile; the
            // dash holds the last projected bitmap.
            return
        }

        guard let buffer = renderMapViewToPixelBuffer() else { return }

        // Real-time PTS from the monotonic clock (NOT frameIndex / fps) so the
        // RTP 90 kHz timestamps stay wall-clock-correct under a variable
        // cadence — a fixed-step PTS would make a 1 fps idle stretch look like
        // it played back 6× too fast once motion resumes.
        let elapsed = max(0.0, now - streamStartMediaTime)
        let pts = CMTime(seconds: elapsed, preferredTimescale: 90_000)
        frameIndex &+= 1
        lastEmittedFingerprint = fingerprint
        lastEmitMediaTime = now
        if frameIndex % 60 == 0 {
            let state = UIApplication.shared.applicationState.rawValue
            log.info("frame tick #\(self.frameIndex, privacy: .public) (appState=\(state, privacy: .public), moving=\(moving, privacy: .public))")
        }
        onFrame?(buffer, pts)
    }

    /// Quantised snapshot of the only continuously-varying inputs to the
    /// rendered picture at a standstill (post-lerp heading + zoom). Coarse
    /// buckets (0.5° / 0.02×) so a fully settled view yields a stable value
    /// — the lerps decay geometrically and would otherwise never compare
    /// exactly equal, defeating the skip. A live rotation/zoom still moves
    /// across buckets every tick and holds the full cadence until it lands.
    private func currentFingerprint() -> RenderFingerprint {
        RenderFingerprint(
            headingHalfDeg: Int((lastHeading * 2).rounded()),
            zoomCenti: Int((currentZoom * 50).rounded())
        )
    }

    private func renderMapViewToPixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        let r = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard r == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                         CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: base,
            width: Int(frameSize.width),
            height: Int(frameSize.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Frame clear colour comes from the active style so the corners
        // outside the rotated tile composite don't glare (near-black on
        // both palettes; dark style is a touch cooler/darker).
        ctx.setFillColor(currentStyle.voidColor)
        ctx.fill(CGRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height))

        // CGContext for CVPixelBuffer has origin at bottom-left;
        // CALayer/UIImage expect top-left. Flip the Y axis once.
        ctx.translateBy(x: 0, y: frameSize.height)
        ctx.scaleBy(x: 1, y: -1)

        // Unified FG + BG path. After the PiP/thumb removal, the
        // MKMapView is no longer in a window so layer.render produces
        // black. Instead we always composite from the pre-rendered
        // tile cache (built when navigation starts) — works FG and BG
        // since it's pure CGContext, no MapKit live render.
        if routeTileCache != nil {
            drawTileCacheFrame(into: ctx)
        } else {
            // Pre-navigation / no cache — vector-only on dark slate.
            drawVectorOnlyFrame(into: ctx)
        }

        // Weather alert pill — bottom-right corner, transform-independent
        // (drawn in the flat outer ctx so it sits in a fixed screen spot
        // regardless of map rotation/zoom). Placed AFTER the map branch so
        // it overlays the tiles, and it deliberately lives in the bottom-
        // right where neither the forward-biased puck nor the route runs.
        // No-op when `weatherAlert == nil` (clear weather).
        drawWeatherAlert(into: ctx)

        // Speed-limit sign — bottom-right corner, transform-independent
        // like the weather pill. Drawn AFTER the weather pill so the sign
        // owns the corner; when both are active the weather pill has
        // already been lifted above the sign (see `drawWeatherAlert`).
        // No-op unless a limit is map-matched and the display mode allows.
        drawSpeedLimitSign(into: ctx)

        // Top-left maneuver overlay — burned into the video so the dash
        // shows the right arrow regardless of how it interprets the
        // primary-maneuver TLV (whose enum is largely undocumented).
        // Nav overlay (maneuver glyph + distance + road name) used to
        // be baked into the stream here. Removed: turn-by-turn info
        // now travels to the dash via the K1G "active-nav" bubble
        // (separate TLV channel), so drawing it on the video would
        // duplicate the same information on the dash screen. Keep
        // `drawNavOverlay`/`drawText`/`formatDistance` as dead code
        // for now in case we want to reintroduce a video-side hint
        // (e.g. for non-K1G dashes or for the in-app preview).
        // drawNavOverlay(into: ctx)

        return buffer
    }
}

// MARK: - BG render: tile cache composite

extension MapViewSource {
    /// Draw one BG frame from the pre-rendered tile cache.
    /// Steps: pick nearest tile → rotate context to heading-up →
    /// draw cropped tile → polyline → user dot in the center.
    private func drawTileCacheFrame(into ctx: CGContext) {
        guard let cache = routeTileCache, let fix = lastFix else { return }
        guard let (refTile, idx) = cache.nearestTile(to: fix.coordinate, hintIndex: lastTileHintIndex) else {
            // Off-route / re-routing — fall back to vector-only.
            drawVectorOnlyFrame(into: ctx)
            return
        }
        lastTileHintIndex = idx


        // DIAG (issue #south-shift): log distance from fix to tile centre
        // every ~5 s so we can see in the OS log whether the renderer is
        // picking a wing tile (~1.5 km off-route) instead of the main row.
        if frameIndex % 30 == 0 {
            let dMeters = PolylineMath.haversine(fix.coordinate, refTile.center)
            let dLat = (refTile.center.latitude - fix.coordinate.latitude) * 111_111
            let dLon = (refTile.center.longitude - fix.coordinate.longitude) * 111_111 * cos(fix.coordinate.latitude * .pi / 180)
            // Predicted pixel offset on the rendered screen for tile.center
            // (relative to puck position):
            //   pxN = dLat * refTile.pxPerDegLat (deg→px, NORTH on screen)
            //   pxE = dLon converted using the actual pxPerDegLon at lat
            //
            // Then in heading-up rotation, the screen-x/y depend on heading.
            // Here we just log the unrotated pixel offsets so we can sanity
            // check whether the pixel math matches the meter offset.
            let pxN = (refTile.center.latitude - fix.coordinate.latitude) * refTile.pxPerDegLat
            let pxE = (refTile.center.longitude - fix.coordinate.longitude) * refTile.pxPerDegLon
            log.info("tile-pick #\(self.frameIndex, privacy: .public) fix=(\(fix.coordinate.latitude, privacy: .public),\(fix.coordinate.longitude, privacy: .public)) tile.center=(\(refTile.center.latitude, privacy: .public),\(refTile.center.longitude, privacy: .public)) dist=\(dMeters, format: .fixed(precision: 1), privacy: .public)m dN=\(dLat, format: .fixed(precision: 1), privacy: .public)m dE=\(dLon, format: .fixed(precision: 1), privacy: .public)m pxN=\(pxN, format: .fixed(precision: 1), privacy: .public) pxE=\(pxE, format: .fixed(precision: 1), privacy: .public) pxPerDegLat=\(refTile.pxPerDegLat, format: .fixed(precision: 1), privacy: .public) pxPerDegLon=\(refTile.pxPerDegLon, format: .fixed(precision: 1), privacy: .public) heading=\(self.lastHeading, format: .fixed(precision: 0), privacy: .public)°")
        }
        // NOTE: heading/zoom lerps are advanced once per tick in
        // `tickOnMain` (so they keep progressing even on skipped frames).
        // Do NOT re-run them here or a rendered frame would step the
        // animation twice as fast as a skipped one.

        // Each baked tile is already a 5×5 OSM grid stitch — a
        // 1280×1280 px composite covering ~3.9 km on a side at z=15
        // (mpp ≈ 3.07 m/px at 50°N × 1280 ≈ 3930 m). That single bitmap
        // is wider than the dash frame at every zoom level we use, AND
        // gridSide is odd so the painted area is symmetric about the
        // centre — so drawing the centre tile alone fully covers the
        // visible area with no black wedge at the frame edge.
        //
        // The old "draw nearest ±2" was inherited from the
        // MKMapSnapshotter era where each tile was a small clamp
        // and the renderer had to mosaic neighbours. With OSM stitches
        // those neighbours OVERLAP each other (anchor stride = 700 m,
        // tile span = ~3.9 km → ~82 % overlap) and stack on top with
        // slightly different lat-dependent pxPerDeg → visible seams
        // and a smeared composite. Single-tile draw is correct here.
        var tilesToDraw: [(RouteTile, CGImage)] = []
        let t = cache.tiles[idx]
        if let img = cache.image(for: t, atIndex: idx)?.cgImage {
            tilesToDraw.append((t, img))
        }
        guard let refTile = tilesToDraw.first?.0 else { return }

        // Pixels-per-degree — MEASURED from snap.point(for:) probes during
        // bake, NOT computed from region.span. MKMapSnapshotter renders
        // at the nearest tile zoom level which may cover 2-3× more area
        // than the requested region, so the naive ratio
        // `pixelSize / region.span` over-estimates scale and makes the
        // entire composite render zoomed in. The measured value is the
        // ground truth: how many ctx-pixels span 1 degree on this bitmap.
        let pxPerDegLon = refTile.pxPerDegLon
        let pxPerDegLat = refTile.pxPerDegLat

        // Anchor coordinate space on the user — they sit at the origin
        // after rotation; neighbouring tiles draw offset from that.
        let centerLon = fix.coordinate.longitude
        let centerLat = fix.coordinate.latitude

        // ─────────────────────────────────────────────────────────────
        // COORDINATE SYSTEM (Y-DOWN, UIKit convention):
        //   (0,0) = top-left   (W,0) = top-right
        //   (0,H) = bottom-left  y increases DOWNWARD
        //
        // Outer ctx was Y-flipped in renderMapViewToPixelBuffer to give
        // us this top-left origin (matches UIKit drawing). We DO NOT
        // flip again here. The whole drawing path is Y-DOWN.
        //
        // Math conventions in this Y-DOWN frame:
        //   dy = -(lat - centerLat) * pxPerDegLat   (north = -y)
        //   biasPx is ADDED to anchor y                (down = +y)
        //   rotation by -heading puts heading at top   (CW rotation)
        //   ctx.draw(image, in:) renders images upside-down in Y-DOWN;
        //   we use `drawImageUIKit` helper to flip per-call.
        // ─────────────────────────────────────────────────────────────

        ctx.saveGState()
        // Forward bias: anchor the user puck below the geometric centre
        // so more of the road ahead is visible. In Y-DOWN, "lower on
        // screen" = larger y, so ADD biasPx.
        let biasPx = frameSize.height * forwardBiasFraction
        ctx.translateBy(x: frameSize.width / 2, y: frameSize.height / 2 + biasPx)
        // Heading-up rotation. In Y-DOWN ctx, CGContext.rotate(by:)
        // rotates clockwise for positive angles (the Y-flip inverts the
        // usual math CCW-positive convention). To bring the heading
        // direction to the TOP of the frame we rotate the map CCW by
        // `heading` degrees → pass -heading.
        ctx.rotate(by: -lastHeading * .pi / 180)
        // Speed-adaptive zoom (slow lerp; see targetZoom/updateZoom).
        // Applied AFTER rotation so the origin sits at the puck.
        ctx.scaleBy(x: currentZoom, y: currentZoom)

        // Draw every overlapping tile shifted by the delta from its
        // own centre to the user's position. Use `t.center` (the
        // requested centre — and the geographic centre of the
        // rendered image), not `t.region.center`. MKMapSnapshotter
        // can adjust the region span but the centre stays put.
        for (t, cg) in tilesToDraw {
            let dx =  (t.center.longitude - centerLon) * pxPerDegLon
            let dy = -(t.center.latitude  - centerLat) * pxPerDegLat   // Y-DOWN: north = -y
            let tw = t.pixelSize.width
            let th = t.pixelSize.height
            // MKMapSnapshotter clamps the region, so the actual pixel
            // location of `t.center` is `t.centerPixel` — NOT (tw/2, th/2).
            // Compensate by shifting the tile rect so the centerPixel
            // lands at (dx, dy) instead of the bitmap midpoint.
            // In Y-DOWN, centerPixel.y is row count from TOP, so the
            // shift sign matches the X axis.
            let mpX = tw / 2 - t.centerPixel.x
            let mpY = th / 2 - t.centerPixel.y
            let rect = CGRect(x: CGFloat(dx) - tw / 2 + mpX,
                              y: CGFloat(dy) - th / 2 + mpY,
                              width: tw, height: th)
            drawImageUIKit(cg, in: rect, ctx: ctx)
        }

        // Draw the route polyline in the same Y-DOWN coordinate space.
        if !routePolylineCoords.isEmpty {
            ctx.setStrokeColor(CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.85))
            // The line is stroked INSIDE the currentZoom scale, so a fixed
            // lineWidth would grow with zoom (a city-zoom 2.9× made it as
            // thick as a road — rider feedback 6/2026). Divide by zoom so
            // the route reads at a constant ~5 px on screen regardless of
            // zoom level.
            ctx.setLineWidth(routeLineScreenPx / currentZoom)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.beginPath()
            var first = true
            for c in routePolylineCoords {
                let dx =  (c.longitude - centerLon) * pxPerDegLon
                let dy = -(c.latitude  - centerLat) * pxPerDegLat       // Y-DOWN: north = -y
                let pt = CGPoint(x: CGFloat(dx), y: CGFloat(dy))
                if first {
                    ctx.move(to: pt)
                    first = false
                } else {
                    ctx.addLine(to: pt)
                }
            }
            ctx.strokePath()
        }

        ctx.restoreGState()

        // Speed-camera POI markers — geo-anchored (they move/rotate WITH
        // the map as the rider travels) but drawn upright + constant-size
        // in the outer ctx so the camera glyph is always readable. Drawn
        // after the map/route restoreGState, before the puck so the user's
        // position stays on top. Projection params captured from this
        // tile-cache frame above.
        drawSpeedCameras(into: ctx,
                         centerLat: centerLat, centerLon: centerLon,
                         pxPerDegLon: pxPerDegLon, pxPerDegLat: pxPerDegLat)

        // Draw user direction arrow in the center. The map is rotated
        // heading-up, so the arrow always points toward the top of the
        // frame (= direction of travel). Drawn AFTER restoreGState so
        // it's not affected by tile rotation; uses a local Y-flip so
        // "tip up" matches screen-up regardless of the outer ctx's
        // bottom-left vs top-left origin (CVPixelBuffer rows go top→
        // bottom, so we flip locally to draw in intuitive "tip = +y").
        drawHeadingArrow(into: ctx)
    }

    /// Apple Maps navigation-mode user puck: blue circle with a white
    /// chevron arrow inside. The map is rotated heading-up, so the
    /// chevron always points toward the top of the frame
    /// (= direction of travel).
    private func drawHeadingArrow(into ctx: CGContext) {
        let cx = frameSize.width / 2
        // Match the forward-bias anchor used in drawTileCacheFrame /
        // drawVectorOnlyFrame so the puck stays put when we fall back
        // to vector-only. Coord system here is Y-DOWN (outer ctx); ADD
        // biasPx to push the puck visually down.
        let biasPx = frameSize.height * forwardBiasFraction
        let cy = frameSize.height / 2 + biasPx

        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        // Local Y-flip so the chevron coords below read naturally
        // (tip at +y = pointing UP on screen). Keeps the original
        // geometry numbers intact even though the outer ctx is Y-DOWN.
        ctx.scaleBy(x: 1, y: -1)
        // Uniform puck enlargement — scales the ring, disc and chevron
        // together so proportions stay identical, just bigger.
        ctx.scaleBy(x: puckScale, y: puckScale)

        // ── White outer ring (acts as a 2 px border around the puck) ──
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: -14, y: -14, width: 28, height: 28))

        // ── Blue circle ──
        ctx.setFillColor(CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: -12, y: -12, width: 24, height: 24))

        // ── White chevron inside the blue circle (Apple Maps nav style) ──
        // Tip at top, base near bottom of the circle. Sized to sit cleanly
        // inside the 24 px disc with ~2 px padding.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.beginPath()
        ctx.move(to: CGPoint(x:  0,   y:  8))    // tip
        ctx.addLine(to: CGPoint(x:  7,   y: -7))    // right base
        ctx.addLine(to: CGPoint(x:  0,   y: -3))    // back notch
        ctx.addLine(to: CGPoint(x: -7,   y: -7))    // left base
        ctx.closePath()
        ctx.fillPath()

        ctx.restoreGState()
    }

    /// Speed → zoom mapping. Linear ramp from "close" at standstill to
    /// "wide" at highway speeds, so the rider sees more road ahead the
    /// faster they go.
    ///   0 km/h → 2.0×   (city — tight, street-level detail)
    ///  60 km/h → 1.4×   (rural / regional)
    /// 130+ km/h → 0.8×  (highway, wide field of view)
    /// Returned value is clamped to [0.8, 2.0]; if speed is invalid
    /// (CoreLocation reports < 0 when unknown) we keep the current zoom.
    ///
    /// Tuned up from the original 0.6–1.5 range on rider feedback
    /// (2026-06: "city map is too zoomed out, hard to see where to go").
    private func targetZoom(forSpeedMPS speed: Double) -> CGFloat {
        guard speed >= 0 else { return currentZoom }
        let kmh = speed * 3.6
        // slope: (0.8 - 2.0) / 130 = -0.00923 per km/h
        let raw = 2.0 - CGFloat(kmh) * 0.00923
        let speedZoom = min(max(raw, 0.8), 2.0)
        return speedZoom * maneuverZoomBoost()
    }

    /// Extra zoom-in as a maneuver approaches, so the rider can see
    /// exactly which way the turn goes. Ramps from 1.0× (no boost) at
    /// `boostStartMeters` out, up to `maxManeuverBoost` right at the turn.
    /// Returns 1.0 when not navigating or the next step is far away.
    private func maneuverZoomBoost() -> CGFloat {
        guard let nav = activeNavigator, nav.isNavigating else { return 1.0 }
        let d = nav.distanceToNextStep
        guard d > 0 else { return 1.0 }
        let boostStartMeters: CGFloat = 200
        let boostFullMeters: CGFloat = 40     // fully boosted by 40 m out
        let maxManeuverBoost: CGFloat = 1.45
        if d >= boostStartMeters { return 1.0 }
        if d <= boostFullMeters { return maxManeuverBoost }
        // Linear interp: 1.0 at boostStart → maxBoost at boostFull.
        let t = (boostStartMeters - CGFloat(d)) / (boostStartMeters - boostFullMeters)
        return 1.0 + (maxManeuverBoost - 1.0) * t
    }

    /// Lerp `currentZoom` toward the target by 5%/frame. At 6 fps this
    /// gives roughly 10 seconds for a full city→highway transition
    /// (95% completion in ~58 frames). Slow enough that the rider
    /// doesn't see the map "breathing" on small speed wobbles.
    ///
    /// Exception: the maneuver-approach boost needs to land BEFORE the
    /// turn, not 10 s later, so when we're zooming IN (target > current)
    /// we lerp ~3× faster. Zooming back out after the turn stays slow so
    /// the map doesn't lurch.
    private func updateZoom() {
        let target = targetZoom(forSpeedMPS: lastFix?.speed ?? -1)
        let zoomingIn = target > currentZoom
        let factor: CGFloat = zoomingIn ? 0.15 : 0.05
        currentZoom += (target - currentZoom) * factor
    }

    /// Lerp `lastHeading` toward `targetHeading` by 15%/frame, taking
    /// the short way around the compass circle (handles the 359°→1°
    /// wrap without the map spinning the long way).
    ///
    /// At 6 fps, 15%/frame ≈ 95% completion in ~2.6 s — fast enough
    /// that the rider feels the map track the turn, slow enough that
    /// a single noisy fix doesn't yank the view.
    private func updateHeading() {
        let factor: Double = 0.15
        var delta = targetHeading - lastHeading
        // Wrap delta into [-180, +180] so we turn the short way.
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        var next = lastHeading + delta * factor
        // Normalise the result into [0, 360).
        while next < 0 { next += 360 }
        while next >= 360 { next -= 360 }
        lastHeading = next
    }

    /// Vector-only fallback: dark background + polyline + dot.
    /// Used when the tile cache is unavailable or the user has gone
    /// off the cached corridor.
    private func drawVectorOnlyFrame(into ctx: CGContext) {
        // NOTE: heading/zoom lerps are advanced once per tick in
        // `tickOnMain`, never here — this path is also reached as the
        // off-route fallback from drawTileCacheFrame, so stepping the
        // lerps here would double-advance them on a rendered frame.
        // Style-aware background (light stone for Light, dark slate for
        // Dark) so the pre-nav / off-corridor fallback matches the map
        // palette instead of always being dark.
        ctx.setFillColor(currentStyle.vectorBackground)
        ctx.fill(CGRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height))

        guard let fix = lastFix, !routePolylineCoords.isEmpty else {
            // Nothing useful to draw.
            return
        }

        // Use a constant scale: 1 m = 0.5 px → 526 px = ~1 km wide view.
        let metersPerPx: Double = 2.0
        let centerLat = fix.coordinate.latitude
        let centerLon = fix.coordinate.longitude
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centerLat * .pi / 180)

        ctx.saveGState()
        // Y-DOWN convention throughout — same coord system as
        // drawTileCacheFrame (see big comment block there).
        let biasPx = frameSize.height * forwardBiasFraction
        ctx.translateBy(x: frameSize.width / 2, y: frameSize.height / 2 + biasPx)
        ctx.rotate(by: -lastHeading * .pi / 180)
        ctx.scaleBy(x: currentZoom, y: currentZoom)

        ctx.setStrokeColor(CGColor(red: 0.0, green: 0.78, blue: 1.0, alpha: 0.95))
        // Constant on-screen thickness regardless of zoom (see the tile
        // path's note). Divide by currentZoom since we stroke inside the
        // zoom scale.
        ctx.setLineWidth(routeLineScreenPx / currentZoom)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        var first = true
        for c in routePolylineCoords {
            let dxM =  (c.longitude - centerLon) * mPerDegLon
            let dyM = -(c.latitude  - centerLat) * mPerDegLat       // Y-DOWN: north = -y
            let pt = CGPoint(x: CGFloat(dxM / metersPerPx), y: CGFloat(dyM / metersPerPx))
            if first {
                ctx.move(to: pt)
                first = false
            } else {
                ctx.addLine(to: pt)
            }
        }
        ctx.strokePath()
        ctx.restoreGState()

        // User direction arrow in the centre (same chevron as the
        // tile-cache path; map is heading-up so arrow always points up).
        drawHeadingArrow(into: ctx)
    }

    private func preparePool() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(frameSize.width),
            kCVPixelBufferHeightKey as String: Int(frameSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        pixelBufferPool = pool
    }

    /// Draw a CGImage right-side-up in a Y-DOWN context.
    ///
    /// `ctx.draw(image, in: rect)` is documented to render images
    /// upside-down when the CTM has a Y-flip (Apple's CGContext.draw
    /// reference, "Discussion" section). Our render pipeline is Y-DOWN
    /// throughout — outer flip in `renderMapViewToPixelBuffer` aligns
    /// CVPixelBuffer row 0 with visual top for VideoToolbox — so every
    /// raw bitmap blit hits this case.
    ///
    /// This helper wraps the draw in a local saveGState + per-call
    /// Y-flip so the image renders right-side-up without contaminating
    /// the outer CTM (which still drives vector math in Y-DOWN). The
    /// flip is anchored on `rect.midY` so adjacent rects stay
    /// pixel-aligned (no seams between adjacent tiles).
    fileprivate func drawImageUIKit(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -rect.midY)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
}

// MARK: - Route rendering

extension MapViewSource {
    func setRoutePolyline(_ polyline: MKPolyline?) {
        if let existing = routePolyline {
            mapView.removeOverlay(existing)
        }
        routePolyline = polyline
        if let polyline {
            mapView.addOverlay(polyline, level: .aboveRoads)
            // Cache coords for the BG composite path.
            let n = polyline.pointCount
            let pts = polyline.points()
            var coords: [CLLocationCoordinate2D] = []
            coords.reserveCapacity(n)
            for i in 0..<n { coords.append(pts[i].coordinate) }
            routePolylineCoords = coords
        } else {
            routePolylineCoords = []
        }
    }
}

// MARK: - Active-nav overlay (Phase 9e)
//
// Top-left maneuver glyph + "distance to next turn" text, burned into
// the same pixel buffer that gets H.264-encoded. The dash sees these
// as part of the projected map and can't tell them apart from the
// underlying tiles.
//
// State is pushed in from ActiveNavLoop on every nav tick. We snapshot
// just the values we need (kind + distance + road name) so we don't
// have to keep a strong ref to the navigator.

extension MapViewSource {
    struct NavOverlayState {
        var kind: ManeuverKind
        var distanceMeters: Double  // distance to next maneuver
        var roadName: String?       // current road, optional
        var unitsImperial: Bool     // for distance string formatting
    }

    /// Caller (typically ActiveNavLoop) pushes the latest nav state.
    /// Pass `nil` to clear the overlay (stops drawing).
    func setNavOverlay(_ state: NavOverlayState?) {
        self.navOverlayState = state
    }

    fileprivate func drawNavOverlay(into ctx: CGContext) {
        guard let s = navOverlayState else { return }

        // 1. Glyph in a 70×70 box at top-left, 12 px margin.
        // Add a soft dark backdrop so the white arrow + text reads
        // over bright map backgrounds.
        let pad: CGFloat = 12
        let backdrop = CGRect(x: pad - 6, y: pad - 6, width: 70 + 12, height: 70 + 12)
        ctx.saveGState()
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        let path = CGPath(
            roundedRect: backdrop,
            cornerWidth: 10,
            cornerHeight: 10,
            transform: nil
        )
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: pad, y: pad)
        ManeuverIcon.draw(s.kind, in: ctx)
        ctx.restoreGState()

        // 2. Distance label centred under the glyph backdrop.
        let distText = Self.formatDistance(meters: s.distanceMeters, imperial: s.unitsImperial)
        Self.drawText(
            distText,
            in: ctx,
            at: CGPoint(x: pad - 6, y: backdrop.maxY + 4),
            width: backdrop.width,
            fontSize: 18,
            bold: true
        )

        // 3. Road name to the right of the glyph, vertically centred.
        if let road = s.roadName, !road.isEmpty {
            let roadOriginX = backdrop.maxX + 10
            let roadWidth = frameSize.width - roadOriginX - pad
            Self.drawText(
                road,
                in: ctx,
                at: CGPoint(x: roadOriginX, y: pad + 20),
                width: roadWidth,
                fontSize: 22,
                bold: false
            )
        }
    }

    private static func formatDistance(meters m: Double, imperial: Bool) -> String {
        if imperial {
            let mi = m / 1609.344
            if m < 160 { // < ~0.1 mi → feet
                let ft = Int((m * 3.280839895).rounded())
                return "\(ft) ft"
            } else if mi < 10 {
                return String(format: "%.1f mi", mi)
            } else {
                return String(format: "%.0f mi", mi)
            }
        } else {
            if m < 1000 {
                return "\(Int(m.rounded())) m"
            } else if m < 10_000 {
                return String(format: "%.1f km", m / 1000.0)
            } else {
                return String(format: "%.0f km", m / 1000.0)
            }
        }
    }

    private static func drawText(
        _ text: String,
        in ctx: CGContext,
        at origin: CGPoint,
        width: CGFloat,
        fontSize: CGFloat,
        bold: Bool
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold
                ? UIFont.systemFont(ofSize: fontSize, weight: .bold)
                : UIFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -3.0  // negative = stroke + fill
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)

        // Core Text draws Y-up; our outer ctx is Y-down post-flip.
        // We flip locally so the text isn't upside-down.
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y + fontSize)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        // Truncate via clip — CT line will draw what fits and clip the
        // rest, which is good enough for road names.
        ctx.clip(to: CGRect(x: 0, y: -fontSize, width: width, height: fontSize * 1.6))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

// MARK: - Ride-alerts overlay (weather pill + speed cameras)
//
// Two burned-in overlays the rider asked for (6/2026), grouped here so
// the map/nav code above stays focused:
//
//   • Weather pill — a compact, glanceable badge in the BOTTOM-RIGHT
//     corner (chosen by the rider: doesn't overlap the route or the
//     forward-biased puck, and there's free space there). Transform-
//     independent: drawn in the flat outer Y-DOWN ctx so it stays pinned
//     to the same screen corner regardless of map rotation/zoom.
//
//   • Speed-camera markers — geo-anchored POIs. Their POSITION rides with
//     the map (we re-apply the exact same scale→rotate→translate CTM the
//     polyline uses, by hand, so a camera sits precisely on its road), but
//     the icon itself is drawn UPRIGHT and constant-size like a real map
//     pin, so it never ends up sideways when the map rotates heading-up.
//
// Both are pure CGContext paths (no asset catalog, no SF Symbols),
// matching the maneuver-glyph philosophy: legible over arbitrary OSM
// tiles after H.264 chroma subsampling.

extension MapViewSource {

    /// Push the latest weather alert (or `nil` to clear). Mirrors
    /// `setNavOverlay`'s shape so the nav pump drives both the same way.
    func setWeatherAlert(_ alert: WeatherAlert?) {
        self.weatherAlert = alert
    }

    /// Install the speed cameras to plot (prefetched along the route).
    /// Pass `[]` to clear.
    func setSpeedCameras(_ cameras: [SpeedCamera]) {
        self.speedCameras = cameras
    }

    // MARK: Speed-limit sign

    /// Install the speed-limit ways to map-match against (prefetched along
    /// the route). Pass `[]` to clear (also clears the current sign).
    func setSpeedLimits(_ ways: [SpeedLimitWay]) {
        self.speedLimitWays = ways
        if ways.isEmpty {
            currentLimitKmh = nil
            isOverSpeedLimit = false
        } else if let fix = lastFix {
            recomputeSpeedLimit(for: fix)
        }
    }

    /// Push the display policy from settings. `mode` is the raw
    /// `SpeedLimitDisplay` value ("off" / "always" / "overOnly"). Cheap —
    /// called on prefetch and every nav tick so a settings change takes
    /// effect on the next frame without a re-fetch.
    func setSpeedLimitConfig(mode: String, toleranceKmh: Double, imperial: Bool) {
        self.speedLimitMode = mode
        self.speedLimitToleranceKmh = toleranceKmh
        self.speedLimitImperial = imperial
    }

    /// Map-match the current GPS fix to the nearest tagged way and update
    /// `currentLimitKmh` / `isOverSpeedLimit` with snap + hysteresis. Runs
    /// at GPS cadence (~1 Hz), not per render frame.
    private func recomputeSpeedLimit(for fix: Fix) {
        guard speedLimitMode != "off", !speedLimitWays.isEmpty else {
            currentLimitKmh = nil
            isOverSpeedLimit = false
            return
        }
        guard let match = SpeedLimitService.nearestLimit(to: fix.coordinate,
                                                         ways: speedLimitWays) else {
            currentLimitKmh = nil
            isOverSpeedLimit = false
            return
        }
        // Hysteresis: acquire within snap, hold until beyond release.
        let haveSign = currentLimitKmh != nil
        let threshold = haveSign ? Self.limitReleaseMeters : Self.limitSnapMeters
        if match.distanceMeters <= threshold {
            currentLimitKmh = match.kmh
            // Over-limit check using GPS speed (m/s → km/h). `fix.speed`
            // is -1 when unknown; treat that as "not over".
            if fix.speed >= 0 {
                let speedKmh = fix.speed * 3.6
                isOverSpeedLimit = speedKmh > Double(match.kmh) + speedLimitToleranceKmh
            } else {
                isOverSpeedLimit = false
            }
        } else {
            currentLimitKmh = nil
            isOverSpeedLimit = false
        }
    }

    /// Whether the limit sign should draw this frame, given the mode and
    /// the current match/over-limit state.
    private var shouldDrawSpeedLimit: Bool {
        guard let _ = currentLimitKmh else { return false }
        switch speedLimitMode {
        case "always":   return true
        case "overOnly": return isOverSpeedLimit
        default:         return false   // "off"
        }
    }

    // MARK: Weather pill

    fileprivate func drawWeatherAlert(into ctx: CGContext) {
        guard let alert = weatherAlert else { return }

        let accent: CGColor = alert.severity == .warning
            ? CGColor(red: 0.93, green: 0.20, blue: 0.18, alpha: 1.0)   // red
            : CGColor(red: 1.00, green: 0.66, blue: 0.05, alpha: 1.0)   // amber

        // Layout constants. Glyph box + gap + text, inside a dark pill with
        // a coloured border so it reads over both light and dark tiles.
        let margin: CGFloat = 12
        let padX: CGFloat = 9
        let glyphSize: CGFloat = 22
        let gap: CGFloat = 7
        let fontSize: CGFloat = 15
        let pillH: CGFloat = 34

        // Measure the title so the pill hugs the text.
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let textW = (alert.title as NSString)
            .size(withAttributes: textAttrs).width.rounded(.up)

        let pillW = padX + glyphSize + gap + textW + padX
        // Bottom-right anchor (Y-DOWN: bottom = large y).
        let originX = frameSize.width - margin - pillW
        // Collision avoidance: the speed-limit sign owns the bottom-right
        // corner (it's the more persistent element). When it's showing,
        // lift the weather pill to sit ABOVE the sign instead of on top of
        // it. The sign is a `signDiameter` disc at the same margin, so the
        // pill's baseline moves up by the sign height + a small gap.
        let signBump: CGFloat = shouldDrawSpeedLimit
            ? Self.speedLimitSignDiameter + 8
            : 0
        let originY = frameSize.height - margin - pillH - signBump
        let pill = CGRect(x: originX, y: originY, width: pillW, height: pillH)

        // Backdrop: 78% black, 1.5 px coloured border.
        ctx.saveGState()
        let path = CGPath(roundedRect: pill, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.78))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.restoreGState()

        // Glyph, vertically centred in the pill.
        let glyphOrigin = CGPoint(x: pill.minX + padX, y: pill.midY - glyphSize / 2)
        ctx.saveGState()
        ctx.translateBy(x: glyphOrigin.x, y: glyphOrigin.y)
        drawWeatherGlyph(alert.glyph, in: ctx, size: glyphSize, tint: accent)
        ctx.restoreGState()

        // Title text, vertically centred. Reuse the same CoreText helper
        // the maneuver overlay uses (white + black stroke for contrast).
        let textOrigin = CGPoint(x: pill.minX + padX + glyphSize + gap,
                                 y: pill.midY - fontSize / 2 - 1)
        Self.drawText(alert.title, in: ctx, at: textOrigin,
                      width: textW + 4, fontSize: fontSize, bold: true)
    }

    /// Draw a weather pictograph in a `size`×`size` box whose origin is the
    /// CURRENT ctx origin (caller has translated). Y-DOWN coordinates
    /// (top-left origin) — silhouettes read fine either way. `tint` colours
    /// the active element (rain streaks, bolt, flake); the cloud base is
    /// light grey so it reads on the dark pill.
    private func drawWeatherGlyph(_ glyph: WeatherAlert.Glyph,
                                  in ctx: CGContext, size: CGFloat, tint: CGColor) {
        let cloudGrey = CGColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1.0)
        let s = size

        func fillCloud() {
            // Cloud = three overlapping discs on a flat base, upper-middle
            // of the box so there's room for rain/flakes beneath.
            ctx.setFillColor(cloudGrey)
            let baseY = s * 0.30
            ctx.fillEllipse(in: CGRect(x: s * 0.06, y: baseY + s * 0.06, width: s * 0.42, height: s * 0.42))
            ctx.fillEllipse(in: CGRect(x: s * 0.30, y: baseY - s * 0.02, width: s * 0.46, height: s * 0.46))
            ctx.fillEllipse(in: CGRect(x: s * 0.52, y: baseY + s * 0.08, width: s * 0.38, height: s * 0.38))
            ctx.fill(CGRect(x: s * 0.14, y: baseY + s * 0.26, width: s * 0.66, height: s * 0.20))
        }

        switch glyph {
        case .rain:
            fillCloud()
            ctx.setStrokeColor(tint)
            ctx.setLineWidth(max(1.6, s * 0.07))
            ctx.setLineCap(.round)
            for i in 0..<3 {
                let x = s * (0.28 + 0.22 * CGFloat(i))
                ctx.move(to: CGPoint(x: x, y: s * 0.74))
                ctx.addLine(to: CGPoint(x: x - s * 0.08, y: s * 0.94))
            }
            ctx.strokePath()

        case .storm:
            fillCloud()
            // Lightning bolt — filled zig-zag.
            ctx.setFillColor(tint)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: s * 0.52, y: s * 0.70))
            ctx.addLine(to: CGPoint(x: s * 0.40, y: s * 0.70))
            ctx.addLine(to: CGPoint(x: s * 0.50, y: s * 0.86))
            ctx.addLine(to: CGPoint(x: s * 0.42, y: s * 0.86))
            ctx.addLine(to: CGPoint(x: s * 0.56, y: s * 1.00))
            ctx.addLine(to: CGPoint(x: s * 0.50, y: s * 0.82))
            ctx.addLine(to: CGPoint(x: s * 0.58, y: s * 0.82))
            ctx.closePath()
            ctx.fillPath()

        case .snow:
            fillCloud()
            ctx.setFillColor(tint)
            for i in 0..<3 {
                let x = s * (0.30 + 0.20 * CGFloat(i))
                ctx.fillEllipse(in: CGRect(x: x - s * 0.04, y: s * 0.80, width: s * 0.08, height: s * 0.08))
            }

        case .ice:
            // Snowflake — 6 spokes from centre, no cloud.
            ctx.setStrokeColor(tint)
            ctx.setLineWidth(max(1.5, s * 0.06))
            ctx.setLineCap(.round)
            let cx = s * 0.5, cy = s * 0.5, r = s * 0.40
            for k in 0..<6 {
                let a = CGFloat(k) * .pi / 3
                ctx.move(to: CGPoint(x: cx, y: cy))
                ctx.addLine(to: CGPoint(x: cx + r * cos(a), y: cy + r * sin(a)))
            }
            ctx.strokePath()

        case .fog:
            // Three horizontal bars.
            ctx.setStrokeColor(cloudGrey)
            ctx.setLineWidth(max(1.8, s * 0.08))
            ctx.setLineCap(.round)
            for i in 0..<3 {
                let y = s * (0.34 + 0.20 * CGFloat(i))
                ctx.move(to: CGPoint(x: s * 0.16, y: y))
                ctx.addLine(to: CGPoint(x: s * 0.84, y: y))
            }
            ctx.strokePath()

        case .wind:
            // Two swoosh lines with a little hook.
            ctx.setStrokeColor(tint)
            ctx.setLineWidth(max(1.8, s * 0.08))
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: s * 0.14, y: s * 0.40))
            ctx.addCurve(to: CGPoint(x: s * 0.74, y: s * 0.34),
                         control1: CGPoint(x: s * 0.50, y: s * 0.22),
                         control2: CGPoint(x: s * 0.74, y: s * 0.18))
            ctx.move(to: CGPoint(x: s * 0.14, y: s * 0.64))
            ctx.addCurve(to: CGPoint(x: s * 0.66, y: s * 0.70),
                         control1: CGPoint(x: s * 0.50, y: s * 0.82),
                         control2: CGPoint(x: s * 0.66, y: s * 0.86))
            ctx.strokePath()
        }
    }

    // MARK: Speed cameras

    /// Plot each speed camera at its projected screen position. Re-applies
    /// the SAME composite transform the tile/polyline path uses (forward
    /// bias → heading rotation → zoom → geo-delta in px), computed by hand
    /// so we can then draw the icon UPRIGHT in the flat outer ctx. Cameras
    /// whose projected position falls outside the frame (+ margin) are
    /// culled.
    fileprivate func drawSpeedCameras(into ctx: CGContext,
                                      centerLat: Double, centerLon: Double,
                                      pxPerDegLon: Double, pxPerDegLat: Double) {
        guard !speedCameras.isEmpty else { return }

        let theta = -lastHeading * .pi / 180.0
        let cosT = cos(theta), sinT = sin(theta)
        // Keep the whole projection in Double; CGFloat↔Double don't mix
        // implicitly in Swift, and the geo-deltas are already Double. We
        // narrow to CGFloat only at the final CGPoint.
        let biasPx = Double(frameSize.height) * Double(forwardBiasFraction)
        let anchorX = Double(frameSize.width) / 2
        let anchorY = Double(frameSize.height) / 2 + biasPx
        let z = Double(currentZoom)
        let w = Double(frameSize.width), h = Double(frameSize.height)

        for cam in speedCameras {
            // Geo-delta in unrotated pixels (same formula as the polyline).
            let dx = (cam.coordinate.longitude - centerLon) * pxPerDegLon
            let dy = -(cam.coordinate.latitude - centerLat) * pxPerDegLat  // Y-DOWN: north = -y
            // Apply zoom, then the heading rotation (CGAffineTransform
            // rotation matrix), then the anchor translate. This reproduces
            // ctx.translate(anchor) · rotate(theta) · scale(z) acting on
            // the point — i.e. exactly where the tile path would put it.
            let zx = dx * z, zy = dy * z
            let rx = zx * cosT - zy * sinT
            let ry = zx * sinT + zy * cosT
            let sx = anchorX + rx
            let sy = anchorY + ry

            // Cull off-frame markers (with a margin so a half-visible icon
            // at the edge still appears).
            guard sx > -24, sx < w + 24,
                  sy > -24, sy < h + 24 else { continue }

            drawCameraMarker(into: ctx, at: CGPoint(x: sx, y: sy), camera: cam)
        }
    }

    /// One upright camera marker centred at screen point `p` (Y-DOWN outer
    /// ctx). A rounded teardrop pin in the camera's accent colour with a
    /// little camera body cut into it, plus the speed limit beneath when
    /// known. Section/average-speed cameras get a violet accent to set them
    /// apart from spot cameras (red).
    private func drawCameraMarker(into ctx: CGContext, at p: CGPoint, camera: SpeedCamera) {
        let accent: CGColor = camera.isSection
            ? CGColor(red: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)   // violet — section
            : CGColor(red: 0.90, green: 0.16, blue: 0.16, alpha: 1.0)   // red — spot

        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)

        // Marker disc (with white outline for contrast over any tile).
        let r: CGFloat = 11
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: -r - 1.5, y: -r - 1.5, width: (r + 1.5) * 2, height: (r + 1.5) * 2))
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))

        // Camera body (white): a rounded rect + a lens circle + a small
        // viewfinder bump, all inside the disc.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let body = CGRect(x: -7, y: -4.5, width: 14, height: 9)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.fillPath()
        // viewfinder bump on top-left
        ctx.fill(CGRect(x: -5.5, y: -6.5, width: 4, height: 2.5))
        // lens hole (accent shows through)
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: -2.6, y: -2.6, width: 5.2, height: 5.2))

        ctx.restoreGState()

        // Speed limit badge beneath the marker, when mapped. Small but
        // bold + stroked so it survives H.264. Skip for section cameras
        // without a number to avoid clutter.
        if let limit = camera.maxspeedKmh {
            let label = "\(limit)"
            let fontSize: CGFloat = 11
            let approxW = CGFloat(label.count) * fontSize * 0.62 + 6
            Self.drawText(label, in: ctx,
                          at: CGPoint(x: p.x - approxW / 2, y: p.y + r + 2),
                          width: approxW, fontSize: fontSize, bold: true)
        }
    }

    // MARK: Speed-limit sign

    /// Outer diameter (px) of the speed-limit sign disc. Exposed as a
    /// constant so the weather pill can hop above it on a collision.
    fileprivate static let speedLimitSignDiameter: CGFloat = 58
    /// Margin (px) from the frame edges, matched to the weather pill.
    fileprivate static let speedLimitSignMargin: CGFloat = 12

    /// Draw the posted speed-limit sign in the bottom-right corner: a
    /// European circular sign — white field, thick red ring, black number.
    /// Transform-independent (flat outer ctx) so it sits in a fixed screen
    /// spot regardless of map rotation/zoom, exactly like the weather pill.
    /// No-op unless `shouldDrawSpeedLimit`.
    fileprivate func drawSpeedLimitSign(into ctx: CGContext) {
        guard shouldDrawSpeedLimit, let kmh = currentLimitKmh else { return }

        // Value + (no) unit. A real road sign carries no unit text — the
        // disc shape IS the unit — so we show the bare number. Imperial
        // riders see the mph-converted number (OSM maxspeed is km/h).
        let value: Int = speedLimitImperial
            ? Int((Double(kmh) / 1.609344).rounded())
            : kmh
        let label = "\(value)"

        let d = Self.speedLimitSignDiameter
        let margin = Self.speedLimitSignMargin
        let r = d / 2
        // Bottom-right anchor (Y-DOWN: bottom = large y).
        let cx = frameSize.width - margin - r
        let cy = frameSize.height - margin - r

        ctx.saveGState()

        // Soft drop shadow so the sign lifts off busy map tiles.
        ctx.setShadow(offset: CGSize(width: 0, height: 1),
                      blur: 3, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        // White field (full disc).
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: d, height: d))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)   // shadow only on the base disc

        // Red ring: drawn as a stroked circle whose line width is the ring
        // thickness (~16% of the diameter, like the real sign).
        let ringW = d * 0.16
        let ringR = r - ringW / 2 - 1   // inset so the stroke stays inside the disc
        ctx.setStrokeColor(CGColor(red: 0.86, green: 0.12, blue: 0.12, alpha: 1.0))
        ctx.setLineWidth(ringW)
        ctx.strokeEllipse(in: CGRect(x: cx - ringR, y: cy - ringR,
                                     width: ringR * 2, height: ringR * 2))

        ctx.restoreGState()

        // Black number, centred in the white field. Size scales down for
        // 3-digit limits (e.g. 130) so it still fits inside the ring.
        let fontSize: CGFloat = label.count >= 3 ? d * 0.40 : d * 0.48
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let textOrigin = CGPoint(x: cx - textSize.width / 2,
                                 y: cy - textSize.height / 2)
        UIGraphicsPushContext(ctx)
        (label as NSString).draw(at: textOrigin, withAttributes: attrs)
        UIGraphicsPopContext()
    }
}

// MARK: - MKMapViewDelegate

extension MapViewSource: MKMapViewDelegate {
    nonisolated func mapView(_: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polyline = overlay as? MKPolyline {
            let r = MKPolylineRenderer(polyline: polyline)
            r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85)
            r.lineWidth = 6
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}

// MARK: - SwiftUI host

import SwiftUI

struct MapViewHost: UIViewRepresentable {
    let source: MapViewSource

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = .black
        container.addSubview(source.hostView)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let mapView = source.hostView
        let native = source.frameSize
        let bounds = container.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard mapView.superview === container else { return }

        mapView.transform = .identity
        mapView.translatesAutoresizingMaskIntoConstraints = true
        mapView.frame = CGRect(origin: .zero, size: native)
        let scale = min(bounds.width / native.width, bounds.height / native.height)
        mapView.transform = CGAffineTransform(scaleX: scale, y: scale)
        mapView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
