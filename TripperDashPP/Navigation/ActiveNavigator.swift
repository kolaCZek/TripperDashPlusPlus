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

    /// True once we've reached the final destination. The HUD shows an
    /// "arrived" confirmation; MapPickerView auto-dismisses after a few
    /// seconds and AppStatus tears down the stream the moment this flips.
    private(set) var hasArrived: Bool = false

    /// The route currently being followed (may be replaced on reroute).
    private(set) var activeRoute: MKRoute?

    /// The destination we set out for.
    private(set) var destination: Destination?

    /// Meters remaining to the destination along the current route.
    private(set) var remainingDistance: CLLocationDistance = 0

    /// Live ETA in seconds. F5 hybrid: a ratio backbone
    /// (`expectedTravelTime * remaining/distance`) corrected by a slowly
    /// tracked pace factor (actual/planned ground speed). The backbone
    /// reacts to POSITION — at a stop `remaining` freezes so the arrival
    /// time only ticks forward, never jumps — while the pace factor bends
    /// the estimate for a rider who sustains a faster/slower pace than
    /// Apple assumed. eta = ratioEta / paceFactor. Replaces F4's
    /// `remaining / instantaneousSpeed`, which whipsawed at every traffic
    /// light because it divided by current speed instead of long-run pace.
    private(set) var etaSeconds: TimeInterval = 0

    /// ETA to the FINAL destination of the whole plan, in seconds from
    /// now. For a single-destination route (`plan == nil`) this is
    /// identical to `etaSeconds` — the current leg IS the destination.
    /// For a multi-stop plan it's `etaSeconds` (the current leg's live,
    /// pace-corrected estimate) plus the PLANNED `travelTime` of every
    /// leg still ahead — those haven't been ridden yet, so there's no
    /// live pace signal for them; only the leg in progress gets the
    /// pace correction. Computed (not cached) so it always reflects the
    /// latest `etaSeconds`/`currentLegIndex` with no extra update sites
    /// to wire through seed/ingest/reroute/leg-advance.
    ///
    /// Used by: `NavigationHUD`'s final-ETA pill (phone shows both this
    /// AND the per-leg `etaSeconds`) and `ActiveNavLoop`, which sends
    /// ONLY this value to the dash (Martin, 6/2026 — the dash has no
    /// room to show two ETAs, and the whole-trip arrival is more useful
    /// than the next-stop one while riding a multi-stop plan).
    var finalDestinationEtaSeconds: TimeInterval {
        guard let plan, currentLegIndex < plan.legs.count else { return etaSeconds }
        let remainingLegsTime = plan.legs[(currentLegIndex + 1)...]
            .reduce(0.0) { $0 + ($1.selected?.travelTime ?? 0) }
        return etaSeconds + remainingLegsTime
    }

    /// EWMA of (actual ground speed / planned route speed). 1.0 = exactly
    /// Apple's assumed pace; >1 = rider faster than plan (ETA shrinks);
    /// <1 = slower (ETA grows). Only folded while genuinely moving, so a
    /// red light freezes it rather than dragging it toward zero. Starts at
    /// 1.0 = "assume Apple's pace until proven otherwise".
    private var paceFactor: Double = 1.0
    /// Count of moving samples folded into `paceFactor`. Require a few
    /// before trusting it so one noisy fix doesn't bend the ETA.
    private var paceSamples: Int = 0
    /// EWMA alpha for the pace factor. ~100 s time constant at 1 Hz fix
    /// rate (1/alpha = 100 samples): a sustained road-type change (90 km/h
    /// stretch, slow village crawl) bends ETA over a minute or two; a stop
    /// or a gear change is averaged out instead of jolting the display.
    private let paceEwmaAlpha: Double = 0.01
    /// Below this the rider is stopped/crawling: don't fold pace (freeze)
    /// and don't trust live correction. 3 m/s ≈ 11 km/h.
    private let paceMinMovingMps: Double = 3.0
    /// Clamp so a wild GPS burst can't more than double or halve ETA.
    private let paceFactorMin: Double = 0.5
    private let paceFactorMax: Double = 2.0

    /// The DEPARTING step at the upcoming maneuver node — the step whose
    /// polyline LEAVES the node. Supplies the OUTGOING heading for the
    /// geometric turn-direction classifier (`ManeuverKind.classify` →
    /// `ManeuverGeometry`). NOTE: despite the name this is NOT the step
    /// whose `.instructions` describe the upcoming maneuver — Apple's
    /// end-of-polyline convention puts that text on `stepBeforeNext` (the
    /// step ENDING at the node). Read the upcoming maneuver via
    /// `upcomingManeuver` / `upcomingInstructions`, never this directly.
    private(set) var nextStep: MKRoute.Step?

    /// The ARRIVING step the rider is currently COMPLETING — the one whose
    /// polyline ENDS at the upcoming maneuver node. Two roles: (1) its
    /// `.instructions` describe the upcoming maneuver (Apple puts the turn
    /// text on the step that ends at the node), and (2) its polyline tail
    /// supplies the INCOMING heading for the geometric turn classifier.
    /// `nil` only in the brief transient before the first GPS fix maps the
    /// rider onto a step, when classification falls back to text.
    private(set) var stepBeforeNext: MKRoute.Step?

    /// The step BEFORE `stepBeforeNext`. Used only to carry a roundabout's
    /// exit ordinal forward across MapKit's split entry/exit roundabout
    /// steps (the exit step drops the ordinal — see `ManeuverKind.classify`).
    /// `nil` when the arriving step is the route's first.
    private(set) var precedingStep: MKRoute.Step?

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
    /// maneuver. This is `distanceToNextStep + nextStep.distance` — the
    /// length of `nextStep`'s polyline IS the leg from the primary
    /// maneuver node (its start) to the secondary maneuver node (its
    /// end), so adding it to the distance-to-primary gives the
    /// distance-to-secondary. (Previously this added `secondNextStep`'s
    /// distance — the leg AFTER the secondary node — overshooting the
    /// look-ahead chip by a whole extra step; field logs 6/2026.)
    private(set) var distanceToSecondNextStep: CLLocationDistance = 0

    // MARK: - Derived maneuver model (single source of truth)
    //
    // Apple's `MKRoute.Step.instructions` describes the maneuver at the
    // END of that step's polyline (the turn ONTO the next road), so the
    // step whose `.instructions` name the UPCOMING maneuver is the one the
    // rider is currently traversing — the ARRIVING step (`stepBeforeNext`),
    // whose polyline ends at the upcoming node — NOT `nextStep` (whose
    // polyline LEAVES the node and carries the maneuver AFTER next). These
    // computed properties are the ONE place that pairing is resolved, so a
    // consumer can never reintroduce the off-by-one by reading
    // `nextStep?.instructions` directly.

    /// The fully classified UPCOMING maneuver (text-family + geometry-
    /// direction). Text/family from the arriving step's instructions;
    /// direction from the angle between the arriving leg (into the node)
    /// and the departing leg (`nextStep`, out of the node). `nil` only in
    /// the pre-first-fix transient when no arriving step is known yet.
    var upcomingManeuver: ManeuverKind? {
        guard let arriving = stepBeforeNext else { return nil }
        return ManeuverKind.classify(arrivingStep: arriving,
                                     departingStep: nextStep,
                                     precedingStep: precedingStep)
    }

    /// The localized instruction text for the UPCOMING maneuver — the
    /// arriving step's `.instructions` (the turn at the end of the leg the
    /// rider is on), NOT `nextStep`'s (which is one maneuver further on).
    var upcomingInstructions: String? { stepBeforeNext?.instructions }

    /// The fully classified LOOK-AHEAD (secondary) maneuver — the one
    /// after `upcomingManeuver`. Its arriving step is `nextStep` (whose
    /// polyline ends at the secondary node) and its departing step is
    /// `secondNextStep`. `nil` when there's no step after next (last leg).
    var lookaheadManeuver: ManeuverKind? {
        guard let arriving = nextStep, let departing = secondNextStep else { return nil }
        return ManeuverKind.classify(arrivingStep: arriving,
                                     departingStep: departing,
                                     precedingStep: stepBeforeNext)
    }

    /// True if we're currently off-route. Reroute logic in 7h reads
    /// this together with the timestamps below.
    private(set) var isOffRoute: Bool = false

    /// Whether a reroute is currently in flight.
    private(set) var isRerouting: Bool = false

    /// Most recent GPS coordinate fed into the navigator via `ingest(fix:)`.
    /// Read-only for consumers (e.g. `ManeuverLog` records where each glyph
    /// was shown). `nil` until the first fix lands. Minimal surface: the
    /// navigator already digests the fix; we just retain its coordinate.
    private(set) var currentCoordinate: CLLocationCoordinate2D?

    // MARK: - Route overview geometry (feat/nav-route-overview-map)

    /// Real GPS breadcrumb of where the rider has ACTUALLY been, thinned
    /// to ~`breadcrumbMinSpacing` m spacing. Drives the grey "travelled"
    /// part of the navigation overview map. Held ACROSS reroutes (a
    /// reroute replaces the route *ahead*, never the past) so the
    /// travelled trace never vanishes when the blue line is swapped —
    /// the rider keeps a continuous "you came from here" progress bar.
    /// Reset only on a fresh `start(...)` and `stop()`.
    private(set) var traveledCoordinates: [CLLocationCoordinate2D] = []

    /// Materialised coordinates of the CURRENT active route (the leg the
    /// rider is on). Refreshed on every active-route swap — `start`,
    /// reroute, leg-advance — and NEVER per fix, so slicing it for the
    /// "ahead" overview each frame is a cheap array op instead of a
    /// full `MKPolyline` materialisation.
    private var activeRouteCoordsCache: [CLLocationCoordinate2D] = []

    /// Materialised coordinates of all plan legs AFTER the current one,
    /// concatenated in order. Empty for single-destination nav and once
    /// the rider is on the final leg. Refreshed whenever the leg /plan
    /// changes (`seed` sees the up-to-date `plan`/`currentLegIndex`),
    /// NOT on reroute (a reroute only swaps the current leg's route).
    private var subsequentLegsCoordsCache: [CLLocationCoordinate2D] = []

    /// Minimum spacing between retained breadcrumb points. 30 m keeps
    /// the travelled trace faithful to the road shape on a 150 pt
    /// overview thumbnail while bounding the array to a few thousand
    /// points even on a multi-hour ride.
    private let breadcrumbMinSpacing: CLLocationDistance = 30

    /// The route still AHEAD of the rider, for the overview map: the
    /// current route sliced from the nearest segment onward, plus any
    /// subsequent plan legs. Cheap — slices the cached arrays, no
    /// polyline materialisation. The grey breadcrumb + this blue line
    /// together span the whole planned route start→finish.
    var routeAheadCoordinates: [CLLocationCoordinate2D] {
        guard !activeRouteCoordsCache.isEmpty else { return subsequentLegsCoordsCache }
        let start = min(max(0, lastSegmentIndex), activeRouteCoordsCache.count - 1)
        var ahead = Array(activeRouteCoordsCache[start...])
        ahead.append(contentsOf: subsequentLegsCoordsCache)
        return ahead
    }

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

    /// Arrival radius for the FINAL destination. Same order as the leg
    /// threshold; the rider has stopped, so a few metres is plenty.
    private let destinationArrivalThreshold: CLLocationDistance = 25

    /// Set true once we've been at least 2× the arrival radius away from
    /// the destination. Guards against firing arrival on the very first
    /// fix of a short route (where remaining can start below the radius).
    private var hasBeenUnderway: Bool = false

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

    /// Fired once when the rider reaches the FINAL destination (single
    /// route, or the last leg of a plan). AppStatus wires this to tear
    /// down the stream + route artefacts. Distinct from a leg-advance,
    /// which is internal and silent.
    var onArrived: (@MainActor () -> Void)?

    // MARK: - API

    /// Classic single-destination entry point. Unchanged behaviour —
    /// used by reroute and as the n=2 fallback. Internally seeds with
    /// no plan, so leg-advance never triggers.
    func start(route: MKRoute, destination: Destination) async {
        self.plan = nil
        self.currentLegIndex = 0
        self.remainingWaypoints = 0
        self.hasArrived = false
        self.hasBeenUnderway = false
        self.traveledCoordinates = []   // fresh ride → empty breadcrumb
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
        self.hasArrived = false
        self.hasBeenUnderway = false
        self.traveledCoordinates = []   // fresh ride → empty breadcrumb

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
        // Seed the maneuver model to the SAME shape ingest() produces on
        // the first fix: the rider is about to traverse steps[0] (the
        // ARRIVING step whose polyline ends at the first maneuver node and
        // whose `.instructions` name that maneuver), departing via
        // steps[1]. Reading text from the arriving step — not the
        // departing one — is the off-by-one fix; see `upcomingManeuver`.
        self.stepBeforeNext = route.steps.first          // arriving (text + incoming leg)
        self.nextStep = route.steps.dropFirst().first    // departing (outgoing leg)
        self.precedingStep = nil                         // nothing before the first step
        self.distanceToNextStep = route.steps.first?.distance ?? 0
        self.secondNextStep = route.steps.dropFirst(2).first
        // distance-to-secondary = distance-to-primary + the primary
        // (departing) step's own length (primary node → secondary node).
        self.distanceToSecondNextStep = (route.steps.first?.distance ?? 0)
            + (route.steps.dropFirst().first?.distance ?? 0)
        // Refresh the overview caches. `plan`/`currentLegIndex` are
        // already set by the caller (start/leg-advance) before seed runs,
        // so this picks up the right "subsequent legs" set.
        refreshOverviewCaches()
    }

    /// Recompute the cached overview geometry — the current route's
    /// coordinates and the concatenated coordinates of all plan legs
    /// after the current one. Called on every active-route swap
    /// (`seed`, reroute), NEVER per fix. The breadcrumb is deliberately
    /// untouched here: a reroute/leg-advance replaces the route ahead,
    /// not the travelled past.
    private func refreshOverviewCaches() {
        activeRouteCoordsCache = activeRoute?.polyline.coordinateList() ?? []
        guard let plan, currentLegIndex < plan.legs.count - 1 else {
            subsequentLegsCoordsCache = []
            return
        }
        var tail: [CLLocationCoordinate2D] = []
        for legIdx in (currentLegIndex + 1)..<plan.legs.count {
            guard plan.legs.indices.contains(legIdx),
                  let route = plan.legs[legIdx].selected?.route else { continue }
            tail.append(contentsOf: route.polyline.coordinateList())
        }
        subsequentLegsCoordsCache = tail
    }

    /// Append a fresh fix to the travelled breadcrumb, thinned so points
    /// are at least `breadcrumbMinSpacing` apart. Keeps the trace honest
    /// to the road shape without unbounded growth on a long ride.
    private func appendBreadcrumb(_ coord: CLLocationCoordinate2D) {
        guard let last = traveledCoordinates.last else {
            traveledCoordinates.append(coord)
            return
        }
        if PolylineMath.haversine(last, coord) >= breadcrumbMinSpacing {
            traveledCoordinates.append(coord)
        }
    }

    func stop() {
        log.info("Navigation stopped")
        self.isNavigating = false
        self.activeRoute = nil
        self.destination = nil
        self.remainingDistance = 0
        self.etaSeconds = 0
        self.nextStep = nil
        self.stepBeforeNext = nil
        self.precedingStep = nil
        self.distanceToNextStep = 0
        self.secondNextStep = nil
        self.distanceToSecondNextStep = 0
        // F5: drop the pace history so the next route starts cold
        // (pure ratio) and doesn't inherit yesterday's tempo.
        self.paceFactor = 1.0
        self.paceSamples = 0
        self.isOffRoute = false
        self.offRouteSince = nil
        // Multi-stop: drop the plan so the next session starts fresh.
        self.plan = nil
        self.currentLegIndex = 0
        self.remainingWaypoints = 0
        // Arrival state — reset so the next route starts clean.
        self.hasArrived = false
        self.hasBeenUnderway = false
        // Overview geometry — drop breadcrumb + caches so the next ride
        // starts with an empty progress bar.
        self.traveledCoordinates = []
        self.activeRouteCoordsCache = []
        self.subsequentLegsCoordsCache = []
    }

    /// Reached the final destination. Flip into the `hasArrived` display
    /// state (HUD shows the "You've arrived" card) and fire `onArrived`
    /// so AppStatus tears down the stream promptly. We DON'T call stop()
    /// here — the HUD needs `hasArrived == true` for the dismiss beat;
    /// MapPickerView calls stop() after the auto-dismiss delay.
    private func handleArrival() {
        log.info("Arrived at destination \(self.destination?.name ?? "?", privacy: .public)")
        self.hasArrived = true
        // NOTE: deliberately do NOT touch `isNavigating` here. MapPickerView's
        // `mode` is derived from `isNavigating`, so flipping it now would
        // unmount the HUD in the same beat `hasArrived` goes true — the
        // "You've arrived" card would never render. The HUD stays up showing
        // the arrival card; MapPickerView calls `stop()` (which clears
        // `isNavigating`) after the 4 s auto-dismiss.
        onArrived?()
    }

    /// Push a fresh GPS fix into the navigator. Call from a location
    /// observer wherever the app already digests fixes (e.g.
    /// AppStatus.observe(locationService:)).
    func ingest(fix: Fix) async {
        guard isNavigating, let route = activeRoute else { return }
        let coord = fix.coordinate
        self.currentCoordinate = coord
        // Record the travelled trace (thinned). Drives the grey
        // "where you've been" line on the overview map; held across
        // reroutes so the progress bar keeps its history.
        appendBreadcrumb(coord)

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

        // Arm the "been under way" guard so a short route can't fire
        // arrival on its very first fix (where remaining may start small).
        if remaining > destinationArrivalThreshold * 2 { hasBeenUnderway = true }

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

        // Final-destination arrival. True for a single-destination route
        // (plan == nil) and for the last leg of a multi-stop plan. Runs
        // AFTER leg-advance so intermediate waypoints advance instead of
        // "arriving". The `hasBeenUnderway` guard blocks a t=0 false-fire.
        let isFinalLeg = (plan == nil) || (currentLegIndex >= (plan?.legs.count ?? 1) - 1)
        if isFinalLeg, hasBeenUnderway, !hasArrived,
           remaining <= destinationArrivalThreshold {
            handleArrival()
            return
        }

        // F5: hybrid live ETA. Ratio backbone tracks position (and
        // freezes at a stop); pace factor bends it toward the rider's
        // sustained tempo. Fold actual/planned pace into a slow EWMA, but
        // ONLY while genuinely moving — at a stop we freeze the factor so
        // waiting at a light bends nothing. plannedSpeed is the route's
        // own average (distance/expectedTravelTime); paceFactor>1 means
        // the rider beats Apple's plan, so ETA shrinks (and vice versa).
        if fix.speed >= paceMinMovingMps, route.expectedTravelTime > 0 {
            let plannedSpeed = route.distance / route.expectedTravelTime
            if plannedSpeed > 0 {
                let sample = max(paceFactorMin, min(paceFactorMax, fix.speed / plannedSpeed))
                if paceSamples == 0 {
                    paceFactor = sample
                } else {
                    paceFactor = (1 - paceEwmaAlpha) * paceFactor + paceEwmaAlpha * sample
                }
                paceSamples += 1
            }
        }
        self.etaSeconds = computeEta(remaining: remaining, route: route)

        // Maneuver lookup. `nextStepIndex` returns the step whose polyline
        // STARTS at the upcoming maneuver node — the DEPARTING step
        // (`nextStep`). The step the rider is currently traversing, whose
        // polyline ENDS at that node, is the ARRIVING step
        // (`stepBeforeNext`). Apple writes the maneuver text on the
        // ARRIVING step (the turn at the END of its polyline), so the
        // upcoming maneuver's text/family come from `stepBeforeNext` while
        // its turn ANGLE comes from arriving→departing geometry. The
        // derived `upcomingManeuver` / `upcomingInstructions` resolve that
        // pairing — consumers must read those, never `nextStep.instructions`.
        if let stepIdx = PolylineMath.nextStepIndex(in: route, afterPolylineIndex: segIdx),
           stepIdx < route.steps.count {
            let step = route.steps[stepIdx]            // DEPARTING (leaves the node)
            self.nextStep = step
            // ARRIVING step = the one BEFORE the departing step; its
            // polyline ends at the node and its `.instructions` name the
            // upcoming maneuver. nil only if the departing step is the
            // route's first (no incoming leg yet).
            self.stepBeforeNext = stepIdx > 0 ? route.steps[stepIdx - 1] : nil
            // PRECEDING step (before arriving) — only used to carry a
            // roundabout's exit ordinal across MapKit's split entry/exit
            // steps. nil when the arriving step is the route's first.
            self.precedingStep = stepIdx > 1 ? route.steps[stepIdx - 2] : nil
            self.distanceToNextStep = PolylineMath.haversine(
                coord,
                step.polyline.points()[0].coordinate
            )
            // F2c: secondary (look-ahead) maneuver = the step AFTER the
            // departing one. The distance from the rider to the SECONDARY
            // node is "distance to the primary node" plus the length of
            // the DEPARTING step's own polyline (`step.distance`), which is
            // exactly the primary-node → secondary-node leg. The previous
            // code added `secondStep.distance` — the leg AFTER the
            // secondary node — overshooting by a whole step (field logs
            // 6/2026 measured ~+160 m on the first maneuver).
            let secondIdx = stepIdx + 1
            if secondIdx < route.steps.count {
                self.secondNextStep = route.steps[secondIdx]
                self.distanceToSecondNextStep = self.distanceToNextStep
                    + step.distance
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
            // Overview: refresh the AHEAD geometry to the new route.
            // The travelled breadcrumb is deliberately NOT touched — a
            // reroute replaces the road in front of the rider, never the
            // ground already covered, so the progress bar keeps its
            // history (the grey trace) and only the blue line ahead
            // changes shape.
            refreshOverviewCaches()
            // F4: reroute keeps the smoothed-speed history so ETA
            // reflects how the rider was actually moving, not the
            // route's untouched expected average. Falls back to the
            // route's expectedTravelTime when we haven't gathered
            // enough samples yet.
            self.etaSeconds = computeEta(remaining: newRoute.distance, route: newRoute)
            // Fresh route after a reroute: the rider sits at the new
            // route's origin, traversing steps[0] (ARRIVING — its polyline
            // ends at the first maneuver node and its `.instructions` name
            // that maneuver), departing via steps[1]. Same shape as `seed`
            // and as the first `ingest` tick, so the off-by-one fix holds
            // across reroutes too.
            self.stepBeforeNext = newRoute.steps.first        // arriving (text + incoming leg)
            self.nextStep = newRoute.steps.dropFirst().first  // departing (outgoing leg)
            self.precedingStep = nil                          // fresh route → nothing before
            self.distanceToNextStep = newRoute.steps.first?.distance ?? 0
            // F2c: rebuild secondary too. Reroute usually keeps the
            // first step short (Apple Maps fences the next maneuver),
            // so the look-ahead is most useful right after a reroute.
            self.secondNextStep = newRoute.steps.dropFirst(2).first
            // distance-to-secondary = distance-to-primary + the primary
            // (departing) leg's own length (primary node → secondary node).
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

    /// F5: hybrid ETA. Backbone is the ratio estimate
    /// (`expectedTravelTime * remaining/distance`) — it tracks position so
    /// it descends smoothly while rolling and freezes at a stop. We then
    /// divide by `paceFactor` so a rider holding a steady pace above/below
    /// Apple's plan sees the arrival bend the right way over a minute or
    /// two. paceFactor stays 1.0 (and is ignored) until a few moving
    /// samples land, so cold start == pure ratio.
    private func computeEta(remaining: CLLocationDistance, route: MKRoute) -> TimeInterval {
        let ratio = route.distance > 0 ? remaining / route.distance : 0
        let ratioEta = route.expectedTravelTime * ratio
        guard paceSamples >= 5 else { return ratioEta }
        return ratioEta / paceFactor
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

// NOTE: The legacy `ManeuverGlyph.symbol(for:)` SF-symbol picker was
// removed here. It NLP-classified the instruction string with the same
// substring approach (and the same left-before-right / road-name bug)
// that this change replaced. The single source of truth is now
// `ManeuverKind.classify(arrivingStep:departingStep:precedingStep:)` →
// `ManeuverKind.sfSymbol`
// (geometry for direction, text for family), used by both the dash
// bubble and the SwiftUI HUD.
