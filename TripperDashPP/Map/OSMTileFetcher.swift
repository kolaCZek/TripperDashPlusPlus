//
//  OSMTileFetcher.swift
//  TripperDashPP
//
//  Downloads OSM raster tiles via plain HTTPS GET. Replaces
//  MKMapSnapshotter for tile baking — gives us three things MapKit
//  can't:
//
//    1. Works in `.background` — URLSession requests are not subject
//       to the GPU-blocked-in-BG restriction that bit us on iOS 16+.
//    2. Disk-cacheable as plain {z}/{x}/{y}.png files (no need to
//       persist measured-geometry headers — Web Mercator is fully
//       deterministic).
//    3. Style-agnostic — swap a base URL and you get OpenTopoMap,
//       CyclOSM, or your own self-hosted style without touching
//       anything else.
//
//  Compliance with OSM tile usage policy
//  (https://operations.osmfoundation.org/policies/tiles/):
//    - Identifiable User-Agent containing app name + contact: ✅
//      "TripperDashPP/1.0 (https://github.com/kolaCZek/TripperDashPlusPlus)"
//    - HTTP caching headers respected (we hold tiles for up to
//      `TileDiskCache.maxAgeDays`, well within OSM's 7-day minimum)
//    - Hard rate limit: max `maxConcurrent` requests in flight,
//      exponential backoff on 429/5xx, no infinite retries
//    - Disk-cache first → in practice only the FIRST trip into a
//      neighbourhood hits the network
//
//  Future swap-in: change `baseURLTemplate` to e.g.
//  "https://tiles.kolaczek.cz/{z}/{x}/{y}.png" for a self-hosted
//  tile server. No other changes needed.
//

import Foundation
import OSLog

/// Errors that can come out of a tile fetch attempt. Surfaced to the
/// caller so it can decide whether to retry, give up, or fall back to
/// a dark-grey "no tile" frame.
enum OSMTileFetchError: Error {
    case http(status: Int)
    case rateLimited
    case network(underlying: Error)
    case cancelled
}

/// Singleton fetcher. Holds the URLSession, the in-flight semaphore,
/// and the dedupe map for parallel requests of the same tile.
actor OSMTileFetcher {

    static let shared = OSMTileFetcher()

    private let log = Logger(subsystem: "cz.kolaczek.TripperDashPP", category: "OSMTileFetcher")

    // Tile provider URL is no longer a single constant — it comes from
    // the `MapStyle` passed into `fetch`. Light uses OSM Carto, Dark uses
    // CARTO dark_all (see `MapStyle.tileURLTemplate`). The fetcher is
    // otherwise style-agnostic: it substitutes `{s}/{z}/{x}/{y}` and
    // applies the same rate-limit / retry / dedupe machinery to both.

    /// Mandatory under OSM tile policy. Without an identifiable
    /// User-Agent OSM.org bans the IP within minutes.
    private let userAgent: String = "TripperDashPP/1.0 (https://github.com/kolaCZek/TripperDashPlusPlus)"

    /// Cap concurrent fetches. OSM policy is "no heavy use" — 4 in
    /// flight is conservative for a navigation app and matches the
    /// concurrency we had on MKMapSnapshotter. Higher values risk
    /// rate-limit responses on long route bakes.
    private let maxConcurrent: Int = 4

    /// Per-attempt timeout. Anything longer than this on a 4G/LTE
    /// motorbike data connection has already failed in practice;
    /// fast-failing keeps the bake pipeline moving.
    private let perRequestTimeout: TimeInterval = 8.0

    /// Max retry attempts on transient errors (5xx, network blip).
    /// On 429 (rate-limit) we don't retry — that's a "back off" signal.
    private let maxRetries: Int = 2

    /// Dedicated URLSession with an aggressive in-RAM cache that
    /// sits in front of TileDiskCache. The OS-level cache catches
    /// the case where the same tile is requested twice within the
    /// same prerender pass (e.g. overlapping anchors).
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = perRequestTimeout
        config.timeoutIntervalForResource = perRequestTimeout * 2
        // 20 MB RAM, 100 MB disk — disk slot is mostly redundant with
        // TileDiskCache but URLSession's HTTP-semantic cache is free
        // and handles 304 Not Modified for us.
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 100 * 1024 * 1024,
            diskPath: "osm-tile-http-cache"
        )
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "image/png,image/*;q=0.8"
        ]
        // Allow tile fetches over cellular — this IS a motorbike nav app.
        config.allowsCellularAccess = true
        // Don't background the URLSession itself — we want completion
        // handlers on our normal queue, and TileDiskCache+the prerender
        // pipeline already handle the "app goes to BG mid-bake" case.
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// Concurrency gate — never more than `maxConcurrent` HTTP fetches
    /// in flight at once. Implemented as a counter that callers
    /// increment/decrement; under contention they suspend on a
    /// continuation in `waitForSlot`.
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Dedupe map — if two callers ask for the same tile at the same
    /// time (which happens when overlapping anchors converge on the
    /// same XYZ), we share the one in-flight Task instead of firing
    /// two HTTP requests. Network-efficient AND nicer to OSM.org.
    private var inFlightTasks: [String: Task<Data, Error>] = [:]

    /// Fetch the PNG bytes for tile (z, x, y) in the given `style`.
    /// Returns the raw PNG data — caller is responsible for caching to
    /// disk (via TileDiskCache, keyed by the same style) and decoding to
    /// CGImage.
    func fetch(style: MapStyle, z: Int, x: Int, y: Int) async throws -> Data {
        // Sanity-clamp y to valid range (Web Mercator). x wraps around
        // the antimeridian but we don't expect any real-world route
        // to hit longitude ±180 within the lateral buffer.
        let n = 1 << z
        guard y >= 0 && y < n else { throw OSMTileFetchError.http(status: 400) }
        let xWrapped = ((x % n) + n) % n   // wrap negatives too

        // Dedupe / in-flight key is namespaced by style so a light and a
        // dark request for the same (z, x, y) DON'T collapse onto one
        // shared task and return each other's palette.
        let key = "\(style.cacheNamespace)/\(z)/\(xWrapped)/\(y)"

        // Dedupe — coalesce with any in-flight task for the same key.
        if let existing = inFlightTasks[key] {
            do {
                return try await existing.value
            } catch {
                // The shared task failed; fall through and try our own.
                // (Don't propagate the SHARED failure — the original
                // caller already got it; we want our own retry chance.)
                log.debug("Dedupe peer failed, retrying solo: \(key, privacy: .public)")
            }
        }

        let task = Task<Data, Error> { [weak self] in
            guard let self else { throw OSMTileFetchError.cancelled }
            return try await self.fetchWithSlot(style: style, z: z, x: xWrapped, y: y, key: key)
        }
        inFlightTasks[key] = task

        defer { inFlightTasks[key] = nil }
        return try await task.value
    }

    /// Pick a deterministic subdomain shard for the `{s}` placeholder so
    /// the same (x, y) always resolves to the same host — keeps URLCache
    /// warm and spreads load across CARTO's a/b/c/d hosts. Returns nil
    /// when the style's template has no `{s}` (e.g. OSM Carto).
    private func shard(forX x: Int, y: Int, subdomains: [String]) -> String? {
        guard !subdomains.isEmpty else { return nil }
        let idx = abs(x &+ y) % subdomains.count
        return subdomains[idx]
    }

    /// Wrap a single fetch with the concurrency-gate dance + retry
    /// loop. Split out so the dedupe wrapper above can share it.
    private func fetchWithSlot(style: MapStyle, z: Int, x: Int, y: Int, key: String) async throws -> Data {
        await waitForSlot()
        defer { releaseSlot() }

        var template = style.tileURLTemplate
        if let s = shard(forX: x, y: y, subdomains: style.subdomains) {
            template = template.replacingOccurrences(of: "{s}", with: s)
        }
        let url = URL(string: template
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)")
        )!
        #if DEBUG
        log.debug("Tile URL [\(style.cacheNamespace, privacy: .public)]: \(url.absoluteString, privacy: .public)")
        #endif

        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                // Exponential backoff: 500 ms, 1 s, 2 s — bounded so
                // a stuck connection doesn't pause the whole bake.
                let delay = UInt64(0.5 * pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    throw OSMTileFetchError.network(underlying: URLError(.badServerResponse))
                }
                switch http.statusCode {
                case 200:
                    log.debug("OSM fetch OK \(key, privacy: .public) (\(data.count, privacy: .public) B, attempt \(attempt, privacy: .public))")
                    return data
                case 429:
                    // Rate-limited — bail immediately, no retry. Caller
                    // should treat this as a soft failure (use the
                    // dark fallback tile) and not hammer the server.
                    log.warning("OSM 429 rate-limited on \(key, privacy: .public)")
                    throw OSMTileFetchError.rateLimited
                case 500...599:
                    // Transient server error — retry per the backoff loop.
                    lastError = OSMTileFetchError.http(status: http.statusCode)
                    continue
                default:
                    // 4xx other than 429 = permanent client error;
                    // don't retry, surface to caller.
                    throw OSMTileFetchError.http(status: http.statusCode)
                }
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw OSMTileFetchError.cancelled
            } catch let urlError as URLError {
                // Network blip — eligible for retry.
                lastError = OSMTileFetchError.network(underlying: urlError)
                continue
            } catch {
                // Already an OSMTileFetchError (e.g. rateLimited) —
                // propagate as-is, don't retry.
                throw error
            }
        }
        throw lastError ?? OSMTileFetchError.network(underlying: URLError(.unknown))
    }

    /// Suspend until a concurrency slot is free, then claim it.
    private func waitForSlot() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        inFlight += 1
    }

    /// Release a slot, waking the next waiter if any.
    private func releaseSlot() {
        inFlight -= 1
        if let cont = waiters.first {
            waiters.removeFirst()
            cont.resume()
        }
    }
}
