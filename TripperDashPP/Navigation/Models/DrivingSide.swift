//
//  DrivingSide.swift
//  TripperDashPP
//
//  Which side of the road traffic drives on at a given geographic point.
//
//  Why this exists:
//  ----------------
//  Several maneuver decisions are MIRRORED between left- and right-hand
//  traffic and were previously hard-coded to the right-hand-traffic
//  (Continental Europe) convention — correct where the app was born,
//  wrong for ~a third of the planet:
//
//    1. Roundabout rotation. Right-hand traffic circulates a roundabout
//       COUNTER-clockwise (CCW); left-hand traffic circulates CLOCKWISE
//       (CW). The dash glyph catalog has distinct byte ranges for each
//       (CCW 0x0A.. / CW 0x31..), so sending the wrong winding draws an
//       arc curving the opposite way to the rider's actual path.
//    2. The default U-turn side when geometry can't disambiguate (RHT
//       U-turns via the left, LHT via the right).
//    3. The direction→exit-number heuristic for roundabout steps that
//       carry a turn word but no ordinal (RHT: right = 1st exit; LHT:
//       left = 1st exit).
//
//  This type resolves the driving side from the maneuver's own location
//  (e.g. the roundabout node = the last vertex of the arriving step's
//  polyline), so the classifier needs no live GPS fix and stays a pure
//  function.
//
//  Approach — coarse geographic regions, NOT reverse-geocoding:
//  -----------------------------------------------------------
//  Reverse-geocoding a country is async + needs the network, which can't
//  live inside the synchronous per-maneuver classifier. Instead we test
//  the point against a table of axis-aligned bounding boxes covering the
//  world's left-hand-traffic regions. Everything not inside a box is
//  right-hand traffic (the global default, and exactly correct for all of
//  Continental Europe / the Americas / China / most of Africa & Asia).
//
//  Accuracy note: the isolated LHT regions (British Isles, Ireland, Japan,
//  Australia, New Zealand, Sri Lanka, Cyprus, Malta) are island/landmass-
//  bounded and resolve exactly. The mainland LHT blocks (Indian
//  subcontinent, southern + eastern Africa, parts of SE Asia) use
//  generous boxes whose edges can misclassify a sliver of an adjacent
//  RHT country along a jagged inland border (e.g. a corner of Afghanistan
//  next to Pakistan, Rwanda/Burundi inside the East-Africa box). That is
//  an acceptable trade for a keyless offline lookup; if a field report
//  ever shows a roundabout drawn the wrong way at a specific border, add
//  or tighten a box here (mirror it in `tools/fake_dash/.../driving_side.py`).
//
//  Mirrored 1:1 by the Python `driving_side.py` so the CI sync test can
//  diff the two and stop them drifting, exactly like the maneuver
//  keywords and the roundabout parser.
//

import CoreLocation
import Foundation

/// The side of the road traffic drives on at a location. Right-hand
/// traffic is the global default; left-hand is looked up from a coarse
/// region table.
enum DrivingSide: Equatable, Sendable {
    case right
    case left

    /// Roundabouts circulate clockwise in left-hand-traffic countries,
    /// counter-clockwise in right-hand-traffic ones.
    var roundaboutClockwise: Bool { self == .left }

    /// An inclusive lat/lon bounding box. `minLon <= maxLon` only (none of
    /// our LHT regions straddle the ±180° antimeridian — New Zealand's
    /// box stops west of it).
    struct GeoBox: Sendable {
        let minLat, maxLat, minLon, maxLon: Double
        func contains(_ c: CLLocationCoordinate2D) -> Bool {
            c.latitude >= minLat && c.latitude <= maxLat
                && c.longitude >= minLon && c.longitude <= maxLon
        }
    }

    /// Coarse bounding boxes for the world's left-hand-traffic regions.
    /// Keep this list IDENTICAL (same boxes, same order) to
    /// `LEFT_HAND_REGIONS` in the Python mirror — the sync test asserts it.
    static let leftHandRegions: [GeoBox] = [
        // British Isles (UK + Ireland). South edge kept at 49.9 so the
        // Cornwall/Scilly tip is in but France's Cherbourg peninsula
        // (≤49.7) stays out. East edge 1.77 keeps Lowestoft Ness (the
        // easternmost point of Britain, ~1.76°E) while excluding RHT
        // Calais (~1.86°E) across the Channel.
        GeoBox(minLat: 49.9, maxLat: 60.9, minLon: -10.7, maxLon: 1.77),
        // Malta.
        GeoBox(minLat: 35.7, maxLat: 36.1, minLon: 14.1, maxLon: 14.6),
        // Cyprus.
        GeoBox(minLat: 34.5, maxLat: 35.8, minLon: 32.2, maxLon: 34.65),
        // Japan — mainland (Kyushu/Shikoku/Honshu/Hokkaido). West edge
        // 129.5 excludes the Korean peninsula (RHT; Busan ~129.1°E) while
        // keeping Nagasaki (~129.9°E). Split from the Ryukyu box below
        // because Japan and Korea overlap in longitude — no single box
        // separates them.
        GeoBox(minLat: 29.0, maxLat: 45.6, minLon: 129.5, maxLon: 146.0),
        // Japan — Ryukyu/Okinawa arc, south of Korea and west of the
        // mainland. Lon ≥122.8 keeps Yonaguni while excluding RHT Taiwan
        // (Taipei ~121.6°E); lat ≤29 keeps it clear of the mainland box.
        GeoBox(minLat: 24.0, maxLat: 29.0, minLon: 122.8, maxLon: 131.0),
        // Australia.
        GeoBox(minLat: -43.8, maxLat: -9.0, minLon: 112.8, maxLon: 154.0),
        // New Zealand (mainland; stops west of the antimeridian).
        GeoBox(minLat: -47.5, maxLat: -33.0, minLon: 166.0, maxLon: 179.2),
        // Indian subcontinent: India, Pakistan, Bangladesh, Nepal, Bhutan.
        // West edge ~62°E follows Pakistan; a sliver of SE Afghanistan is
        // unavoidably included along the jagged border (accepted).
        GeoBox(minLat: 6.5, maxLat: 37.1, minLon: 62.0, maxLon: 92.8),
        // Sri Lanka.
        GeoBox(minLat: 5.8, maxLat: 9.9, minLon: 79.6, maxLon: 81.95),
        // SE Asia LHT bloc: Thailand, Malaysia, Singapore, Indonesia,
        // Brunei, East Timor. RHT neighbours (Vietnam/Laos/Cambodia/
        // Philippines) sit mostly east/north of this box.
        GeoBox(minLat: -11.0, maxLat: 20.5, minLon: 95.0, maxLon: 119.5),
        // Southern Africa: South Africa, Lesotho, Eswatini, Namibia,
        // Botswana, Zimbabwe, southern Mozambique. Top at -16 keeps most
        // of RHT Angola/DRC out.
        GeoBox(minLat: -35.0, maxLat: -16.0, minLon: 11.0, maxLon: 41.0),
        // Eastern Africa LHT: Zambia, Malawi, Tanzania, Kenya, Uganda,
        // northern Mozambique. West edge 28.5 avoids most of RHT DRC; a
        // corner of Rwanda/Burundi is unavoidably included (accepted).
        GeoBox(minLat: -16.0, maxLat: 5.2, minLon: 28.5, maxLon: 42.0),
        // Guyana (the only LHT country in mainland South America).
        GeoBox(minLat: 1.0, maxLat: 8.7, minLon: -61.5, maxLon: -56.4),
    ]

    /// Resolve the driving side at `coordinate`. Right-hand traffic is the
    /// default; we only override to left when the point falls inside a
    /// known left-hand-traffic region. Pure + cheap (a handful of box
    /// tests) so it runs inside the per-maneuver classifier.
    static func at(_ coordinate: CLLocationCoordinate2D) -> DrivingSide {
        for box in leftHandRegions where box.contains(coordinate) {
            return .left
        }
        return .right
    }
}
