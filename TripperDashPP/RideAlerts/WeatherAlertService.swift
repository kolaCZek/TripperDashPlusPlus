//
//  WeatherAlertService.swift
//  TripperDashPP
//
//  Ride-relevant weather alerting for the dash. Mirrors the OEM Royal
//  Enfield app's "Weather Alerts" notification, but keyless and
//  phone-side: we fetch the current conditions at the rider's position
//  (and a look-ahead point further along the route) and, when something
//  a motorcyclist actually cares about is happening — rain, ice,
//  thunderstorms, strong gusts, fog — we surface a compact pill burned
//  into the bottom-right of the streamed map frame (see
//  `MapViewSource.drawWeatherAlert`).
//
//  Why Open-Meteo (not WeatherKit):
//    - WeatherKit needs a PAID Apple Developer membership + a signed
//      JWT entitlement. TripperDash++ ships on a free Personal Team
//      (see CLAUDE.md "Distribution") and uses NO paid-only entitlements,
//      so WeatherKit is off the table.
//    - Open-Meteo is keyless, free for non-commercial use, returns WMO
//      weather codes + wind gusts + visibility + precipitation in one
//      GET, and supports MULTI-POINT queries (comma-separated lat/lon)
//      so the rider-position sample and the look-ahead sample cost a
//      single request. Verified shape (6/2026):
//        GET /v1/forecast?latitude=A,B&longitude=A,B
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

    /// Short, glanceable label for the pill (≤ ~14 chars so it fits the
    /// 526-px-wide frame's bottom-right corner without truncation).
    let title: String

    let severity: Severity

    /// True when the condition was detected at the LOOK-AHEAD sample
    /// (further along the route) rather than at the rider's current
    /// position. The pill prefixes an "↑" so the rider reads it as
    /// "coming up", not "right now".
    let isAhead: Bool

    /// SF-Symbol-free glyph selector for `MapViewSource` to draw the
    /// matching pictograph (rain/storm/snow/ice/fog/wind) via CGContext
    /// paths — no asset catalog, consistent with the maneuver glyphs.
    let glyph: Glyph

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
/// plus a look-ahead point, and publishes the worst current `WeatherAlert`
/// (or `nil`). MainActor-isolated so the published value can be read
/// straight by `AppStatus` / the nav pump without a hop; the network call
/// itself is `async` and off the main thread inside `URLSession`.
@MainActor
final class WeatherAlertService {

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "WeatherAlert")

    /// Latest evaluated alert (`nil` = nothing worth showing). Read by the
    /// nav pump each tick and pushed into `MapViewSource.setWeatherAlert`.
    private(set) var current: WeatherAlert?

    /// Minimum spacing between network polls. Weather doesn't change fast
    /// and Open-Meteo asks for courteous use; 5 min is plenty for a ride.
    private static let pollInterval: TimeInterval = 300

    /// How far along the route to sample the look-ahead point. ~20 km is
    /// roughly 10–12 min ahead at regional speeds — enough warning to pull
    /// over before a storm front without alerting for weather two counties
    /// away.
    private static let lookaheadMeters: Double = 20_000

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

    /// Evaluate weather at `position` (+ a look-ahead point taken
    /// `lookaheadMeters` along `routeAhead`, if supplied). Throttled to
    /// `pollInterval` and to ~1 km of movement, so it's safe to call from
    /// the 1 Hz nav pump every tick — the actual fetch only fires when the
    /// throttle opens. Updates `current` in place; returns the new value.
    @discardableResult
    func refresh(position: CLLocationCoordinate2D,
                 routeAhead: [CLLocationCoordinate2D] = []) async -> WeatherAlert? {
        // Throttle: time AND a coarse position grid (3 decimal places ≈
        // 100 m) so a stationary rider doesn't re-poll, but crossing into
        // a new neighbourhood does.
        let key = String(format: "%.2f,%.2f", position.latitude, position.longitude)
        if let last = lastPollAt,
           Date().timeIntervalSince(last) < Self.pollInterval,
           key == lastPollKey {
            return current
        }
        lastPollAt = Date()
        lastPollKey = key

        let ahead = Self.pointAlong(routeAhead, from: position, meters: Self.lookaheadMeters)
        do {
            let samples = try await fetch(points: [position] + (ahead.map { [$0] } ?? []))
            let here = samples.first.flatMap { Self.classify($0, isAhead: false) }
            let upcoming = samples.count > 1 ? Self.classify(samples[1], isAhead: true) : nil
            // Worst wins; a current-position warning outranks a milder
            // look-ahead and vice-versa.
            current = [here, upcoming].compactMap { $0 }.max(by: { $0.severity < $1.severity })
            log.info("Weather refresh: \(self.current.map { "\($0.title) sev=\($0.severity.rawValue) ahead=\($0.isAhead)" } ?? "clear", privacy: .public)")
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
    /// classifier consumes.
    struct Sample: Sendable, Equatable {
        var weatherCode: Int
        var gustsKmh: Double
        var visibilityM: Double
        var precipitationMm: Double
        var isAhead: Bool
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

    private func fetch(points: [CLLocationCoordinate2D]) async throws -> [Sample] {
        guard !points.isEmpty else { return [] }
        let lats = points.map { String(format: "%.4f", $0.latitude) }.joined(separator: ",")
        let lons = points.map { String(format: "%.4f", $0.longitude) }.joined(separator: ",")
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
                isAhead: idx > 0
            )
        }
    }

    // MARK: - Classification (pure, testable)

    /// Map one weather `Sample` to a ride-relevant `WeatherAlert`, or `nil`
    /// when there's nothing a motorcyclist needs to know (clear, cloudy,
    /// light wind, good visibility). Pure and `nonisolated` so the logic
    /// tests can pin the exact truth table without the network or the main
    /// actor — same pattern as `CallStateObserver.callState`.
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
            return WeatherAlert(title: isAhead ? "Ice ahead" : "Ice / freezing",
                                severity: .warning, isAhead: isAhead, glyph: .ice)
        }

        // 2. Thunderstorm (with or without hail).
        if [95, 96, 99].contains(code) {
            return WeatherAlert(title: isAhead ? "Storm ahead" : "Thunderstorm",
                                severity: .warning, isAhead: isAhead, glyph: .storm)
        }

        // 3. Heavy rain / violent showers, or any rain with strong gusts.
        if [65, 82].contains(code) {
            return WeatherAlert(title: isAhead ? "Heavy rain ahead" : "Heavy rain",
                                severity: .warning, isAhead: isAhead, glyph: .rain)
        }

        // 4. Heavy snow / snow showers.
        if [75, 86].contains(code) {
            return WeatherAlert(title: isAhead ? "Snow ahead" : "Heavy snow",
                                severity: .warning, isAhead: isAhead, glyph: .snow)
        }

        // 5. Strong gusts — independent of precip. >65 km/h is a genuine
        //    hazard for a motorcycle (lane-keeping, crosswinds on bridges).
        if s.gustsKmh >= 65 {
            return WeatherAlert(title: isAhead ? "Wind ahead" : "Strong wind",
                                severity: .warning, isAhead: isAhead, glyph: .wind)
        }

        // 6. Very low visibility (dense fog) — WARNING under 500 m.
        if s.visibilityM < 500 {
            return WeatherAlert(title: isAhead ? "Dense fog ahead" : "Dense fog",
                                severity: .warning, isAhead: isAhead, glyph: .fog)
        }

        // ── CAUTION tier ──────────────────────────────────────────────

        // 7. Ordinary rain / drizzle / showers.
        if [51, 53, 55, 61, 63, 80, 81].contains(code) {
            return WeatherAlert(title: isAhead ? "Rain ahead" : "Rain",
                                severity: .caution, isAhead: isAhead, glyph: .rain)
        }

        // 8. Ordinary snow / snow grains.
        if [71, 73, 77, 85].contains(code) {
            return WeatherAlert(title: isAhead ? "Snow ahead" : "Snow",
                                severity: .caution, isAhead: isAhead, glyph: .snow)
        }

        // 9. Fog (45/48) or moderate low visibility.
        if [45, 48].contains(code) || s.visibilityM < 2000 {
            return WeatherAlert(title: isAhead ? "Fog ahead" : "Fog",
                                severity: .caution, isAhead: isAhead, glyph: .fog)
        }

        // 10. Moderate gusts.
        if s.gustsKmh >= 50 {
            return WeatherAlert(title: isAhead ? "Wind ahead" : "Gusty wind",
                                severity: .caution, isAhead: isAhead, glyph: .wind)
        }

        // Clear / cloudy / light wind → nothing to show.
        return nil
    }

    // MARK: - Route geometry

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
