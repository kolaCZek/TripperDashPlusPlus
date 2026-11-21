//
//  SunsetPillTests.swift
//  TripperDashPPTests
//
//  `ActiveNavLoop.sunsetPillText`: the dash's sunset pill shows the local
//  sunset time only while the sun is up and the ETA falls after sunset.
//  Prague, 2026-06-21: sunset ≈ 19:15:41 UTC (21:15 CEST, matches the
//  Python mirror in tools/fake_dash/tests/test_solar_clock.py).
//

import Testing
import Foundation
import CoreLocation
@testable import TripperDashPP

struct SunsetPillTests {

    private let prague = CLLocationCoordinate2D(latitude: 50.08, longitude: 14.43)
    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ h: Int, _ m: Int = 0, day: Int = 21, month: Int = 6) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m))!
    }

    private func text(_ coord: CLLocationCoordinate2D, now: Date, eta: Date?,
                      is24Hour: Bool = true) -> String? {
        ActiveNavLoop.sunsetPillText(coord: coord, now: now, eta: eta,
                                     is24Hour: is24Hour, timeZone: utc)
    }

    @Test func sunsetAheadAndLateEtaShowsSunsetTime() {
        #expect(text(prague, now: at(15), eta: at(20)) == "19:15")
        #expect(text(prague, now: at(15), eta: at(20), is24Hour: false) == "7:15 PM")
    }

    @Test func etaBeforeSunsetHides() {
        #expect(text(prague, now: at(15), eta: at(18)) == nil)
    }

    @Test func afterSunsetHides() {
        #expect(text(prague, now: at(20), eta: at(21)) == nil)
    }

    @Test func noSunsetDayHides() {
        let tromso = CLLocationCoordinate2D(latitude: 69.65, longitude: 18.96)
        #expect(text(tromso, now: at(12), eta: at(22)) == nil)                       // polar day
        #expect(text(tromso, now: at(12, day: 21, month: 12), eta: at(22, day: 21, month: 12)) == nil) // polar night
    }

    @Test func noEtaHides() {
        #expect(text(prague, now: at(15), eta: nil) == nil)
    }

    @Test func nextSunsetMatchesPublishedTime() {
        let s = SolarClock.nextSunset(coord: prague, after: at(8))
        #expect(s.map { abs($0.timeIntervalSince(at(19, 15))) < 4 * 60 } == true)
    }
}
