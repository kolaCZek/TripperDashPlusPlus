//
//  RouteProjectionTests.swift
//  TripperDashPPTests
//
//  Tests the along-route projection geometry AND the along-route speed-
//  camera selection it powers. The key scenario is the SHARP BEND: a camera
//  just past a hairpin is only ~170 m away in a straight line yet ~600 m
//  ahead ALONG THE ROAD, and the along-route distance is what must be
//  reported. Pure value types, headless (no CoreLocation/MapKit).
//
//  Geometry note: 0.001° latitude ≈ 111 m; 0.001° longitude at ~50°N ≈
//  71 m. Fixtures use a simple L-shaped / hairpin polyline so along-route
//  arc-lengths are hand-verifiable.
//

import CoreLocation
import MapKit
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
    /// leg slightly east. A camera on the SECOND leg is ~170 m away in a
    /// straight line but ~600 m ahead ALONG THE ROAD — the along-route
    /// distance is what must be reported.
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
        // it's ~170 m away (bearing ~14°), but along the road it's: rest of
        // leg 1 up to 50.004, then down leg 2 to 50.002 — ~600 m ahead.
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

/// Map matching and reroute-heading statics behind the wrong-way U-turn
/// (PR #191), on real MKPolylines. Python mirrors of the same scenarios live
/// in tools/fake_dash/tests/test_wrong_way_uturn.py.
@MainActor
struct RerouteHeadingTests {

    /// x metres east, y metres north of 50°N 14°E.
    private func pt(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 50 + y / 111_320,
                               longitude: 14 + x / (111_320 * cos(50 * .pi / 180)))
    }

    private func line(_ xy: [(Double, Double)]) -> MKPolyline {
        let c = xy.map { pt($0.0, $0.1) }
        return MKPolyline(coordinates: c, count: c.count)
    }

    /// Up carriageway A (x = 0), across, back down B (x = 20); 100 m segments.
    private var dividedTurnaround: MKPolyline {
        line(stride(from: 0.0, through: 1000, by: 100).map { (0, $0) }
             + stride(from: 1000.0, through: 0, by: -100).map { (20, $0) })
    }

    @Test func gpsErrorTowardsFarCarriagewayKeepsCursor() {
        let route = dividedTurnaround
        let rider = pt(11, 450)
        #expect(PolylineMath.nearestSegment(on: route, from: 4, to: rider).segmentIndex > 10)
        #expect(PolylineMath.nearestSegment(on: route, from: 4, to: rider, preferContinuity: true).segmentIndex == 4)
    }

    @Test func longSegmentDoesNotFreezeCursor() {
        // 800 m approach, 15 m median crossing, return carriageway.
        let route = line([(0, 0), (0, 800), (15, 800), (15, 0)])
        for y in [790.0, 300, 50] {
            let r = PolylineMath.nearestSegment(on: route, from: 0, to: pt(15, y),
                                                preferContinuity: true, course: 180)
            #expect(r.segmentIndex == 2)
        }
    }

    @Test func outAndBackStandingTakesEarliestTie() {
        // Ways out (x = 0) and back (x = 3), 50 m vertices; rider standing at
        // y = 880, fix 2 m towards the way back.
        let route = line(stride(from: 0.0, through: 1000, by: 50).map { (0, $0) }
                         + stride(from: 1000.0, through: 0, by: -50).map { (3, $0) })
        let rider = pt(2, 880)
        #expect(PolylineMath.nearestSegment(on: route, from: 16, to: rider).segmentIndex > 20)
        #expect(PolylineMath.nearestSegment(on: route, from: 16, to: rider, preferContinuity: true).segmentIndex == 17)
        #expect(PolylineMath.nearestSegment(on: route, from: 16, to: rider,
                                            preferContinuity: true, course: 0).segmentIndex == 17)
    }

    @Test func forwardPickHonoursHeadingAndDetourCap() {
        let north = [pt(0, 0), pt(0, 111)]
        let south = [pt(0, 0), pt(0, -111)]
        #expect(ActiveNavigator.forwardRouteIndex([(south, 600), (north, 600)], course: 0) == 1)
        #expect(ActiveNavigator.forwardRouteIndex([(south, 600), (north, 1320)], course: 0) == nil)
        #expect(ActiveNavigator.forwardRouteIndex([(south, 600), (south, 600)], course: 350) == nil)
    }

    @Test func wrongWayClock() {
        let t0 = Date(timeIntervalSince1970: 0)
        // Not active: anything at or below 120° stops the clock.
        #expect(ActiveNavigator.wrongWaySince(nil, offLine: 180, at: t0, active: false) == t0)
        #expect(ActiveNavigator.wrongWaySince(t0, offLine: 100, at: t0, active: false) == nil)
        // Active: 60–120° keeps it, under 60° clears it.
        #expect(ActiveNavigator.wrongWaySince(t0, offLine: 100, at: t0, active: true) == t0)
        #expect(ActiveNavigator.wrongWaySince(t0, offLine: 30, at: t0, active: true) == nil)
    }
}

/// The on-route turn arrow (`MapViewSource.routeArrow` / `routeIndex`):
/// pure geometry, path units = pixels, Y down.
struct RouteArrowGeometryTests {

    private func arrow(_ pts: [CGPoint], node: Int, before: CGFloat = 45, after: CGFloat = 40) -> (shaft: [CGPoint], head: [CGPoint])? {
        MapViewSource.routeArrow(along: pts, node: node, before: before, after: after,
                                 headLength: 13, headWidth: 21)
    }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.01 }

    @Test func rightTurnFollowsTheRoute() throws {
        // Up the screen to (0,0), then right.
        let a = try #require(arrow([CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], node: 1))
        #expect(near(a.shaft.first!, CGPoint(x: 0, y: 45)))          // 45 before the node
        #expect(a.shaft.contains { near($0, CGPoint(x: 0, y: 0)) })   // bends at the node
        #expect(near(a.shaft.last!, CGPoint(x: 27, y: 0)))           // head base = tip − 13
        #expect(near(a.head[0], CGPoint(x: 40, y: 0)))                // tip 40 past the node
        #expect(near(a.head[1], CGPoint(x: 27, y: 10.5)) || near(a.head[1], CGPoint(x: 27, y: -10.5)))
        #expect(abs(a.head[1].y + a.head[2].y) < 0.01 && abs(abs(a.head[1].y - a.head[2].y) - 21) < 0.01)
    }

    @Test func headSpansSeveralDenseVertices() throws {
        // Dense vertices every 2 px after the node: the head base is 13 px
        // back from the tip along the line, and no shaft vertex is in the head.
        let pts = [CGPoint(x: 0, y: 50)] + (0...30).map { CGPoint(x: CGFloat($0) * 2, y: 0) }
        let a = try #require(arrow(pts, node: 1))
        #expect(near(a.head[0], CGPoint(x: 40, y: 0)))
        #expect(near(a.shaft.last!, CGPoint(x: 27, y: 0)))
        #expect(a.shaft.dropLast().allSatisfy { $0.x <= 27 })
    }

    @Test func headPointsAlongTheRouteAtTheTip() throws {
        // A hairpin inside the head: base → tip is sideways, the route's
        // last segment into the tip points down (+y).
        let pts = [CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 8)]
        let a = try #require(arrow(pts, node: 1, after: 16))
        #expect(near(a.head[0], CGPoint(x: 8, y: 8)))
        #expect(abs(a.head[1].y - a.head[2].y) < 0.01)            // base across x
        #expect(abs(a.head[1].y - (8 - 13)) < 0.01)               // 13 back along −y
    }

    @Test func clampsToTheRouteEnds() throws {
        // Node at the start: no shaft before it. Short tail: tip at the end.
        let a = try #require(arrow([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -20)], node: 0))
        #expect(near(a.shaft.first!, CGPoint(x: 0, y: 0)))
        #expect(near(a.head[0], CGPoint(x: 0, y: -20)))
        // Not enough route after the node for a head (arrival): no arrow.
        #expect(arrow([CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0)], node: 1)?.head == nil)
        #expect(arrow([CGPoint(x: 0, y: 0)], node: 3)?.head == nil)
    }

    @Test func nodeIndexIsTheFirstPassAndTheClosestVertex() {
        typealias C = CLLocationCoordinate2D
        // North in ~1.1 m steps, then back south over the same points.
        let up = (0...20).map { C(latitude: 50 + Double($0) * 0.00001, longitude: 14) }
        let route = up + up.reversed().dropFirst()
        let node = C(latitude: 50.0001, longitude: 14)   // vertex 10
        #expect(MapViewSource.routeIndex(nearest: node, in: route, withinMeters: 10) == 10)
        #expect(MapViewSource.routeIndex(nearest: C(latitude: 50.01, longitude: 14), in: route, withinMeters: 10) == nil)
        // A small ring passing ~4 m from the node before reaching it: the
        // exact vertex wins over the earlier near pass.
        let ring = [C(latitude: 50, longitude: 14), C(latitude: 50.00004, longitude: 14),
                    C(latitude: 50.00004, longitude: 14.0001), C(latitude: 50.00008, longitude: 14.0001),
                    C(latitude: 50.00008, longitude: 14)]
        #expect(MapViewSource.routeIndex(nearest: C(latitude: 50.00008, longitude: 14), in: ring, withinMeters: 10) == 4)
    }
}
