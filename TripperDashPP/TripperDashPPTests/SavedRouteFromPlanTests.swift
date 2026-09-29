//
//  SavedRouteFromPlanTests.swift
//  TripperDashPPTests
//
//  feat/save-route-from-planner — the REAL `SavedRoute.fromPlan`,
//  `SavedRoutesStore.replace` and `RouteStartPlanner.analyze` (the Python
//  suite only mirrors them): every point kept (live origin as a named
//  fixed point), route name rules, empty names, distance fallback, re-save
//  overwrites (under the rider's name), and the start rules — a loop started at home skips home
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
        let first = try #require(SavedRoute.fromPlan([stop("Kokořín", 50.4330, 14.5780)],
                                                     roadDistanceMeters: nil,
                                                     now: Date(timeIntervalSince1970: 1_000)))
        store.add(first)
        let edited = try #require(SavedRoute.fromPlan(
            [stop("Mělník", 50.3505, 14.4741), stop("Kokořín", 50.4330, 14.5780)],
            roadDistanceMeters: nil))
        let out = try #require(store.replace(id: first.id, with: edited))
        #expect(store.routes.count == 1)
        #expect(out.id == first.id && out.createdAt == first.createdAt)
        #expect(out.name == "Mělník → Kokořín")
        #expect(store.replace(id: UUID(), with: edited) == nil)
    }

    @Test func plannerSaveUsesTheRidersNameOrFallsBack() throws {
        let store = SavedRoutesStore(defaults: UserDefaults(suiteName: "test.routes.\(UUID().uuidString)")!)
        let route = try #require(SavedRoute.fromPlan(
            [stop("Mělník", 50.3505, 14.4741), stop("Kokořín", 50.4330, 14.5780)],
            roadDistanceMeters: nil, now: Date(timeIntervalSince1970: 1_000)))
        let first = store.save(route, named: "  Sunday loop ", replacing: nil)
        #expect(first.name == "Sunday loop")
        // Re-save: same entry (id, createdAt), the name typed this time.
        let again = store.save(route, named: "Kokořín via Mělník", replacing: first.id)
        #expect(store.routes.count == 1)
        #expect(again.id == first.id && again.createdAt == first.createdAt)
        #expect(again.name == "Kokořín via Mělník")
        // Blank → the automatic name; a gone id → added anew.
        let blank = store.save(route, named: "   ", replacing: UUID())
        #expect(blank.name == "Mělník → Kokořín")
        #expect(store.routes.count == 2)
        // A pasted essay is capped.
        let long = store.save(route, named: String(repeating: "x", count: 500), replacing: nil)
        #expect(long.name.count == SavedRoutesStore.maxNameLength)
    }

    @Test func onlyACustomNameIsSuggestedOnResave() throws {
        var saved = try #require(SavedRoute.fromPlan(
            [stop("Mělník", 50.3505, 14.4741), stop("Kokořín", 50.4330, 14.5780)],
            roadDistanceMeters: nil))
        // Saved under the automatic name → not suggested again, so a changed
        // destination gets its own `First → Last`.
        #expect(saved.customName == nil)
        saved.name = "Sunday loop"
        #expect(saved.customName == "Sunday loop")
        let single = try #require(SavedRoute.fromPlan([stop("Úštěk", 50.5850, 14.3420)],
                                                      roadDistanceMeters: nil))
        #expect(single.name == "Úštěk" && single.customName == nil)
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

    @Test func loopWithoutOriginStartedAtItsEndDoesNotPrompt() {
        // Review 3 of #151: nearest = the destination the rider stands on →
        // "from nearest" would arrive at once; ride from the first point.
        let noOrigin = Array(loop.dropFirst())                 // Mělník, Kokořín, Home
        let d = RouteStartPlanner.analyze(points: noOrigin,
                                          riderLocation: CLLocationCoordinate2D(latitude: 50.2387, longitude: 14.2015))
        #expect(d.nearestIndex == 2)
        #expect(d.shouldPrompt == false)
    }

    @Test func denseTrackStartedAtItsEndDoesNotPrompt() {
        // Review 4 of #151: on a dense track the rider at the end is nearest
        // to a point just before it; still "at the destination".
        let step = 22 / 111_320 / cos(50 * Double.pi / 180)
        let track = (0..<500).map { RoutePoint(latitude: 50, longitude: 14 + Double($0) * step) }
        let rider = CLLocationCoordinate2D(latitude: 50, longitude: 14 + 497 * step + 0.00001)
        let d = RouteStartPlanner.analyze(points: track, riderLocation: rider)
        #expect(d.nearestIndex == 497)
        #expect(d.shouldPrompt == false)
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
