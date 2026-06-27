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
//  a distinct, potentially large payload (each route is up to
//  `RoutePoint.navigableCap` points). Keeping them out of NavSettings
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

    /// Rename in place. No-op (logged) if the id is gone.
    func rename(id: UUID, to newName: String) {
        guard let idx = routes.firstIndex(where: { $0.id == id }) else {
            log.warning("rename: id not found \(id)")
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func route(id: UUID) -> SavedRoute? {
        routes.first { $0.id == id }
    }

    /// Routes most-recent-first for the list view.
    var sortedByNewest: [SavedRoute] {
        routes.sorted { $0.createdAt > $1.createdAt }
    }
}
