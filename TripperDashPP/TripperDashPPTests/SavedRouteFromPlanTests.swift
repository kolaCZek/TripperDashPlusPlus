//
//  SavedRouteFromPlanTests.swift
//  TripperDashPPTests
//
//  feat/save-route-from-planner — the REAL `SavedRoute.fromPlan`,
//  `SavedRoutesStore.replace` and `RouteStartPlanner.analyze` (the Python
//  suite only mirrors them): every point kept (live origin as a named
//  fixed point), route name rules, empty names, distance fallback, re-save
//  overwrites (under the rider's name), road-distance writes, and the start rules — a loop started at home skips home
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

    @Test func roadDistanceIsWrittenOnlyForTheRoutedPoints() throws {
        let store = SavedRoutesStore(defaults: UserDefaults(suiteName: "test.routes.\(UUID().uuidString)")!)
        let route = try #require(SavedRoute.fromPlan(
            [stop("Mělník", 50.3505, 14.4741), stop("Kokořín", 50.4330, 14.5780)],
            roadDistanceMeters: nil))
        store.add(route)
        let routed = route.points
        store.setRoadDistance(id: route.id, meters: 21_500, forPoints: routed)
        #expect(store.route(id: route.id)?.totalDistanceMeters == 21_500)
        // A later edit changed the points: the late result is dropped.
        store.updatePoints(id: route.id, points: routed.reversed())
        let straight = try #require(store.route(id: route.id)?.totalDistanceMeters)
        store.setRoadDistance(id: route.id, meters: 99_000, forPoints: routed)
        #expect(store.route(id: route.id)?.totalDistanceMeters == straight)
        // Unknown id: no-op.
        store.setRoadDistance(id: UUID(), meters: 1, forPoints: routed)
        #expect(store.routes.count == 1)
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
        // A pasted essay is capped, with no trailing blank at the cut; a
        // library rename is capped too.
        let long = store.save(route, named: String(repeating: "x", count: 500), replacing: nil)
        #expect(long.name.count == SavedRoutesStore.maxNameLength)
        let cutAtSpace = store.save(route, named: String(repeating: "a", count: 79) + " b", replacing: nil)
        #expect(cutAtSpace.name == String(repeating: "a", count: 79))
        store.rename(id: first.id, to: String(repeating: "y", count: 200))
        #expect(store.routes.first { $0.id == first.id }?.name.count == SavedRoutesStore.maxNameLength)
    }

    @Test func unchangedLongAutomaticNameIsKeptWhole() throws {
        let store = SavedRoutesStore(defaults: UserDefaults(suiteName: "test.routes.\(UUID().uuidString)")!)
        let route = try #require(SavedRoute.fromPlan(
            [stop("Parkoviště u Státního hradu Kokořín, Kokořínský Důl", 50.4330, 14.5780),
             stop("Rozhledna na vrchu Vlhošť, Holany", 50.5580, 14.4180)],
            roadDistanceMeters: nil))
        #expect(route.name.count > SavedRoutesStore.maxNameLength)
        // Save tapped on the prefilled automatic name: not truncated, so it
        // still reads as automatic and won't stick to changed stops.
        let saved = store.save(route, named: route.name, replacing: nil)
        #expect(saved.name == route.name)
        #expect(saved.customName == nil)
    }

    @Test func automaticNameWithAStrayBlankStaysAutomatic() throws {
        let store = SavedRoutesStore(defaults: UserDefaults(suiteName: "test.routes.\(UUID().uuidString)")!)
        // A stop label with a trailing blank (MKMapItem / shared link): the
        // prompt's text is trimmed, but it's still the automatic name.
        let route = try #require(SavedRoute.fromPlan(
            [stop("Mělník", 50.3505, 14.4741), stop("Kokořín ", 50.4330, 14.5780)],
            roadDistanceMeters: nil))
        let saved = store.save(route, named: route.name, replacing: nil)
        #expect(saved.name == route.name)
        #expect(saved.customName == nil)
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

    @Test func plannerCancelAsksOnlyForAnUnsavedMultiStopPlan() {
        let three = ["a|Home", "b|Mělník", "c|Kokořín"]
        #expect(MapPickerView.planHasUnsavedWork(stops: three, saved: nil))
        #expect(MapPickerView.planHasUnsavedWork(stops: three, saved: ["a|Home", "c|Kokořín"]))
        #expect(!MapPickerView.planHasUnsavedWork(stops: three, saved: three))
        // A→B is one search away — cancel straight through, as before.
        #expect(!MapPickerView.planHasUnsavedWork(stops: ["a|Home", "c|Kokořín"], saved: nil))
    }
}

/// feat/edit-route-mid-ride — the pure half of the "Edit route" sheet: which
/// stops are still ahead, and the replacement plan's waypoints.
@MainActor
struct EditRouteMidRideTests {

    private func stop(_ name: String, _ lat: Double, _ lon: Double) -> Waypoint {
        Waypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }
    private let here = CLLocationCoordinate2D(latitude: 50.30, longitude: 14.40)

    @Test func remainingStopsStartAtTheCurrentLegsDestination() {
        let home = Waypoint.currentLocation(CLLocationCoordinate2D(latitude: 50.2385, longitude: 14.2011))
        let a = stop("Mělník", 50.3505, 14.4741)
        let b = stop("Kokořín", 50.4330, 14.5780)
        let c = stop("Doksy", 50.5647, 14.6550)
        let plan = PlannedRoute(waypoints: [home, a, b, c])
        #expect(PlannedRoute.remainingStops(of: plan, fromLegIndex: 0) == [a, b, c])
        #expect(PlannedRoute.remainingStops(of: plan, fromLegIndex: 1) == [b, c])
        #expect(PlannedRoute.remainingStops(of: plan, fromLegIndex: 2) == [c])
        #expect(PlannedRoute.remainingStops(of: plan, fromLegIndex: 3).isEmpty)
        // Single-destination nav: the destination alone.
        #expect(PlannedRoute.remainingStops(of: PlannedRoute(waypoints: [home, c]), fromLegIndex: 0) == [c])
    }

    @Test func replacementIsTheLiveOriginThenTheEditedStops() throws {
        let a = stop("Mělník", 50.3505, 14.4741)
        let b = stop("Kokořín", 50.4330, 14.5780)
        let wps = try #require(PlannedRoute.replacementWaypoints(currentLocation: here, stops: [b, a]))
        #expect(wps.count == 3)
        #expect(wps[0].isCurrentLocation)
        #expect(wps[0].coordinate.latitude == here.latitude && wps[0].coordinate.longitude == here.longitude)
        #expect(Array(wps.dropFirst()) == [b, a])   // reorder kept, ids kept
        // One leg per gap, from here.
        #expect(PlannedRoute(waypoints: wps).legs.count == 2)
    }

    @Test func draftOriginIsReplacedAndNoStopGivesNothing() throws {
        let old = Waypoint.currentLocation(CLLocationCoordinate2D(latitude: 50.0, longitude: 14.0))
        let a = stop("Mělník", 50.3505, 14.4741)
        // The draft's own origin row is passed in as-is: replaced by `here`.
        let wps = try #require(PlannedRoute.replacementWaypoints(currentLocation: here, stops: [old, a]))
        #expect(wps.count == 2 && wps[0].id != old.id && wps[1] == a)
        #expect(wps.filter(\.isCurrentLocation).count == 1)
        #expect(PlannedRoute.replacementWaypoints(currentLocation: here, stops: []) == nil)
        #expect(PlannedRoute.replacementWaypoints(currentLocation: here, stops: [old]) == nil)
    }

    @Test func editorIsNotOfferedForTracksOrDensePlans() {
        let home = Waypoint.currentLocation(here)
        let small = PlannedRoute(waypoints: [home, stop("A", 50.35, 14.47), stop("B", 50.43, 14.57)])
        #expect(small.isEditableMidRide)
        small.isTrack = true
        #expect(!small.isEditableMidRide)
        let dense = PlannedRoute(waypoints: [home] + (0..<RoutePoint.editableListThreshold).map {
            stop("P\($0)", 50 + Double($0) * 0.01, 14)
        })
        #expect(!dense.isEditableMidRide)
    }

    @Test func progressBaselineKeepsTheDistanceAlreadyRidden() {
        // 30 km ridden, then an edit to two new legs of 20 + 50 km: the bar
        // stays at 30/100, not 0, and the tick sits at (30 + 20)/100.
        let edited = ActiveNavigator.progressBaseline(alreadyCovered: 30_000, legDistances: [20_000, 50_000])
        #expect(edited.total == 100_000)
        #expect(edited.fractions == [0.5])
        // A fresh start is the plain sum; a negative "covered" is clamped.
        let fresh = ActiveNavigator.progressBaseline(alreadyCovered: 0, legDistances: [20_000, 50_000])
        #expect(fresh.total == 70_000)
        #expect(fresh.fractions == [20_000.0 / 70_000.0])
        #expect(ActiveNavigator.progressBaseline(alreadyCovered: -5, legDistances: [1_000]).total == 1_000)
        #expect(ActiveNavigator.progressBaseline(alreadyCovered: 0, legDistances: [1_000]).fractions.isEmpty)
    }

    @Test func liveActivityPushesANewDestinationName() {
        let old = RideActivityAttributes.ContentState(
            maneuverSymbol: "arrow.up", distanceText: "300 m", maneuverText: nil,
            etaText: "ETA 14:30", remainingText: "42 km left", progress: 0.4,
            isRerouting: false, destinationName: nil)
        var renamed = old
        renamed.destinationName = "Doksy"
        #expect(!LiveActivityController.shouldPush(old: old, new: old, imperial: false))
        #expect(LiveActivityController.shouldPush(old: old, new: renamed, imperial: false))
    }
}
