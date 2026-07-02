//
//  WeatherAlertService.swift
//  TripperDashPP
//
//  Ride-relevant weather alerting for the dash. Mirrors the OEM Royal
//  Enfield app's "Weather Alerts" notification, but keyless and
//  phone-side: we fetch the current conditions at the rider's position
//  AND at several points sampled along the route ahead, then — when
//  something a motorcyclist actually cares about is happening — rain,
//  ice, thunderstorms, strong gusts, fog — we surface a compact pill
//  burned into the bottom-right of the streamed map frame, reporting how
//  far along the route the next hazard sits ("Rain 15 km"). See
//  `MapViewSource.drawWeatherAlert`.
//
//  Why Open-Meteo (not WeatherKit):
//    - WeatherKit needs a PAID Apple Developer membership + a signed
//      JWT entitlement. TripperDash++ ships on a free Personal Team
//      (see CLAUDE.md "Distribution") and uses NO paid-only entitlements,
//      so WeatherKit is off the table.
//    - Open-Meteo is keyless, free for non-commercial use, returns WMO
//      weather codes + wind gusts + visibility + precipitation in one
//      GET, and supports MULTI-POINT queries (comma-separated lat/lon)
//      so the rider-position sample and EVERY along-route look-ahead
//      sample cost a single request. Verified shape (6/2026):
//        GET /v1/forecast?latitude=A,B,C&longitude=A,B,C
//            &current=weather_code,temperature_2m,precipitation,
//                     wind_gusts_10m,visibility&timezone=UTC
//        → top-level ARRAY (one object per point), each with
//          `.current.weather_code` (WMO), `.wind_gusts_10m` (km/h),
//          `.visibility` (m), `.precipitation` (mm).
//
//  Severity policy is deliberately CONSERVATIVE (Martin, 6/2026: only
//  surface things that matter on the bike — no clear/cloudy spam). The
//  classifier is a `nonisolated static` pure function so it can be unit
//  tested without standing up the network, exactly like
//  `CallStateObserver.callState`.
//

import CoreLocation
import Foundation
import OSLog

// MARK: - Model

/// A ride-relevant weather condition worth showing on the dash. `nil`
/// from the service means "nothing a motorcyclist needs to know" —
/// clear, cloudy, light wind — which is the common case and draws
/// nothing (no pill, no map clutter).
struct WeatherAlert: Equatable, Sendable {

    /// Three-step severity ladder. Drives the pill's accent colour and,
    /// when there are competing conditions, which one wins (`>` by
    /// `rawValue`).
    enum Severity: Int, Comparable, Sendable {
        case caution = 1   // amber  — rain, fog, snow, moderate gusts
        case warning = 2   // red    — storm, ice, heavy rain, strong gusts

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Short, glanceable label for the pill — the bare hazard noun
    /// ("Rain", "Storm", "Ice"). The renderer appends the distance
    /// ("Rain 15 km") from `distanceAhead`, so the label itself stays
    /// free of "ahead" wording. Kept ≤ ~10 chars so label + distance
    /// still fits the 526-px-wide frame's bottom-right corner.
    let title: String

    let severity: Severity

    /// True when the condition was detected further along the route
    /// rather than at the rider's current position. Equivalent to
    /// `distanceAhead != nil`; kept as the cheap boolean the pipeline
    /// already threads.
    let isAhead: Bool

    /// SF-Symbol-free glyph selector for `MapViewSource` to draw the
    /// matching pictograph (rain/storm/snow/ice/fog/wind) via CGContext
    /// paths — no asset catalog, consistent with the maneuver glyphs.
    let glyph: Glyph

    /// How far along the route the hazard sits, in metres, or `nil` when
    /// it's at the rider's current position. Drives the pill's distance
    /// suffix ("Rain 15 km"). Defaults to `nil` so the classifier can
    /// stay position-agnostic and only the along-route picker stamps a
    /// real distance.
    var distanceAhead: CLLocationDistance? = nil

    enum Glyph: Sendable {
        case rain
        case storm
        case snow
        case ice
        case fog
        case wind
    }
}

// MARK: - Service

/// Polls Open-Meteo for ride-relevant weather at the rider's position
/// plus a series of look-ahead points along the route, and publishes the
/// hazard to surface (or `nil`). MainActor-isolated so the published
/// value can be read straight by `AppStatus` / the nav pump without a
/// hop; the network call itself is `async` and off the main thread inside
/// `URLSession`.
@MainActor
final class WeatherAlertService {

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "WeatherAlert")

    /// Latest evaluated alert (`nil` = nothing worth showing). Read by the
    /// nav pump each tick and pushed into `MapViewSource.setWeatherAlert`.
    private(set) var current: WeatherAlert?

    /// Minimum spacing between network polls. Weather doesn't change fast
    /// and Open-Meteo asks for courteous use; 5 min is plenty for a ride.
    private static let pollInterval: TimeInterval = 300

    /// How far along the route to look, and how densely. Every point
    /// rides in the SAME single Open-Meteo GET (comma-separated lat/lon),
    /// so density is cheap in requests — it's the request COUNT that's
    /// rate-limited, not the point count. 10 km spacing out to 100 km ≈
    /// 10 look-ahead points + the rider position, once per `pollInterval`.
    /// Rider-confirmed (Martin, 7/2026): "up to 100 km, every 10 km".
    private static let sampleSpacingMeters: Double = 10_000
    private static let sampleRangeMeters: Double   = 100_000

    private var lastPollAt: Date?
    private var lastPollKey: String?

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 16
        cfg.allowsCellularAccess = true
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = [
            "User-Agent": "TripperDashPP/1.0 (https://github.com/kolaCZek/TripperDashPlusPlus)"
        ]
        return URLSession(configuration: cfg)
    }()

    /// Evaluate weather at `position` plus a series of points sampled
    /// along `routeAhead` (every `sampleSpacingMeters` out to
    /// `sampleRangeMeters`). Throttled to `pollInterval` and to ~1 km of
    /// movement, so it's safe to call from the 1 Hz nav pump every tick —
    /// the actual fetch only fires when the throttle opens. Updates
    /// `current` in place; returns the new value.
    @discardableResult
    func refresh(position: CLLocationCoordinate2D,
                 routeAhead: [CLLocationCoordinate2D] = []) async -> WeatherAlert? {
        // Throttle: time AND a coarse position grid (2 decimal places ≈
        // 1 km) so a stationary rider doesn't re-poll, but crossing into
        // a new neighbourhood does.
        let key = String(format: "%.2f,%.2f", position.latitude, position.longitude)
        if let last = lastPollAt,
           Date().timeIntervalSince(last) < Self.pollInterval,
           key == lastPollKey {
            return current
        }
        lastPollAt = Date()
        lastPollKey = key

        // Rider position is sample 0 (distance 0), followed by the
        // along-route look-ahead points. All in one GET.
        let aheadSamples = Self.samplesAlong(
            routeAhead, from: position,
            everyMeters: Self.sampleSpacingMeters, maxMeters: Self.sampleRangeMeters)
        let points: [(coord: CLLocationCoordinate2D, distanceM: CLLocationDistance)] =
            [(coord: position, distanceM: 0)] + aheadSamples
        do {
            let samples = try await fetch(points: points)
            current = Self.pickAlongRoute(samples)
            log.info("Weather refresh: \(self.current.map { "\($0.title) sev=\($0.severity.rawValue) dist=\($0.distanceAhead.map { "\(Int($0 / 1000))km" } ?? "here")" } ?? "clear", privacy: .public)")
        } catch {
            // Soft failure — keep the previous value rather than blanking a
            // valid warning on one flaky fetch. (Don't null `current`.)
            log.warning("Weather fetch failed: \(String(describing: error), privacy: .public)")
        }
        return current
    }

    /// Clear any active alert (called when navigation stops / streaming
    /// tears down so a stale pill doesn't linger into the next ride).
    func reset() {
        current = nil
        lastPollAt = nil
        lastPollKey = nil
    }

    // MARK: - Network

    /// Raw decoded sample for one geographic point — only the fields the
    /// classifier consumes, plus the along-route distance the caller
    /// tagged the point with.
    struct Sample: Sendable, Equatable {
        var weatherCode: Int
        var gustsKmh: Double
        var visibilityM: Double
        var precipitationMm: Double
        var isAhead: Bool
        /// Distance from the rider along the route, in metres. `0` for the
        /// rider's own position sample.
        var distanceM: CLLocationDistance
    }

    private struct OMResponse: Decodable {
        struct Current: Decodable {
            let weather_code: Int
            let wind_gusts_10m: Double?
            let visibility: Double?
            let precipitation: Double?
        }
        let current: Current
    }

    /// Fetch weather for every `(coord, distanceM)` point in one
    /// multi-point Open-Meteo GET. The returned `Sample`s carry each
    /// point's along-route distance straight through, so the picker can
    /// report "how far".
    private func fetch(points: [(coord: CLLocationCoordinate2D, distanceM: CLLocationDistance)]) async throws -> [Sample] {
        guard !points.isEmpty else { return [] }
        let lats = points.map { String(format: "%.4f", $0.coord.latitude) }.joined(separator: ",")
        let lons = points.map { String(format: "%.4f", $0.coord.longitude) }.joined(separator: ",")
        var comp = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comp.queryItems = [
            .init(name: "latitude", value: lats),
            .init(name: "longitude", value: lons),
            .init(name: "current", value: "weather_code,precipitation,wind_gusts_10m,visibility"),
            .init(name: "timezone", value: "UTC"),
        ]
        let (data, response) = try await session.data(from: comp.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // Open-Meteo returns a bare OBJECT for a single point and an ARRAY
        // for multiple — normalise to an array so decoding is uniform.
        let decoder = JSONDecoder()
        let responses: [OMResponse]
        if let arr = try? decoder.decode([OMResponse].self, from: data) {
            responses = arr
        } else {
            responses = [try decoder.decode(OMResponse.self, from: data)]
        }
        return responses.enumerated().map { idx, r in
            Sample(
                weatherCode: r.current.weather_code,
                gustsKmh: r.current.wind_gusts_10m ?? 0,
                visibilityM: r.current.visibility ?? .greatestFiniteMagnitude,
                precipitationMm: r.current.precipitation ?? 0,
                isAhead: idx > 0,
                distanceM: idx < points.count ? points[idx].distanceM : 0
            )
        }
    }

    // MARK: - Along-route hazard selection (pure, testable)

    /// Choose the single hazard to surface from a position + look-ahead
    /// sample set, and stamp its along-route distance. Policy
    /// (motorcycle-biased):
    ///   1. Classify every sample; drop the clears.
    ///   2. A `.warning` anywhere in range outranks any `.caution` (the
    ///      storm matters more than the nearby drizzle).
    ///   3. Within one severity, the NEAREST hazard wins (you hit it first).
    ///   4. A hazard at the rider's position (`distanceM == 0`) reports
    ///      with no "ahead" flag and no distance suffix.
    /// Returns `nil` when nothing ride-relevant is anywhere on the sampled
    /// route. Pure and `nonisolated` so it unit-tests without the network
    /// or the main actor.
    nonisolated static func pickAlongRoute(_ samples: [Sample]) -> WeatherAlert? {
        let hazards: [(alert: WeatherAlert, dist: CLLocationDistance)] = samples.compactMap {
            guard let a = classify($0, isAhead: $0.distanceM > 0) else { return nil }
            return (a, $0.distanceM)
        }
        guard !hazards.isEmpty else { return nil }
        // Highest severity first, then nearest. `max(by:)` returns the
        // element no other compares "greater" than.
        let best = hazards.max { lhs, rhs in
            if lhs.alert.severity != rhs.alert.severity {
                return lhs.alert.severity < rhs.alert.severity   // higher severity wins
            }
            return lhs.dist > rhs.dist                            // nearer wins
        }!
        let atRider = best.dist == 0
        return WeatherAlert(
            title: best.alert.title,
            severity: best.alert.severity,
            isAhead: !atRider,
            glyph: best.alert.glyph,
            distanceAhead: atRider ? nil : best.dist
        )
    }

    // MARK: - Classification (pure, testable)

    /// Map one weather `Sample` to a ride-relevant `WeatherAlert`, or `nil`
    /// when there's nothing a motorcyclist needs to know (clear, cloudy,
    /// light wind, good visibility). Pure and `nonisolated` so the logic
    /// tests can pin the exact truth table without the network or the main
    /// actor — same pattern as `CallStateObserver.callState`.
    ///
    /// The title is the bare hazard noun ("Rain", "Storm"); the pill's
    /// renderer composes the distance suffix from `distanceAhead`. `isAhead`
    /// is threaded onto the alert but no longer bakes into the title.
    ///
    /// WMO code reference (Open-Meteo `weather_code`):
    ///   0 clear · 1–3 clouds · 45/48 fog · 51/53/55 drizzle ·
    ///   56/57 freezing drizzle · 61/63/65 rain · 66/67 freezing rain ·
    ///   71/73/75 snow · 77 snow grains · 80/81/82 rain showers ·
    ///   85/86 snow showers · 95 thunderstorm · 96/99 thunderstorm+hail
    ///
    /// Severity ranking is biased for a motorcycle: ICE and THUNDERSTORM
    /// always warn; gusts matter far more than they would in a car.
    nonisolated static func classify(_ s: Sample, isAhead: Bool) -> WeatherAlert? {
        let code = s.weatherCode

        // Highest priority first — a single sample can satisfy several
        // tests (e.g. a thunderstorm with strong gusts); we report the most
        // dangerous condition.

        // 1. Ice — freezing rain/drizzle. Catastrophic on two wheels;
        //    always a WARNING regardless of anything else.
        if [56, 57, 66, 67].contains(code) {
            return WeatherAlert(title: "Ice", severity: .warning, isAhead: isAhead, glyph: .ice)
        }

        // 2. Thunderstorm (with or without hail).
        if [95, 96, 99].contains(code) {
            return WeatherAlert(title: "Storm", severity: .warning, isAhead: isAhead, glyph: .storm)
        }

        // 3. Heavy rain / violent showers, or any rain with strong gusts.
        if [65, 82].contains(code) {
            return WeatherAlert(title: "Heavy rain", severity: .warning, isAhead: isAhead, glyph: .rain)
        }

        // 4. Heavy snow / snow showers.
        if [75, 86].contains(code) {
            return WeatherAlert(title: "Heavy snow", severity: .warning, isAhead: isAhead, glyph: .snow)
        }

        // 5. Strong gusts — independent of precip. >65 km/h is a genuine
        //    hazard for a motorcycle (lane-keeping, crosswinds on bridges).
        if s.gustsKmh >= 65 {
            return WeatherAlert(title: "Strong wind", severity: .warning, isAhead: isAhead, glyph: .wind)
        }

        // 6. Very low visibility (dense fog) — WARNING under 500 m.
        if s.visibilityM < 500 {
            return WeatherAlert(title: "Dense fog", severity: .warning, isAhead: isAhead, glyph: .fog)
        }

        // ── CAUTION tier ──────────────────────────────────────────────

        // 7. Ordinary rain / drizzle / showers.
        if [51, 53, 55, 61, 63, 80, 81].contains(code) {
            return WeatherAlert(title: "Rain", severity: .caution, isAhead: isAhead, glyph: .rain)
        }

        // 8. Ordinary snow / snow grains.
        if [71, 73, 77, 85].contains(code) {
            return WeatherAlert(title: "Snow", severity: .caution, isAhead: isAhead, glyph: .snow)
        }

        // 9. Fog (45/48) or moderate low visibility.
        if [45, 48].contains(code) || s.visibilityM < 2000 {
            return WeatherAlert(title: "Fog", severity: .caution, isAhead: isAhead, glyph: .fog)
        }

        // 10. Moderate gusts.
        if s.gustsKmh >= 50 {
            return WeatherAlert(title: "Gusty wind", severity: .caution, isAhead: isAhead, glyph: .wind)
        }

        // Clear / cloudy / light wind → nothing to show.
        return nil
    }

    // MARK: - Route geometry

    /// Sample the polyline `coords` ahead of `from`, one point every
    /// `everyMeters`, out to `maxMeters` total, returning each point with
    /// its along-route distance from the rider. Walks from the vertex
    /// nearest `from` (so we measure ahead of the rider, not from the route
    /// origin), reusing the same walk `pointAlong` performs. Empty / too
    /// short a route → fewer (or zero) points.
    nonisolated static func samplesAlong(
        _ coords: [CLLocationCoordinate2D],
        from: CLLocationCoordinate2D,
        everyMeters: Double,
        maxMeters: Double
    ) -> [(coord: CLLocationCoordinate2D, distanceM: CLLocationDistance)] {
        guard coords.count >= 2, everyMeters > 0 else { return [] }
        var out: [(coord: CLLocationCoordinate2D, distanceM: CLLocationDistance)] = []
        var target = everyMeters
        while target <= maxMeters {
            guard let p = pointAlong(coords, from: from, meters: target) else { break }
            // `pointAlong` clamps to `coords.last` when the route is shorter
            // than `target`; if this point coincides with the previous one
            // we've run off the end — stop rather than emit duplicates.
            if let last = out.last, haversine(last.coord, p) < 1 { break }
            out.append((coord: p, distanceM: target))
            // If we've reached the physical end of the route, there's
            // nothing further to sample.
            if let end = coords.last, haversine(p, end) < 1 { break }
            target += everyMeters
        }
        return out
    }

    /// Walk `meters` along the polyline `coords` starting from the vertex
    /// nearest `from`, returning the coordinate reached (or the last vertex
    /// if the route is shorter than `meters`). Returns `nil` when the route
    /// is empty so the caller skips the look-ahead sample entirely.
    nonisolated static func pointAlong(_ coords: [CLLocationCoordinate2D],
                                       from: CLLocationCoordinate2D,
                                       meters: Double) -> CLLocationCoordinate2D? {
        guard coords.count >= 2 else { return coords.first }
        // Find the nearest vertex to start walking from (so we measure
        // ahead of the rider, not from the route origin).
        var startIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, c) in coords.enumerated() {
            let d = haversine(from, c)
            if d < bestDist { bestDist = d; startIdx = i }
        }
        var remaining = meters
        var i = startIdx
        while i < coords.count - 1 {
            let seg = haversine(coords[i], coords[i + 1])
            if seg >= remaining {
                let t = seg > 0 ? remaining / seg : 0
                let lat = coords[i].latitude + (coords[i + 1].latitude - coords[i].latitude) * t
                let lon = coords[i].longitude + (coords[i + 1].longitude - coords[i].longitude) * t
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            remaining -= seg
            i += 1
        }
        return coords.last
    }

    /// Great-circle distance in metres. Local copy so the service has no
    /// dependency on the renderer's `PolylineMath`.
    nonisolated static func haversine(_ a: CLLocationCoordinate2D,
                                      _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let la1 = a.latitude * .pi / 180
        let la2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
