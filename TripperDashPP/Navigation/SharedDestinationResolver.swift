//
//  SharedDestinationResolver.swift
//  TripperDashPP
//
//  "Share to TripperDash++" — Tesla-style. When the rider shares a place
//  or a route from Google Maps or Apple Maps into the app, this resolves
//  the shared payload (a URL or a plain-text blob) into an ordered list
//  of waypoints that pre-fill the planner.
//
//  Two halves:
//    • A PURE parser (`parse(...)`) — URL/text → [ResolvedWaypoint].
//      No I/O, fully unit-testable (Python mirror in
//      tools/fake_dash/tests/test_shared_destination_resolver.py).
//    • A thin async wrapper (`resolve(...)`) that first follows a
//      Google short-link redirect (maps.app.goo.gl carries NO coords —
//      it's a pure redirect) before handing the expanded URL to the
//      parser. Network only happens for the short-link case.
//
//  Graceful degradation (Martin, 8/2026): when nothing geocodable can be
//  extracted (offline short-link, unknown Google URL shape), we still
//  surface whatever human-readable label we found (place/road name) as a
//  `.searchHint` so the planner can open with its search field pre-filled
//  for a manual lookup — never a dead end.
//

import CoreLocation
import Foundation

/// One resolved stop from a shared link/text.
struct ResolvedWaypoint: Equatable, Sendable {
    /// Present when we recovered real coordinates.
    var coordinate: CLLocationCoordinate2D?
    /// Human-readable label (place/road name), when known.
    var name: String?

    init(coordinate: CLLocationCoordinate2D? = nil, name: String? = nil) {
        self.coordinate = coordinate
        self.name = name
    }

    static func == (l: ResolvedWaypoint, r: ResolvedWaypoint) -> Bool {
        l.name == r.name
            && l.coordinate?.latitude == r.coordinate?.latitude
            && l.coordinate?.longitude == r.coordinate?.longitude
    }
}

/// Outcome of resolving a shared payload.
enum ShareResolution: Equatable, Sendable {
    /// One or more stops with coordinates — pre-fill the planner directly.
    /// A single element is a single destination; 2+ is a multi-stop route.
    case waypoints([ResolvedWaypoint])
    /// No coordinates recovered, but we have a label to search for —
    /// open the planner's search field pre-filled with this text.
    case searchHint(String)
    /// Nothing usable at all.
    case empty
}

enum SharedDestinationResolver {

    // MARK: - Public async entry

    /// Resolve a shared payload. `urlFollower` expands a short-link to its
    /// redirect target (injected so tests stay offline); defaults to a
    /// real bounded HEAD/GET follow.
    static func resolve(
        text: String?,
        url: URL?,
        urlFollower: (URL) async -> URL? = Self.followRedirect
    ) async -> ShareResolution {
        // Prefer an explicit URL; otherwise scrape the first URL out of the
        // shared text (Google often shares "Name\nhttps://maps.app.goo.gl/…").
        let primaryURL = url ?? Self.firstURL(in: text)

        if let u = primaryURL {
            // Short-links carry no coords — expand first. Covers Google
            // (maps.app.goo.gl) AND the new Apple short form (maps.apple/p/…).
            if Self.isShortLink(u), let expanded = await urlFollower(u) {
                let r = parse(url: expanded, text: text)
                if case .empty = r {} else { return r }
            }
            let r = parse(url: u, text: text)
            if case .empty = r {} else { return r }
        }

        // No URL, or URL yielded nothing → fall back to the text itself.
        return parse(url: nil, text: text)
    }

    // MARK: - Pure parser

    /// Pure: derive waypoints (or a search hint) from a URL and/or text.
    /// No I/O. This is the unit-tested core.
    static func parse(url: URL?, text: String?) -> ShareResolution {
        if let u = url {
            let host = (u.host ?? "").lowercased()

            // --- Apple Maps (incl. new maps.apple short host & /place) ---
            if host.contains("maps.apple") {
                if let wps = parseAppleMaps(u), !wps.isEmpty {
                    return .waypoints(wps)
                }
            }

            // --- Google Maps (expanded) ---
            if host.contains("google.") || host.contains("goo.gl") {
                if let wps = parseGoogleMaps(u), !wps.isEmpty {
                    return .waypoints(wps)
                }
            }

            // --- Generic geo: URI ---
            if u.scheme?.lowercased() == "geo", let c = parseGeoURI(u) {
                return .waypoints([ResolvedWaypoint(coordinate: c)])
            }
        }

        // --- Text fallbacks ---
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            // Bare "lat, lon" pair anywhere in the text.
            if let c = parseLatLonPair(t) {
                return .waypoints([ResolvedWaypoint(coordinate: c)])
            }
            // Otherwise the best human label we can offer for manual search:
            // strip any URLs out of the text, keep the first non-empty line.
            if let hint = searchHint(from: t) {
                return .searchHint(hint)
            }
        }

        return .empty
    }

    // MARK: - Apple Maps

    /// `https://maps.apple.com/?...` — coords live in `ll` / `sll` / `q`
    /// (`lat,lon`); multi-stop uses `saddr`/`daddr` (address OR `lat,lon`).
    static func parseAppleMaps(_ url: URL) -> [ResolvedWaypoint]? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        func value(_ k: String) -> String? {
            items.first { $0.name.lowercased() == k }?.value
        }
        var out: [ResolvedWaypoint] = []

        // Ordered start → destination when present (a shared route).
        for key in ["saddr", "daddr"] {
            if let v = value(key) {
                if let c = parseLatLonPair(v) {
                    out.append(ResolvedWaypoint(coordinate: c))
                } else if !v.isEmpty {
                    out.append(ResolvedWaypoint(name: v))
                }
            }
        }
        if !out.isEmpty { return out }

        // Single place: ll / sll / q / coordinate + optional name.
        // The new maps.apple.com/place?… form carries `name=` and
        // `coordinate=lat,lon`; older forms use `q`.
        let name = value("name") ?? value("q").flatMap { v -> String? in
            // `q` can be "lat,lon" OR a place name.
            parseLatLonPair(v) == nil ? v : nil
        }
        for key in ["ll", "sll", "q", "coordinate"] {
            if let v = value(key), let c = parseLatLonPair(v) {
                return [ResolvedWaypoint(coordinate: c, name: name)]
            }
        }
        if let name { return [ResolvedWaypoint(name: name)] }
        return nil
    }

    // MARK: - Google Maps

    /// Expanded Google URLs come in several shapes:
    ///   • `/maps/dir/A/B/C/...`            → multi-stop route (each seg a WP)
    ///   • `/maps/place/Name/@lat,lng,z`    → single place
    ///   • `?q=lat,lng` / `?query=lat,lng`  → single place
    ///   • `...!3dLAT!4dLNG...`             → embedded place coords
    static func parseGoogleMaps(_ url: URL) -> [ResolvedWaypoint]? {
        let full = url.absoluteString
        let path = url.path

        // --- /dir/ multi-stop ---
        if let range = path.range(of: "/dir/") {
            let tail = String(path[range.upperBound...])
            let segs = tail.split(separator: "/").map(String.init)
                .filter { !$0.hasPrefix("@") && !$0.hasPrefix("data=") && !$0.isEmpty }
            var out: [ResolvedWaypoint] = []
            for seg in segs {
                let decoded = seg.removingPercentEncoding ?? seg
                let cleaned = decoded.replacingOccurrences(of: "+", with: " ")
                if let c = parseLatLonPair(cleaned) {
                    out.append(ResolvedWaypoint(coordinate: c))
                } else if !cleaned.isEmpty {
                    out.append(ResolvedWaypoint(name: cleaned))
                }
            }
            // Also honor destination coords in the @lat,lng if the last seg
            // was a name but we can still anchor the view — skip: keep names.
            if !out.isEmpty { return out }
        }

        // --- saddr/daddr query route (Google's "directions" share) ---
        // e.g. ?saddr=50.23,14.17&daddr=Zvoleněves — start + destination,
        // each either "lat,lon" or a place name (name geocoded downstream).
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            func qval(_ k: String) -> String? {
                comps.queryItems?.first { $0.name.lowercased() == k }?.value
            }
            var route: [ResolvedWaypoint] = []
            for key in ["saddr", "daddr"] {
                guard let raw = qval(key), !raw.isEmpty else { continue }
                // Google packs multiple destinations into one daddr joined by
                // "to:" (e.g. "Zvoleněves to:Prague"). Split into segments.
                let decoded = (raw.removingPercentEncoding ?? raw)
                    .replacingOccurrences(of: "+", with: " ")
                let segments = decoded
                    .components(separatedBy: "to:")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                for seg in segments {
                    if let c = parseLatLonPair(seg) {
                        route.append(ResolvedWaypoint(coordinate: c))
                    } else {
                        route.append(ResolvedWaypoint(name: seg))
                    }
                }
            }
            if !route.isEmpty { return route }
        }

        // --- /place/ single ---
        var placeName: String?
        if let r = path.range(of: "/place/") {
            let tail = String(path[r.upperBound...])
            if let nameSeg = tail.split(separator: "/").first {
                let decoded = (String(nameSeg).removingPercentEncoding ?? String(nameSeg))
                    .replacingOccurrences(of: "+", with: " ")
                if !decoded.hasPrefix("@") { placeName = decoded }
            }
        }

        // Query q=/query= (may be lat,lon or a name).
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in comps.queryItems ?? [] {
                let n = item.name.lowercased()
                if (n == "q" || n == "query" || n == "destination"), let v = item.value {
                    if let c = parseLatLonPair(v) {
                        return [ResolvedWaypoint(coordinate: c, name: placeName)]
                    } else if placeName == nil, !v.isEmpty {
                        placeName = v
                    }
                }
            }
        }

        // `@lat,lng,zoom` — the map center; good coordinates for a place.
        if let c = parseAtCoord(full) {
            return [ResolvedWaypoint(coordinate: c, name: placeName)]
        }
        // `!3dLAT!4dLNG` — the place's precise pin (better than @center).
        if let c = parseBangCoord(full) {
            return [ResolvedWaypoint(coordinate: c, name: placeName)]
        }
        if let placeName { return [ResolvedWaypoint(name: placeName)] }
        return nil
    }

    // MARK: - Coordinate scanners

    /// `@37.33,-122.03,15z` → first coord pair after an `@`.
    static func parseAtCoord(_ s: String) -> CLLocationCoordinate2D? {
        guard let at = s.range(of: "@") else { return nil }
        let tail = String(s[at.upperBound...])
        let head = tail.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "," }
        return parseLatLonPair(String(head))
    }

    /// `!3d50.0755!4d14.4378` → Google's embedded place pin.
    static func parseBangCoord(_ s: String) -> CLLocationCoordinate2D? {
        func grab(_ tag: String) -> Double? {
            guard let r = s.range(of: tag) else { return nil }
            let tail = s[r.upperBound...]
            let num = tail.prefix { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(num)
        }
        guard let lat = grab("!3d"), let lon = grab("!4d") else { return nil }
        return validCoord(lat: lat, lon: lon)
    }

    /// `geo:lat,lon` / `geo:lat,lon?q=...`.
    static func parseGeoURI(_ url: URL) -> CLLocationCoordinate2D? {
        // scheme is "geo", the "path"/opaque holds "lat,lon".
        let body = url.absoluteString
            .replacingOccurrences(of: "geo:", with: "")
            .split(separator: "?").first.map(String.init) ?? ""
        return parseLatLonPair(body)
    }

    /// Parse a "lat,lon" (or "lat, lon") pair with validation.
    static func parseLatLonPair(_ s: String) -> CLLocationCoordinate2D? {
        // Find the first two comma-separated numeric tokens.
        let parts = s.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let latStr = parts[0].trimmingCharacters(in: .whitespaces)
        let lonStr = parts[1].trimmingCharacters(in: .whitespaces)
        guard let lat = Double(latStr), let lon = Double(lonStr) else { return nil }
        return validCoord(lat: lat, lon: lon)
    }

    static func validCoord(lat: Double, lon: Double) -> CLLocationCoordinate2D? {
        guard lat >= -90, lat <= 90, lon >= -180, lon <= 180,
              !(lat == 0 && lon == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Text helpers

    static func isShortLink(_ url: URL) -> Bool {
        let h = (url.host ?? "").lowercased()
        // Google short-links.
        if h == "maps.app.goo.gl" || h == "goo.gl" || h.hasSuffix(".app.goo.gl") {
            return true
        }
        // New Apple short form: https://maps.apple/p/<id> (host has no .com,
        // path starts with /p/). Redirects to maps.apple.com/place?…
        if h == "maps.apple" && url.path.hasPrefix("/p/") {
            return true
        }
        return false
    }

    /// First http(s) URL embedded in free text.
    static func firstURL(in text: String?) -> URL? {
        guard let text else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let match = detector?.firstMatch(in: text, options: [], range: range)
        return match?.url
    }

    /// Best human-readable label for a manual search fallback: strip URLs,
    /// return the first non-empty line.
    static func searchHint(from text: String) -> String? {
        var stripped = text
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            for m in detector.matches(in: text, options: [], range: range).reversed() {
                if let r = Range(m.range, in: stripped) {
                    stripped.replaceSubrange(r, with: "")
                }
            }
        }
        let line = stripped
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return (line?.isEmpty == false) ? line : nil
    }

    // MARK: - Redirect follow (real network)

    /// Follow a short-link's redirect to its expanded URL. Bounded, HEAD
    /// first (falls back to GET), returns nil on any failure so the caller
    /// degrades to the text fallback.
    static func followRedirect(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        do {
            let (_, response) = try await session.data(for: request)
            if let final = response.url, final != url { return final }
        } catch {
            // HEAD can be rejected; try a GET.
            request.httpMethod = "GET"
            if let (_, response) = try? await session.data(for: request),
               let final = response.url, final != url {
                return final
            }
        }
        return nil
    }
}
