//
//  SpeedCameraService.swift
//  TripperDashPP
//
//  Best-effort speed-camera overlay for the dash map. Mirrors the kind of
//  radar awareness riders expect from a nav app, sourced from
//  OpenStreetMap (`highway=speed_camera`) via the public Overpass API.
//  Cameras along the active route are prefetched when navigation starts
//  (bbox query around the route corridor) and again when a reroute / leg
//  change leaves the covered area, cached on disk, and handed to
//  `MapViewSource` which draws a small camera pictograph at each
//  position (see `MapViewSource.drawSpeedCameras`).
//
//  IMPORTANT — this is a BEST-EFFORT map enrichment, not a guaranteed
//  safety system. OSM speed-camera coverage is crowd-sourced and
//  incomplete: some real cameras are missing, some mapped ones are gone,
//  and mobile/temporary cameras are never in the data. The rider must
//  not treat an empty map as "no enforcement here."
//
//  Why Overpass + OSM (not a commercial radar DB):
//    - Keyless and free, consistent with the app's no-paid-entitlement
//      stance (see CLAUDE.md). Commercial radar feeds (TomTom, RadarBot)
//      need an API key + a paid plan + per-region licensing.
//    - OSM already underpins the basemap; staying in the OSM ecosystem
//      keeps attribution and licensing simple (ODbL).
//    - Verified Overpass shape (6/2026):
//        POST https://overpass-api.de/api/interpreter
//        data=[out:json][timeout:25];
//             node["highway"="speed_camera"](south,west,north,east);
//             out body;
//        → { elements: [ { type:"node", id, lat, lon,
//                          tags:{ highway:"speed_camera",
//                                 maxspeed?, direction?, note? } }, … ] }
//

import CoreLocation
import Foundation
import OSLog

// MARK: - Model

/// One mapped speed camera. `id` is the OSM node id (stable across
/// fetches, used for de-duplication). `maxspeedKmh` is parsed from the
/// `maxspeed` tag when present, via the shared `MaxspeedParser` — so an
/// imperial "55 mph" camera is stored as 89 km/h, same as the limit
/// service (bug #3). `isSection` flags average-speed / section-control
/// cameras (OSM `enforcement=average_speed` or a Czech "úsekové měření"
/// note), which the renderer can badge differently.
struct SpeedCamera: Equatable, Sendable, Identifiable {
    let id: Int64
    let coordinate: CLLocationCoordinate2D
    let maxspeedKmh: Int?
    let isSection: Bool

    static func == (lhs: SpeedCamera, rhs: SpeedCamera) -> Bool {
        lhs.id == rhs.id
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.maxspeedKmh == rhs.maxspeedKmh
            && lhs.isSection == rhs.isSection
    }
}

/// One OSM average-speed section (relation `type=enforcement` +
/// `enforcement=average_speed`), reduced to its `from` / `to` points and
/// posted limit. Direction matters: each carriageway has its own relation,
/// so a section only applies when the rider passes `from` with `to` still
/// ahead on the route (see `SpeedSectionTracker`).
nonisolated struct SpeedSection: Equatable, Sendable {
    let id: Int64
    let fromLat: Double, fromLon: Double
    let toLat: Double, toLon: Double
    let maxspeedKmh: Int?
}

/// Everything one Overpass query returns for a region.
nonisolated struct SpeedCameraData: Sendable {
    let cameras: [SpeedCamera]
    let sections: [SpeedSection]
    static let empty = SpeedCameraData(cameras: [], sections: [])

    /// Union by OSM id (a reroute/leg fetch overlaps the earlier one).
    func merged(with other: SpeedCameraData) -> SpeedCameraData {
        let camIds = Set(cameras.map(\.id))
        let secIds = Set(sections.map(\.id))
        return SpeedCameraData(
            cameras: cameras + other.cameras.filter { !camIds.contains($0.id) },
            sections: sections + other.sections.filter { !secIds.contains($0.id) })
    }
}

// MARK: - Service

/// Fetches + caches OSM speed cameras along a route. The actor owns the
/// network session and the disk cache. Results are
/// `Sendable` value types so the MainActor renderer can hold them without
/// a hop.
actor SpeedCameraService {

    static let shared = SpeedCameraService()

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "SpeedCamera")

    /// Public Overpass endpoints. We try them in order on failure — the
    /// main instance occasionally returns 504/429 under load, and the
    /// Kumi mirror is a courteous fallback. Both speak the identical API.
    private let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]

    /// Lateral buffer (m) added around the route bbox so cameras just off
    /// the corridor (e.g. on a parallel carriageway, or right after a
    /// junction the route takes) are still captured. 1 km is generous
    /// without ballooning the query area.
    static let corridorBufferMeters: Double = 1_000

    /// Disk cache directory. Cameras change slowly; a 30-day TTL means a
    /// region is fetched roughly monthly. Keyed by a coarse bbox hash so
    /// re-riding the same area is a disk hit, not a network call.
    private let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SpeedCameras", isDirectory: true)
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
        return cfg.makeSession()
    }()

    /// Fetch every speed camera within the bounding box of `route`
    /// (expanded by the corridor buffer). Disk-cache first; only the first
    /// ride through a region hits the network. Returns nil on total
    /// failure (no network, no cache) so the caller can retry later — a
    /// missing radar layer must never break navigation.
    func camerasAlong(route coords: [CLLocationCoordinate2D]) async -> SpeedCameraData? {
        guard coords.count >= 2 else { return .empty }
        let box = Self.boundingBox(of: coords, bufferMeters: Self.corridorBufferMeters)
        let key = box.cacheKey

        let cached = loadCache(key: key)
        if let cached, cached.complete {
            log.info("Speed cameras: disk-cache hit \(key, privacy: .public) (\(cached.data.cameras.count, privacy: .public) + \(cached.data.sections.count, privacy: .public) sections)")
            return cached.data
        }

        do {
            let data = try await fetch(box: box)
            saveCache(key: key, data: data)
            log.info("Speed cameras: fetched \(data.cameras.count, privacy: .public) + \(data.sections.count, privacy: .public) sections for \(key, privacy: .public)")
            return data
        } catch {
            log.warning("Speed cameras fetch failed: \(String(describing: error), privacy: .public)")
            return cached?.data
        }
    }

    // MARK: - Network

    /// Fetch every speed camera within a square bbox of `radiusMeters`
    /// around `center`. Used by FREE-RIDE (`AppStatus.startFreeRide`),
    /// which has no route corridor to query along — instead it shows all
    /// cameras in the rider's vicinity on the map (map overlay only, NO
    /// voice: free-ride has no turn-by-turn, so the announcer is never
    /// fed this set). Same fetch / disk-cache / `makeCamera` path as
    /// `camerasAlong`; only the bbox construction differs (a square around
    /// a point vs. a route corridor). Returns `[]` on total failure.
    func camerasAround(center: CLLocationCoordinate2D,
                       radiusMeters: Double) async -> [SpeedCamera] {
        guard center.latitude.isFinite, center.longitude.isFinite else { return [] }
        let box = Self.boundingBox(around: center, radiusMeters: radiusMeters)
        let key = box.cacheKey

        // Free-ride draws cameras only, so a pre-sections cache is fine.
        if let cached = loadCache(key: key) {
            log.info("Speed cameras (around): disk-cache hit \(key, privacy: .public) (\(cached.data.cameras.count, privacy: .public))")
            return cached.data.cameras
        }

        do {
            let data = try await fetch(box: box)
            saveCache(key: key, data: data)
            log.info("Speed cameras (around): fetched \(data.cameras.count, privacy: .public) for \(key, privacy: .public)")
            return data.cameras
        } catch {
            log.warning("Speed cameras (around) fetch failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: - Network

    // Internal (not private) so `makeCamera` — which is `internal` and
    // unit-testable — can take `Element` in its signature without tripping
    // "method cannot be declared internal because its parameter uses a
    // private type". Still namespaced under the actor.
    struct OverpassResponse: Decodable {
        struct Element: Decodable {
            let type: String?
            let id: Int64
            let lat: Double?
            let lon: Double?
            let tags: [String: String]?
            let members: [Member]?
        }
        struct Member: Decodable {
            let type: String
            let ref: Int64
            let role: String
        }
        let elements: [Element]
    }

    /// ONE query for both layers: camera nodes, plus the average-speed
    /// section relations and (as bare `skel` nodes) their `from` / `to`
    /// points. The skel nodes carry no tags, which is how `makeCameras`
    /// tells them apart from real cameras.
    private func fetch(box: BBox) async throws -> SpeedCameraData {
        let bbox = "(\(box.south),\(box.west),\(box.north),\(box.east))"
        let query = """
        [out:json][timeout:25];
        node["highway"="speed_camera"]\(bbox);
        out body;
        relation["type"="enforcement"]["enforcement"="average_speed"]\(bbox)->.sec;
        .sec out body;
        (node(r.sec:"from"); node(r.sec:"to"););
        out skel;
        """
        let elements = try await overpass(query).elements
        return SpeedCameraData(cameras: Self.makeCameras(elements),
                               sections: Self.makeSections(elements))
    }

    /// POST one Overpass query, trying each endpoint in turn.
    private func overpass(_ query: String) async throws -> OverpassResponse {
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
                    // 429/504 from a busy mirror — try the next endpoint.
                    lastError = URLError(.badServerResponse)
                    continue
                }
                let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
                return decoded
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    /// Pure decode of one Overpass node → `SpeedCamera?`. Skips elements
    /// missing coordinates. `nonisolated static` so it's unit-testable
    /// against canned Overpass JSON without the actor or the network.
    nonisolated static func makeCamera(_ e: OverpassResponse.Element) -> SpeedCamera? {
        guard let lat = e.lat, let lon = e.lon else { return nil }
        let tags = e.tags ?? [:]
        // Shared parser with the limit service: handles "50", "50 km/h",
        // "80;100", and crucially "55 mph" → 89 (US/UK cameras). Before,
        // this took bare leading digits and rendered "55" for a 55 mph
        // zone (bug #3).
        let maxspeed: Int? = MaxspeedParser.kmh(tags["maxspeed"])
        let note = (tags["note"] ?? "").lowercased()
        let isSection = tags["enforcement"] == "average_speed"
            || tags["speed_camera"] == "section"
            || note.contains("úsek")     // Czech "úsekové měření"
            || note.contains("section")
            || note.contains("average")
        return SpeedCamera(
            id: e.id,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            maxspeedKmh: maxspeed,
            isSection: isSection
        )
    }

    /// Camera nodes only — skips the tagless `from`/`to` skel nodes and
    /// relations that share the response.
    nonisolated static func makeCameras(_ elements: [OverpassResponse.Element]) -> [SpeedCamera] {
        elements.filter { $0.tags?["highway"] == "speed_camera" }.compactMap(makeCamera)
    }

    /// Average-speed relations → `SpeedSection`s. A relation needs a `from`
    /// AND a `to` node with known coordinates; the ~15% mapped with
    /// role-less members can't be oriented and are skipped. A missing
    /// `maxspeed` stays nil (the renderer falls back to the road limit).
    nonisolated static func makeSections(_ elements: [OverpassResponse.Element]) -> [SpeedSection] {
        var coords: [Int64: (Double, Double)] = [:]
        for e in elements where e.type == "node" {
            if let lat = e.lat, let lon = e.lon { coords[e.id] = (lat, lon) }
        }
        return elements.compactMap { e in
            guard e.type == "relation", let members = e.members else { return nil }
            func point(_ role: String) -> (Double, Double)? {
                members.first { $0.type == "node" && $0.role == role }.flatMap { coords[$0.ref] }
            }
            guard let from = point("from"), let to = point("to") else { return nil }
            return SpeedSection(id: e.id, fromLat: from.0, fromLon: from.1,
                                toLat: to.0, toLon: to.1,
                                maxspeedKmh: MaxspeedParser.kmh(e.tags?["maxspeed"]))
        }
    }

    // MARK: - Bounding box

    struct BBox: Sendable, Equatable {
        let south: Double, west: Double, north: Double, east: Double
        /// Coarse cache key — round to 2 decimals (~1.1 km) so nearby
        /// routes share a cached region instead of each cutting a new
        /// micro-bbox fetch.
        var cacheKey: String {
            String(format: "%.2f_%.2f_%.2f_%.2f", south, west, north, east)
        }
        func contains(_ o: BBox) -> Bool {
            o.south >= south && o.north <= north && o.west >= west && o.east <= east
        }

    }

    /// Axis-aligned bbox of `coords`, expanded by `bufferMeters` on every
    /// side. `nonisolated static` for testability.
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

    /// Square bbox of half-side `radiusMeters` centred on `center`. Used by
    /// free-ride's "cameras around me" fetch. `nonisolated static` for
    /// testability.
    nonisolated static func boundingBox(around center: CLLocationCoordinate2D,
                                        radiusMeters: Double) -> BBox {
        let latBuf = radiusMeters / 111_320.0
        let lonBuf = radiusMeters / (111_320.0 * max(0.01, cos(center.latitude * .pi / 180)))
        return BBox(south: center.latitude - latBuf, west: center.longitude - lonBuf,
                    north: center.latitude + latBuf, east: center.longitude + lonBuf)
    }

    // MARK: - Disk cache

    private struct CacheEnvelope: Codable {
        let savedAt: Date
        let cameras: [Cam]
        /// nil in caches written before sections existed → `complete: false`,
        /// so the route path re-fetches once but can fall back to the old
        /// cameras when offline.
        let sections: [Sec]?
        struct Cam: Codable {
            let id: Int64, lat: Double, lon: Double
            let maxspeed: Int?, section: Bool
        }
        struct Sec: Codable {
            let id: Int64
            let fromLat: Double, fromLon: Double, toLat: Double, toLon: Double
            let maxspeed: Int?
        }
    }

    private func cacheURL(key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private func loadCache(key: String) -> (data: SpeedCameraData, complete: Bool)? {
        let url = cacheURL(key: key)
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(CacheEnvelope.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince(env.savedAt) < Self.cacheTTL else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let cameras = env.cameras.map {
            SpeedCamera(id: $0.id,
                        coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                        maxspeedKmh: $0.maxspeed,
                        isSection: $0.section)
        }
        let sections = (env.sections ?? []).map {
            SpeedSection(id: $0.id, fromLat: $0.fromLat, fromLon: $0.fromLon,
                         toLat: $0.toLat, toLon: $0.toLon, maxspeedKmh: $0.maxspeed)
        }
        return (SpeedCameraData(cameras: cameras, sections: sections), env.sections != nil)
    }

    private func saveCache(key: String, data: SpeedCameraData) {
        let env = CacheEnvelope(
            savedAt: Date(),
            cameras: data.cameras.map {
                .init(id: $0.id, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude,
                      maxspeed: $0.maxspeedKmh, section: $0.isSection)
            },
            sections: data.sections.map {
                .init(id: $0.id, fromLat: $0.fromLat, fromLon: $0.fromLon,
                      toLat: $0.toLat, toLon: $0.toLon, maxspeed: $0.maxspeedKmh)
            }
        )
        if let data = try? JSONEncoder().encode(env) {
            try? data.write(to: cacheURL(key: key), options: .atomic)
        }
    }

    // MARK: - Cache maintenance (Settings)

    /// (fileCount, totalBytes) for the on-disk speed-camera cache. Reuses
    /// `SpeedLimitService.dirStats` so the two RideAlerts caches count
    /// their `.json` files the exact same way.
    func diskCacheStats() -> (count: Int, bytes: Int) {
        SpeedLimitService.dirStats(cacheDir)
    }

    /// Nuke the whole speed-camera disk cache, then recreate the empty
    /// directory. Called from Settings → "Clear cache" so a rider who
    /// wants a clean slate clears cameras too, not just map tiles.
    func clearDiskCache() {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: cacheDir)
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            log.info("Speed-camera disk cache CLEARED")
        } catch {
            log.warning("Speed-camera cache clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Helpers

private extension URLSessionConfiguration {
    nonisolated func makeSession() -> URLSession { URLSession(configuration: self) }
}

extension CharacterSet {
    /// Percent-encoding set for an x-www-form-urlencoded VALUE — stricter
    /// than `.urlQueryAllowed`, which leaves `+`, `&`, `=` unescaped and
    /// would corrupt the Overpass query.
    nonisolated static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
