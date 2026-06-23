//
//  ManeuverGeometry.swift
//  TripperDashPP
//
//  Direction-of-turn classification from ROUTE GEOMETRY rather than the
//  localized `MKRoute.Step.instructions` text.
//
//  Why geometry instead of text:
//  ------------------------------
//  `MKRoute.Step` exposes NO structured maneuver type — Apple keeps the
//  turn enum private and only hands us a localized free-text string
//  ("Turn right onto…", "Odbočte doprava…"). The text classifier
//  (`ManeuverKind.classify`) had two field-confirmed failure modes that
//  are *intrinsic* to NLP-ing that string:
//
//    1. A right turn onto a road whose NAME contains a left-token
//       ("…onto Leftbank Road") was read as a LEFT turn, because the
//       classifier substring-matched "left" anywhere in the clause and
//       checked left before right. (Bug B, 6/2026 field ride.)
//    2. Locale fragility: every language needs its own keyword list, and
//       a missing or reordered keyword silently degrades to ".straight".
//
//  The *direction* of a turn is a geometric fact: the signed angle
//  between the rider's incoming heading and the outgoing heading at the
//  maneuver point. We can compute that directly from the step polylines,
//  with zero language dependence. This kills Bug B permanently and makes
//  slight/normal/sharp/U-turn fall out of one angle threshold table.
//
//  What geometry CANNOT give us (still text-derived in `classify`):
//    - roundabout EXIT NUMBER — the route polyline passes THROUGH the
//      circle but never traces the arms we DON'T take, so the exit count
//      is unknowable from geometry. Parsed from text instead (see
//      `RoundaboutInstructionParser`).
//    - merge / fork / ferry / railroad / arrive — these are semantic, not
//      angular (a merge and a slight-right can have the same angle).
//
//  So the production classifier is a HYBRID: text decides the maneuver
//  FAMILY (roundabout? merge? exit? ferry? arrival? plain turn?), and for
//  the plain-turn family geometry decides the DIRECTION + sharpness.
//
//  Robustness note (the load-bearing detail):
//  ------------------------------------------
//  Polyline vertices near a maneuver can be sub-meter apart. Taking the
//  bearing of just the last incoming / first outgoing segment reads pure
//  GPS/encoding jitter and can flip the sign of the turn (a 0.4 m blip
//  before the node turned a +90° right into −50° "left" in unit tests).
//  We therefore ACCUMULATE distance walking back from / forward through
//  the node until we've covered `anchorDistanceMeters` of real travel,
//  then take the bearing across that span. This is the same trick OSRM /
//  Valhalla use to compute their `bearing_before` / `bearing_after`.
//

import CoreLocation
import Foundation
import MapKit

enum ManeuverGeometry {

    /// How far (meters) to walk away from the maneuver node before
    /// sampling a bearing. ~18 m smooths out vertex jitter and short
    /// curb-radius arcs while staying local enough to capture the actual
    /// turn (not the road's general curvature 100 m away).
    static let anchorDistanceMeters: CLLocationDistance = 18.0

    /// A lateral turn direction + sharpness derived purely from the
    /// signed turn angle. Maps 1:1 onto the lateral `ManeuverKind` cases.
    enum Turn: Equatable {
        case straight
        case slightLeft, left, sharpLeft
        case slightRight, right, sharpRight
        case uTurnLeft, uTurnRight
    }

    /// Signed turn angle in degrees at the maneuver node.
    /// Positive = right (clockwise), negative = left (counter-clockwise).
    /// `nil` when there isn't enough geometry on either side to get a
    /// trustworthy bearing (degenerate step) — caller falls back to text.
    ///
    /// - Parameters:
    ///   - previousStepPolyline: the step the rider is COMPLETING; its
    ///     vertices end at the maneuver node. Pass `nil` for the very
    ///     first step (no incoming leg → no turn).
    ///   - currentStepPolyline: the step that STARTS at the maneuver node
    ///     (i.e. `nextStep.polyline`), whose first vertices leave the node.
    static func signedTurnAngle(previousStepPolyline: MKPolyline?,
                                currentStepPolyline: MKPolyline) -> Double? {
        guard let prev = previousStepPolyline else { return nil }

        let prevPts = coordinates(of: prev)
        let curPts = coordinates(of: currentStepPolyline)
        guard prevPts.count >= 2, curPts.count >= 2 else { return nil }

        guard let incoming = incomingBearing(prevPts),
              let outgoing = outgoingBearing(curPts) else { return nil }

        return signedDelta(from: incoming, to: outgoing)
    }

    /// Convenience: angle → `Turn` bucket. Thresholds tuned for
    /// motorcycle turn-by-turn (a rider cares about lean-in vs
    /// near-stop). `nil` angle → `nil` (let caller fall back to text).
    static func turn(forSignedAngle angle: Double?) -> Turn? {
        guard let a = angle else { return nil }
        let mag = abs(a)
        switch mag {
        case 160...:      return a > 0 ? .uTurnRight : .uTurnLeft
        case 110..<160:   return a > 0 ? .sharpRight : .sharpLeft
        case 35..<110:    return a > 0 ? .right : .left
        case 12..<35:     return a > 0 ? .slightRight : .slightLeft
        default:          return .straight
        }
    }

    /// One-shot helper used by `ManeuverKind.classify`.
    static func turn(previousStepPolyline: MKPolyline?,
                     currentStepPolyline: MKPolyline) -> Turn? {
        turn(forSignedAngle: signedTurnAngle(
            previousStepPolyline: previousStepPolyline,
            currentStepPolyline: currentStepPolyline))
    }

    // MARK: - Bearing sampling

    /// Bearing of the rider's approach to the node: walk BACKWARD from the
    /// node (= last vertex) until `anchorDistanceMeters` is covered, then
    /// take the bearing from that anchor TO the node.
    private static func incomingBearing(_ prevPts: [CLLocationCoordinate2D]) -> Double? {
        let node = prevPts[prevPts.count - 1]
        var acc: CLLocationDistance = 0
        var anchor = prevPts[0]
        var i = prevPts.count - 1
        while i > 0 {
            acc += haversine(prevPts[i], prevPts[i - 1])
            anchor = prevPts[i - 1]
            if acc >= anchorDistanceMeters { break }
            i -= 1
        }
        guard haversine(anchor, node) >= 1.0 else { return nil }
        return bearing(from: anchor, to: node)
    }

    /// Bearing of the rider's departure from the node: walk FORWARD from
    /// the node (= first vertex) until `anchorDistanceMeters` is covered,
    /// then take the bearing from the node TO that anchor.
    private static func outgoingBearing(_ curPts: [CLLocationCoordinate2D]) -> Double? {
        let node = curPts[0]
        var acc: CLLocationDistance = 0
        var anchor = curPts[curPts.count - 1]
        var i = 0
        while i < curPts.count - 1 {
            acc += haversine(curPts[i], curPts[i + 1])
            anchor = curPts[i + 1]
            if acc >= anchorDistanceMeters { break }
            i += 1
        }
        guard haversine(node, anchor) >= 1.0 else { return nil }
        return bearing(from: node, to: anchor)
    }

    // MARK: - Geometry primitives

    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let n = polyline.pointCount
        guard n > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(), count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }

    /// Initial great-circle bearing a→b, degrees, 0=N, 90=E, clockwise.
    static func bearing(from a: CLLocationCoordinate2D,
                        to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Signed smallest delta from bearing `i` to `o`, in (−180, 180].
    /// Positive = clockwise (right), negative = counter-clockwise (left).
    static func signedDelta(from i: Double, to o: Double) -> Double {
        (o - i + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    /// Great-circle distance in meters.
    static func haversine(_ a: CLLocationCoordinate2D,
                          _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let R = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(min(1, sqrt(h)))
    }
}
