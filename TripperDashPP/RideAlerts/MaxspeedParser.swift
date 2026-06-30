//
//  MaxspeedParser.swift
//  TripperDashPP
//
//  Single source of truth for turning an OSM `maxspeed` tag value into an
//  integer km/h. Previously the limit service and the camera service each
//  had their OWN parser, and they disagreed: SpeedLimitService converted
//  "mph" correctly while SpeedCameraService just took the leading digits,
//  so a US/UK camera tagged `maxspeed=55 mph` rendered "55" on the dash
//  instead of 88 km/h (bug #3). Both now call this one type.
//
//  OSM `maxspeed` conventions this handles (see the OSM wiki "Key:maxspeed"):
//    "50"            → 50      (bare number = km/h, the global default unit)
//    "50 km/h"       → 50      (explicit metric)
//    "30 mph"        → 48      (imperial → km/h, ×1.609344, rounded)
//    "30mph"         → 48      (no space)
//    "80;100"        → 80      (multi-value: take the leading/lower value)
//    "none"          → nil     (derestricted; not a numeric posting)
//    "walk"          → nil     (walking pace; not a fixed number)
//    "signals"       → nil     (variable speed; no fixed number)
//    "CZ:urban"      → nil     (implied/zone limit — resolved elsewhere, #5)
//    nil / ""        → nil
//
//  Deliberately geography-agnostic: it does NOT try to guess that a bare
//  `maxspeed=55` in Texas "really means" 55 mph. Per OSM convention an
//  imperial limit MUST carry the `mph` suffix; a missing suffix is a data
//  defect we can't safely second-guess from the tag alone. (Display-side
//  unit choice — showing km/h vs mph to the rider — is a separate concern
//  handled by the renderer from the user's `units` setting, not here.)
//
//  `knots` (waterways) and `mph`-with-decimals are not represented in road
//  `maxspeed` data and are intentionally out of scope.
//

import Foundation

enum MaxspeedParser {

    private static let mphToKmh = 1.609344

    /// Parse an OSM `maxspeed` value to integer km/h, or `nil` when the
    /// value carries no explicit numeric limit. Pure + side-effect free so
    /// both services and the unit tests share identical behaviour.
    static func kmh(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        let lower = raw.lowercased()

        // Leading integer covers "50", "50 km/h", "80;100", "30 mph",
        // "30mph". A value that doesn't START with a digit ("none",
        // "walk", "signals", "CZ:urban") yields no digits → nil.
        let digits = lower.prefix { $0.isNumber }
        guard let value = Int(digits), value > 0 else { return nil }

        if lower.contains("mph") {
            return Int((Double(value) * mphToKmh).rounded())
        }
        return value   // km/h — the OSM default unit
    }
}
