//
//  SunsetPillTests.swift
//  TripperDashPPTests
//
//  `ActiveNavLoop.sunsetPillText`: the dash's sunset pill shows the
//  sunset time where the rider will be along the route, only when civil
//  dusk (−6°) comes before the ETA. Expected times match the Python
//  mirror (tools/fake_dash/tests/test_solar_clock.py, TestSunsetPill).
//

import Testing
import Foundation
import CoreLocation
@testable import TripperDashPP

struct SunsetPillTests {

    private let prague = CLLocationCoordinate2D(latitude: 50.08, longitude: 14.43)
    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ h: Int, _ m: Int = 0, _ s: Int = 0,
                    day: Int = 15, month: Int = 9) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: DateComponents(year: 2026, month: month, day: day,
                                             hour: h, minute: m, second: s))!
    }

    private func text(_ route: [CLLocationCoordinate2D], now: Date, eta: Date?,
                      shown: Bool = false, is24Hour: Bool = true) -> String? {
        ActiveNavLoop.sunsetPillText(route: route, now: now, eta: eta, shown: shown,
                                     is24Hour: is24Hour, timeZone: utc)
    }

    // Prague 2026-09-15: sunset 17:16 UTC, civil dusk 17:48:40 UTC.
    @Test func etaAfterDuskShowsSunsetTime() {
        #expect(text([prague], now: at(15), eta: at(18, 30)) == "17:16")
        #expect(text([prague], now: at(15), eta: at(18, 30), is24Hour: false) == "5:16 PM")
    }

    @Test func etaAfterSunsetButBeforeDuskHides() {
        #expect(text([prague], now: at(15), eta: at(17, 40)) == nil)
    }

    @Test func duskNearEtaHasHysteresis() {
        // ETA 30 s after dusk: inside the ±60 s band, so it keeps its state.
        #expect(text([prague], now: at(15), eta: at(17, 49, 10)) == nil)
        #expect(text([prague], now: at(15), eta: at(17, 49, 10), shown: true) == "17:16")
    }

    @Test func sunAlreadySetHides() {
        #expect(text([prague], now: at(18, 30), eta: at(19, 30)) == nil)
        let tromso = CLLocationCoordinate2D(latitude: 69.65, longitude: 18.96)
        #expect(text([tromso], now: at(12, day: 21, month: 12), eta: at(22, day: 21, month: 12)) == nil) // polar night
    }

    @Test func noEtaHides() {
        #expect(text([prague], now: at(15), eta: nil) == nil)
    }

    @Test func whiteNightHides() {
        // Trondheim, solstice: sunset 23:38 CEST, but the sun bottoms out
        // near −3°. 22:00 → 01:00 CEST ride.
        let trondheim = CLLocationCoordinate2D(latitude: 63.43, longitude: 10.39)
        #expect(text([trondheim], now: at(20, day: 21, month: 6), eta: at(23, day: 21, month: 6)) == nil)
    }

    @Test func polarDayHides() {
        let tromso = CLLocationCoordinate2D(latitude: 69.65, longitude: 18.96)
        #expect(text([tromso], now: at(12, day: 21, month: 6), eta: at(22, day: 21, month: 6)) == nil)
    }

    @Test func longRouteUsesPredictedPosition() {
        // Chicago → Denver, 15 h from 17:00 UTC. Sunset at Chicago is
        // 23:59 UTC, at Denver 01:08; on the predicted track 00:34.
        let chicago = CLLocationCoordinate2D(latitude: 41.88, longitude: -87.63)
        let denver = CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99)
        let now = at(17)
        let eta = now.addingTimeInterval(15 * 3600)
        #expect(text([chicago, denver], now: now, eta: eta) == "00:34")
        #expect(text([chicago], now: now, eta: eta) == "23:59")
    }

    @Test func firstCrossingMatchesPublishedSunset() {
        // Prague summer solstice: 21:15 CEST (timeanddate.com).
        let s = SolarClock.firstCrossing(along: [(coord: prague, date: at(8, day: 21, month: 6)),
                                                 (coord: prague, date: at(23, day: 21, month: 6))],
                                         below: SolarClock.sunsetElevation)
        #expect(s.map { abs($0.timeIntervalSince(at(19, 15, day: 21, month: 6))) < 4 * 60 } == true)
    }
}
