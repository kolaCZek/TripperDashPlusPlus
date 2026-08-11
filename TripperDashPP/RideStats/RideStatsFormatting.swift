//
//  RideStatsFormatting.swift
//  TripperDashPP
//
//  Pure metric/imperial readout strings for the GPS trip computer. All
//  `nonisolated static` so the unit tests can pin them synchronously
//  without hopping onto the main actor (the app defaults types to
//  `@MainActor`; these are pure math + string formatting). Honour the
//  rider's `DashNavSettings.units` via the `imperial:` flag.
//
//  Rounding note: every numeric string goes through `String(format:)`
//  (C printf). Test expectations are computed the way printf rounds, not
//  by eye — a sub-km `(950/100).rounded()` case rounds to 1000, not 900.
//

import Foundation

nonisolated enum RideStatsFormatting {

    private static let metersPerMile = 1609.344
    private static let feetPerMeter = 3.280839895013123
    private static let mphPerMps = 2.2369362920544
    private static let kmhPerMps = 3.6

    /// Swap the printf period for a comma when the rider prefers it. Only
    /// touches the decimal point (there are no thousands separators in these
    /// short readouts), so it's a safe single-character replace.
    private static func sep(_ s: String, useCommaDecimal: Bool) -> String {
        useCommaDecimal ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    /// Distance: one decimal under 100 units, whole at/above 100.
    /// e.g. "12.4 km" / "7.5 mi" / "142 km" / "124 mi".
    nonisolated static func distance(_ meters: Double, imperial: Bool,
                                     useCommaDecimal: Bool = false) -> String {
        let m = max(0, meters)
        let raw: String
        if imperial {
            let mi = m / metersPerMile
            raw = mi < 100 ? String(format: "%.1f mi", mi)
                           : String(format: "%.0f mi", mi)
        } else {
            let km = m / 1000
            raw = km < 100 ? String(format: "%.1f km", km)
                           : String(format: "%.0f km", km)
        }
        return sep(raw, useCommaDecimal: useCommaDecimal)
    }

    /// Speed, whole number: "90 km/h" / "60 mph". No decimal, so the
    /// separator preference is irrelevant — kept parameterless.
    nonisolated static func speed(_ mps: Double, imperial: Bool) -> String {
        let v = max(0, mps)
        return imperial ? String(format: "%.0f mph", v * mphPerMps)
                        : String(format: "%.0f km/h", v * kmhPerMps)
    }

    /// Duration H:MM:SS, dropping the hours field when zero: "1:23:45" /
    /// "12:04" / "0:45". Units-independent.
    nonisolated static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// Clock time HH:MM for the app UI, honouring the rider's 24/12h
    /// preference. 24-hour → "14:33"; 12-hour → "2:33 PM" (the app HUD has
    /// room for the meridiem, unlike the ASCII-only dash). Uses the phone's
    /// current calendar/timezone.
    nonisolated static func clock(_ date: Date, is24Hour: Bool,
                                  calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let h24 = comps.hour ?? 0
        let m = comps.minute ?? 0
        if is24Hour {
            return String(format: "%d:%02d", h24, m)
        }
        let mod = h24 % 12
        let h = mod == 0 ? 12 : mod
        let suffix = h24 < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h, m, suffix)
    }

    /// Elevation, whole units: "340 m" / "1115 ft".
    nonisolated static func elevation(_ meters: Double, imperial: Bool) -> String {
        let m = max(0, meters)
        return imperial ? String(format: "%.0f ft", m * feetPerMeter)
                        : String(format: "%.0f m", m)
    }
}
