//
//  RouteProjection.swift
//  TripperDashPP
//
//  feat/speed-camera-voice-alert — along-route geometry so a speed-camera
//  warning fires by DISTANCE ALONG THE ROUTE, not by an as-the-crow-flies
//  cone from the rider's GPS heading.
//
//  ── The problem it solves ─────────────────────────────────────────────
//
//  `SpeedCameraAnnouncer` originally decided "is this camera ahead?" with a
//  75° heading cone and measured proximity with a straight-line haversine.
//  That breaks on a sharp bend: a camera 300 m further along the road, but
//  sitting just past a hairpin, lies >75° off the rider's current heading
//  (the road doubles back), so the cone REJECTS it — the rider gets no
//  warning, or a late one only once the bend straightens out. Conversely a
//  camera on a parallel road the route never takes can fall INSIDE the cone
//  and warn spuriously.
//
//  ── The fix ──────────────────────────────────────────────────────────
//
//  When navigation is active we know the route polyline. We project both
//  the rider and each camera onto that polyline and compare their
//  ALONG-ROUTE arc positions:
//
//    * A camera is "ahead" iff its projected arc-length is greater than the
//      rider's projected arc-length (it lies further down the route).
//    * Its warning distance is the arc-length BETWEEN the two projections
//      (sum of segment lengths along the polyline), never the straight
//      line. So the camera past the hairpin is correctly reported as ~300 m
//      ahead and warns on time.
//    * A camera whose nearest point on the route is far from the camera
//      itself (i.e. it isn't really on this road — a parallel-road false
//      positive) is rejected by an off-route lateral gate.
//
//  This whole type is PURE: plain `Double` lat/lon, no CoreLocation /
//  MapKit, so it unit-tests headless on Linux exactly like
//  `SpeedCameraAnnouncer`. The caller (`ActiveNavLoop`) adapts the
//  navigator's `[CLLocationCoordinate2D]` polyline into `[Point]`.
//
//  ── Performance ──────────────────────────────────────────────────────
//
//  Projecting a point onto the polyline is O(segments). Doing it for the
//  rider plus N cameras each tick is O(polyline × cameras). At 1 Hz with a
//  route polyline of a few hundred points and a handful of nearby cameras
//  this is trivially cheap (sub-millisecond). We keep the polyline as the
//  route-AHEAD slice (the caller passes `routeAheadCoordinates`, already
//  trimmed to the rider's current segment onward), which bounds the segment
//  count to the remaining ride and keeps the rider's own projection near
//  the head of the array. No caching is needed at this scale; if a future
//  route ever had thousands of points the projection could be windowed
//  around the rider's last-known segment index — noted, not needed today.
//

import Foundation

/// Pure along-route projector. Value type, no shared state — build one from
/// the current route polyline each tick (cheap) and query it.
struct RouteProjection {

    /// A plain lat/lon point — the polyline vertices and the query points.
    /// Kept free of CoreLocation so the whole type is off-device testable.
    struct Point: Equatable {
        let latitude: Double
        let longitude: Double
        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// The result of projecting a query point onto the polyline.
    struct Projection: Equatable {
        /// Arc-length (metres) from the polyline START to the projected
        /// point, measured along the polyline.
        let alongMeters: Double
        /// Straight-line distance (metres) from the query point to its
        /// nearest point ON the polyline — the "how far off the route is
        /// this" lateral offset, used to reject points that aren't on it.
        let lateralMeters: Double
    }

    /// Polyline vertices in order. Two or more points make a usable route.
    private let coords: [Point]
    /// Cumulative arc-length up to each vertex, `cumulative[i]` = metres
    /// from `coords[0]` to `coords[i]`. Precomputed once so a projection is
    /// a single pass with O(1) arc-length lookup per segment.
    private let cumulative: [Double]

    /// Build from an ordered polyline. Fewer than two points yields an
    /// empty projector whose `project` always returns nil (the caller then
    /// falls back to the cone logic).
    init(coords: [Point]) {
        self.coords = coords
        var cum = [Double](repeating: 0, count: coords.count)
        if coords.count >= 2 {
            for i in 1..<coords.count {
                cum[i] = cum[i - 1] + Self.haversineMeters(
                    lat1: coords[i - 1].latitude, lon1: coords[i - 1].longitude,
                    lat2: coords[i].latitude, lon2: coords[i].longitude)
            }
        }
        self.cumulative = cum
    }

    /// Whether this projector has a usable polyline (≥ 2 points).
    var isUsable: Bool { coords.count >= 2 }

    /// Total polyline length in metres.
    var totalMeters: Double { cumulative.last ?? 0 }

    /// Project `p` onto the polyline: find the nearest point across all
    /// segments and return its along-route arc-length plus the lateral
    /// offset. Returns nil when the polyline is unusable (< 2 points).
    func project(_ p: Point) -> Projection? {
        guard coords.count >= 2 else { return nil }

        var bestLateral = Double.infinity
        var bestAlong = 0.0

        for i in 0..<(coords.count - 1) {
            let a = coords[i]
            let b = coords[i + 1]
            // Project onto segment a→b in a local equirectangular plane
            // (metres) centred on `a`. Good to sub-metre over the short
            // segments a road polyline uses; avoids full geodesics.
            let (t, foot) = Self.projectOntoSegment(p: p, a: a, b: b)
            let lateral = Self.haversineMeters(
                lat1: p.latitude, lon1: p.longitude,
                lat2: foot.latitude, lon2: foot.longitude)
            if lateral < bestLateral {
                bestLateral = lateral
                let segLen = cumulative[i + 1] - cumulative[i]
                bestAlong = cumulative[i] + t * segLen
            }
        }

        return Projection(alongMeters: bestAlong, lateralMeters: bestLateral)
    }

    // MARK: - Along-route camera selection

    /// A camera reduced to the primitives this projector needs.
    struct Target: Equatable {
        let id: Int64
        let latitude: Double
        let longitude: Double
        init(id: Int64, latitude: Double, longitude: Double) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// Along-route distance (metres) from `rider` to `target`, or nil when
    /// the target is not usefully ahead on THIS route. Returns nil if:
    ///   * the polyline is unusable (< 2 points),
    ///   * the target projects further than `maxLateralMeters` off the
    ///     route (it's on a different road — a false positive), or
    ///   * the target's arc-length is at or behind the rider's (already
    ///     passed).
    /// Otherwise returns `targetAlong - riderAlong`, the true remaining
    /// distance along the road.
    func alongRouteDistanceAhead(rider: Point,
                                 target: Target,
                                 maxLateralMeters: Double) -> Double? {
        guard let riderProj = project(rider) else { return nil }
        let targetPoint = Point(latitude: target.latitude, longitude: target.longitude)
        guard let targetProj = project(targetPoint) else { return nil }
        guard targetProj.lateralMeters <= maxLateralMeters else { return nil }
        let ahead = targetProj.alongMeters - riderProj.alongMeters
        guard ahead > 0 else { return nil }
        return ahead
    }

    // MARK: - Geometry (pure)

    /// Great-circle distance in metres. Same formula as
    /// `SpeedCameraAnnouncer.haversineMeters`; duplicated here so the type
    /// is self-contained and independently testable.
    static func haversineMeters(lat1: Double, lon1: Double,
                                lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }

    /// Project point `p` onto segment `a`→`b` in a local equirectangular
    /// plane (x = east metres, y = north metres) centred on `a`. Returns
    /// the clamped parameter `t` ∈ [0, 1] (0 = at `a`, 1 = at `b`) and the
    /// foot of the perpendicular back in lat/lon. Equirectangular is exact
    /// enough over the tens-of-metres segments a road polyline uses.
    static func projectOntoSegment(p: Point, a: Point, b: Point) -> (t: Double, foot: Point) {
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(a.latitude * .pi / 180)

        let ax = 0.0, ay = 0.0
        let bx = (b.longitude - a.longitude) * mPerDegLon
        let by = (b.latitude - a.latitude) * mPerDegLat
        let px = (p.longitude - a.longitude) * mPerDegLon
        let py = (p.latitude - a.latitude) * mPerDegLat

        let dx = bx - ax, dy = by - ay
        let segLenSq = dx * dx + dy * dy
        var t = 0.0
        if segLenSq > 0 {
            t = ((px - ax) * dx + (py - ay) * dy) / segLenSq
            t = max(0, min(1, t))
        }
        let footX = ax + t * dx
        let footY = ay + t * dy
        let footLon = a.longitude + footX / mPerDegLon
        let footLat = a.latitude + footY / mPerDegLat
        return (t, Point(latitude: footLat, longitude: footLon))
    }
}
