//
//  SavedRouteFromPlanTests.swift
//  TripperDashPPTests
//
//  feat/save-route-from-planner — the REAL `SavedRoute.fromPlan`,
//  `SavedRoutesStore.replace` and `RouteStartPlanner.analyze` (the Python
//  suite only mirrors them): every point kept (live origin as a named
//  fixed point), route name rules, empty names, distance fallback, re-save
//  overwrites, and the start rules — a loop started at home skips home
//  without a prompt; a one-way route joined near its end still prompts.
//

import CoreLocation
import Foundation
import Testing
@testable import TripperDashPP

@MainActor
struct SavedRouteFromPlanTests {

    private let home = Waypoint.currentLocation(CLLocationCoordinate2D(latitude: 50.2385, longitude: 14.2011))
    private func stop(_ name: String, _ lat: Double, _ lon: Double) -> Waypoint {
        Waypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    @Test func keepsTheLiveOriginAsANamedFixedPoint() throws {
        let fix = CLLocationCoordinate2D(latitude: 50.2390, longitude: 14.2020)
        let r = try #require(SavedRoute.fromPlan(
            [home, stop("Mělník", 50.3505, 14.4741), stop("Kokořín", 50.4330, 14.5780)],
            roadDistanceMeters: 42_000, currentLocation: fix, currentLocationName: "Zvoleněves"))
        #expect(r.kind == .waypoints)
        #expect(r.points.map(\.name) == ["Zvoleněves", "Mělník", "Kokořín"])
        #expect(r.points[0].latitude == fix.latitude && r.points[0].longitude == fix.longitude)
        #expect(r.name == "Zvoleněves → Kokořín")
        #expect(r.totalDistanceMeters == 42_000)
    }

    @Test func ungeocodedOriginFallsBackToCoordinatesAndNeverToCurrentLocation() throws {
        let r = try #require(SavedRoute.fromPlan([home, stop("Kokořín", 50.4330, 14.5780)],
                                                 roadDistanceMeters: nil))
        #expect(r.points[0].name == nil)
        #expect(r.name == "50.2385, 14.2011 → Kokořín")
        #expect(!r.points.contains { $0.name == "Current location" })
    }

    @Test func singleStopIsNamedAfterItAndUncomputedFallsBackToStraightLine() throws {
        // Origin removed from the plan by the rider → just the stops.
        let one = try #require(SavedRoute.fromPlan([stop("Kokořín", 50.4330, 14.5780)],
                                                   roadDistanceMeters: nil))
        #expect(one.name == "Kokořín")
        #expect(one.totalDistanceMeters == 0)
        let two = try #require(SavedRoute.fromPlan(
            [stop("Mělník", 50.3505, 14.4741), stop("Kokořín", 50.4330, 14.5780)],
            roadDistanceMeters: nil))
        #expect(two.totalDistanceMeters > 10_000 && two.totalDistanceMeters < 12_000)
    }

    @Test func onlyTheLiveOriginSavesNothing() {
        #expect(SavedRoute.fromPlan([home], roadDistanceMeters: nil) == nil)
    }

    @Test func emptyStopNameFallsBackToCoordinates() throws {
        let r = try #require(SavedRoute.fromPlan([stop("", 50.4330, 14.5780)],
                                                 roadDistanceMeters: nil))
        #expect(r.points[0].name == nil)
        #expect(r.name == "50.4330, 14.5780")
    }

    @Test func replaceKeepsIdAndCreatedAt() throws {
        let store = SavedRoutesStore(defaults: UserDefaults(suiteName: "test.routes.\(UUID().uuidString)")!)
        let first = try #require(SavedRoute.fromPlan([home, stop("Kokořín", 50.4330, 14.5780)],
                                                     roadDistanceMeters: nil,
                                                     now: Date(timeIntervalSince1970: 1_000)))
        store.add(first)
        let edited = try #require(SavedRoute.fromPlan(
            [home, stop("Mělník", 50.3505, 14.4741), stop("Kokořín", 50.4330, 14.5780)],
            roadDistanceMeters: nil))
        let out = try #require(store.replace(id: first.id, with: edited))
        #expect(store.routes.count == 1)
        #expect(out.id == first.id && out.createdAt == first.createdAt)
        #expect(out.name == "Mělník → Kokořín")
        #expect(store.replace(id: UUID(), with: edited) == nil)
    }

    private let loop = [RoutePoint(latitude: 50.2385, longitude: 14.2011, name: "Zvoleněves"),
                        RoutePoint(latitude: 50.3505, longitude: 14.4741, name: "Mělník"),
                        RoutePoint(latitude: 50.4330, longitude: 14.5780, name: "Kokořín"),
                        RoutePoint(latitude: 50.2386, longitude: 14.2012, name: "Home")]

    @Test func loopStartedAtHomeSkipsHomeWithoutAPrompt() {
        let bike = CLLocationCoordinate2D(latitude: 50.2387, longitude: 14.2015)   // ~30 m off
        let d = RouteStartPlanner.analyze(points: loop, riderLocation: bike)
        #expect(d.shouldPrompt == false)
        let nav = RouteStartPlanner.droppingReachedStart(
            RouteStartPlanner.navigablePoints(loop, mode: .fromFirst, nearestIndex: d.nearestIndex),
            riderLocation: bike)
        #expect(nav.map(\.name) == ["Mělník", "Kokořín", "Home"])
    }

    @Test func firstPointIsKeptWhenTheRiderIsNotThere() {
        let away = CLLocationCoordinate2D(latitude: 50.2450, longitude: 14.2011)   // ~720 m north
        #expect(RouteStartPlanner.droppingReachedStart(loop, riderLocation: away).count == 4)
        #expect(RouteStartPlanner.droppingReachedStart(loop, riderLocation: nil).count == 4)
        #expect(RouteStartPlanner.droppingReachedStart([loop[0]], riderLocation: loop[0].coordinate).count == 1)
    }

    @Test func oneWayRouteJoinedNearItsEndStillPrompts() {
        // Review 2 of #151: A → B → C with C 80 km past B; the rider is
        // 30 km short of C, so C is the nearest point — ask, don't
        // silently send them 100+ km back to A.
        let oneWay = [RoutePoint(latitude: 50.00, longitude: 14.0, name: "A"),
                      RoutePoint(latitude: 50.10, longitude: 14.0, name: "B"),
                      RoutePoint(latitude: 50.82, longitude: 14.0, name: "C")]
        let rider = CLLocationCoordinate2D(latitude: 50.55, longitude: 14.0)
        let d = RouteStartPlanner.analyze(points: oneWay, riderLocation: rider)
        #expect(d.nearestIndex == 2)
        #expect(d.shouldPrompt == true)
    }
}
