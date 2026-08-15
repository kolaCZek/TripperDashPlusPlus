//
//  RouteProjectionTests.swift
//  TripperDashPPTests
//
//  Tests the along-route projection geometry AND the along-route speed-
//  camera selection it powers. The key scenario is the SHARP BEND: a camera
//  just past a hairpin lies >75° off the rider's heading (so the old
//  straight-line cone would reject it) yet is only ~300 m ahead ALONG THE
//  ROAD and must warn. Pure value types, headless (no CoreLocation/MapKit).
//
//  Geometry note: 0.001° latitude ≈ 111 m; 0.001° longitude at ~50°N ≈
//  71 m. Fixtures use a simple L-shaped / hairpin polyline so along-route
//  arc-lengths are hand-verifiable.
//

import Testing
@testable import TripperDashPP

struct RouteProjectionTests {

    private typealias Point = RouteProjection.Point
    private typealias Target = RouteProjection.Target

    // MARK: - Projection basics

    @Test func projectsOntoStraightLine() {
        // A due-north line from (50.000) to (50.010) at lon 14.0.
        let line = [
            Point(latitude: 50.000, longitude: 14.0),
            Point(latitude: 50.010, longitude: 14.0),
        ]
        let proj = RouteProjection(coords: line)
        #expect(proj.isUsable)
        // A point at 50.005 on the line → ~half the length along, ~0 lateral.
        let p = proj.project(Point(latitude: 50.005, longitude: 14.0))
        #expect(p != nil)
        let half = proj.totalMeters / 2
        #expect(abs((p?.alongMeters ?? 0) - half) < 5)
        #expect((p?.lateralMeters ?? 99) < 2)
    }

    @Test func lateralOffsetForPointBesideLine() {
        let line = [
            Point(latitude: 50.000, longitude: 14.0),
            Point(latitude: 50.010, longitude: 14.0),
        ]
        let proj = RouteProjection(coords: line)
        // A point 0.001° east of the midpoint (~71 m off) → lateral ~71 m.
        let p = proj.project(Point(latitude: 50.005, longitude: 14.001))
        #expect(p != nil)
        #expect((p?.lateralMeters ?? 0) > 60 && (p?.lateralMeters ?? 0) < 85)
    }

    @Test func unusablePolylineReturnsNil() {
        let proj = RouteProjection(coords: [Point(latitude: 50.0, longitude: 14.0)])
        #expect(!proj.isUsable)
        #expect(proj.project(Point(latitude: 50.0, longitude: 14.0)) == nil)
    }

    // MARK: - Along-route camera selection

    /// A hairpin: the road runs north, then doubles back south on a parallel
    /// leg slightly east. A camera on the SECOND leg is only a short way
    /// ahead along the road, but sits nearly due south of the rider (bearing
    /// ~180° off a "heading north" rider) — the classic cone false-negative.
    @Test func cameraPastSharpBendIsAhead() {
        // Leg 1: north up lon 14.000, from 50.000 to 50.004 (~444 m).
        // Leg 2: back south down lon 14.0006 (~43 m east), 50.004 → 50.000.
        let route = [
            Point(latitude: 50.000, longitude: 14.0000),
            Point(latitude: 50.004, longitude: 14.0000),
            Point(latitude: 50.000, longitude: 14.0006),
        ]
        let proj = RouteProjection(coords: route)
        // Rider near the start of leg 1.
        let rider = Point(latitude: 50.0005, longitude: 14.0000)
        // Camera on leg 2 at latitude 50.002 (past the bend). Straight-line
        // it's slightly EAST and roughly level → way off the heading cone,
        // but along the road it's: rest of leg 1 up to 50.004, then down
        // leg 2 to 50.002 — a few hundred metres ahead.
        let cam = Target(id: 1, latitude: 50.002, longitude: 14.0006)
        let ahead = proj.alongRouteDistanceAhead(
            rider: rider, target: cam, maxLateralMeters: 60)
        #expect(ahead != nil)
        // Roughly: (50.004-50.0005)=~389 m up + (50.004-50.002)=~222 m down
        // ≈ 611 m. Allow a wide band — the point is it's POSITIVE and in the
        // right ballpark, not the cone's "behind/reject".
        #expect((ahead ?? 0) > 400 && (ahead ?? 0) < 800)
    }

    @Test func cameraAlreadyPassedIsNotAhead() {
        let route = [
            Point(latitude: 50.000, longitude: 14.0),
            Point(latitude: 50.010, longitude: 14.0),
        ]
        let proj = RouteProjection(coords: route)
        // Rider well up the line; camera behind (further back down the road).
        let rider = Point(latitude: 50.006, longitude: 14.0)
        let cam = Target(id: 2, latitude: 50.002, longitude: 14.0)
        let ahead = proj.alongRouteDistanceAhead(
            rider: rider, target: cam, maxLateralMeters: 60)
        #expect(ahead == nil)   // behind → not ahead
    }

    @Test func cameraOnParallelRoadIsRejected() {
        let route = [
            Point(latitude: 50.000, longitude: 14.0),
            Point(latitude: 50.010, longitude: 14.0),
        ]
        let proj = RouteProjection(coords: route)
        let rider = Point(latitude: 50.002, longitude: 14.0)
        // Camera ~350 m east of the route (0.005° lon ≈ 357 m) — a parallel
        // road the route never takes. Lateral gate (60 m) rejects it.
        let cam = Target(id: 3, latitude: 50.005, longitude: 14.005)
        let ahead = proj.alongRouteDistanceAhead(
            rider: rider, target: cam, maxLateralMeters: 60)
        #expect(ahead == nil)
    }

    @Test func alongRouteDistanceMeasuresArcLength() {
        // Straight 0.010° north line ≈ 1113 m. Rider at start, camera at
        // 50.003 → ~334 m ahead along the road.
        let route = [
            Point(latitude: 50.000, longitude: 14.0),
            Point(latitude: 50.010, longitude: 14.0),
        ]
        let proj = RouteProjection(coords: route)
        let rider = Point(latitude: 50.000, longitude: 14.0)
        let cam = Target(id: 4, latitude: 50.003, longitude: 14.0)
        let ahead = proj.alongRouteDistanceAhead(
            rider: rider, target: cam, maxLateralMeters: 60)
        #expect(ahead != nil)
        #expect(abs((ahead ?? 0) - 334) < 15)
    }
}
