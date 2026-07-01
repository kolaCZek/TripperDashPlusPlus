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
/// is always km/h (the OSM dataset is European; we convert for display).
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
struct SpeedLimitMatch: Equatable, Sendable {
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

    static let empty = SpeedLimitData(limits: [], roads: [])
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
    private static let corridorBufferMeters: Double = 300

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
        let ax = (a.longitude - p.longitude) * mPerDegLon
        let ay = (a.latitude - p.latitude) * mPerDegLat
        let bx = (b.longitude - p.longitude) * mPerDegLon
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

    struct BBox {
        let south, west, north, east: Double
        /// Coarse key (~0.01° ≈ 1.1 km grid) so re-riding a region is a
        /// disk hit, matching the camera service's keying granularity.
        var cacheKey: String {
            func q(_ v: Double) -> Int { Int((v * 100).rounded()) }
            return "\(q(south))_\(q(west))_\(q(north))_\(q(east))"
        }
    }

    nonisolated static func boundingBox(of coords: [CLLocationCoordinate2D],
                                        bufferMeters: Double) -> BBox {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for c in coords {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let latBuf = bufferMeters / 111_320.0
        let midLat = (minLat + maxLat) / 2
        let lonBuf = bufferMeters / (111_320.0 * max(0.01, cos(midLat * .pi / 180)))
        return BBox(south: minLat - latBuf, west: minLon - lonBuf,
                    north: maxLat + latBuf, east: maxLon + lonBuf)
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
