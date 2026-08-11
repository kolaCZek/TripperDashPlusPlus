//
//  RideStatsFormattingTests.swift
//  TripperDashPPTests
//
//  Truth-table tests for the metric/imperial ride-stats formatters.
//  Expected values computed the way `String(format:)` (C printf) rounds,
//  not by eye — including the unit-conversion boundaries and the
//  whole-vs-decimal switch at 100 units.
//

import Testing
import Foundation
@testable import TripperDashPP

struct RideStatsFormattingTests {

    typealias F = RideStatsFormatting

    // MARK: Distance

    @Test func distanceMetricOneDecimalUnder100() {
        #expect(F.distance(12_400, imperial: false) == "12.4 km")
        #expect(F.distance(99_000, imperial: false) == "99.0 km")
    }

    @Test func distanceMetricWholeAt100AndAbove() {
        #expect(F.distance(100_400, imperial: false) == "100 km")
        #expect(F.distance(142_300, imperial: false) == "142 km")
    }

    @Test func distanceImperialConversion() {
        // 12070.08 m / 1609.344 = 7.5 mi exactly.
        #expect(F.distance(12_070.08, imperial: true) == "7.5 mi")
        // 200 km = 124.27 mi → whole above 100.
        #expect(F.distance(200_000, imperial: true) == "124 mi")
    }

    @Test func distanceClampsNegative() {
        #expect(F.distance(-5, imperial: false) == "0.0 km")
    }

    // MARK: Decimal separator

    @Test func distanceCommaDecimalSeparator() {
        #expect(F.distance(12_400, imperial: false, useCommaDecimal: true) == "12,4 km")
        #expect(F.distance(12_070.08, imperial: true, useCommaDecimal: true) == "7,5 mi")
    }

    @Test func distanceCommaSeparatorNoOpAboveHundred() {
        // No decimal point in the whole-number regime → comma flag is inert.
        #expect(F.distance(142_300, imperial: false, useCommaDecimal: true) == "142 km")
    }

    @Test func distancePeriodIsDefault() {
        #expect(F.distance(12_400, imperial: false) == "12.4 km")
    }

    // MARK: Clock (app-side 24/12h)

    @Test func clock24Hour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 2000-01-01 14:33 UTC
        let d = cal.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 14, minute: 33))!
        #expect(F.clock(d, is24Hour: true, calendar: cal) == "14:33")
    }

    @Test func clock12HourAfternoon() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 14, minute: 33))!
        #expect(F.clock(d, is24Hour: false, calendar: cal) == "2:33 PM")
    }

    @Test func clock12HourNoonAndMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = cal.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 12, minute: 0))!
        let midnight = cal.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 0, minute: 5))!
        #expect(F.clock(noon, is24Hour: false, calendar: cal) == "12:00 PM")
        #expect(F.clock(midnight, is24Hour: false, calendar: cal) == "12:05 AM")
    }

    // MARK: Speed

    @Test func speedMetric() {
        #expect(F.speed(25, imperial: false) == "90 km/h")   // 25 * 3.6
        #expect(F.speed(0, imperial: false) == "0 km/h")
    }

    @Test func speedImperial() {
        // 26.8224 m/s = 60.0 mph exactly (26.8224 * 2.23693629…).
        #expect(F.speed(26.8224, imperial: true) == "60 mph")
        #expect(F.speed(20, imperial: true) == "45 mph")     // 20 * 2.23693 = 44.7 → 45
    }

    // MARK: Duration

    @Test func durationDropsHoursWhenZero() {
        #expect(F.duration(45) == "0:45")
        #expect(F.duration(724) == "12:04")
        #expect(F.duration(3599) == "59:59")
    }

    @Test func durationShowsHours() {
        #expect(F.duration(3600) == "1:00:00")
        #expect(F.duration(5025) == "1:23:45")
    }

    @Test func durationClampsNegative() {
        #expect(F.duration(-10) == "0:00")
    }

    // MARK: Elevation

    @Test func elevationMetric() {
        #expect(F.elevation(340, imperial: false) == "340 m")
    }

    @Test func elevationImperial() {
        #expect(F.elevation(100, imperial: true) == "328 ft")   // 100 * 3.28084
        #expect(F.elevation(340, imperial: true) == "1115 ft")  // 340 * 3.28084 = 1115.5 → 1115 (round-half-even)
    }
}
