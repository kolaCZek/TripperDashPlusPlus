//
//  MotionInterpolatorTests.swift
//  TripperDashPPTests
//
//  Deterministic tests for the GPS→render motion smoother. All pure geometry:
//  feed fixes + tick timestamps, assert the emitted display coordinate.
//

import CoreLocation
import XCTest
@testable import TripperDashPP

final class MotionInterpolatorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func fix(_ lat: Double, _ lon: Double,
                     speed: Double, course: Double, at: Date) -> Fix {
        Fix(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0, horizontalAccuracy: 5,
            speed: speed, course: course, timestamp: at)
    }

    // MARK: helpers

    func testFirstFixSeedsDisplayAtFix() {
        var m = MotionInterpolator()
        m.ingest(fix: fix(50, 14, speed: 10, course: 90, at: t0))
        let c = m.tick(now: t0)
        XCTAssertEqual(c?.latitude ?? .nan, 50, accuracy: 1e-6)
        XCTAssertEqual(c?.longitude ?? .nan, 14, accuracy: 1e-6)
    }

    func testNilBeforeAnyFix() {
        var m = MotionInterpolator()
        XCTAssertNil(m.tick(now: t0))
    }

    // MARK: extrapolation

    func testExtrapolatesForwardBetweenFixes() {
        var m = MotionInterpolator()
        // Heading due east at 20 m/s.
        m.ingest(fix: fix(50, 14, speed: 20, course: 90, at: t0))
        _ = m.tick(now: t0)
        // 0.5s later, no new fix: should have advanced roughly east.
        let c = m.tick(now: t0.addingTimeInterval(0.5))!
        XCTAssertGreaterThan(c.longitude, 14, "should move east")
        XCTAssertEqual(c.latitude, 50, accuracy: 1e-4, "east-only, lat ~constant")
    }

    func testStationaryDoesNotDrift() {
        var m = MotionInterpolator()
        m.ingest(fix: fix(50, 14, speed: 0.1, course: -1, at: t0))  // below threshold
        _ = m.tick(now: t0)
        let c = m.tick(now: t0.addingTimeInterval(2.0))!
        XCTAssertEqual(c.latitude, 50, accuracy: 1e-6)
        XCTAssertEqual(c.longitude, 14, accuracy: 1e-6)
    }

    func testStopsExtrapolatingAfterMaxWindow() {
        var m = MotionInterpolator()
        m.maxExtrapolationS = 3
        m.ingest(fix: fix(50, 14, speed: 20, course: 90, at: t0))
        _ = m.tick(now: t0)
        let near = m.tick(now: t0.addingTimeInterval(3.0))!
        // Far past the window: position must not keep sailing off.
        let far = m.tick(now: t0.addingTimeInterval(10.0))!
        XCTAssertEqual(near.longitude, far.longitude, accuracy: 1e-4,
                       "should hold once past maxExtrapolationS")
    }

    // MARK: acceleration

    func testBrakingDoesNotOvershoot() {
        // Two fixes showing deceleration 20 -> 4 m/s over 1s (a = -16, clamped
        // to -maxAccel). The extrapolated marker must travel LESS than a naive
        // constant-20-m/s dead reckoning would.
        var m = MotionInterpolator()
        m.maxAccelMPS2 = 20
        m.ingest(fix: fix(50, 14, speed: 20, course: 90, at: t0))
        m.ingest(fix: fix(50, 14.0002, speed: 4, course: 90, at: t0.addingTimeInterval(1)))
        _ = m.tick(now: t0.addingTimeInterval(1))
        let c = m.tick(now: t0.addingTimeInterval(1.5))!
        // Constant-20 would add 20*0.5=10 m east (~0.00014°). With braking the
        // step must be smaller.
        let deltaLon = c.longitude - 14.0002
        XCTAssertLessThan(deltaLon, 0.00014, "braking must undershoot constant-speed")
        XCTAssertGreaterThanOrEqual(deltaLon, 0, "still moving forward")
    }

    // MARK: route following

    /// A right-angle route: east then north. Rider drives east; the marker must
    /// stay ON the polyline (lat ~ constant) rather than cutting toward the
    /// corner.
    func testFollowsRouteThroughCorner() {
        var m = MotionInterpolator()
        let corner = CLLocationCoordinate2D(latitude: 50, longitude: 14.001)
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 14.000),
            corner,
            CLLocationCoordinate2D(latitude: 50.001, longitude: 14.001),
        ]
        m.setRoute(route)
        m.ingest(fix: fix(50, 14.0002, speed: 15, course: 90, at: t0))
        XCTAssertTrue(m.isFollowingRoute, "close fix should latch route-follow")
        _ = m.tick(now: t0)
        let c = m.tick(now: t0.addingTimeInterval(0.4))!
        // Still on the east leg: latitude pinned to the route line.
        XCTAssertEqual(c.latitude, 50, accuracy: 1e-4)
    }

    /// A fix far off the route must NOT latch route-follow (rider took a detour).
    func testOffRouteDoesNotLatch() {
        var m = MotionInterpolator()
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 14.000),
            CLLocationCoordinate2D(latitude: 50, longitude: 14.010),
        ]
        m.setRoute(route)
        // ~300 m north of the route line.
        m.ingest(fix: fix(50.0027, 14.005, speed: 15, course: 0, at: t0))
        XCTAssertFalse(m.isFollowingRoute)
    }

    /// Latched on-route, then the rider genuinely leaves: after enough confirmed
    /// off-route fixes the latch must release so the marker follows the rider,
    /// not the old line.
    func testReleasesRouteWhenRiderLeaves() {
        var m = MotionInterpolator()
        m.offRouteConfirmFixes = 3
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 14.000),
            CLLocationCoordinate2D(latitude: 50, longitude: 14.010),
        ]
        m.setRoute(route)
        m.ingest(fix: fix(50, 14.001, speed: 15, course: 90, at: t0))
        XCTAssertTrue(m.isFollowingRoute)
        // Three fixes ~300 m off the line.
        for i in 1...3 {
            m.ingest(fix: fix(50.0027, 14.002 + Double(i) * 0.0005,
                     speed: 15, course: 45, at: t0.addingTimeInterval(Double(i))))
        }
        XCTAssertFalse(m.isFollowingRoute, "sustained off-route must release the latch")
    }

    // MARK: static geometry

    func testOffsetEastMovesLongitude() {
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = MotionInterpolator.offset(a, distanceMeters: 111_111, courseDeg: 90)
        XCTAssertEqual(b.longitude, 1.0, accuracy: 0.01)
        XCTAssertEqual(b.latitude, 0.0, accuracy: 1e-6)
    }

    func testBearingDueNorthIsZero() {
        let a = CLLocationCoordinate2D(latitude: 50, longitude: 14)
        let b = CLLocationCoordinate2D(latitude: 50.01, longitude: 14)
        XCTAssertEqual(MotionInterpolator.bearing(from: a, to: b), 0, accuracy: 0.5)
    }

    func testDistanceUnderBrakingCoastsToStop() {
        // v0=10, a=-5: stops at t=2s having covered 10 m. Asking for 5s must
        // still return the 10 m stop distance, not a negative-speed overshoot.
        let d = MotionInterpolator.distance(overSeconds: 5, v0: 10, accel: -5)
        XCTAssertEqual(d, 10, accuracy: 0.01)
    }
}
