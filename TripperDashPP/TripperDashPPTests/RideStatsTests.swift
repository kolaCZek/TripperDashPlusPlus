//
//  RideStatsTests.swift
//  TripperDashPPTests
//
//  Unit tests for the pure GPS ride accumulator (`RideStats`). Every
//  accumulation rule + the tunable drift guard. No actor, no network —
//  pure folding of scripted fixes.
//

import Testing
import CoreLocation
@testable import TripperDashPP

struct RideStatsTests {

    /// Build a fix with only the fields the accumulator reads.
    private func fix(_ lat: Double, _ lon: Double, alt: Double = 0,
                     speed: Double = 10, acc: Double = 5,
                     t: TimeInterval) -> Fix {
        Fix(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: alt, horizontalAccuracy: acc, verticalAccuracy: 5,
            course: 0, speed: speed,
            timestamp: Date(timeIntervalSince1970: t)))
    }

    @Test func accumulatesDistanceAcrossTwoFixes() {
        var s = RideStats()
        // ~111 m apart at the equator (0.001° lon ≈ 111.32 m).
        s = s.folding(fix(0, 0.000, t: 0))
        s = s.folding(fix(0, 0.001, t: 5))
        #expect(abs(s.distanceMeters - 111.32) < 1.5)
    }

    @Test func jitterBelowFloorAddsNoDistance() {
        var s = RideStats()
        s = s.folding(fix(0, 0, acc: 5, t: 0))
        s = s.folding(fix(0, 0.00001, acc: 5, t: 2)) // ~1.1 m < 3 m floor
        #expect(s.distanceMeters == 0)
    }

    @Test func rejectsInaccurateFix() {
        var s = RideStats()
        s = s.folding(fix(0, 0, acc: 5, t: 0))
        s = s.folding(fix(0, 0.001, acc: 80, t: 5)) // 80 m > 50 m gate
        #expect(s.distanceMeters == 0)
        #expect(s.acceptedFixCount == 1)
    }

    @Test func teleportGlitchSkippedForDistanceButClockAdvances() {
        var s = RideStats()
        s = s.folding(fix(0, 0, speed: 10, t: 0))
        // 0.01° lon ≈ 1113 m in 1 s → 1113 m/s ≫ 90 m/s cap → glitch.
        s = s.folding(fix(0, 0.01, speed: 10, acc: 5, t: 1))
        #expect(s.distanceMeters == 0)
        #expect(s.acceptedFixCount == 2) // still accepted, clock advanced
    }

    @Test func maxSpeedTracksGpsSpeed() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, speed: 12, t: 0))
        s = s.folding(fix(0, 0.001, speed: 25, t: 5))
        s = s.folding(fix(0, 0.002, speed: 8,  t: 10))
        #expect(s.maxSpeedMps == 25)
    }

    @Test func maxSpeedIgnoresUnknownSpeed() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, speed: -1, t: 0))
        s = s.folding(fix(0, 0.001, speed: -1, t: 5))
        #expect(s.maxSpeedMps == 0)
    }

    @Test func movingTimeCountsOnlyWhileMoving() {
        var s = RideStats()
        // Moving 0→5 s (speed 10), stopped 5→30 s (speed 0.1).
        s = s.folding(fix(0, 0.000, speed: 10,  t: 0))
        s = s.folding(fix(0, 0.001, speed: 10,  t: 5))
        s = s.folding(fix(0, 0.001, speed: 0.1, acc: 5, t: 30)) // no move
        #expect(abs(s.movingSeconds - 5) < 0.01)
    }

    @Test func movingTimeCapsHugeGap() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, speed: 10, t: 0))
        // 300 s gap while "moving" → capped at 10 s.
        s = s.folding(fix(0, 0.050, speed: 10, acc: 5, t: 300))
        #expect(s.movingSeconds <= 10.0001)
    }

    @Test func averageSpeedIsMovingAverage() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, speed: 10, t: 0))
        s = s.folding(fix(0, 0.001, speed: 10, t: 5)) // ~111 m in 5 moving s
        #expect(abs(s.averageSpeedMps - 111.32 / 5) < 0.5)
    }

    @Test func averageSpeedZeroWhenNoMovingTime() {
        #expect(RideStats().averageSpeedMps == 0)
    }

    @Test func elevationGainCountsAscentAboveHysteresis() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, alt: 100, t: 0))
        s = s.folding(fix(0, 0.001, alt: 101, t: 5)) // +1 m < 2 m → not yet
        s = s.folding(fix(0, 0.002, alt: 103, t: 10)) // cumulative +3 m ≥ 2 → count
        #expect(abs(s.elevationGainMeters - 3) < 0.01)
    }

    @Test func elevationGainIgnoresDescent() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, alt: 100, t: 0))
        s = s.folding(fix(0, 0.001, alt: 90,  t: 5))
        #expect(s.elevationGainMeters == 0)
    }

    @Test func elapsedIsWallClockSpan() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, speed: 10, t: 100))
        s = s.folding(fix(0, 0.001, speed: 0.1, t: 160)) // 60 s later, barely moving
        // Wall clock counts all 60 s even though moving time doesn't.
        #expect(abs(s.elapsedSeconds - 60) < 0.01)
    }

    // MARK: - Drift guard (Task 2)

    @Test func tunablesAreTheReviewedValues() {
        #expect(RideStats.accuracyGateMeters == 50)
        #expect(RideStats.jitterFloorMeters == 3)
        #expect(RideStats.teleportSpeedMps == 90)
        #expect(RideStats.movingThresholdMps == 0.7)
        #expect(RideStats.maxStepSeconds == 10)
        #expect(RideStats.ascentHysteresisMeters == 2)
    }

    // MARK: - Gating coverage (review hardening)

    @Test func rejectsNonMonotonicTimestamp() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, t: 10))
        s = s.folding(fix(0, 0.001, t: 5)) // earlier than last → rejected
        #expect(s.acceptedFixCount == 1)
        #expect(s.distanceMeters == 0)
    }

    @Test func rejectsDuplicateTimestamp() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, t: 10))
        s = s.folding(fix(0, 0.001, t: 10)) // equal timestamp → rejected
        #expect(s.acceptedFixCount == 1)
    }

    @Test func rejectsNegativeAccuracy() {
        var s = RideStats()
        s = s.folding(fix(0, 0.000, acc: 5, t: 0))
        s = s.folding(fix(0, 0.001, acc: -1, t: 5)) // invalid accuracy → rejected
        #expect(s.acceptedFixCount == 1)
        #expect(s.distanceMeters == 0)
    }

    @Test func teleportWithUnknownSpeedAddsNoMovingTime() {
        // A GPS position jump (glitch) with unknown Doppler speed must not
        // accrue moving time off the bogus implied speed — the blessed
        // refinement of rule 3 (zero the implied term on a glitch).
        var s = RideStats()
        s = s.folding(fix(0, 0, speed: 10, t: 0))
        s = s.folding(fix(0, 0.01, speed: -1, acc: 5, t: 1)) // ~1113 m/s implied → glitch, speed unknown
        #expect(s.distanceMeters == 0)
        #expect(s.movingSeconds == 0)
        #expect(s.acceptedFixCount == 2)
    }

    @Test func flatSegmentHoldsAscentBuffer() {
        // Sub-hysteresis rise, then a FLAT fix, then more rise: the flat
        // fix must NOT wipe the accumulated buffer (reset is strict-descent
        // -only), so +1 (flat) +1 crosses the 2 m hysteresis and counts.
        var s = RideStats()
        s = s.folding(fix(0, 0.000, alt: 100, t: 0))
        s = s.folding(fix(0, 0.001, alt: 101, t: 5))  // +1 m, buffer=1 (<2)
        s = s.folding(fix(0, 0.002, alt: 101, t: 10)) // flat, buffer stays 1
        s = s.folding(fix(0, 0.003, alt: 102, t: 15)) // +1 m, buffer=2 → counts
        #expect(abs(s.elevationGainMeters - 2) < 0.01)
    }
}
