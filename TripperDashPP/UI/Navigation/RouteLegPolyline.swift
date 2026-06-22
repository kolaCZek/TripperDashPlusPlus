//
//  RouteLegPolyline.swift
//  TripperDashPP
//
//  feat/route-waypoints — shared map-overlay primitives for in-map
//  alternative picking.
//
//  Generalises the tap-to-select-route hit-test that previously lived
//  inside RoutePreviewSheet. There a polyline was tagged with a single
//  `routeId`; here it carries `(legIndex, optionIndex)` so a tap maps
//  back to a specific leg's specific alternative — the core of "pick
//  the route between two waypoints by tapping it on the map".
//
//  The picking math is a free function (`pickLegOption`) decoupled from
//  any gesture/Coordinator so it's unit-testable on the Mac without a
//  live MKMapView.
//

import CoreLocation
import MapKit

/// An `MKPolyline` tagged with the leg + alternative it represents, so
/// a map tap can be correlated back to a `PlannedRoute` selection.
/// (MKPolyline has no useful overlay equality, so we tag instead of
/// comparing.)
final class RouteLegPolyline: MKPolyline {
    var legIndex: Int = 0
    var optionIndex: Int = 0
    /// Whether this option is the currently-selected one for its leg.
    /// Drives renderer styling (thick blue vs thin gray).
    var isSelected: Bool = false

    /// Build a tagged polyline from a route option's geometry.
    static func make(coordinates: [CLLocationCoordinate2D],
                     legIndex: Int,
                     optionIndex: Int,
                     isSelected: Bool) -> RouteLegPolyline {
        let poly = coordinates.withUnsafeBufferPointer { buf in
            RouteLegPolyline(coordinates: buf.baseAddress!, count: buf.count)
        }
        poly.legIndex = legIndex
        poly.optionIndex = optionIndex
        poly.isSelected = isSelected
        return poly
    }
}

/// Result of a successful in-map pick: which leg, which alternative.
struct LegOptionPick: Equatable {
    let legIndex: Int
    let optionIndex: Int
}

/// Hit-test a tap against a set of tagged polylines and return the
/// (leg, option) it selects, or nil if the nearest line is beyond the
/// tolerance.
///
/// Heuristic (carried over from RoutePreviewSheet and proven good
/// enough for picking between a handful of candidates): find the
/// polyline whose nearest VERTEX is closest to the tap, then accept it
/// only if that distance is within `tolerancePoints` screen points
/// converted to meters at the tap latitude + current zoom.
///
/// Decoupled from MKMapView gestures so it can be unit-tested: callers
/// pass the already-converted tap coordinate plus the meters-per-point
/// scale at the current zoom.
///
/// - Parameters:
///   - tap: tap location in map coordinates.
///   - candidates: tagged polylines currently on the map.
///   - metersPerPoint: ground meters covered by one screen point at the
///     tap location/zoom (`visibleMapRect.width / bounds.width`,
///     divided by `MKMapPointsPerMeterAtLatitude`). See
///     `metersPerScreenPoint(in:)` for the MKMapView convenience.
///   - tolerancePoints: screen-point radius to accept (default 22,
///     matching the prior RoutePreviewSheet value).
///   - minToleranceMeters: floor so a very zoomed-out map still accepts
///     a deliberate tap (default 30 m).
func pickLegOption(tap: CLLocationCoordinate2D,
                   candidates: [RouteLegPolyline],
                   metersPerPoint: Double,
                   tolerancePoints: Double = 22,
                   minToleranceMeters: Double = 30) -> LegOptionPick? {
    let tapLoc = CLLocation(latitude: tap.latitude, longitude: tap.longitude)
    var best: (pick: LegOptionPick, dist: CLLocationDistance)?

    for poly in candidates {
        let coords = poly.coordinateList()
        guard let nearest = coords
            .map({ CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: tapLoc) })
            .min()
        else { continue }
        if best == nil || nearest < best!.dist {
            best = (LegOptionPick(legIndex: poly.legIndex, optionIndex: poly.optionIndex), nearest)
        }
    }

    guard let candidate = best else { return nil }
    let threshold = max(minToleranceMeters, metersPerPoint * tolerancePoints)
    return candidate.dist <= threshold ? candidate.pick : nil
}

extension MKMapView {
    /// Ground meters covered by one screen point at the given latitude
    /// and the current zoom. Feed into `pickLegOption`.
    func metersPerScreenPoint(at latitude: CLLocationDegrees) -> Double {
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(latitude)
        guard pointsPerMeter > 0, bounds.width > 0 else { return .greatestFiniteMagnitude }
        let mapPointsPerScreenPoint = visibleMapRect.size.width / Double(bounds.width)
        return mapPointsPerScreenPoint / pointsPerMeter
    }
}

extension MKPolyline {
    /// Materialise the polyline's coordinates into an array.
    func coordinateList() -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                              count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
