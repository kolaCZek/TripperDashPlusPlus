//
//  GPXExporter.swift
//  TripperDashPP
//
//  feat/free-ride-and-gpx-export — the write-side counterpart to
//  GPXParser.swift. Serialises a recorded ride (`RideStats.trackPoints`)
//  into a GPX 1.1 `<trk>` document with one `<trkseg>` of `<trkpt>`
//  elements, each carrying `<ele>`, `<time>`, and (when known) a Garmin
//  TrackPointExtension `<speed>`.
//
//  Symmetry with the importer: `GPXParser` reads `<trkpt lat lon><ele>
//  <time>` back into `RoutePoint`s, so a file this exporter writes
//  re-imports cleanly as a `.track` SavedRoute (the round-trip is pinned
//  by the Python mirror test `gpx_export_mirror` + `test_gpx_export`).
//
//  Dependency-free by design (no MapKit/UIKit) so the string-building
//  math is mirrored 1:1 in the Python suite and unit-tested without a
//  Mac — same rule as GPXGeometry. All XML values are escaped and
//  coordinates are emitted at 7 decimal places (~1.1 cm), which is finer
//  than GPS precision and matches common GPX writers.
//

import Foundation

/// Stateless GPX serialiser for a recorded ride track.
enum GPXExporter {

    /// Coordinate decimal places. 7 dp ≈ 1.1 cm at the equator — well
    /// below GPS accuracy, matches Garmin/Strava output, and keeps the
    /// file compact. Elevation is 1 dp (GPS altitude is coarse).
    static let coordinatePrecision = 7
    static let elevationPrecision = 1
    static let speedPrecision = 2

    /// ISO-8601 UTC timestamp formatter shared across all `<time>`
    /// elements. GPX requires UTC ("Z"); `.withInternetDateTime` emits
    /// exactly `2026-07-27T09:41:03Z`. A single formatter instance is
    /// reused (ISO8601DateFormatter is thread-safe for formatting).
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Build a GPX 1.1 document string from a recorded ride.
    ///
    /// - Parameters:
    ///   - stats: the accumulator whose `trackPoints` are serialised.
    ///   - trackName: `<trk><name>` (e.g. a timestamped ride title).
    /// - Returns: the full GPX XML, or `nil` when there is nothing to
    ///   export (no recorded points) — the caller disables the share
    ///   affordance in that case rather than writing an empty track.
    static func gpx(from stats: RideStats, trackName: String) -> String? {
        gpx(points: stats.trackPoints, trackName: trackName)
    }

    /// Core serialiser over a raw point list (the testable seam — the
    /// Python mirror calls the equivalent of this).
    static func gpx(points: [RideStats.TrackPoint], trackName: String) -> String? {
        guard !points.isEmpty else { return nil }

        var xml = ""
        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"TripperDashPP\" "
        xml += "xmlns=\"http://www.topografix.com/GPX/1/1\" "
        xml += "xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\">\n"

        // <metadata><name>…</name><time>…</time></metadata>: the ride's
        // display name + the first fix time, so a re-import (and any
        // desktop GPX tool) has a sensible title and date without opening
        // the track.
        xml += "  <metadata>\n"
        xml += "    <name>\(escape(trackName))</name>\n"
        xml += "    <time>\(isoFormatter.string(from: points[0].timestamp))</time>\n"
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

    /// A default, human-readable, filesystem-safe track name derived from
    /// the ride's start time, e.g. "Ride 2026-07-27 09:41". Used both as
    /// the `<name>` and (slugified by the caller) the filename.
    static func defaultTrackName(start: Date?, now: Date = Date()) -> String {
        let date = start ?? now
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Ride \(f.string(from: date))"
    }

    /// A filesystem-safe filename (no extension) for a track name:
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
        return name.isEmpty ? "ride" : name
    }

    // MARK: - Element builders

    private static func trkpt(_ p: RideStats.TrackPoint) -> String {
        let lat = fixed(p.latitude, coordinatePrecision)
        let lon = fixed(p.longitude, coordinatePrecision)
        var s = "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">\n"
        s += "        <ele>\(fixed(p.altitude, elevationPrecision))</ele>\n"
        s += "        <time>\(isoFormatter.string(from: p.timestamp))</time>\n"
        // Garmin TrackPointExtension speed (m/s). Only when known
        // (-1 == unknown Doppler speed) so we never emit a bogus 0/−1.
        if p.speedMps >= 0 {
            s += "        <extensions>\n"
            s += "          <gpxtpx:TrackPointExtension>\n"
            s += "            <gpxtpx:speed>\(fixed(p.speedMps, speedPrecision))</gpxtpx:speed>\n"
            s += "          </gpxtpx:TrackPointExtension>\n"
            s += "        </extensions>\n"
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
