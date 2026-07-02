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
