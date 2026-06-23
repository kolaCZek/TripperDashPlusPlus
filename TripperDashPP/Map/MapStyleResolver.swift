//
//  MapStyleResolver.swift
//  TripperDashPP
//
//  Turns the user's MapStyleSettings.Mode + the live GPS fix + the clock
//  into a concrete MapStyle for the renderer. For manual Light/Dark it's
//  a trivial pass-through; for Auto it thresholds the sun's elevation
//  (from SolarClock) with hysteresis + a minimum dwell so the palette
//  can't strobe at dusk/dawn.
//
//  Why a dead-band, not a single threshold: a rider parked right at the
//  switch-over angle would otherwise flip Light↔Dark every time the sun
//  wobbled across it. We switch to Dark only once the sun drops below
//  civil twilight (−6°) and back to Light only once it climbs back above
//  the horizon (0°). Between −6° and 0° we HOLD whatever we last showed.
//  A minimum dwell (10 min) on top guarantees at most one flip per dwell
//  window even in pathological terrain/elevation cases.
//

import CoreLocation
import Foundation

struct MapStyleResolver {

    /// Switch to Dark once the sun is below this elevation (civil
    /// twilight — roughly when street lighting comes on).
    static let darkBelowDeg: Double = -6.0

    /// Switch back to Light once the sun climbs above this elevation
    /// (geometric horizon). The −6°…0° gap is the hysteresis dead-band.
    static let lightAboveDeg: Double = 0.0

    /// Minimum time between two Auto switches. Belt-and-braces on top of
    /// the dead-band: even if elevation somehow oscillates across a
    /// threshold, we change palette at most once per this window.
    static let minDwell: TimeInterval = 600  // 10 minutes

    /// Resolve the effective palette.
    ///
    /// - Parameters:
    ///   - mode: the user's preference (`.light` / `.dark` / `.auto`).
    ///   - coord: latest GPS coordinate (nil → no fix yet; Auto holds).
    ///   - date: the instant to evaluate the sun for (use the fix's
    ///     timestamp so replay / testing is deterministic).
    ///   - current: the palette currently shown — carries the hysteresis
    ///     state across calls.
    ///   - lastSwitch: when the palette last changed (nil → never), for
    ///     the dwell lock.
    /// - Returns: the palette to show now. Equal to `current` whenever
    ///   the resolver decides to hold.
    static func resolve(
        mode: MapStyleSettings.Mode,
        coord: CLLocationCoordinate2D?,
        date: Date,
        current: MapStyle,
        lastSwitch: Date?
    ) -> MapStyle {
        switch mode {
        case .light:
            return .light
        case .dark:
            return .dark
        case .auto:
            guard let coord else { return current }   // no GPS yet → hold
            // Dwell lock: too soon since the last switch → hold.
            if let last = lastSwitch, date.timeIntervalSince(last) < minDwell {
                return current
            }
            let elev = SolarClock.elevation(coord: coord, date: date)
            if current == .light && elev < darkBelowDeg { return .dark }
            if current == .dark && elev > lightAboveDeg { return .light }
            return current                            // inside dead-band → hold
        }
    }
}
