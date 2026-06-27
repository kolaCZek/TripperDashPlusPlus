//
//  GPXParser.swift
//  TripperDashPP
//
//  feat/saved-routes-gpx — a dependency-free GPX importer built on
//  Foundation's SAX `XMLParser`. Turns a .gpx file into a `SavedRoute`
//  ready for the library.
//
//  Extraction priority (a GPX file may contain several of these):
//    1. <rte><rtept>   — an explicit planned route → RouteKind.track
//    2. <trk><trkseg><trkpt> — a recorded track (all segments
//                        concatenated in document order) → .track
//    3. <wpt>          — standalone waypoints → RouteKind.waypoints
//
//  Rationale for the priority: <rte>/<trk> describe an intended *path*
//  (dense, ordered), so they navigate as a reduced via-point track.
//  Bare <wpt>s are sparse named places the rider wants to pass through,
//  so each is kept as a real stop. If a file has BOTH a track and loose
//  waypoints, the track wins (it's the actual route); the waypoints are
//  ignored to avoid mixing two unrelated geometries.
//
//  The parser is deliberately tolerant: it reads `lat`/`lon` attributes
//  regardless of element namespace prefix (matches on the local name),
//  ignores unknown elements/extensions, and skips points with malformed
//  or out-of-range coordinates rather than failing the whole import.
//

import CoreLocation
import Foundation
import os

/// Result of parsing a GPX document, before reduction/persistence.
struct ParsedGPX {
    var name: String
    var kind: RouteKind
    /// Full, un-reduced ordered points exactly as they appeared.
    var rawPoints: [RoutePoint]
}

enum GPXImportError: LocalizedError {
    case unreadable
    case malformedXML(String)
    case noUsablePoints

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Couldn't read the GPX file."
        case .malformedXML(let detail):
            return "The GPX file is not valid XML (\(detail))."
        case .noUsablePoints:
            return "No route, track, or waypoints were found in the GPX file."
        }
    }
}

/// Stateless façade. `importRoute(from:)` is the one entry point the UI
/// calls from the `.fileImporter` completion.
enum GPXImporter {

    private static let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "GPXImport")

    /// Read + parse + reduce a GPX file URL into a `SavedRoute`.
    ///
    /// Handles the security-scoped resource dance the document picker
    /// hands us (`startAccessingSecurityScopedResource`). Throws a
    /// `GPXImportError` the caller can surface in an alert.
    static func importRoute(from url: URL) throws -> SavedRoute {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            throw GPXImportError.unreadable
        }
        let filename = url.lastPathComponent
        return try importRoute(from: data, filename: filename)
    }

    /// Testable core: parse raw bytes (filename only used for the name
    /// fallback + provenance).
    static func importRoute(from data: Data, filename: String?) throws -> SavedRoute {
        let parsed = try parse(data: data, filenameFallback: filename)
        guard !parsed.rawPoints.isEmpty else { throw GPXImportError.noUsablePoints }

        // Distance is always measured on the FULL trace, before reduction.
        let fullDistance = GPXGeometry.pathLength(parsed.rawPoints.map(\.coordinate))

        let points: [RoutePoint]
        switch parsed.kind {
        case .waypoints:
            // Sparse named stops — keep them all.
            points = parsed.rawPoints
        case .track:
            // Dense trace — simplify to ≤cap via-points, preserving the
            // most significant vertices (and always the endpoints).
            points = GPXGeometry.reduce(parsed.rawPoints, cap: RoutePoint.navigableCap)
        }

        log.info("Imported GPX '\(parsed.name, privacy: .public)' kind=\(parsed.kind.rawValue, privacy: .public) raw=\(parsed.rawPoints.count) reduced=\(points.count) dist=\(Int(fullDistance))m")

        return SavedRoute(name: parsed.name,
                          kind: parsed.kind,
                          points: points,
                          totalDistanceMeters: fullDistance,
                          sourceFilename: filename)
    }

    /// Parse the document and pick the highest-priority geometry present.
    static func parse(data: Data, filenameFallback: String?) throws -> ParsedGPX {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false  // we match on local names
        guard parser.parse() else {
            let err = parser.parserError?.localizedDescription ?? "unknown"
            throw GPXImportError.malformedXML(err)
        }

        // Priority: route points → track points → waypoints.
        let kind: RouteKind
        let pts: [RoutePoint]
        if !delegate.routePoints.isEmpty {
            kind = .track; pts = delegate.routePoints
        } else if !delegate.trackPoints.isEmpty {
            kind = .track; pts = delegate.trackPoints
        } else {
            kind = .waypoints; pts = delegate.waypoints
        }

        let fallback = (filenameFallback as NSString?)?
            .deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
        let name = delegate.bestName(fallback: fallback)

        return ParsedGPX(name: name, kind: kind, rawPoints: pts)
    }
}

/// SAX delegate — accumulates the three point streams + candidate names
/// in document order. We never hold the whole DOM; just append on each
/// closing point element.
private final class GPXParserDelegate: NSObject, XMLParserDelegate {

    // Collected geometry.
    var waypoints: [RoutePoint] = []
    var routePoints: [RoutePoint] = []
    var trackPoints: [RoutePoint] = []

    // Name candidates, by source (most-specific first when chosen).
    private var metadataName: String?
    private var routeName: String?
    private var trackName: String?

    // Parse cursor.
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentPointName: String?
    /// Which point element we're inside, if any.
    private enum PointContext { case wpt, rtept, trkpt }
    private var pointContext: PointContext?
    /// Section we're inside, to attribute a <name> correctly.
    private enum Section { case metadata, route, track, none }
    private var section: Section = .none
    /// Accumulator for the text content of the current element.
    private var textBuffer = ""
    private var capturingNameFor: NameTarget?
    private enum NameTarget { case metadata, route, track, point }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        textBuffer = ""

        switch name {
        case "metadata":
            section = .metadata
        case "rte":
            section = .route
        case "trk":
            section = .track
        case "wpt", "rtept", "trkpt":
            currentLat = attributeDict.firstValue("lat").flatMap(Double.init)
            currentLon = attributeDict.firstValue("lon").flatMap(Double.init)
            currentPointName = nil
            pointContext = (name == "wpt") ? .wpt : (name == "rtept" ? .rtept : .trkpt)
        case "name":
            // Attribute the upcoming text to the nearest enclosing scope.
            if pointContext != nil {
                capturingNameFor = .point
            } else {
                switch section {
                case .metadata: capturingNameFor = .metadata
                case .route:    capturingNameFor = .route
                case .track:    capturingNameFor = .track
                case .none:     capturingNameFor = nil
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(elementName)

        switch name {
        case "name":
            let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                switch capturingNameFor {
                case .metadata: if metadataName == nil { metadataName = text }
                case .route:    if routeName == nil { routeName = text }
                case .track:    if trackName == nil { trackName = text }
                case .point:    currentPointName = text
                case .none:     break
                }
            }
            capturingNameFor = nil

        case "wpt", "rtept", "trkpt":
            if let lat = currentLat, let lon = currentLon,
               GPXGeometry.isValid(lat: lat, lon: lon) {
                let p = RoutePoint(latitude: lat, longitude: lon, name: currentPointName)
                switch pointContext {
                case .wpt:   waypoints.append(p)
                case .rtept: routePoints.append(p)
                case .trkpt: trackPoints.append(p)
                case .none:  break
                }
            }
            currentLat = nil; currentLon = nil; currentPointName = nil
            pointContext = nil

        case "metadata", "rte", "trk":
            section = .none

        default:
            break
        }
        textBuffer = ""
    }

    /// Choose the best route name: route/track name → metadata name →
    /// caller's filename fallback → a generic default.
    func bestName(fallback: String?) -> String {
        let candidates = [routeName, trackName, metadataName, fallback]
        for c in candidates {
            if let c, !c.trimmingCharacters(in: .whitespaces).isEmpty { return c }
        }
        return "Imported route"
    }

    /// Strip any namespace prefix ("gpx:trkpt" → "trkpt").
    private func localName(_ raw: String) -> String {
        if let colon = raw.lastIndex(of: ":") {
            return String(raw[raw.index(after: colon)...])
        }
        return raw
    }
}

private extension Dictionary where Key == String, Value == String {
    /// Case-insensitive, namespace-tolerant attribute lookup
    /// ("lat"/"LAT"/"gpx:lat" all match "lat").
    func firstValue(_ key: String) -> String? {
        if let v = self[key] { return v }
        let lk = key.lowercased()
        for (k, v) in self {
            let local = k.contains(":") ? String(k[k.index(after: k.lastIndex(of: ":")!)...]) : k
            if local.lowercased() == lk { return v }
        }
        return nil
    }
}

/// Pure geometry helpers for GPX import — haversine length, validity,
/// and Douglas–Peucker reduction. Kept free of UIKit/MapKit so the math
/// can be mirrored 1:1 in the Python test suite (no Mac needed).
enum GPXGeometry {

    /// Reject NaN / infinite / out-of-range coordinates.
    static func isValid(lat: Double, lon: Double) -> Bool {
        guard lat.isFinite, lon.isFinite else { return false }
        return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    }

    /// Great-circle distance between two coordinates, metres. Same
    /// formula as PolylineMath.haversine — duplicated here to keep this
    /// enum dependency-free + independently testable.
    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let R = 6_371_000.0
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let dφ = (b.latitude - a.latitude) * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ/2) * sin(dφ/2) + cos(φ1) * cos(φ2) * sin(dλ/2) * sin(dλ/2)
        return R * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Sum of segment lengths along an ordered coordinate list, metres.
    static func pathLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(coords.count - 1) {
            total += haversine(coords[i], coords[i + 1])
        }
        return total
    }

    /// Bounding region (center + lat/lon span in degrees) that frames all
    /// points with padding — used by the saved-route preview map to pick
    /// an `MKCoordinateRegion`. Returns nil for an empty input.
    ///
    /// `paddingFactor` enlarges the raw min/max box so the trace isn't
    /// flush against the edges; `minSpanDegrees` stops a single point or a
    /// tiny route from zooming in absurdly far. Antimeridian crossing is
    /// NOT handled (motorcycle routes don't wrap ±180°); a route spanning
    /// the date line would frame the long way round.
    static func boundingSpan(_ coords: [CLLocationCoordinate2D],
                             paddingFactor: Double = 1.35,
                             minSpanDegrees: Double = 0.004)
        -> (center: CLLocationCoordinate2D, latDelta: Double, lonDelta: Double)? {
        guard let first = coords.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let latDelta = max((maxLat - minLat) * paddingFactor, minSpanDegrees)
        let lonDelta = max((maxLon - minLon) * paddingFactor, minSpanDegrees)
        return (center, latDelta, lonDelta)
    }

    /// Reduce a dense ordered point list to at most `cap` points,
    /// preserving shape. Strategy:
    ///   1. Douglas–Peucker with an initial epsilon, doubling epsilon
    ///      until the result fits under `cap` (RDP alone can't take a
    ///      hard count, so we binary-feel our way to ≤cap).
    ///   2. First + last point are ALWAYS retained.
    ///   3. Any point carrying a GPX `<name>` is force-kept (riders name
    ///      the stops that matter — a fuel halt, a viewpoint), so a named
    ///      via never gets simplified away.
    ///
    /// Returns the kept points in original order. Fresh UUIDs are NOT
    /// minted — the original RoutePoint identities are preserved.
    static func reduce(_ points: [RoutePoint], cap: Int) -> [RoutePoint] {
        guard points.count > cap, cap >= 2 else { return points }

        // Indices that must survive: endpoints + named points.
        var forced = Set<Int>([0, points.count - 1])
        for (i, p) in points.enumerated() where (p.name?.isEmpty == false) {
            forced.insert(i)
        }

        // If the forced set alone already meets/exceeds the cap, just
        // take the forced points (endpoints + names) in order — we can't
        // honour the cap AND keep every named point, and names win.
        if forced.count >= cap {
            return points.enumerated()
                .filter { forced.contains($0.offset) }
                .map { $0.element }
        }

        var epsilon = 10.0  // metres
        var kept = douglasPeucker(points, epsilon: epsilon, forced: forced)
        var guardCount = 0
        while kept.count > cap && guardCount < 40 {
            epsilon *= 1.6
            kept = douglasPeucker(points, epsilon: epsilon, forced: forced)
            guardCount += 1
        }

        // Epsilon growth can overshoot below cap; that's fine (≤cap). If
        // it somehow still exceeds cap (pathological forced set), trim
        // evenly while keeping endpoints.
        if kept.count > cap {
            kept = evenlySample(kept, cap: cap)
        }
        return kept
    }

    /// Classic Douglas–Peucker, distance measured as cross-track metres
    /// via an equirectangular projection (fine at trace scale). `forced`
    /// indices are always kept by splitting the recursion at them.
    static func douglasPeucker(_ points: [RoutePoint],
                               epsilon: Double,
                               forced: Set<Int>) -> [RoutePoint] {
        guard points.count >= 3 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        for i in forced { if i >= 0 && i < keep.count { keep[i] = true } }

        // Recurse over segments delimited by already-kept anchors so
        // forced points partition the run.
        func simplify(_ start: Int, _ end: Int) {
            guard end > start + 1 else { return }
            var maxDist = 0.0
            var idx = start
            for i in (start + 1)..<end {
                let d = perpendicularDistance(points[i].coordinate,
                                              segmentStart: points[start].coordinate,
                                              segmentEnd: points[end].coordinate)
                if d > maxDist { maxDist = d; idx = i }
            }
            if maxDist > epsilon {
                keep[idx] = true
                simplify(start, idx)
                simplify(idx, end)
            }
        }

        // Walk anchor-to-anchor so forced midpoints subdivide correctly.
        let anchors = (0..<points.count).filter { keep[$0] }
        for j in 0..<(anchors.count - 1) {
            simplify(anchors[j], anchors[j + 1])
        }

        return (0..<points.count).filter { keep[$0] }.map { points[$0] }
    }

    /// Evenly sample `cap` points (keeping endpoints) — last-resort trim.
    static func evenlySample(_ points: [RoutePoint], cap: Int) -> [RoutePoint] {
        guard points.count > cap, cap >= 2 else { return points }
        var out: [RoutePoint] = []
        let step = Double(points.count - 1) / Double(cap - 1)
        for i in 0..<cap {
            out.append(points[Int((Double(i) * step).rounded())])
        }
        // Guard against rounding dupes at the tail.
        if out.last?.id != points.last?.id { out[out.count - 1] = points[points.count - 1] }
        return out
    }

    /// Perpendicular (cross-track) distance from a point to a segment,
    /// metres. Equirectangular projection around the segment midpoint —
    /// same approach as PolylineMath.perpendicularDistance.
    static func perpendicularDistance(_ p: CLLocationCoordinate2D,
                                      segmentStart a: CLLocationCoordinate2D,
                                      segmentEnd b: CLLocationCoordinate2D) -> Double {
        let midLat = (a.latitude + b.latitude) / 2 * .pi / 180
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(midLat)

        let ax = a.longitude * mPerDegLon, ay = a.latitude * mPerDegLat
        let bx = b.longitude * mPerDegLon, by = b.latitude * mPerDegLat
        let px = p.longitude * mPerDegLon, py = p.latitude * mPerDegLat

        let dx = bx - ax, dy = by - ay
        let lenSq = dx*dx + dy*dy
        guard lenSq > 0 else { return haversine(p, a) }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))
        let projX = ax + t * dx, projY = ay + t * dy
        let ex = px - projX, ey = py - projY
        return sqrt(ex*ex + ey*ey)
    }
}
