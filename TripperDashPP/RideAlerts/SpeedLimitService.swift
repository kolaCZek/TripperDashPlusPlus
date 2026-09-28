//
//  SpeedLimitService.swift
//  TripperDashPP
//
//  Fetches OSM `maxspeed` road data along the active route and map-matches
//  the rider's GPS position to the nearest road segment to derive the
//  posted speed limit. Sibling of `SpeedCameraService` — same Overpass +
//  bbox + disk-cache machinery — but it queries *ways* (with geometry)
//  instead of point nodes, because a speed limit belongs to a stretch of
//  road, not a single coordinate.
//
//  Coverage note (6/2026): this is EXPLICIT `maxspeed` tags only. Where a
//  road isn't tagged, no sign shows — we deliberately do NOT guess an
//  implied limit from the road class yet (that needs a per-country table
//  and urban/rural detection; tracked as a follow-up). So treat a missing
//  sign as "unknown", never "no limit".
//

import Foundation
import CoreLocation
import os.log

// MARK: - Model

/// One OSM way carrying an explicit `maxspeed`, with its full polyline
/// geometry so we can measure how close the rider is to it. `maxspeedKmh`
/// is always km/h (`MaxspeedParser` converts mph tags; we convert for display).
struct SpeedLimitWay: Equatable, Sendable, Identifiable {
    let id: Int64
    let coords: [CLLocationCoordinate2D]
    let maxspeedKmh: Int

    static func == (lhs: SpeedLimitWay, rhs: SpeedLimitWay) -> Bool {
        guard lhs.id == rhs.id, lhs.maxspeedKmh == rhs.maxspeedKmh,
              lhs.coords.count == rhs.coords.count else { return false }
        for (a, b) in zip(lhs.coords, rhs.coords) {
            if a.latitude != b.latitude || a.longitude != b.longitude { return false }
        }
        return true
    }
}

/// Result of map-matching a GPS point to the limit ways: the matched
/// limit plus how far (m) the rider is from that road segment. The caller
/// applies snap/hysteresis thresholds so the sign doesn't flicker in the
/// gaps between tagged segments.
nonisolated struct SpeedLimitMatch: Equatable, Sendable {
    let kmh: Int
    let distanceMeters: Double
}

/// Bare drivable-road geometry WITHOUT a limit. We fetch these alongside
/// the tagged ways purely so the map-match can tell when the rider is
/// actually on a *different, closer* road than the nearest tagged one —
/// the "shadow" case where a parallel untagged street (e.g. a 50 km/h
/// residential through an obec) sits right under the rider while a faster
/// tagged road (a 90 km/h tertiary) runs 30 m away. Without this the
/// match would snap to the only thing it can see — the wrong 90.
struct RoadShape: Sendable, Identifiable {
    let id: Int64
    let coords: [CLLocationCoordinate2D]
}

/// Everything the renderer needs for the speed-limit layer: the tagged
/// limit ways to read a number from, and ALL nearby drivable roads
/// (tagged or not) to sanity-check which road the rider is really on.
struct SpeedLimitData: Sendable {
    let limits: [SpeedLimitWay]
    let roads: [RoadShape]

    nonisolated static let empty = SpeedLimitData(limits: [], roads: [])
}

/// Uniform lat/lon bucket grid over polyline segments, built ONCE when the
/// speed-limit layer is installed so the per-fix map-match only measures
/// the segments in the 3×3 cells around the rider instead of every segment
/// in the route bbox (downtown that's tens of thousands, at 1 Hz, on main).
///
/// Exactness: `nearestWithinWindow` returns a hit only when its distance is
/// smaller than the distance from the point to the 3×3 window edge. Any
/// segment at least that close then has its closest point inside the window,
/// so it was bucketed into a window cell and was measured, and the answer
/// equals the full scan's (ties broken by (line, segment) order, like the
/// full scan's first-strictly-smaller rule). Otherwise it returns `nil` and
/// the caller falls back to the full scan (`SpeedLimitService.nearestLimit`
/// / `nearestRoadDistance`). That only happens off the data (>~250 m from
/// every road).
nonisolated struct SegmentGrid: Sendable {
    nonisolated struct Hit: Equatable, Sendable {
        /// Index into the `lines` array the grid was built from.
        let line: Int
        let distanceMeters: Double
    }

    /// Minimum cell edge (m). One cell is the smallest exact query radius.
    static let cellMeters: Double = 250

    nonisolated private struct SegRef: Sendable {
        let line: Int32
        let seg: Int32
    }

    private let lines: [[CLLocationCoordinate2D]]
    private let originLat: Double
    private let originLon: Double
    /// Longitudes are unwrapped around this one (`unwrapLongitude`), so data across
    /// the antimeridian stays one contiguous block instead of a grid ~360°
    /// wide (review N1).
    private let refLon: Double
    private let cellLatDeg: Double
    private let cellLonDeg: Double
    private let cells: [Int: [SegRef]]
    /// Segments bucketed (each counted once, however many cells it spans).
    let segmentCount: Int
    var cellCount: Int { cells.count }

    /// Buckets every segment of `lines` into each cell its lat/lon bounding
    /// box overlaps. Lines with < 2 points are skipped (as in the full scan).
    init(lines: [[CLLocationCoordinate2D]]) {
        let ref = lines.first { $0.count >= 2 }?[0].longitude ?? 0
        var minLat = 90.0, maxLat = -90.0, minLon = Double.infinity
        var segCount = 0
        for line in lines where line.count >= 2 {
            for c in line {
                minLat = min(minLat, c.latitude)
                maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, SpeedLimitService.unwrapLongitude(c.longitude, near: ref))
            }
            segCount += line.count - 1
        }
        if segCount == 0 { minLat = 0; maxLat = 0; minLon = 0 }
        // Size lon cells at the data's highest |latitude| (smallest cos) so
        // every cell is at least `cellMeters` wide across the whole data set.
        let refLat = max(abs(minLat), abs(maxLat))
        let latDeg = Self.cellMeters / 111_320.0
        let lonDeg = Self.cellMeters / (111_320.0 * max(0.01, cos(refLat * .pi / 180)))

        var buckets: [Int: [SegRef]] = [:]
        for (li, line) in lines.enumerated() where line.count >= 2 {
            for i in 0..<(line.count - 1) {
                let a = line[i], b = line[i + 1]
                let r0 = Self.index(min(a.latitude, b.latitude), minLat, latDeg)
                let r1 = Self.index(max(a.latitude, b.latitude), minLat, latDeg)
                let aLon = SpeedLimitService.unwrapLongitude(a.longitude, near: ref)
                let bLon = SpeedLimitService.unwrapLongitude(b.longitude, near: ref)
                let c0 = Self.index(min(aLon, bLon), minLon, lonDeg)
                let c1 = Self.index(max(aLon, bLon), minLon, lonDeg)
                let segRef = SegRef(line: Int32(li), seg: Int32(i))
                for r in r0...r1 {
                    for c in c0...c1 {
                        buckets[Self.key(r, c), default: []].append(segRef)
                    }
                }
            }
        }
        self.lines = lines
        self.originLat = minLat
        self.originLon = minLon
        self.refLon = ref
        self.cellLatDeg = latDeg
        self.cellLonDeg = lonDeg
        self.cells = buckets
        self.segmentCount = segCount
    }

    private static func index(_ v: Double, _ origin: Double, _ cell: Double) -> Int {
        Int(((v - origin) / cell).rounded(.down))
    }

    /// Collisions (only possible for points absurdly far from the data) just
    /// add extra real candidates; exactness only needs window cells present.
    private static func key(_ row: Int, _ col: Int) -> Int {
        row &* 1_048_576 &+ col
    }

    /// Nearest segment among the 3×3 cells around `p`, or `nil` when the
    /// grid is empty, nothing is there, or the best hit is not provably the
    /// global nearest (see type doc) — the caller must then full-scan.
    func nearestWithinWindow(to p: CLLocationCoordinate2D) -> Hit? {
        guard segmentCount > 0 else { return nil }
        let lon = SpeedLimitService.unwrapLongitude(p.longitude, near: refLon)
        let r0 = Self.index(p.latitude, originLat, cellLatDeg)
        let c0 = Self.index(lon, originLon, cellLonDeg)
        var best: Hit?
        var bestSeg = 0
        for r in (r0 - 1)...(r0 + 1) {
            for c in (c0 - 1)...(c0 + 1) {
                guard let refs = cells[Self.key(r, c)] else { continue }
                for ref in refs {
                    let li = Int(ref.line), i = Int(ref.seg)
                    let line = lines[li]
                    let d = SpeedLimitService.distancePointToSegment(p, line[i], line[i + 1])
                    if let b = best {
                        guard d < b.distanceMeters
                                || (d == b.distanceMeters && (li, i) < (b.line, bestSeg))
                        else { continue }
                    }
                    best = Hit(line: li, distanceMeters: d)
                    bestSeg = i
                }
            }
        }
        guard let hit = best else { return nil }
        // Exact radius: distance from p to the window edge, in the same
        // local projection `distancePointToSegment` measures in. The 0.5 m
        // margin absorbs floating-point rounding at cell borders.
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(p.latitude * .pi / 180)
        let south = originLat + Double(r0 - 1) * cellLatDeg
        let north = originLat + Double(r0 + 2) * cellLatDeg
        let west = originLon + Double(c0 - 1) * cellLonDeg
        let east = originLon + Double(c0 + 2) * cellLonDeg
        let radius = min((p.latitude - south) * mPerDegLat,
                         (north - p.latitude) * mPerDegLat,
                         (lon - west) * mPerDegLon,
                         (east - lon) * mPerDegLon)
        return hit.distanceMeters < radius - 0.5 ? hit : nil
    }
}

// MARK: - Service

/// Fetches + caches OSM `maxspeed` ways along a route. Actor-isolated for
/// the network/cache; the map-match itself is a `nonisolated static` pure
/// function so the MainActor renderer can call it every fix without a hop
/// and so it's unit-testable against canned geometry.
actor SpeedLimitService {

    static let shared = SpeedLimitService()

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "SpeedLimit")

    /// Same public Overpass endpoints + courteous-fallback policy as the
    /// camera service. Both speak the identical API.
    private let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]

    /// Lateral buffer (m) around the route bbox. Tighter than the camera
    /// service's 1 km — a speed limit only matters for roads the rider is
    /// actually on, and a smaller box keeps the (heavier, geometry-laden)
    /// way query cheaper.
    static let corridorBufferMeters: Double = 300

    private let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SpeedLimits", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let cacheTTL: TimeInterval = 30 * 24 * 3600

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 40
        cfg.allowsCellularAccess = true
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = [
            "User-Agent": "TripperDashPP/1.0 (https://github.com/kolaCZek/TripperDashPlusPlus)"
        ]
        // NB: `URLSessionConfiguration.makeSession()` is a `private`
        // extension scoped to SpeedCameraService.swift, so it's not
        // visible here — construct the session directly.
        return URLSession(configuration: cfg)
    }()

    /// Fetch the speed-limit layer within the route's bounding box: the
    /// `maxspeed`-tagged ways AND the bare geometry of every other drivable
    /// road nearby (for the shadow guard). Disk-cache first; only the first
    /// ride through a region hits the network. Returns `.empty` on total
    /// failure — a missing limit layer must never break navigation.
    func limitsAlong(route coords: [CLLocationCoordinate2D]) async -> SpeedLimitData {
        guard coords.count >= 2 else { return .empty }
        let box = Self.boundingBox(of: coords, bufferMeters: Self.corridorBufferMeters)
        let key = box.cacheKey

        if let cached = loadCache(key: key) {
            log.info("Speed limits: disk-cache hit \(key, privacy: .public) (\(cached.limits.count, privacy: .public) limits, \(cached.roads.count, privacy: .public) roads)")
            return cached
        }
        do {
            let data = try await fetch(box: box)
            saveCache(key: key, data: data)
            log.info("Speed limits: fetched \(data.limits.count, privacy: .public) limits + \(data.roads.count, privacy: .public) roads for \(key, privacy: .public)")
            return data
        } catch {
            log.warning("Speed limits fetch failed: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }

    // MARK: - Map-match (pure, testable)

    /// Map-match `point` to the nearest segment of any limit way and return
    /// the posted limit + the perpendicular distance to that segment.
    /// `nil` only when there are no ways at all. The caller decides whether
    /// the distance is close enough to trust (snap threshold) and applies
    /// hysteresis. Pure + `nonisolated static` so it runs on the MainActor
    /// renderer each fix and is unit-testable.
    nonisolated static func nearestLimit(to point: CLLocationCoordinate2D,
                                         ways: [SpeedLimitWay]) -> SpeedLimitMatch? {
        var best: SpeedLimitMatch?
        for way in ways {
            guard way.coords.count >= 2 else { continue }
            for i in 0..<(way.coords.count - 1) {
                let d = distancePointToSegment(point, way.coords[i], way.coords[i + 1])
                if best == nil || d < best!.distanceMeters {
                    best = SpeedLimitMatch(kmh: way.maxspeedKmh, distanceMeters: d)
                }
            }
        }
        return best
    }

    /// Shortest perpendicular distance (m) from `point` to ANY of the bare
    /// drivable roads, or `nil` if there are none. Used by the shadow guard
    /// to compare "nearest road of any kind" against "nearest road that
    /// carries a limit": if the rider is sitting much closer to an untagged
    /// road, the tagged match is a parallel-road artefact and is suppressed.
    nonisolated static func nearestRoadDistance(to point: CLLocationCoordinate2D,
                                                roads: [RoadShape]) -> Double? {
        var best: Double?
        for road in roads {
            guard road.coords.count >= 2 else { continue }
            for i in 0..<(road.coords.count - 1) {
                let d = distancePointToSegment(point, road.coords[i], road.coords[i + 1])
                if best == nil || d < best! { best = d }
            }
        }
        return best
    }

    /// Perpendicular distance (m) from `p` to the segment `a→b`, using a
    /// local equirectangular projection around `p`. Accurate to well under
    /// a metre at the few-hundred-metre scale we map-match over, and far
    /// cheaper than great-circle math for a per-fix inner loop.
    nonisolated static func distancePointToSegment(_ p: CLLocationCoordinate2D,
                                                   _ a: CLLocationCoordinate2D,
                                                   _ b: CLLocationCoordinate2D) -> Double {
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(p.latitude * .pi / 180)
        // Project to local metres with `p` at the origin.
        let px = 0.0, py = 0.0
        // `remainder(_, 360)` wraps the longitude delta into ±180° so a
        // road across the antimeridian (Taveuni, Chukotka) measures metres,
        // not the long way round. Exact no-op for every |Δlon| < 180°.
        let ax = remainder(a.longitude - p.longitude, 360) * mPerDegLon
        let ay = (a.latitude - p.latitude) * mPerDegLat
        let bx = remainder(b.longitude - p.longitude, 360) * mPerDegLon
        let by = (b.latitude - p.latitude) * mPerDegLat

        let dx = bx - ax, dy = by - ay
        let segLenSq = dx * dx + dy * dy
        if segLenSq < 1e-9 {
            // Degenerate segment — distance to the point `a`.
            return hypot(px - ax, py - ay)
        }
        // Projection parameter t of p onto the segment, clamped to [0,1].
        var t = ((px - ax) * dx + (py - ay) * dy) / segLenSq
        t = max(0, min(1, t))
        let projX = ax + t * dx
        let projY = ay + t * dy
        return hypot(px - projX, py - projY)
    }

    // MARK: - Network

    struct OverpassResponse: Decodable {
        struct Element: Decodable {
            struct Pt: Decodable { let lat: Double; let lon: Double }
            let id: Int64
            let tags: [String: String]?
            let geometry: [Pt]?
        }
        let elements: [Element]
    }

    private func fetch(box: BBox) async throws -> SpeedLimitData {
        // Fetch ALL drivable roads in the corridor (not just the
        // `maxspeed`-tagged ones) so the map-match can tell which road the
        // rider is really on. `out geom;` returns each way's full
        // coordinate list inline — no second node-resolution round-trip.
        // The `highway` regex is the drivable set; footways/cycleways/steps
        // are excluded so a parallel pavement can't shadow the road.
        let query = """
        [out:json][timeout:25];
        way["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|road|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"](\(box.south),\(box.west),\(box.north),\(box.east));
        out geom;
        """
        var lastError: Error?
        for endpoint in endpoints {
            do {
                var req = URLRequest(url: URL(string: endpoint)!)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")"
                    .data(using: .utf8)
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard http.statusCode == 200 else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
                return Self.split(decoded.elements)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    /// Split a batch of Overpass highway elements into the tagged limit
    /// ways (those carrying a parseable numeric `maxspeed`) and the bare
    /// road shapes (ALL drivable roads, tagged or not — the limit ways are
    /// roads too, so a tagged road the rider is actually on still counts as
    /// the nearest road and won't be shadowed by itself). `nonisolated
    /// static` so it's unit-testable against canned JSON.
    nonisolated static func split(_ elements: [OverpassResponse.Element]) -> SpeedLimitData {
        var limits: [SpeedLimitWay] = []
        var roads: [RoadShape] = []
        for e in elements {
            guard let geom = e.geometry, geom.count >= 2 else { continue }
            let coords = geom.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            roads.append(RoadShape(id: e.id, coords: coords))
            if let kmh = parseMaxspeedKmh(e.tags?["maxspeed"]) {
                limits.append(SpeedLimitWay(id: e.id, coords: coords, maxspeedKmh: kmh))
            }
        }
        return SpeedLimitData(limits: limits, roads: roads)
    }

    /// Parse an OSM `maxspeed` tag into km/h. Thin wrapper over the shared
    /// `MaxspeedParser` so the limit service and the camera service can't
    /// disagree (they used to — see MaxspeedParser.swift, bug #3). Kept as
    /// a named static so existing call sites and the source drift-guard
    /// test (`func parseMaxspeedKmh(`) stay valid.
    ///   "50", "50 km/h"           → 50
    ///   "80;100" (multiple)       → 80 (leading value)
    ///   "30 mph"                  → 48 (converted)
    ///   "none" / "walk" / "CZ:..." → nil (no explicit numeric limit)
    nonisolated static func parseMaxspeedKmh(_ raw: String?) -> Int? {
        MaxspeedParser.kmh(raw)
    }

    // MARK: - bbox

    struct BBox: Sendable, Equatable {
        let south, west, north, east: Double
        // ponytail: plain min/max test, so an antimeridian box (west > east)
        // never "contains" anything and a reroute there just refetches.
        func contains(_ o: BBox) -> Bool {
            o.south >= south && o.north <= north && o.west >= west && o.east <= east
        }
        /// Coarse key (~0.01° ≈ 1.1 km grid) so re-riding a region is a
        /// disk hit, matching the camera service's keying granularity.
        var cacheKey: String {
            func q(_ v: Double) -> Int { Int((v * 100).rounded()) }
            return "\(q(south))_\(q(west))_\(q(north))_\(q(east))"
        }
    }

    /// `lon` shifted by a whole turn when it is more than 180° from `ref`,
    /// so points either side of the antimeridian compare as neighbours.
    /// Returns `lon` itself (bit for bit) everywhere else.
    nonisolated static func unwrapLongitude(_ lon: Double, near ref: Double) -> Double {
        if lon - ref > 180 { return lon - 360 }
        if lon - ref < -180 { return lon + 360 }
        return lon
    }

    /// A route across the antimeridian gets `west > east`, which Overpass
    /// reads as the box that wraps through ±180° (instead of a band round
    /// the whole planet). Identical to a plain min/max box everywhere else.
    nonisolated static func boundingBox(of coords: [CLLocationCoordinate2D],
                                        bufferMeters: Double) -> BBox {
        let ref = coords.first?.longitude ?? 0
        var minLat = 90.0, maxLat = -90.0, minLon = Double.infinity, maxLon = -Double.infinity
        for c in coords {
            let lon = unwrapLongitude(c.longitude, near: ref)
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, lon);         maxLon = max(maxLon, lon)
        }
        let latBuf = bufferMeters / 111_320.0
        let midLat = (minLat + maxLat) / 2
        let lonBuf = bufferMeters / (111_320.0 * max(0.01, cos(midLat * .pi / 180)))
        return BBox(south: minLat - latBuf, west: remainder(minLon - lonBuf, 360),
                    north: maxLat + latBuf, east: remainder(maxLon + lonBuf, 360))
    }

    // MARK: - Disk cache

    private struct CacheEnvelope: Codable {
        let savedAt: Date
        let ways: [Way]
        /// Bare drivable-road geometry for the shadow guard. Optional so a
        /// pre-shadow-guard cache file still decodes (it just has no roads,
        /// and the guard then no-ops until the next refetch).
        let roads: [Road]?
        struct Way: Codable {
            let id: Int64
            let lats: [Double]
            let lons: [Double]
            let maxspeed: Int
        }
        struct Road: Codable {
            let id: Int64
            let lats: [Double]
            let lons: [Double]
        }
    }

    private func cacheURL(key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private func loadCache(key: String) -> SpeedLimitData? {
        let url = cacheURL(key: key)
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(CacheEnvelope.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince(env.savedAt) < Self.cacheTTL else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let limits: [SpeedLimitWay] = env.ways.compactMap { w in
            guard w.lats.count == w.lons.count, w.lats.count >= 2 else { return nil }
            let coords = zip(w.lats, w.lons).map {
                CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1)
            }
            return SpeedLimitWay(id: w.id, coords: coords, maxspeedKmh: w.maxspeed)
        }
        let roads: [RoadShape] = (env.roads ?? []).compactMap { r in
            guard r.lats.count == r.lons.count, r.lats.count >= 2 else { return nil }
            let coords = zip(r.lats, r.lons).map {
                CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1)
            }
            return RoadShape(id: r.id, coords: coords)
        }
        return SpeedLimitData(limits: limits, roads: roads)
    }

    private func saveCache(key: String, data: SpeedLimitData) {
        let env = CacheEnvelope(
            savedAt: Date(),
            ways: data.limits.map { w in
                CacheEnvelope.Way(id: w.id,
                                  lats: w.coords.map(\.latitude),
                                  lons: w.coords.map(\.longitude),
                                  maxspeed: w.maxspeedKmh)
            },
            roads: data.roads.map { r in
                CacheEnvelope.Road(id: r.id,
                                   lats: r.coords.map(\.latitude),
                                   lons: r.coords.map(\.longitude))
            }
        )
        if let raw = try? JSONEncoder().encode(env) {
            try? raw.write(to: cacheURL(key: key))
        }
    }

    // MARK: - Cache maintenance (Settings)

    /// (fileCount, totalBytes) for the on-disk speed-limit cache. Used by
    /// Settings so "Clear cache" can show a real footprint and disable
    /// itself when there's nothing to clear.
    func diskCacheStats() -> (count: Int, bytes: Int) {
        Self.dirStats(cacheDir)
    }

    /// Nuke the whole speed-limit disk cache, then recreate the empty
    /// directory so the next fetch can write straight into it. Called from
    /// Settings → "Clear cache". Also fixes the stale-schema case: an old
    /// cache file predating the shadow guard has no road geometry, so the
    /// guard no-ops and a parallel-road limit (the phantom 90) keeps
    /// showing until the file is gone — clearing forces a fresh fetch that
    /// includes the roads.
    func clearDiskCache() {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: cacheDir)
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            log.info("Speed-limit disk cache CLEARED")
        } catch {
            log.warning("Speed-limit cache clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// (count, bytes) of the `.json` cache files directly in `dir`.
    /// `nonisolated static` so it's a pure filesystem walk with no actor
    /// state — cheap enough to call on demand from the Settings sheet.
    nonisolated static func dirStats(_ dir: URL) -> (count: Int, bytes: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return (0, 0) }
        var count = 0
        var total = 0
        for url in items where url.pathExtension == "json" {
            count += 1
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return (count, total)
    }
}
