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
    static func nextStepIndex(in route: MKRoute,
                              afterPolylineIndex segmentIndex: Int) -> Int? {
        // MKRouteStep's polyline is a subset of the route polyline —
        // we don't get a global index, so we compare coordinate
        // matches against the route polyline's points.
        let routePoints = route.polyline.points()
        var pointIdx = 0
        for (stepIdx, step) in route.steps.enumerated() {
            let stepStart = step.polyline.points()[0].coordinate
            // Walk routePoints forward until we hit this step's start.
            while pointIdx < route.polyline.pointCount {
                let p = routePoints[pointIdx].coordinate
                if haversine(p, stepStart) < 5 { break }
                pointIdx += 1
            }
            if pointIdx > segmentIndex {
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
