//
//  SpeedCameraAnnouncerTests.swift
//  TripperDashPPTests
//
//  Tests the "when to speak a speed-camera warning" decision logic: a
//  camera fires once when the rider enters the warning radius AND it is
//  ahead, never fires for a camera behind the rider, never repeats, and
//  resets cleanly. Pure value type, runs headless (no CoreLocation).
//
//  Geometry note: 0.001° of latitude ≈ 111 m; 0.001° of longitude at
//  ~50°N ≈ 71 m. The fixtures below sit a rider at (50.0, 14.0) and place
//  cameras due north/south at known offsets so distance and bearing are
//  predictable.
//

import Testing
@testable import TripperDashPP

struct SpeedCameraAnnouncerTests {

    private typealias Target = SpeedCameraAnnouncer.Target

    // A camera ~222 m due north of the rider (0.002° lat). Well inside the
    // 400 m radius, bearing 0° (north).
    private let camNorth = Target(id: 1, latitude: 50.002, longitude: 14.0)
    // A camera ~222 m due south of the rider. Bearing 180°.
    private let camSouth = Target(id: 2, latitude: 49.998, longitude: 14.0)
    // A camera ~1.1 km due north — outside the warning radius.
    private let camFarNorth = Target(id: 3, latitude: 50.010, longitude: 14.0)

    private let riderLat = 50.0
    private let riderLon = 14.0

    @Test func firesOnceWhenAheadAndClose() {
        var a = SpeedCameraAnnouncer()
        // Heading north (0°), camera due north and close → fire.
        let hit = a.onTick(riderLat: riderLat, riderLon: riderLon,
                           headingDegrees: 0, cameras: [camNorth])
        #expect(hit?.id == 1)
        // Same tick data again → already fired, silence.
        let again = a.onTick(riderLat: riderLat, riderLon: riderLon,
                            headingDegrees: 0, cameras: [camNorth])
        #expect(again == nil)
    }

    @Test func doesNotFireForCameraBehind() {
        var a = SpeedCameraAnnouncer()
        // Heading north (0°) but the camera is due south (bearing 180°) —
        // behind the rider, already passed → no warning.
        let hit = a.onTick(riderLat: riderLat, riderLon: riderLon,
                          headingDegrees: 0, cameras: [camSouth])
        #expect(hit == nil)
    }

    @Test func doesNotFireBeyondRadius() {
        var a = SpeedCameraAnnouncer()
        // Camera is ahead (north, heading north) but ~1.1 km away → silent.
        let hit = a.onTick(riderLat: riderLat, riderLon: riderLon,
                          headingDegrees: 0, cameras: [camFarNorth])
        #expect(hit == nil)
    }

    @Test func unknownHeadingFallsBackToProximity() {
        var a = SpeedCameraAnnouncer()
        // course = -1 (stationary / unknown). Ahead-check is skipped, so a
        // close camera in ANY direction warns. The south camera is close.
        let hit = a.onTick(riderLat: riderLat, riderLon: riderLon,
                          headingDegrees: -1, cameras: [camSouth])
        #expect(hit?.id == 2)
    }

    @Test func picksNearestWhenSeveralQualify() {
        var a = SpeedCameraAnnouncer()
        // Two cameras ahead (both north, heading north): one at 222 m, one
        // that is nearer. The nearest must be chosen first.
        let nearer = Target(id: 10, latitude: 50.001, longitude: 14.0)  // ~111 m
        let farther = camNorth                                          // ~222 m
        let hit = a.onTick(riderLat: riderLat, riderLon: riderLon,
                          headingDegrees: 0, cameras: [farther, nearer])
        #expect(hit?.id == 10)
        // Next tick the nearer one is fired; the farther one is still ahead
        // and close → now it fires.
        let hit2 = a.onTick(riderLat: riderLat, riderLon: riderLon,
                           headingDegrees: 0, cameras: [farther, nearer])
        #expect(hit2?.id == 1)
    }

    @Test func resetRearmsFiredCameras() {
        var a = SpeedCameraAnnouncer()
        #expect(a.onTick(riderLat: riderLat, riderLon: riderLon,
                        headingDegrees: 0, cameras: [camNorth])?.id == 1)
        // Already fired → silent.
        #expect(a.onTick(riderLat: riderLat, riderLon: riderLon,
                        headingDegrees: 0, cameras: [camNorth]) == nil)
        a.reset()
        // After reset the same camera warns again (re-ride of the road).
        #expect(a.onTick(riderLat: riderLat, riderLon: riderLon,
                        headingDegrees: 0, cameras: [camNorth])?.id == 1)
    }

    @Test func emptyCamerasAndBadFixAreSafe() {
        var a = SpeedCameraAnnouncer()
        #expect(a.onTick(riderLat: riderLat, riderLon: riderLon,
                        headingDegrees: 0, cameras: []) == nil)
        // Non-finite rider fix → nil, no crash.
        #expect(a.onTick(riderLat: .nan, riderLon: riderLon,
                        headingDegrees: 0, cameras: [camNorth]) == nil)
    }

    // MARK: - Geometry helpers

    @Test func haversineKnownDistance() {
        // ~222 m for 0.002° latitude at this latitude band.
        let d = SpeedCameraAnnouncer.haversineMeters(
            lat1: 50.0, lon1: 14.0, lat2: 50.002, lon2: 14.0)
        #expect(d > 210 && d < 235)
    }

    @Test func bearingDueNorthIsZero() {
        let b = SpeedCameraAnnouncer.bearingDegrees(
            lat1: 50.0, lon1: 14.0, lat2: 50.002, lon2: 14.0)
        #expect(b < 1 || b > 359)
    }

    @Test func angularDifferenceWraps() {
        #expect(SpeedCameraAnnouncer.angularDifference(350, 10) == 20)
        #expect(SpeedCameraAnnouncer.angularDifference(0, 180) == 180)
        #expect(SpeedCameraAnnouncer.angularDifference(90, 90) == 0)
    }
}
