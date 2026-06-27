//
//  SavedRoute.swift
//  TripperDashPP
//
//  feat/saved-routes-gpx — a route the rider imported (GPX) and saved
//  to the on-device library. Distinct from the transient `PlannedRoute`
//  used while actively planning: a `SavedRoute` is the persisted,
//  Codable record; navigating it rebuilds a fresh `PlannedRoute` from
//  these points (origin = live GPS) and lets MKDirections compute the
//  legs, so the existing turn-by-turn / reroute / dash-glyph engine is
//  reused verbatim — no parallel navigation stack.
//
//  Two import shapes funnel into the SAME model (rider-confirmed
//  6/2026):
//    - `.waypoints` — a handful of standalone <wpt> stops. Every point
//      is kept; MKDirections routes between them.
//    - `.track` — a dense <trk>/<rte> trace (potentially thousands of
//      points). Reduced to ≤`RoutePoint.navigableCap` via-points with
//      Douglas–Peucker BEFORE saving, so MKDirections has a sane number
//      of legs. `totalDistanceMeters` is measured along the ORIGINAL
//      (pre-reduction) trace so the displayed length matches the real
//      GPX, not the simplified one.
//

import CoreLocation
import Foundation

/// A single navigable point of a saved route. Value type, Codable.
struct RoutePoint: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var latitude: Double
    var longitude: Double
    /// Optional label carried from a GPX `<name>` (named <wpt>/<rtept>).
    /// nil for anonymous trackpoints.
    var name: String?

    init(id: UUID = UUID(), latitude: Double, longitude: Double, name: String? = nil) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D, name: String? = nil) {
        self.id = id
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.name = name
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Where the route's geometry came from — drives the import reduction
/// strategy and a small badge in the UI.
enum RouteKind: String, Codable, Sendable {
    /// Standalone GPX `<wpt>` stops: sparse, every one is a real
    /// destination. Kept as-is.
    case waypoints
    /// A dense `<trk>`/`<rte>` trace: simplified to via-points.
    case track
}

/// A persisted, importable route in the on-device library.
struct SavedRoute: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var kind: RouteKind
    /// Ordered navigable points. For `.track` these are already reduced
    /// to ≤`RoutePoint.navigableCap`; for `.waypoints` it's the full set.
    var points: [RoutePoint]
    /// Length measured along the ORIGINAL trace (haversine sum), metres.
    /// Stored at import so the list doesn't have to recompute, and so a
    /// reduced track still reports its true on-the-ground length.
    var totalDistanceMeters: Double
    /// Original filename (e.g. "alps-day2.gpx"), for display + dedupe.
    var sourceFilename: String?
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         kind: RouteKind,
         points: [RoutePoint],
         totalDistanceMeters: Double,
         sourceFilename: String? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.kind = kind
        self.points = points
        self.totalDistanceMeters = totalDistanceMeters
        self.sourceFilename = sourceFilename
        self.createdAt = createdAt
    }

    // MARK: - Equatable / Hashable
    //
    // Synthesised (value-based) on purpose — every stored property is
    // Hashable, so SwiftUI sees a row as "changed" when the name, points,
    // or distance change, even though the id is stable. An identity-only
    // `==`/`hash` (l.id == r.id) was the original bug: SavedRouteRow is a
    // separate child view whose `route` is a `let`, so SwiftUI memoises it
    // by equating the old and new value. Identity-only equality reported
    // "unchanged" after a rename/edit, so the row kept the stale name
    // until the list was rebuilt from scratch (sheet reopen). Do NOT
    // reintroduce a custom identity-only conformance here; if a
    // Set<SavedRoute>/dictionary keyed by identity is ever needed, wrap
    // the id instead.

    // MARK: - Derived display

    /// First point's coordinate (route start). nil only for an empty
    /// (malformed) route, which the importer rejects.
    var startCoordinate: CLLocationCoordinate2D? { points.first?.coordinate }
    var endCoordinate: CLLocationCoordinate2D? { points.last?.coordinate }

    /// Human label for the start point: its GPX name, else lat/lon.
    var startName: String { Self.label(for: points.first) }
    /// Human label for the destination point.
    var endName: String { Self.label(for: points.last) }

    private static func label(for p: RoutePoint?) -> String {
        guard let p else { return "—" }
        if let n = p.name, !n.isEmpty { return n }
        return String(format: "%.4f, %.4f", p.latitude, p.longitude)
    }

    /// "62 km" / "38 mi" / "850 m" — honours the rider's unit choice.
    func distanceDisplay(metric: Bool) -> String {
        let m = totalDistanceMeters
        if metric {
            if m < 1000 { return String(format: "%.0f m", m) }
            if m < 10_000 { return String(format: "%.1f km", m / 1000) }
            return String(format: "%.0f km", m / 1000)
        } else {
            let miles = m / 1609.344
            if miles < 0.1 { return String(format: "%.0f ft", m * 3.280839895) }
            if miles < 10 { return String(format: "%.1f mi", miles) }
            return String(format: "%.0f mi", miles)
        }
    }

    /// Bridge each point into a `Waypoint`. The first point is flagged so
    /// callers can choose to replace it with the live-GPS origin.
    func waypoints() -> [Waypoint] {
        points.enumerated().map { idx, p in
            Waypoint(name: p.name ?? (idx == 0 ? "Route start"
                                      : idx == points.count - 1 ? "Route end"
                                      : "Via \(idx)"),
                     addressLine: nil,
                     coordinate: p.coordinate,
                     isCurrentLocation: false)
        }
    }
}

extension RoutePoint {
    /// Hard cap on navigable via-points for a `.track` route. MKDirections
    /// is called once per leg (point→point), so this bounds the network /
    /// recompute cost. 24 legs is already a long tour; the geometry is
    /// preserved by Douglas–Peucker choosing the most significant points.
    static let navigableCap = 24
}
