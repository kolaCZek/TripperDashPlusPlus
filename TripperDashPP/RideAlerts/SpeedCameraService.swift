//
//  SpeedCameraService.swift
//  TripperDashPP
//
//  Best-effort speed-camera overlay for the dash map. Mirrors the kind of
//  radar awareness riders expect from a nav app, sourced from
//  OpenStreetMap (`highway=speed_camera`) via the public Overpass API.
//  Cameras along the active route are prefetched once when navigation
//  starts (bbox query around the route corridor), cached on disk, and
//  handed to `MapViewSource` which draws a small camera pictograph at each
//  position (see `MapViewSource.drawSpeedCameras`).
//
//  IMPORTANT — this is a BEST-EFFORT map enrichment, not a guaranteed
//  safety system. OSM speed-camera coverage is crowd-sourced and
//  incomplete: some real cameras are missing, some mapped ones are gone,
//  and mobile/temporary cameras are never in the data. The rider must
//  not treat an empty map as "no enforcement here." This is stated again
//  in the settings footer so the expectation is set in the UI too.
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
/// `maxspeed` tag when present (km/h assumed — the dataset is European;
/// "50" → 50). `isSection` flags average-speed / section-control cameras
/// (OSM `enforcement=average_speed` or a Czech "úsekové měření" note),
/// which the renderer can badge differently.
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

// MARK: - Service

/// Fetches + caches OSM speed cameras along a route. The actor owns the
/// network session, the in-RAM cache and the disk cache. Results are
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
    private static let corridorBufferMeters: Double = 1_000

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
    /// ride through a region hits the network. Returns `[]` on total
    /// failure — a missing radar layer must never break navigation.
    func camerasAlong(route coords: [CLLocationCoordinate2D]) async -> [SpeedCamera] {
        guard coords.count >= 2 else { return [] }
        let box = Self.boundingBox(of: coords, bufferMeters: Self.corridorBufferMeters)
        let key = box.cacheKey

        if let cached = loadCache(key: key) {
            log.info("Speed cameras: disk-cache hit \(key, privacy: .public) (\(cached.count, privacy: .public))")
            return cached
        }

        do {
            let cams = try await fetch(box: box)
            saveCache(key: key, cameras: cams)
            log.info("Speed cameras: fetched \(cams.count, privacy: .public) for \(key, privacy: .public)")
            return cams
        } catch {
            log.warning("Speed cameras fetch failed: \(String(describing: error), privacy: .public)")
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
            let id: Int64
            let lat: Double?
            let lon: Double?
            let tags: [String: String]?
        }
        let elements: [Element]
    }

    private func fetch(box: BBox) async throws -> [SpeedCamera] {
        let query = """
        [out:json][timeout:25];
        node["highway"="speed_camera"](\(box.south),\(box.west),\(box.north),\(box.east));
        out body;
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
                    // 429/504 from a busy mirror — try the next endpoint.
                    lastError = URLError(.badServerResponse)
                    continue
                }
                let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
                return decoded.elements.compactMap(Self.makeCamera)
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
        let maxspeed: Int? = tags["maxspeed"].flatMap { raw in
            // "50", "50 km/h", "80;100" → take the leading integer.
            let digits = raw.prefix { $0.isNumber }
            return Int(digits)
        }
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

    // MARK: - Bounding box

    struct BBox: Sendable {
        let south: Double, west: Double, north: Double, east: Double
        /// Coarse cache key — round to 2 decimals (~1.1 km) so nearby
        /// routes share a cached region instead of each cutting a new
        /// micro-bbox fetch.
        var cacheKey: String {
            String(format: "%.2f_%.2f_%.2f_%.2f", south, west, north, east)
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

    // MARK: - Disk cache

    private struct CacheEnvelope: Codable {
        let savedAt: Date
        let cameras: [Cam]
        struct Cam: Codable {
            let id: Int64, lat: Double, lon: Double
            let maxspeed: Int?, section: Bool
        }
    }

    private func cacheURL(key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private func loadCache(key: String) -> [SpeedCamera]? {
        let url = cacheURL(key: key)
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(CacheEnvelope.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince(env.savedAt) < Self.cacheTTL else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return env.cameras.map {
            SpeedCamera(id: $0.id,
                        coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                        maxspeedKmh: $0.maxspeed,
                        isSection: $0.section)
        }
    }

    private func saveCache(key: String, cameras: [SpeedCamera]) {
        let env = CacheEnvelope(
            savedAt: Date(),
            cameras: cameras.map {
                .init(id: $0.id, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude,
                      maxspeed: $0.maxspeedKmh, section: $0.isSection)
            }
        )
        if let data = try? JSONEncoder().encode(env) {
            try? data.write(to: cacheURL(key: key), options: .atomic)
        }
    }
}

// MARK: - Helpers

private extension URLSessionConfiguration {
    func makeSession() -> URLSession { URLSession(configuration: self) }
}

extension CharacterSet {
    /// Percent-encoding set for an x-www-form-urlencoded VALUE — stricter
    /// than `.urlQueryAllowed`, which leaves `+`, `&`, `=` unescaped and
    /// would corrupt the Overpass query.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
