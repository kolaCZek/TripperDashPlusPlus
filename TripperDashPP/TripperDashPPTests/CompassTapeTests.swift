//
//  CompassTapeTests.swift
//  TripperDashPPTests
//
//  Bottom-row compass tape (`MapViewSource.compassTapeMarks`) and the
//  Settings → Map → Bottom row migration from the old progress-bar toggle.
//

import Testing
import CoreGraphics
@testable import TripperDashPP

struct CompassTapeTests {

    private func label(at dx: CGFloat, heading: Double) -> String? {
        MapViewSource.compassTapeMarks(heading: heading, halfWidth: 140)
            .first { abs($0.dx - dx) < 0.001 }?.label
    }

    @Test func labelUnderTheCentreFollowsTheHeading() {
        #expect(label(at: 0, heading: 0) == "N")
        #expect(label(at: 0, heading: 45) == "NE")
        #expect(label(at: 0, heading: 270) == "W")
    }

    @Test func eastIsRightOfNorthAndTheTapeWrapsThroughNorth() {
        // Heading 359°: N sits 1° right of the centre, NW 44° left.
        #expect(label(at: 1.25, heading: 359) == "N")
        #expect(label(at: -44 * 1.25, heading: 359) == "NW")
        // Heading 10°: E is 80° to the right.
        #expect(label(at: 80 * 1.25, heading: 10) == "E")
    }

    @Test func marksAreEvery15DegreesInsideTheHalfWidth() {
        let marks = MapViewSource.compassTapeMarks(heading: 47, halfWidth: 100)
        #expect(marks.allSatisfy { abs($0.dx) <= 100 })
        #expect(marks.count == 11)   // ±80° around 47°: -30° ... 120°
        #expect(marks.filter { $0.label != nil }.map(\.label) == ["N", "NE", "E"])
    }

    @Test func oldProgressToggleMapsToTheBottomRow() {
        typealias Row = DashNavSettings.BottomRow
        #expect(Row.resolve(nil, legacyProgressBar: nil) == .progress)   // fresh install
        #expect(Row.resolve(nil, legacyProgressBar: true) == .progress)
        #expect(Row.resolve(nil, legacyProgressBar: false) == .off)
        #expect(Row.resolve(.compass, legacyProgressBar: true) == .compass)
    }
}
