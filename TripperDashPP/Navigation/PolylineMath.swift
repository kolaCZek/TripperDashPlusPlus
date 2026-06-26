//
//  PolylineMath.swift
//  TripperDashPP
//
//  Phase 7f geometry helpers — on-route detection, nearest-segment
//  index, remaining distance along an MKPolyline. Apple gives us a
//  polyline but no convenient "am I on it?" query, so we compute it
//  here using Haversine on each segment.
//
//  Performance: ActiveNavigator caches the last progressIndex and
//  only walks forward from there each tick (instead of scanning the
//  whole polyline). For a 100 km route at 6 fps + 25 m/s that means
//  ~4 segment checks per tick steady-state. Cheap.
//

import CoreLocation
import Foundation
import MapKit

enum PolylineMath {

    /// Perpendicular distance (meters) from `coord` to the nearest
    /// segment of `polyline`, plus the index of that segment in the
    /// polyline's `points()` array.
    ///
    /// `searchFrom` lets the caller skip segments already passed
    /// (forward-only walking). Pass 0 for a cold lookup.
    static func nearestSegment(on polyline: MKPolyline,
                               from searchFrom: Int,
                               to coord: CLLocationCoordinate2D)
                              -> (distanceMeters: CLLocationDistance, segmentIndex: Int) {
        let count = polyline.pointCount
        guard count >= 2 else { return (.greatestFiniteMagnitude, 0) }
        let points = polyline.points()
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        var bestIdx = max(0, searchFrom)
        let start = max(0, searchFrom)
        for i in start..<(count - 1) {
            let a = points[i].coordinate
            let b = points[i + 1].coordinate
            let d = perpendicularDistance(point: coord, segmentStart: a, segmentEnd: b)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return (bestDist, bestIdx)
    }

    /// Remaining distance from `segmentIndex` (and the projection
    /// onto that segment) all the way to the end of the polyline.
    static func remainingDistance(on polyline: MKPolyline,
                                  from segmentIndex: Int,
                                  currentCoord: CLLocationCoordinate2D)
                                  -> CLLocationDistance {
        let count = polyline.pointCount
        guard count >= 2, segmentIndex < count - 1 else { return 0 }
        let points = polyline.points()
        // From currentCoord projected onto [segmentIndex, segmentIndex+1]
        // to the segment end, then sum the rest of the segments.
        let segEnd = points[segmentIndex + 1].coordinate
        var total = haversine(currentCoord, segEnd)
        for i in (segmentIndex + 1)..<(count - 1) {
            total += haversine(points[i].coordinate, points[i + 1].coordinate)
        }
        return total
    }

    /// Index of the next step whose start lies beyond `segmentIndex`.
    /// Used to surface the upcoming maneuver in the HUD.
    ///
    /// MKRoute.Step's polyline is a subset of the route polyline but we
    /// get no global index, so we map each step's start onto the route
    /// polyline ourselves. We snap each step start to the NEAREST route
    /// vertex (argmin), walking a forward cursor so steps stay in route
    /// order, and advance the cursor to just AFTER the matched vertex so
    /// two steps can never share one vertex.
    ///
    /// Why not the previous "first vertex within 5 m" match: a step's
    /// start rarely lands on a route vertex to within a few metres — the
    /// route polyline is decimated (vertices ~10–30 m apart). With a hard
    /// 5 m threshold, a step whose start had no vertex that close ran the
    /// SHARED forward cursor all the way to the end of the polyline,
    /// corrupting the mapping for every later step. And two maneuvers
    /// spaced closer than the vertex pitch — MapKit's roundabout
    /// entry/exit split, or two junctions in quick succession — could
    /// match the SAME vertex and silently drop one maneuver from the
    /// turn-by-turn stream. That was the Slaný 6/2026 field bug: the
    /// junction at 50.22517,14.11473 vanished from the instructions, and
    /// the roundabout glyph showed with no exit number then flipped to a
    /// plain right arrow as the dropped step's stale classification leaked
    /// through. Nearest-vertex + cursor=bestIdx+1 keeps adjacent
    /// maneuvers on distinct vertices, so neither is lost.
    static func nextStepIndex(in route: MKRoute,
                              afterPolylineIndex segmentIndex: Int) -> Int? {
        let routePoints = route.polyline.points()
        let routeCount = route.polyline.pointCount
        guard routeCount > 0 else { return nil }

        var cursor = 0
        for (stepIdx, step) in route.steps.enumerated() {
            let stepStart = step.polyline.points()[0].coordinate
            // Nearest route vertex to this step's start, searching forward
            // from the cursor.
            var bestIdx = cursor
            var bestDist = CLLocationDistance.greatestFiniteMagnitude
            var risingStreak = 0
            var i = cursor
            while i < routeCount {
                let d = haversine(routePoints[i].coordinate, stepStart)
                if d < bestDist {
                    bestDist = d
                    bestIdx = i
                    risingStreak = 0
                } else {
                    // Past the local minimum. A short rising streak
                    // tolerates a roundabout briefly doubling back near an
                    // earlier vertex without scanning the whole remaining
                    // polyline for every step (keeps this ~O(points), not
                    // O(points × steps), on long routes).
                    risingStreak += 1
                    if risingStreak >= 8 { break }
                }
                i += 1
            }
            // Advance to just AFTER the matched vertex so the next step —
            // strictly later along the route — starts its own search there
            // and can't collapse onto this step's vertex.
            cursor = min(bestIdx + 1, routeCount - 1)

            if bestIdx > segmentIndex {
                return stepIdx
            }
        }
        return nil
    }

    // MARK: - Geometry primitives

    /// Great-circle distance between two coordinates in meters.
    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let R = 6_371_000.0
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let dφ = (b.latitude - a.latitude) * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ/2) * sin(dφ/2) +
                cos(φ1) * cos(φ2) * sin(dλ/2) * sin(dλ/2)
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return R * c
    }

    /// Perpendicular (cross-track) distance from a point to the line
    /// segment defined by start→end. Returns distance to nearer
    /// endpoint when the projection falls outside the segment.
    /// Approximation: treats the local area as flat (fine at <100 km).
    static func perpendicularDistance(point p: CLLocationCoordinate2D,
                                      segmentStart a: CLLocationCoordinate2D,
                                      segmentEnd b: CLLocationCoordinate2D) -> CLLocationDistance {
        // Convert lat/lon to local meters using equirectangular projection
        // around segment midpoint.
        let midLat = (a.latitude + b.latitude) / 2 * .pi / 180
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(midLat)

        let ax = a.longitude * mPerDegLon
        let ay = a.latitude * mPerDegLat
        let bx = b.longitude * mPerDegLon
        let by = b.latitude * mPerDegLat
        let px = p.longitude * mPerDegLon
        let py = p.latitude * mPerDegLat

        let dx = bx - ax
        let dy = by - ay
        let lenSq = dx*dx + dy*dy
        guard lenSq > 0 else { return haversine(p, a) }

        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))
        let projX = ax + t * dx
        let projY = ay + t * dy
        let ex = px - projX
        let ey = py - projY
        return sqrt(ex*ex + ey*ey)
    }
}
