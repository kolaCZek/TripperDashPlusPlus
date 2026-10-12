//
//  RideIntents.swift
//  TripperDashPP
//
//  Shortcuts / Siri actions (App Intents): start a free ride, navigate to
//  a favorite, a saved route or any place, stop the ride, and ask how far
//  is left. Each action calls into `AppStatus`; starting a ride arms the
//  same connect-then-auto-start path as the picker's Connect button.
//
//  Starting a ride needs the app in the foreground (route prerender, and
//  a While Using location grant only starts updates there), so those
//  actions open the app — which needs an unlocked phone. Redirecting a
//  running navigation, stopping and the status query run in the
//  background, so they work from a helmet headset with the phone locked.
//
//  The typical automation: Shortcuts → Automation → Wi-Fi → the bike's
//  network → Start Free Ride. iOS rejoins that network after a drop
//  mid-ride and fires the automation again, so Start Free Ride is a no-op
//  while a ride is running or about to start (`ShortcutPolicy`), decided
//  in the background without opening the app.
//

import AppIntents
import Foundation

// MARK: - Decisions (pure, unit-tested)

enum ShortcutPolicy {

    enum FreeRide: Equatable {
        case alreadyRiding, alreadyStarting, planStaged, noBike, startNow, waitForLink, connect, reconnect
    }

    static func freeRide(rideActive: Bool,
                         requestPending: Bool,
                         planStaged: Bool,
                         link: BikeLink.LinkState,
                         canConnect: Bool) -> FreeRide {
        if rideActive {
            // The link gave up reconnecting (bike off past the reconnect
            // budget): connect again, and the ride resumes on .connected.
            // A drop mid-ride sits in .reconnecting and stays a no-op.
            switch link {
            case .idle, .error: return canConnect ? .reconnect : .alreadyRiding
            default: return .alreadyRiding
            }
        }
        if requestPending { return .alreadyStarting }
        // Don't throw away a route the rider planned.
        if planStaged { return .planStaged }
        switch link {
        case .connected: return .startNow
        case .connecting, .handshaking, .reconnecting: return .waitForLink
        case .idle, .error: return canConnect ? .connect : .noBike
        }
    }

    enum Navigate: Equatable { case stage, redirect, finishingArrival, handPlanStaged }

    /// A new destination mid-navigation replaces the running route. In the
    /// few seconds between arrival and the switch to free ride, `replacePlan`
    /// refuses and the stage path would be torn down by `finishArrival`.
    /// A plan the rider built or edited by hand is never replaced.
    static func navigate(navigating: Bool, arrived: Bool, handPlanStaged: Bool) -> Navigate {
        if navigating { return arrived ? .finishingArrival : .redirect }
        return handPlanStaged ? .handPlanStaged : .stage
    }
}

// MARK: - Entities

nonisolated struct FavoriteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Favorite"
    static let defaultQuery = FavoriteQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct FavoriteQuery: EntityStringQuery {
    @MainActor private var all: [FavoriteEntity] {
        AppStatus.shared.navigationStore.settings.favorites.map { FavoriteEntity(id: $0.id, name: $0.name) }
    }

    @MainActor func entities(for identifiers: [UUID]) async throws -> [FavoriteEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    @MainActor func entities(matching string: String) async throws -> [FavoriteEntity] {
        all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor func suggestedEntities() async throws -> [FavoriteEntity] { all }
}

nonisolated struct SavedRouteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Route"
    static let defaultQuery = SavedRouteQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct SavedRouteQuery: EntityStringQuery {
    @MainActor private var all: [SavedRouteEntity] {
        AppStatus.shared.savedRoutesStore.routes.map { SavedRouteEntity(id: $0.id, name: $0.name) }
    }

    @MainActor func entities(for identifiers: [UUID]) async throws -> [SavedRouteEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    @MainActor func entities(matching string: String) async throws -> [SavedRouteEntity] {
        all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor func suggestedEntities() async throws -> [SavedRouteEntity] { all }
}

// MARK: - Intents

// Main-actor isolated (the project default): `nonisolated` isn't allowed on
// the `@Parameter` properties a nonisolated struct would make nonisolated.

/// Decides in the background and opens the app only to start a ride, so the
/// automation's repeat when the phone rejoins the bike's Wi-Fi mid-ride
/// returns without bringing the app forward or asking to unlock.
struct StartFreeRideIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Start Free Ride"
    static let description = IntentDescription("Connects to your bike and streams the map to the dash, without a route.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = AppStatus.shared
        if let refusal = status.freeRideShortcutRefusal { return .result(dialog: "\(refusal)") }
        throw needsToContinueInForegroundError("Open TripperDash++ to start or continue your ride.") {
            status.startFreeRideFromShortcut()
        }
    }
}

/// Mid-navigation the new route replaces the running one in the background;
/// otherwise the app has to come forward to start the ride, which iOS asks
/// the rider to confirm. `ForegroundContinuableIntent` is deprecated in
/// iOS 26 for `supportedModes`, which needs iOS 26 — we target 18.6.
@MainActor
private func navigate<I: ForegroundContinuableIntent>(_ intent: I,
                                                      _ go: @escaping @MainActor () async -> String) async throws -> String {
    let status = AppStatus.shared
    // Refused straight away: deciding after go()'s await could see a ride
    // the rider's own plan just started, and redirect it.
    if status.handPlanStaged && !status.activeNavigator.isNavigating { return AppStatus.planStagedReply }
    if status.activeNavigator.isNavigating { return await go() }   // redirect, in the background
    throw intent.needsToContinueInForegroundError("Open TripperDash++ to start the ride.") {
        _ = await go()
    }
}

struct NavigateToFavoriteIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Navigate to Favorite"
    static let description = IntentDescription("Navigates to a favorite, such as Home or Work. Replaces the route of a running navigation.")
    static let openAppWhenRun = false

    @Parameter(title: "Favorite")
    var favorite: FavoriteEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = AppStatus.shared
        guard let fav = status.navigationStore.settings.favorites.first(where: { $0.id == favorite.id }) else {
            return .result(dialog: "That favorite no longer exists.")
        }
        let said = try await navigate(self) { await status.navigateFromShortcut(to: fav.asDestination) }
        return .result(dialog: "\(said)")
    }
}

struct RideSavedRouteIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Ride Saved Route"
    static let description = IntentDescription("Navigates a saved route, joining it at the nearest point if you're partway along. Replaces the route of a running navigation.")
    static let openAppWhenRun = false

    @Parameter(title: "Route")
    var route: SavedRouteEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = AppStatus.shared
        guard let saved = status.savedRoutesStore.route(id: route.id) else {
            return .result(dialog: "That route no longer exists.")
        }
        let said = try await navigate(self) { await status.navigateFromShortcut(to: saved) }
        return .result(dialog: "\(said)")
    }
}

struct NavigateToPlaceIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Navigate to Place"
    static let description = IntentDescription("Finds a place near you and navigates there after you confirm it. Replaces the route of a running navigation.")
    static let openAppWhenRun = false

    @Parameter(title: "Place", requestValueDialog: "Where to?")
    var place: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = AppStatus.shared
        guard let dest = await LocalSearchService().geocode(place, near: status.locationService.lastFix?.coordinate) else {
            return .result(dialog: "Couldn't find \(place).")
        }
        // The search may pick a different place than meant: name it before
        // acting. Starting a ride already asks to open the app, so ask once.
        let label = [dest.name, dest.addressLine].compactMap { $0 }.joined(separator: ", ")
        if status.handPlanStaged && !status.activeNavigator.isNavigating {
            return .result(dialog: "\(AppStatus.planStagedReply)")
        }
        if status.activeNavigator.isNavigating {
            // Arrival beat included: navigateFromShortcut answers "Just arrived" without asking.
            if !status.activeNavigator.hasArrived {
                try await requestConfirmation(dialog: "Reroute to \(label)?")
            }
            return .result(dialog: "\(await status.navigateFromShortcut(to: dest))")
        }
        throw needsToContinueInForegroundError("Open TripperDash++ to navigate to \(label)?") {
            _ = await status.navigateFromShortcut(to: dest)
        }
    }
}

struct StopRideIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Ride"
    static let description = IntentDescription("Stops navigation or a free ride.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(AppStatus.shared.stopRideFromShortcut())")
    }
}

struct RideStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Ride Status"
    static let description = IntentDescription("Tells the distance and arrival time left, or the free-ride distance so far.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(AppStatus.shared.rideStatusForShortcut())")
    }
}

// MARK: - Siri phrases

/// Siri phrases are English-only, like the rest of the app's UI. Every
/// phrase must name the app.
nonisolated struct TripperDashShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartFreeRideIntent(),
                    phrases: ["Start free ride with \(.applicationName)",
                              "Start a ride with \(.applicationName)"],
                    shortTitle: "Free Ride",
                    systemImageName: "map.fill")
        AppShortcut(intent: NavigateToFavoriteIntent(),
                    phrases: ["Navigate to \(\.$favorite) with \(.applicationName)",
                              "Ride to \(\.$favorite) with \(.applicationName)",
                              "Navigate to a favorite with \(.applicationName)"],
                    shortTitle: "Navigate to Favorite",
                    systemImageName: "star.fill")
        AppShortcut(intent: RideSavedRouteIntent(),
                    phrases: ["Ride \(\.$route) with \(.applicationName)",
                              "Ride a saved route with \(.applicationName)"],
                    shortTitle: "Ride Saved Route",
                    systemImageName: "point.topleft.down.to.point.bottomright.curvepath")
        AppShortcut(intent: NavigateToPlaceIntent(),
                    phrases: ["Navigate with \(.applicationName)",
                              "Find a place with \(.applicationName)"],
                    shortTitle: "Navigate to Place",
                    systemImageName: "magnifyingglass")
        AppShortcut(intent: StopRideIntent(),
                    phrases: ["Stop ride with \(.applicationName)",
                              "Stop \(.applicationName)"],
                    shortTitle: "Stop Ride",
                    systemImageName: "stop.circle.fill")
        AppShortcut(intent: RideStatusIntent(),
                    phrases: ["How far to go with \(.applicationName)",
                              "Ride status from \(.applicationName)"],
                    shortTitle: "Ride Status",
                    systemImageName: "gauge.with.dots.needle.33percent")
    }
}
