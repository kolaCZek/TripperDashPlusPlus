//
//  GPXExporter.swift
//  TripperDashPP
//
//  feat/free-ride-and-gpx-export — the write-side counterpart to
//  GPXParser.swift. Serialises a `SavedRoute` (the on-device library
//  record) into a GPX 1.1 document so the rider can export any saved
//  route — including a recorded free ride — to the filesystem / share
//  sheet.
//
//  Shape: a single `<trk>` with one `<trkseg>` of `<trkpt lat lon>`
//  elements, each carrying an optional `<name>` when the RoutePoint has
//  one. SavedRoute holds coordinates (+ optional names) only — no
//  per-point elevation / time / speed — so those GPX fields are
//  deliberately not emitted. A file this exporter writes re-imports
//  cleanly through GPXParser as a `.track` SavedRoute (round-trip pinned
//  by the Python mirror test `gpx_export_mirror` + `test_gpx_export`).
//
//  Dependency-free by design (no MapKit/UIKit) so the string-building
//  math is mirrored 1:1 in the Python suite and unit-tested without a
//  Mac — same rule as GPXGeometry. All XML values are escaped and
//  coordinates are emitted at 7 decimal places (~1.1 cm), which is finer
//  than GPS precision and matches common GPX writers.
//

import Foundation

/// Stateless GPX serialiser for a saved route.
enum GPXExporter {

    /// Coordinate decimal places. 7 dp ≈ 1.1 cm at the equator — well
    /// below GPS accuracy, matches Garmin/Strava output, and keeps the
    /// file compact.
    static let coordinatePrecision = 7

    /// ISO-8601 UTC timestamp formatter for the `<metadata><time>` stamp
    /// (the file's creation time). GPX requires UTC ("Z").
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Build a GPX 1.1 document from a saved route.
    ///
    /// - Parameters:
    ///   - route: the library record whose points are serialised.
    ///   - now: creation timestamp for `<metadata><time>` (injectable for
    ///     tests).
    /// - Returns: the full GPX XML, or `nil` when the route has no points.
    static func gpx(from route: SavedRoute, now: Date = Date()) -> String? {
        gpx(points: route.points, trackName: route.name, now: now)
    }

    /// Core serialiser over a raw point list (the testable seam — the
    /// Python mirror calls the equivalent of this).
    static func gpx(points: [RoutePoint], trackName: String, now: Date = Date()) -> String? {
        guard !points.isEmpty else { return nil }

        var xml = ""
        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"TripperDashPP\" "
        xml += "xmlns=\"http://www.topografix.com/GPX/1/1\">\n"

        // <metadata><name>…</name><time>…</time></metadata>: the route's
        // display name + the export time, so a desktop GPX tool has a
        // sensible title and date without opening the track.
        xml += "  <metadata>\n"
        xml += "    <name>\(escape(trackName))</name>\n"
        xml += "    <time>\(isoFormatter.string(from: now))</time>\n"
        xml += "  </metadata>\n"

        xml += "  <trk>\n"
        xml += "    <name>\(escape(trackName))</name>\n"
        xml += "    <trkseg>\n"
        for p in points {
            xml += trkpt(p)
        }
        xml += "    </trkseg>\n"
        xml += "  </trk>\n"
        xml += "</gpx>\n"
        return xml
    }

    /// A filesystem-safe filename (no extension) for a route name:
    /// spaces → '-', strips anything outside [A-Za-z0-9-_].
    static func fileBaseName(for trackName: String) -> String {
        let collapsed = trackName.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ":", with: "")
        let allowed = collapsed.unicodeScalars.filter {
            CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
            ).contains($0)
        }
        let name = String(String.UnicodeScalarView(allowed))
        return name.isEmpty ? "route" : name
    }

    // MARK: - Element builders

    private static func trkpt(_ p: RoutePoint) -> String {
        let lat = fixed(p.latitude, coordinatePrecision)
        let lon = fixed(p.longitude, coordinatePrecision)
        var s = "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">\n"
        // Carry a point's GPX name back out when it has one (named vias /
        // waypoints). Anonymous trackpoints emit no <name>.
        if let n = p.name, !n.isEmpty {
            s += "        <name>\(escape(n))</name>\n"
        }
        s += "      </trkpt>\n"
        return s
    }

    // MARK: - Formatting helpers

    /// Fixed-decimal, locale-independent (always '.') number formatting —
    /// GPX is machine-readable, a comma decimal separator would break it.
    /// Mirrors the Python `f"{v:.{n}f}"` used in the test.
    static func fixed(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    /// Minimal XML text escaping for element/attribute content.
    static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}
