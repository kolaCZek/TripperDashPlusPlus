//
//  SolarClock.swift
//  TripperDashPP
//
//  Sun elevation angle for a coordinate + instant. Pure math, no
//  dependencies — the input for the Auto map style (Light by day, Dark
//  after dusk). We threshold elevation rather than building a
//  sunrise/sunset *table* on purpose:
//
//    * no timezone database needed — we work in elevation, not local
//      clock time, so a GPS fix anywhere on Earth just works;
//    * polar edge cases fall out for free — above the Arctic Circle in
//      winter the sun simply never crosses the threshold, so Auto holds
//      Dark all "day" with no special-casing;
//    * the light/dark hysteresis dead-band (−6°…0°) is naturally
//      expressed as two elevation thresholds.
//
//  Algorithm: simplified NOAA solar-position
//  (Julian day → mean longitude + anomaly → ecliptic longitude →
//   declination + right ascension → local hour angle via GMST →
//   elevation). Accuracy ≈ ±0.01° vs PyEphem at the test fixtures —
//   far finer than the 6°-wide dead-band needs.
//
//  Mirrored 1:1 in `tools/fake_dash/tests/solar.py`; keep them in sync
//  (see `tools/fake_dash/tests/test_solar_clock.py`).
//

import CoreLocation
import Foundation

/// Stateless solar-position helper. The only value the map-style logic
/// needs is the sun's elevation angle, so that's all we expose.
enum SolarClock {

    /// Sun elevation in degrees above the horizon (negative = below) for
    /// `coord` at `date`.
    static func elevation(coord: CLLocationCoordinate2D, date: Date) -> Double {
        let jd = julianDay(date)
        let n = jd - 2_451_545.0                                  // days since J2000.0
        let L = (280.460 + 0.9856474 * n)
            .truncatingRemainder(dividingBy: 360.0)               // mean longitude (deg)
        let g = (357.528 + 0.9856003 * n)
            .truncatingRemainder(dividingBy: 360.0) * .pi / 180.0 // mean anomaly (rad)
        let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g))
            * .pi / 180.0                                         // ecliptic longitude (rad)
        let epsilon = 23.439 * .pi / 180.0                        // obliquity of ecliptic
        let decl = asin(sin(epsilon) * sin(lambda))               // declination
        let gmst = (18.697374558 + 24.06570982441908 * n)
            .truncatingRemainder(dividingBy: 24.0)                // Greenwich mean sidereal (hours)
        let ra = atan2(cos(epsilon) * sin(lambda), cos(lambda))   // right ascension (rad)
        let lst = gmst * 15.0 * .pi / 180.0
            + coord.longitude * .pi / 180.0                       // local sidereal (rad)
        let ha = lst - ra                                         // hour angle (rad)
        let lat = coord.latitude * .pi / 180.0
        let elev = asin(
            sin(lat) * sin(decl)
            + cos(lat) * cos(decl) * cos(ha)
        )
        return elev * 180.0 / .pi
    }

    /// Convert a `Date` to its Julian Day number. The Unix epoch
    /// (1970-01-01T00:00:00Z) is Julian Day 2440587.5.
    private static func julianDay(_ date: Date) -> Double {
        return date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
    }
}
