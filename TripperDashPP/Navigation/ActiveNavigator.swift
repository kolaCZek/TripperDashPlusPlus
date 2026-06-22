//
//  ActiveNavigator.swift
//  TripperDashPP
//
//  Phase 7f — owns the *active* navigation session. Subscribes to
//  LocationService updates, computes on-route status, remaining
//  distance, upcoming maneuver, and ETA. Phase 7h adds reroute
//  hysteresis on top.
//
//  Lifecycle: start(route:) → tick on each location update → stop().
//  All published state goes through @Observable so the HUD reactively
//  updates without timers in the view.
//

import CoreLocation
import Foundation
import MapKit
import os
import Observation

@MainActor
@Observable
final class ActiveNavigator {

    // MARK: - Published state

    /// True once start(route:) was called and we haven't stopped.
    private(set) var isNavigating: Bool = false

    /// The route currently being followed (may be replaced on reroute).
    private(set) var activeRoute: MKRoute?

    /// The destination we set out for.
    private(set) var destination: Destination?

    /// Meters remaining to the destination along the current route.
    private(set) var remainingDistance: CLLocationDistance = 0

    /// Live ETA in seconds. F4: derived from `remainingDistance /
    /// smoothedSpeed`, with the route's `expectedTravelTime`-derived
    /// ratio as the cold-start fallback. Reacts to actual rider speed
    /// instead of assuming the original Apple Maps average.
    private(set) var etaSeconds: TimeInterval = 0

    /// EWMA-smoothed ground speed in m/s. Updated on every `ingest`
    /// when the GPS reports a valid (>=0) speed. Initial 0 means
    /// "not yet known" — caller falls back to the ratio estimator.
    private var smoothedSpeedMps: Double = 0
    /// Number of valid speed samples folded into `smoothedSpeedMps`.
    /// We require at least 3 before trusting the live estimate so a
    /// single noisy first fix doesn't dominate.
    private var validSpeedSamples: Int = 0
    /// Smoothing factor for the EWMA. ~30 s effective window at 1 Hz
    /// fix rate (`alpha=0.1` → time constant ≈ 1/alpha = 10 samples).
    /// Smooths out red-lights and gear changes without lagging real
    /// speed changes (highway entry / village exit) by more than ~10 s.
    private let speedEwmaAlpha: Double = 0.1
    /// Minimum speed (m/s) we feed into the ETA divider so a stop at
    /// a light doesn't blow ETA up to "arrive in 12 hours". 2 m/s ≈
    /// 7 km/h, slow-roll pace.
    private let etaMinSpeedMps: Double = 2.0
    /// Sanity cap: ETA never grows beyond 4× the original Apple Maps
    /// expected travel time. Prevents a stretch of stop-and-go from
    /// projecting an absurd arrival time.
    private let etaMaxRatio: Double = 4.0

    /// The next maneuver step the rider should anticipate.
    private(set) var nextStep: MKRoute.Step?

    /// Distance from current position to the next maneuver.
    private(set) var distanceToNextStep: CLLocationDistance = 0

    /// F2c: the maneuver after `nextStep` — the look-ahead. Nil if
    /// `nextStep` is already the destination (no further turns).
    /// Populated unconditionally; whether we actually emit the
    /// secondary TLV chain depends on `distanceToNextStep`
    /// versus the lookahead threshold (decided downstream in
    /// `ActiveNavLoop`).
    private(set) var secondNextStep: MKRoute.Step?

    /// Distance from the *current position* to the secondary
    /// maneuver. This is `distanceToNextStep + secondNextStep.distance`
    /// — the next step's distance field is measured FROM the previous
    /// maneuver TO this step's maneuver point, so it's also the
    /// "between primary and secondary" leg length.
    private(set) var distanceToSecondNextStep: CLLocationDistance = 0

    /// True if we're currently off-route. Reroute logic in 7h reads
    /// this together with the timestamps below.
    private(set) var isOffRoute: Bool = false

    /// Whether a reroute is currently in flight.
    private(set) var isRerouting: Bool = false

    // MARK: - Multi-stop plan state (feat/route-waypoints)

    /// The multi-stop plan being navigated, when started via
    /// `start(plan:)`. nil for the classic single-destination path
    /// (`start(route:destination:)`), which behaves exactly as before.
    private(set) var plan: PlannedRoute?

    /// Index into `plan.legs` of the leg currently being navigated.
    /// `activeRoute` is always the selected MKRoute of this leg (or a
    /// reroute thereof).
    private(set) var currentLegIndex: Int = 0

    /// Number of legs still to drive, INCLUDING the current one. 1 on
    /// the final leg. 0 when not plan-navigating. Drives the HUD's
    /// "stop N of M" pill.
    private(set) var remainingWaypoints: Int = 0

    /// Distance (m) to the current leg's end waypoint at which we
    /// switch to the next leg. Same order of magnitude as a
    /// destination arrival. Kept below the off-route threshold (60 m)
    /// so leg-advance wins over a reroute near the waypoint.
    private let legArrivalThreshold: CLLocationDistance = 30

    // MARK: - Reroute hysteresis state (7h)

    private var offRouteSince: Date?
    private var lastRerouteAt: Date = .distantPast
    private let offRouteDistanceThreshold: CLLocationDistance = 60   // m
    private let offRouteDurationThreshold: TimeInterval = 5          // s
    private let rerouteCooldown: TimeInterval = 30                   // s

    // MARK: - Internals

    private var lastSegmentIndex: Int = 0
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "ActiveNavigator")

    /// Caller hook for when we lose the route and want a new one.
    /// Set by AppStatus / RootView so the navigator can call back into
    /// RoutingService without owning a reference to it.
    var onRerouteRequested: ((@MainActor (CLLocationCoordinate2D, Destination) async -> MKRoute?))?

    /// Caller hook fired whenever the active route is replaced —
    /// fresh `start()` AND every successful reroute. Callers wire
    /// this to: (1) push the new polyline into `MapViewSource` so
    /// the dash + Map UI render the right line, (2) tear down the
    /// stale `RouteTileCache` and pre-render a new one. Without
    /// this, a reroute updates the navigator's internal state but
    /// the rider keeps seeing the old blue line until they restart
    /// navigation from scratch.
    var onActiveRouteChanged: (@MainActor (MKRoute) async -> Void)?

    // MARK: - API

    /// Classic single-destination entry point. Unchanged behaviour —
    /// used by reroute and as the n=2 fallback. Internally seeds with
    /// no plan, so leg-advance never triggers.
    func start(route: MKRoute, destination: Destination) async {
        self.plan = nil
        self.currentLegIndex = 0
        self.remainingWaypoints = 0
        seed(route: route, destination: destination)
        self.isNavigating = true
        log.info("Navigation started to \(destination.name, privacy: .public) — \(Int(route.distance)) m / \(Int(route.expectedTravelTime)) s")
        await onActiveRouteChanged?(route)
    }

    /// Multi-stop entry point (feat/route-waypoints). Drives the legs of
    /// `plan` one at a time starting at `fromLegIndex`. `activeRoute` is
    /// the selected MKRoute of the current leg; everything downstream
    /// (PolylineMath, tile cache, ActiveNavLoop, maneuver TLVs) sees a
    /// single MKRoute exactly as in the single-destination case.
    func start(plan: PlannedRoute, fromLegIndex: Int = 0) async {
        guard plan.isComputed, !plan.legs.isEmpty else {
            log.error("start(plan:) called with an uncomputed plan — ignoring")
            return
        }
        self.plan = plan
        self.currentLegIndex = max(0, min(fromLegIndex, plan.legs.count - 1))
        self.remainingWaypoints = plan.legs.count - self.currentLegIndex

        let leg = plan.legs[self.currentLegIndex]
        guard let route = leg.selected?.route,
              let destWp = plan.waypoint(id: leg.toWaypointId) else {
            log.error("start(plan:) — current leg has no selected route — ignoring")
            return
        }
        seed(route: route, destination: destWp.asDestination)
        self.isNavigating = true
        log.info("Multi-stop navigation started — leg \(self.currentLegIndex + 1)/\(plan.legs.count) to \(destWp.name, privacy: .public)")
        await onActiveRouteChanged?(route)
    }

    /// Seed all per-leg display + geometry state from a single route.
    /// Shared by both entry points and by leg-advance. Does NOT flip
    /// `isNavigating` or fire `onActiveRouteChanged` — the caller owns
    /// those so it can order them correctly.
    private func seed(route: MKRoute, destination: Destination) {
        self.activeRoute = route
        self.destination = destination
        self.lastSegmentIndex = 0
        self.offRouteSince = nil
        self.isOffRoute = false
        // Seed initial display values from the route itself.
        self.remainingDistance = route.distance
        self.etaSeconds = route.expectedTravelTime
        self.nextStep = route.steps.first
        self.distanceToNextStep = route.steps.first?.distance ?? 0
        self.secondNextStep = route.steps.dropFirst().first
        self.distanceToSecondNextStep = (route.steps.first?.distance ?? 0)
            + (route.steps.dropFirst().first?.distance ?? 0)
    }

    func stop() {
        log.info("Navigation stopped")
        self.isNavigating = false
        self.activeRoute = nil
        self.destination = nil
        self.remainingDistance = 0
        self.etaSeconds = 0
        self.nextStep = nil
        self.distanceToNextStep = 0
        self.secondNextStep = nil
        self.distanceToSecondNextStep = 0
        // F4: drop the smoothed-speed history so the next route
        // starts cold and doesn't inherit yesterday's average.
        self.smoothedSpeedMps = 0
        self.validSpeedSamples = 0
        self.isOffRoute = false
        self.offRouteSince = nil
        // Multi-stop: drop the plan so the next session starts fresh.
        self.plan = nil
        self.currentLegIndex = 0
        self.remainingWaypoints = 0
    }

    /// Push a fresh GPS fix into the navigator. Call from a location
    /// observer wherever the app already digests fixes (e.g.
    /// AppStatus.observe(locationService:)).
    func ingest(fix: Fix) async {
        guard isNavigating, let route = activeRoute else { return }
        let coord = fix.coordinate

        let (distFromRoute, segIdx) = PolylineMath.nearestSegment(
            on: route.polyline,
            from: lastSegmentIndex,
            to: coord
        )
        self.lastSegmentIndex = segIdx

        let remaining = PolylineMath.remainingDistance(
            on: route.polyline,
            from: segIdx,
            currentCoord: coord
        )
        self.remainingDistance = remaining

        // Multi-stop leg advance: if we're plan-navigating and within
        // the arrival radius of the CURRENT leg's end waypoint, and
        // there's another leg after this one, switch to it. This runs
        // BEFORE off-route/reroute so arriving at an intermediate
        // waypoint advances the leg instead of triggering a reroute to
        // the same waypoint. Returns early — the next tick ingests
        // against the new leg's route.
        if let plan, currentLegIndex < plan.legs.count - 1,
           remaining <= legArrivalThreshold {
            await advanceToNextLeg(in: plan)
            return
        }

        // F4: live ETA. Fold the GPS-reported speed into an EWMA; once
        // we have a few valid samples and the smoothed speed is above
        // the floor, divide remaining distance by it. Otherwise fall
        // back to the route-ratio estimator (matches what Apple Maps
        // does pre-CarPlay).
        if fix.speed >= 0 {
            if validSpeedSamples == 0 {
                smoothedSpeedMps = fix.speed
            } else {
                smoothedSpeedMps = (1 - speedEwmaAlpha) * smoothedSpeedMps
                    + speedEwmaAlpha * fix.speed
            }
            validSpeedSamples += 1
        }
        self.etaSeconds = computeEta(remaining: remaining, route: route)

        // Next maneuver lookup.
        if let stepIdx = PolylineMath.nextStepIndex(in: route, afterPolylineIndex: segIdx),
           stepIdx < route.steps.count {
            let step = route.steps[stepIdx]
            self.nextStep = step
            self.distanceToNextStep = PolylineMath.haversine(
                coord,
                step.polyline.points()[0].coordinate
            )
            // F2c: secondary maneuver = step *after* the next one, if
            // any. `step.distance` is the leg length from this step's
            // start to the following maneuver — so the distance from
            // the rider to the secondary turn is "distance to primary
            // turn + distance the primary leg itself covers". That
            // matches what the dash expects in the 0x05 TLV.
            let secondIdx = stepIdx + 1
            if secondIdx < route.steps.count {
                let secondStep = route.steps[secondIdx]
                self.secondNextStep = secondStep
                self.distanceToSecondNextStep = self.distanceToNextStep
                    + secondStep.distance
            } else {
                self.secondNextStep = nil
                self.distanceToSecondNextStep = 0
            }
        }

        // On-route detection + hysteresis-based reroute trigger.
        let nowOff = distFromRoute > offRouteDistanceThreshold
        if nowOff {
            if offRouteSince == nil { offRouteSince = .now }
            self.isOffRoute = true
            if let since = offRouteSince,
               Date.now.timeIntervalSince(since) >= offRouteDurationThreshold,
               Date.now.timeIntervalSince(lastRerouteAt) >= rerouteCooldown,
               !isRerouting {
                await requestReroute(from: coord)
            }
        } else {
            offRouteSince = nil
            self.isOffRoute = false
        }
    }

    // MARK: - Reroute

    private func requestReroute(from coord: CLLocationCoordinate2D) async {
        guard let dest = destination, let cb = onRerouteRequested else { return }
        isRerouting = true
        defer { isRerouting = false }
        lastRerouteAt = .now
        log.info("Requesting reroute from \(coord.latitude),\(coord.longitude) to \(dest.name, privacy: .public)")
        if let newRoute = await cb(coord, dest) {
            log.info("Reroute succeeded — swapping active route")
            self.activeRoute = newRoute
            self.lastSegmentIndex = 0
            self.offRouteSince = nil
            self.isOffRoute = false
            self.remainingDistance = newRoute.distance
            // F4: reroute keeps the smoothed-speed history so ETA
            // reflects how the rider was actually moving, not the
            // route's untouched expected average. Falls back to the
            // route's expectedTravelTime when we haven't gathered
            // enough samples yet.
            self.etaSeconds = computeEta(remaining: newRoute.distance, route: newRoute)
            self.nextStep = newRoute.steps.first
            self.distanceToNextStep = newRoute.steps.first?.distance ?? 0
            // F2c: rebuild secondary too. Reroute usually keeps the
            // first step short (Apple Maps fences the next maneuver),
            // so the look-ahead is most useful right after a reroute.
            self.secondNextStep = newRoute.steps.dropFirst().first
            self.distanceToSecondNextStep = (newRoute.steps.first?.distance ?? 0)
                + (newRoute.steps.dropFirst().first?.distance ?? 0)
            // Fire the route-changed hook so Map UI repaints the new
            // blue line and the tile cache re-bakes around the new
            // polyline. Without this the rider sees the OLD line
            // floating on the dash even though we're internally
            // navigating the new route — confusing and dangerous.
            await onActiveRouteChanged?(newRoute)
        } else {
            log.warning("Reroute failed — keeping existing route, will retry after cooldown")
        }
    }

    // MARK: - Leg advance (multi-stop)

    /// Switch from the current leg to the next one. Reuses `seed(...)`
    /// to reset all display/geometry state, then fires the same
    /// `onActiveRouteChanged` hook reroute uses — so the polyline swap
    /// and tile re-bake are already wired for free. Called from
    /// `ingest(fix:)` when the rider reaches an intermediate waypoint.
    private func advanceToNextLeg(in plan: PlannedRoute) async {
        let next = currentLegIndex + 1
        guard plan.legs.indices.contains(next) else { return }
        let leg = plan.legs[next]
        guard let route = leg.selected?.route,
              let destWp = plan.waypoint(id: leg.toWaypointId) else {
            log.error("Leg advance \(self.currentLegIndex)→\(next): next leg has no selected route — staying put")
            return
        }
        log.info("Leg advance \(self.currentLegIndex + 1)→\(next + 1) of \(plan.legs.count) — now to \(destWp.name, privacy: .public)")
        currentLegIndex = next
        remainingWaypoints = plan.legs.count - next
        // Keep the smoothed-speed history across legs — the rider's
        // pace doesn't reset at a waypoint, so ETA on the new leg
        // should start from how they were actually moving.
        seed(route: route, destination: destWp.asDestination)
        await onActiveRouteChanged?(route)
    }

    // MARK: - ETA helper

    /// F4: live ETA estimator. Prefers `remaining / smoothedSpeed`
    /// once we've collected at least 3 valid samples and the smoothed
    /// speed is above the slow-roll floor. Otherwise falls back to
    /// the original ratio estimator. Clamps the result so a long
    /// stop-and-go burst can't project a comical arrival time.
    private func computeEta(remaining: CLLocationDistance, route: MKRoute) -> TimeInterval {
        // Cold start / stopped: fall back to the route-ratio estimator
        // (same behaviour as before F4).
        let ratio = route.distance > 0 ? remaining / route.distance : 0
        let ratioEta = route.expectedTravelTime * ratio

        guard validSpeedSamples >= 3, smoothedSpeedMps > etaMinSpeedMps else {
            return ratioEta
        }

        let liveEta = remaining / smoothedSpeedMps
        // Sanity cap: never project more than `etaMaxRatio` × the
        // original expected travel time. Protects against pathological
        // bursts (jam, mechanical stop) blowing the ETA into the next
        // day. The ratio estimator already self-limits to
        // `expectedTravelTime`, so the cap only ever bites the live
        // branch.
        let cap = route.expectedTravelTime * etaMaxRatio
        return min(liveEta, cap)
    }

    // MARK: - Formatting helpers

    /// "320 m" under 1 km, "1.4 km" otherwise. Both the HUD and the
    /// dash maneuver card render this string so the rider's eye sees
    /// the same number in both places.
    static func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f km", meters / 1000)
    }
}

/// SF Symbol picker for an MKRoute.Step maneuver. Apple doesn't expose
/// a typed maneuver enum on MKRoute.Step — we have to NLP the
/// instructions string. Best-effort, falls back to a generic arrow
/// so we always have something to draw.
enum ManeuverGlyph {
    static func symbol(for step: MKRoute.Step) -> String {
        let s = step.instructions.lowercased()
        // Czech + English heuristics — Apple Maps returns localized
        // instructions in the system language, which on this user's
        // device is Czech.
        if s.contains("u-turn") || s.contains("otočte") || s.contains("otočit") {
            return "arrow.uturn.left"
        }
        if s.contains("sharp left") || s.contains("ostře vlevo") || s.contains("ostře doleva") {
            return "arrow.turn.up.left"
        }
        if s.contains("sharp right") || s.contains("ostře vpravo") || s.contains("ostře doprava") {
            return "arrow.turn.up.right"
        }
        if s.contains("slight left") || s.contains("mírně vlevo") || s.contains("mírně doleva") {
            return "arrow.up.left"
        }
        if s.contains("slight right") || s.contains("mírně vpravo") || s.contains("mírně doprava") {
            return "arrow.up.right"
        }
        if s.contains("left") || s.contains("vlevo") || s.contains("doleva") {
            return "arrow.turn.up.left"
        }
        if s.contains("right") || s.contains("vpravo") || s.contains("doprava") {
            return "arrow.turn.up.right"
        }
        if s.contains("arrive") || s.contains("destination") || s.contains("cíl") {
            return "mappin.and.ellipse"
        }
        if s.contains("merge") || s.contains("zařaďte") {
            return "arrow.merge"
        }
        if s.contains("exit") || s.contains("sjeďte") || s.contains("sjezd") {
            return "arrow.up.right.square"
        }
        return "arrow.up"
    }
}
