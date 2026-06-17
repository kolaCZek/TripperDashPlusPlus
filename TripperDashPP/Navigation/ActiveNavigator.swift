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

    /// Estimated arrival time, derived from remaining distance and the
    /// route's average speed.
    private(set) var etaSeconds: TimeInterval = 0

    /// The next maneuver step the rider should anticipate.
    private(set) var nextStep: MKRouteStep?

    /// Distance from current position to the next maneuver.
    private(set) var distanceToNextStep: CLLocationDistance = 0

    /// True if we're currently off-route. Reroute logic in 7h reads
    /// this together with the timestamps below.
    private(set) var isOffRoute: Bool = false

    /// Whether a reroute is currently in flight.
    private(set) var isRerouting: Bool = false

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

    // MARK: - API

    func start(route: MKRoute, destination: Destination) {
        self.activeRoute = route
        self.destination = destination
        self.lastSegmentIndex = 0
        self.offRouteSince = nil
        self.isOffRoute = false
        self.isNavigating = true
        log.info("Navigation started to \(destination.name, privacy: .public) — \(Int(route.distance)) m / \(Int(route.expectedTravelTime)) s")
        // Seed initial display values from the route itself.
        self.remainingDistance = route.distance
        self.etaSeconds = route.expectedTravelTime
        self.nextStep = route.steps.first
        self.distanceToNextStep = route.steps.first?.distance ?? 0
    }

    func stop() {
        log.info("Navigation stopped")
        self.isNavigating = false
        self.activeRoute = nil
        self.destination = nil
        self.nextStep = nil
        self.remainingDistance = 0
        self.etaSeconds = 0
        self.distanceToNextStep = 0
        self.isOffRoute = false
        self.offRouteSince = nil
    }

    /// Push a fresh GPS fix into the navigator. Call from a location
    /// observer wherever the app already digests fixes (e.g.
    /// AppStatus.observe(locationService:)).
    func ingest(fix: CLLocation) async {
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

        // ETA: scale original travel time by remaining/total ratio. Not
        // perfect (doesn't react to live speed) but matches what Apple
        // Maps does in pre-CarPlay mode.
        let ratio = route.distance > 0 ? remaining / route.distance : 0
        self.etaSeconds = route.expectedTravelTime * ratio

        // Next maneuver lookup.
        if let stepIdx = PolylineMath.nextStepIndex(in: route, afterPolylineIndex: segIdx),
           stepIdx < route.steps.count {
            let step = route.steps[stepIdx]
            self.nextStep = step
            self.distanceToNextStep = PolylineMath.haversine(
                coord,
                step.polyline.points()[0].coordinate
            )
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
            self.etaSeconds = newRoute.expectedTravelTime
            self.nextStep = newRoute.steps.first
            self.distanceToNextStep = newRoute.steps.first?.distance ?? 0
        } else {
            log.warning("Reroute failed — keeping existing route, will retry after cooldown")
        }
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

/// SF Symbol picker for an MKRouteStep maneuver. Apple doesn't expose
/// a typed maneuver enum on MKRouteStep — we have to NLP the
/// instructions string. Best-effort, falls back to a generic arrow
/// so we always have something to draw.
enum ManeuverGlyph {
    static func symbol(for step: MKRouteStep) -> String {
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
