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

import Foundation
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

    // MARK: - Along-route (sharp-bend fix)

    // A hairpin route: north up lon 14.0000 to 50.004, then back south down
    // a leg ~43 m east. A camera on the second leg sits nearly due south of
    // a rider on the first leg (the old cone would REJECT it) yet is only a
    // few hundred metres ahead along the road.
    private let hairpin: [(lat: Double, lon: Double)] = [
        (50.0000, 14.0000),
        (50.0040, 14.0000),
        (50.0000, 14.0006),
    ]

    @Test func alongRouteFiresForCameraPastSharpBend() {
        var a = SpeedCameraAnnouncer()
        // Rider heading NORTH near the start of leg 1.
        let rider = (lat: 50.0010, lon: 14.0000)
        // Camera on leg 2 at 50.0035 — bearing from the rider is ~south, so
        // the 75° cone would reject it. Along the road it's ~393 m ahead
        // (inside the 400 m warn radius) → must fire.
        let cam = Target(id: 100, latitude: 50.0035, longitude: 14.0006)
        let hit = a.onTickAlongRoute(
            riderLat: rider.lat, riderLon: rider.lon,
            routeAhead: hairpin, headingDegrees: 0, cameras: [cam])
        #expect(hit?.id == 100)
        // Fires once.
        let again = a.onTickAlongRoute(
            riderLat: rider.lat, riderLon: rider.lon,
            routeAhead: hairpin, headingDegrees: 0, cameras: [cam])
        #expect(again == nil)
    }

    @Test func alongRouteDoesNotFireForCameraBehindOnRoute() {
        var a = SpeedCameraAnnouncer()
        // Straight north line; rider well up it, camera further back.
        let route: [(lat: Double, lon: Double)] = [(50.000, 14.0), (50.010, 14.0)]
        let cam = Target(id: 101, latitude: 50.002, longitude: 14.0)
        let hit = a.onTickAlongRoute(
            riderLat: 50.006, riderLon: 14.0,
            routeAhead: route, headingDegrees: 0, cameras: [cam])
        #expect(hit == nil)
    }

    @Test func alongRouteRespectsWarnRadius() {
        var a = SpeedCameraAnnouncer()
        let route: [(lat: Double, lon: Double)] = [(50.000, 14.0), (50.020, 14.0)]
        // Camera ~1.1 km ahead along the road (0.010° ≈ 1113 m) → beyond the
        // 400 m warn radius → silent.
        let cam = Target(id: 102, latitude: 50.010, longitude: 14.0)
        let hit = a.onTickAlongRoute(
            riderLat: 50.000, riderLon: 14.0,
            routeAhead: route, headingDegrees: 0, cameras: [cam])
        #expect(hit == nil)
        // A closer camera (~334 m ahead) fires.
        let near = Target(id: 103, latitude: 50.003, longitude: 14.0)
        let hit2 = a.onTickAlongRoute(
            riderLat: 50.000, riderLon: 14.0,
            routeAhead: route, headingDegrees: 0, cameras: [near])
        #expect(hit2?.id == 103)
    }

    @Test func alongRouteFallsBackToConeWithoutPolyline() {
        var a = SpeedCameraAnnouncer()
        // Empty polyline → fall back to the cone logic: north camera, heading
        // north, close → fires exactly like the classic path.
        let hit = a.onTickAlongRoute(
            riderLat: riderLat, riderLon: riderLon,
            routeAhead: [], headingDegrees: 0, cameras: [camNorth])
        #expect(hit?.id == 1)
        // And a behind camera still doesn't (cone rejects south).
        var b = SpeedCameraAnnouncer()
        let miss = b.onTickAlongRoute(
            riderLat: riderLat, riderLon: riderLon,
            routeAhead: [], headingDegrees: 0, cameras: [camSouth])
        #expect(miss == nil)
    }

    @Test func alongRouteRejectsParallelRoadCamera() {
        var a = SpeedCameraAnnouncer()
        let route: [(lat: Double, lon: Double)] = [(50.000, 14.0), (50.010, 14.0)]
        // Camera ~350 m east of the route (parallel road) → lateral gate
        // rejects it even though it's "ahead" in latitude.
        let cam = Target(id: 104, latitude: 50.004, longitude: 14.005)
        let hit = a.onTickAlongRoute(
            riderLat: 50.001, riderLon: 14.0,
            routeAhead: route, headingDegrees: 0, cameras: [cam])
        #expect(hit == nil)
    }

    // MARK: - Average-speed sections

    /// Straight route due north along lon 14.0, a vertex every 0.001° lat
    /// (~111 m). Section `from` 50.010 → `to` 50.020 (~1.11 km), its nodes
    /// ~21 m off the line like real carriageway nodes. The opposite
    /// carriageway's relation runs the other way and must never engage.
    private let route = (0...30).map { (lat: 50.0 + Double($0) * 0.001, lon: 14.0) }
    private let northbound = SpeedSection(id: 10, fromLat: 50.010, fromLon: 14.0003,
                                          toLat: 50.020, toLon: 14.0003, maxspeedKmh: 80)
    private let southbound = SpeedSection(id: 11, fromLat: 50.020, fromLon: 13.9997,
                                          toLat: 50.010, toLon: 13.9997, maxspeedKmh: 80)

    /// Ride the route at a constant 20 m/s (72 km/h), 1 Hz, returning the
    /// per-tick readings.
    private func rideThrough(_ sections: [SpeedSection]) -> [SpeedSectionTracker.Reading?] {
        var tracker = SpeedSectionTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        var readings: [SpeedSectionTracker.Reading?] = []
        for t in 0..<160 {
            let lat = 50.0005 + 20.0 / 111_195.0 * Double(t)
            guard lat < 50.029 else { break }
            let seg = Int((lat - 50.0) / 0.001)
            readings.append(tracker.onTick(
                riderLat: lat, riderLon: 14.0,
                time: t0.addingTimeInterval(Double(t)),
                routeAhead: Array(route[seg...]),
                sections: sections))
        }
        return readings
    }

    @Test func sectionAverageMatchesSteadySpeed() {
        let inside = rideThrough([northbound]).compactMap { $0 }
        // ~1.11 km at 20 m/s ≈ 55 ticks inside, then the panel goes away.
        #expect(inside.count > 50 && inside.count < 60)
        #expect(inside.first?.averageKmh == nil)          // first seconds: no figure yet
        #expect(inside.first?.limitKmh == 80)
        let averages = inside.compactMap(\.averageKmh)
        #expect(!averages.isEmpty)
        #expect(averages.allSatisfy { abs($0 - 72) < 2 })
        #expect(inside.last!.remainingMeters < 30)
        #expect(abs(inside.first!.lengthMeters - 1_112) < 15)
    }

    @Test func sectionPanelHidesAfterTheEndPoint() {
        let readings = rideThrough([northbound])
        let lastInside = readings.lastIndex { $0 != nil }!
        #expect(readings[(lastInside + 1)...].allSatisfy { $0 == nil })
    }

    @Test func oppositeCarriagewaySectionNeverEngages() {
        #expect(rideThrough([southbound]).allSatisfy { $0 == nil })
    }

    @Test func sectionsNeedFromAndToRoles() throws {
        let json = """
        {"elements":[
          {"type":"node","id":1,"lat":50.0,"lon":14.0,"tags":{"highway":"speed_camera"}},
          {"type":"relation","id":7,"tags":{"maxspeed":"50"},
           "members":[{"type":"node","ref":2,"role":"from"},{"type":"node","ref":3,"role":"to"}]},
          {"type":"relation","id":8,
           "members":[{"type":"node","ref":2,"role":""},{"type":"node","ref":3,"role":""}]},
          {"type":"node","id":2,"lat":50.01,"lon":14.0},
          {"type":"node","id":3,"lat":50.02,"lon":14.0}
        ]}
        """
        let elements = try JSONDecoder()
            .decode(SpeedCameraService.OverpassResponse.self, from: Data(json.utf8)).elements
        let sections = SpeedCameraService.makeSections(elements)
        #expect(sections.map(\.id) == [7])
        #expect(sections.first?.maxspeedKmh == 50)
        #expect(sections.first?.toLat == 50.02)
        // Bare from/to nodes are not cameras.
        #expect(SpeedCameraService.makeCameras(elements).map(\.id) == [1])
    }
}
