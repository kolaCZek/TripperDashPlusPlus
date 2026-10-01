//
//  SavedRoutesStore.swift
//  TripperDashPP
//
//  feat/saved-routes-gpx — main-actor owner of the imported-route
//  library. Mirrors NavigationStore's shape exactly: Codable payload in
//  UserDefaults under a single versioned key, CRUD that persists on
//  every mutation, tolerant decode that falls back to empty rather than
//  throwing. UI observes it via @Environment(SavedRoutesStore.self).
//
//  Why a separate store (not folded into NavSettings): saved routes are
//  a distinct, potentially large payload (a `.track` route keeps its
//  full-precision trace — potentially thousands of points). Keeping them out of NavSettings
//  means the hot favorites/prefs blob stays small and a corrupt route
//  library can't take the rider's Home/Work pins down with it.
//

import CoreLocation
import Foundation
import os

/// Codable envelope so we can version the route-library payload
/// independently of NavSettings.
struct SavedRoutesPayload: Codable, Sendable {
    var schemaVersion: Int = 1
    var routes: [SavedRoute] = []

    init(routes: [SavedRoute] = []) {
        self.schemaVersion = 1
        self.routes = routes
    }
}

@MainActor
@Observable
final class SavedRoutesStore {

    private(set) var routes: [SavedRoute] = []

    private let defaults: UserDefaults
    private let storageKey = "SavedRoutesStore.v1"
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "SavedRoutesStore")

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.routes = load()?.routes ?? []
    }

    // MARK: - Persistence

    private func load() -> SavedRoutesPayload? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(SavedRoutesPayload.self, from: data)
            log.info("Loaded \(decoded.routes.count) saved route(s) (v\(decoded.schemaVersion))")
            return decoded
        } catch {
            log.error("Failed to decode saved routes: \(error.localizedDescription, privacy: .public) — starting empty")
            return nil
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(SavedRoutesPayload(routes: routes))
            defaults.set(data, forKey: storageKey)
        } catch {
            log.error("Failed to persist saved routes: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - CRUD

    /// Append a freshly-imported route. Returns the stored value.
    @discardableResult
    func add(_ route: SavedRoute) -> SavedRoute {
        routes.append(route)
        persist()
        return route
    }

    /// Overwrite a route with a new version of itself (planner re-save),
    /// keeping its id and createdAt. nil if the id is gone.
    @discardableResult
    func replace(id: UUID, with route: SavedRoute) -> SavedRoute? {
        guard let idx = routes.firstIndex(where: { $0.id == id }) else { return nil }
        let old = routes[idx]
        routes[idx] = SavedRoute(id: id,
                                 name: route.name,
                                 kind: route.kind,
                                 points: route.points,
                                 totalDistanceMeters: route.totalDistanceMeters,
                                 sourceFilename: route.sourceFilename,
                                 createdAt: old.createdAt)
        persist()
        return routes[idx]
    }

    /// Planner save: store `route` under `name` (`cleanName`; blank keeps
    /// the route's automatic name), overwriting `id` if it's still in the
    /// library (keeps id + createdAt), else adding it.
    @discardableResult
    func save(_ route: SavedRoute, named name: String, replacing id: UUID?) -> SavedRoute {
        var route = route
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The unedited automatic name stays whole: capped (or trimmed, if a
        // stop label has a stray blank), it would no longer match
        // `automaticName` and stick to changed stops as "custom".
        if !typed.isEmpty, typed != route.name.trimmingCharacters(in: .whitespacesAndNewlines) {
            route.name = Self.cleanName(typed)
        }
        if let id, let updated = replace(id: id, with: route) { return updated }
        return add(route)
    }

    /// A pasted essay would wreck the library rows and the detail title.
    static let maxNameLength = 80

    /// Trimmed and capped at `maxNameLength` (re-trimmed, so a cut at a
    /// space leaves no trailing blank). `prefix` counts Characters, so an
    /// emoji or accented letter is never split.
    static func cleanName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rename in place. No-op (logged) if the id is gone.
    func rename(id: UUID, to newName: String) {
        guard let idx = routes.firstIndex(where: { $0.id == id }) else {
            log.warning("rename: id not found \(id)")
            return
        }
        let trimmed = Self.cleanName(newName)
        routes[idx].name = trimmed.isEmpty ? routes[idx].name : trimmed
        persist()
    }

    func remove(id: UUID) {
        routes.removeAll { $0.id == id }
        persist()
    }

    /// Replace a route's ordered points (used by the detail editor:
    /// reorder / delete individual points). Recomputes the stored
    /// distance from the new geometry and no-ops if the id is gone or the
    /// edit would leave fewer than 2 points (a route needs a start + end).
    func updatePoints(id: UUID, points: [RoutePoint]) {
        guard let idx = routes.firstIndex(where: { $0.id == id }) else {
            log.warning("updatePoints: id not found \(id)")
            return
        }
        guard points.count >= 2 else {
            log.warning("updatePoints: refusing to leave <2 points")
            return
        }
        routes[idx].points = points
        routes[idx].totalDistanceMeters =
            GPXGeometry.pathLength(points.map(\.coordinate))
        persist()
    }

    /// Store a routed (road) distance for a route, but only if its points are
    /// still `points`: a later edit already wrote its own straight-line figure.
    func setRoadDistance(id: UUID, meters: Double, forPoints points: [RoutePoint]) {
        guard let idx = routes.firstIndex(where: { $0.id == id }),
              routes[idx].points == points else { return }
        routes[idx].totalDistanceMeters = meters
        persist()
    }

    func route(id: UUID) -> SavedRoute? {
        routes.first { $0.id == id }
    }

    /// Routes most-recent-first for the list view.
    var sortedByNewest: [SavedRoute] {
        routes.sorted { $0.createdAt > $1.createdAt }
    }
}
