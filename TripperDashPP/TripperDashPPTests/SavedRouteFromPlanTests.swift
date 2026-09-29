//
//  SavedRouteFromPlanTests.swift
//  TripperDashPPTests
//
//  feat/save-route-from-planner — the REAL `SavedRoute.fromPlan`,
//  `SavedRoutesStore.replace` and `RouteStartPlanner.analyze` (the Python
//  suite only mirrors them): stops kept, live origin dropped, route name
//  rules, empty names, distance fallback, re-save overwrites, and a round
//  trip that ends at its start never offers "start from nearest".
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

    @Test func dropsLiveOriginKeepsStopsAndNamesFirstToLast() throws {
        let r = try #require(SavedRoute.fromPlan(
            [home, stop("Mělník", 50.3505, 14.4741), stop("Kokořín", 50.4330, 14.5780)],
            roadDistanceMeters: 42_000))
        #expect(r.kind == .waypoints)
        #expect(r.points.map(\.name) == ["Mělník", "Kokořín"])
        #expect(r.name == "Mělník → Kokořín")
        #expect(r.totalDistanceMeters == 42_000)
    }

    @Test func singleStopIsNamedAfterItAndUncomputedFallsBackToStraightLine() throws {
        let one = try #require(SavedRoute.fromPlan([home, stop("Kokořín", 50.4330, 14.5780)],
                                                   roadDistanceMeters: nil))
        #expect(one.name == "Kokořín")
        #expect(one.totalDistanceMeters == 0)
        let two = try #require(SavedRoute.fromPlan(
            [home, stop("Mělník", 50.3505, 14.4741), stop("Kokořín", 50.4330, 14.5780)],
            roadDistanceMeters: nil))
        #expect(two.totalDistanceMeters > 10_000 && two.totalDistanceMeters < 12_000)
    }

    @Test func onlyTheLiveOriginSavesNothing() {
        #expect(SavedRoute.fromPlan([home], roadDistanceMeters: nil) == nil)
    }

    @Test func emptyStopNameFallsBackToCoordinates() throws {
        let r = try #require(SavedRoute.fromPlan([home, stop("", 50.4330, 14.5780)],
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

    @Test func roundTripStartedAtItsEndNeverPromptsForNearest() {
        // Planned at home: Mělník → Kokořín → Home. At the bike (home) the
        // nearest point is the destination — must start from the first.
        let points = [RoutePoint(latitude: 50.3505, longitude: 14.4741, name: "Mělník"),
                      RoutePoint(latitude: 50.4330, longitude: 14.5780, name: "Kokořín"),
                      RoutePoint(latitude: 50.2385, longitude: 14.2011, name: "Home")]
        let d = RouteStartPlanner.analyze(points: points,
                                          riderLocation: CLLocationCoordinate2D(latitude: 50.2385, longitude: 14.2011))
        #expect(d.nearestIndex == 2)
        #expect(d.shouldPrompt == false)
    }
}
