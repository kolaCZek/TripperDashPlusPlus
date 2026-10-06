//
//  ManeuverDistanceTextTests.swift
//  TripperDashPPTests
//
//  The phone (HUD, Live Activity, demo preview) shows the distance to the
//  next turn rounded exactly like the dash's turn card: the bucketed value
//  the active-nav loop puts on the wire, in the unit the unit byte picks.
//

import Testing
@testable import TripperDashPP

struct ManeuverDistanceTextTests {

    @Test(arguments: [
        (24.0, "24 m"),     // < 50 m: nearest 1 m
        (73.0, "75 m"),     // 50…200 m: nearest 25 m
        (188.0, "200 m"),
        (437.0, "400 m"),   // ≥ 200 m: nearest 100 m
        (985.0, "1.0 km"),  // buckets to 1000 m → km, like the unit byte
        (1449.0, "1.4 km"),
    ])
    func metric(meters: Double, text: String) {
        #expect(DashNavSettings.maneuverDistanceText(meters: meters, imperial: false) == text)
    }

    @Test(arguments: [
        (30.0, "100 ft"),   // 98.4 ft → nearest 10 ft
        (100.0, "350 ft"),  // 328 ft → nearest 50 ft
        (500.0, "0.3 mi"),  // ≥ 160 m: nearest 0.1 mi
    ])
    func imperial(meters: Double, text: String) {
        #expect(DashNavSettings.maneuverDistanceText(meters: meters, imperial: true) == text)
    }

    @Test func commaDecimal() {
        #expect(DashNavSettings.maneuverDistanceText(meters: 1449, imperial: false,
                                                     useCommaDecimal: true) == "1,4 km")
    }

    /// The Live Activity (and the demo preview, which uses it) shows the
    /// same text as the HUD.
    @Test(arguments: [24.0, 73.0, 437.0, 985.0, 12_345.0])
    func liveActivityMatches(meters: Double) {
        for imperial in [false, true] {
            #expect(LiveActivityController.distanceText(meters: meters, imperial: imperial)
                    == DashNavSettings.maneuverDistanceText(meters: meters, imperial: imperial))
        }
    }
}
