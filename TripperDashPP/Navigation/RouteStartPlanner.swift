//
//  RouteStartPlanner.swift
//  TripperDashPP
//
//  feat/saved-routes-gpx — pure decision logic for "where do we start
//  navigating a saved route from?".
//
//  When the rider taps Start on a saved route, the route's stored first
//  point may be far from where they actually are (they saved a tour that
//  begins 200 km away, or they're resuming a route halfway along). Two
//  behaviours, rider-confirmed:
//
//    • .fromFirst   — drive to the route's first point, then follow the
//                     whole route start→end.
//    • .fromNearest — snap onto the route at the closest point and follow
//                     it from there to the end, skipping the leading
//                     portion already behind the rider.
//
//  We only PROMPT when the choice is non-obvious: the nearest point is
//  not the first one AND starting from first would mean a meaningful
//  detour backwards. Otherwise we silently start from the first point
//  (the common case: rider is at/near the route start).
//
//  This type holds NO UIKit/MapKit/CoreLocation-manager state — just
//  coordinate math — so it's unit-testable on Linux and mirrored 1:1 in
//  the Python suite.
//

import CoreLocation
import Foundation

enum RouteStartMode: String, Sendable, Equatable {
    case fromFirst
    case fromNearest
}

/// Outcome of analysing a saved route against the rider's live position.
struct RouteStartDecision: Sendable, Equatable {
    /// Index into the route's points of the closest point to the rider.
    let nearestIndex: Int
    /// Metres from the rider to the route's first point.
    let distanceToFirst: Double
    /// Metres from the rider to the nearest point on the route.
    let distanceToNearest: Double
    /// True → the UI should ask the rider first/nearest. False → just
    /// start from the first point (no dialog).
    let shouldPrompt: Bool
}

enum RouteStartPlanner {

    /// How much closer the nearest point must be than the first point
    /// before we bother asking. Below this, starting from first is fine
    /// and we skip the dialog. 300 m chosen so normal GPS scatter at the
    /// route start never triggers a spurious prompt, but resuming a route
    /// you're genuinely partway along does.
    static let promptThresholdMeters = 300.0

    /// Analyse a route against the rider's current coordinate.
    ///
    /// `riderLocation == nil` (no GPS fix yet) → never prompt, start from
    /// first (we have nothing to compare against).
    static func analyze(points: [RoutePoint],
                        riderLocation: CLLocationCoordinate2D?) -> RouteStartDecision {
        guard let rider = riderLocation, let first = points.first else {
            return RouteStartDecision(nearestIndex: 0,
                                      distanceToFirst: 0,
                                      distanceToNearest: 0,
                                      shouldPrompt: false)
        }

        let distFirst = GPXGeometry.haversine(rider, first.coordinate)

        var nearestIdx = 0
        var nearestDist = distFirst
        for (i, p) in points.enumerated() {
            let d = GPXGeometry.haversine(rider, p.coordinate)
            if d < nearestDist { nearestDist = d; nearestIdx = i }
        }

        // Prompt only when the nearest point isn't the first AND the
        // saving (first − nearest) exceeds the threshold. That second
        // clause is what stops a prompt when the rider is basically at
        // the start but a slightly-closer second point exists.
        let shouldPrompt = nearestIdx > 0
            && (distFirst - nearestDist) > promptThresholdMeters

        return RouteStartDecision(nearestIndex: nearestIdx,
                                  distanceToFirst: distFirst,
                                  distanceToNearest: nearestDist,
                                  shouldPrompt: shouldPrompt)
    }

    /// The ordered route points to actually navigate, given the chosen
    /// start mode. For `.fromNearest` the leading points before the
    /// nearest index are dropped; for `.fromFirst` the full list is used.
    ///
    /// The live-GPS origin is NOT included here — callers prepend the
    /// rider's current location as the routing origin (so MKDirections
    /// has a real source). These are the via/destination points.
    static func navigablePoints(_ points: [RoutePoint],
                                mode: RouteStartMode,
                                nearestIndex: Int) -> [RoutePoint] {
        switch mode {
        case .fromFirst:
            return points
        case .fromNearest:
            guard nearestIndex > 0, nearestIndex < points.count else { return points }
            return Array(points[nearestIndex...])
        }
    }
}
