//
//  NavigationStore.swift
//  TripperDashPP
//
//  Phase 7d — main-actor owner of NavSettings. Handles persistence,
//  favorites CRUD, quick-access slot management. UI observes it via
//  @Environment(NavigationStore.self).
//
//  Why a separate store (not a property on AppStatus): AppStatus is
//  already big (bike link, location, streaming pipeline, wakelock).
//  Navigation is a wholly separate concern that doesn't touch the
//  streaming path. Keeping them apart means MapPickerView can be
//  reasoned about without dragging the whole transport pipeline.
//

import Foundation
import os
import SwiftUI

@MainActor
@Observable
final class NavigationStore {

    private(set) var settings: NavSettings = NavSettings()

    private let defaults: UserDefaults
    private let storageKey = "NavigationStore.settings.v1"
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "NavigationStore")

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = load() ?? NavSettings()
        // Enforce slot invariant (always exactly 4 entries) in case a
        // hand-edited or migrated payload arrives malformed.
        normaliseSlots()
    }

    // MARK: - Persistence

    private func load() -> NavSettings? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(NavSettings.self, from: data)
            log.info("Loaded NavSettings (v\(decoded.schemaVersion), \(decoded.favorites.count) favorites)")
            return decoded
        } catch {
            log.error("Failed to decode NavSettings: \(error.localizedDescription, privacy: .public) — falling back to defaults")
            return nil
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: storageKey)
        } catch {
            log.error("Failed to persist NavSettings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func normaliseSlots() {
        var slots = settings.quickAccessSlotIds
        if slots.count < 4 {
            slots.append(contentsOf: Array(repeating: nil, count: 4 - slots.count))
        } else if slots.count > 4 {
            slots = Array(slots.prefix(4))
        }
        // Drop slot references to deleted favorites.
        let existingIds = Set(settings.favorites.map(\.id))
        slots = slots.map { id in (id.flatMap { existingIds.contains($0) ? $0 : nil }) }
        settings.quickAccessSlotIds = slots
    }

    // MARK: - Favorites CRUD

    /// Insert at end. Returns the newly-created favorite (includes id).
    @discardableResult
    func addFavorite(_ fav: Favorite, pinToQuickAccess: Bool = false) -> Favorite {
        settings.favorites.append(fav)
        if pinToQuickAccess {
            assignToFirstFreeSlot(fav.id)
        }
        persist()
        return fav
    }

    func updateFavorite(_ updated: Favorite) {
        guard let idx = settings.favorites.firstIndex(where: { $0.id == updated.id }) else {
            log.warning("updateFavorite: id not found \(updated.id)")
            return
        }
        settings.favorites[idx] = updated
        persist()
    }

    func removeFavorite(id: UUID) {
        settings.favorites.removeAll { $0.id == id }
        // Clear any slot pointing at it.
        for i in settings.quickAccessSlotIds.indices {
            if settings.quickAccessSlotIds[i] == id {
                settings.quickAccessSlotIds[i] = nil
            }
        }
        persist()
    }

    // MARK: - Quick-access slots

    /// Place a favorite into a specific slot (0…3). Pass nil to clear.
    /// If the favorite is already in another slot, it's moved (no
    /// duplicate slot assignments).
    func setQuickAccessSlot(_ slot: Int, favoriteId: UUID?) {
        guard (0..<4).contains(slot) else { return }
        if let favId = favoriteId {
            for i in settings.quickAccessSlotIds.indices where settings.quickAccessSlotIds[i] == favId {
                settings.quickAccessSlotIds[i] = nil
            }
        }
        settings.quickAccessSlotIds[slot] = favoriteId
        persist()
    }

    /// Returns the favorite for a given slot (0…3), nil if empty or
    /// the referenced favorite no longer exists.
    func favoriteAtSlot(_ slot: Int) -> Favorite? {
        guard (0..<4).contains(slot),
              let id = settings.quickAccessSlotIds[slot]
        else { return nil }
        return settings.favorites.first { $0.id == id }
    }

    /// Favorites that are NOT in any quick-access slot. Used by the
    /// "Others" list under the tiles.
    var otherFavorites: [Favorite] {
        let pinned = Set(settings.quickAccessSlotIds.compactMap { $0 })
        return settings.favorites.filter { !pinned.contains($0.id) }
    }

    private func assignToFirstFreeSlot(_ id: UUID) {
        for i in settings.quickAccessSlotIds.indices {
            if settings.quickAccessSlotIds[i] == nil {
                settings.quickAccessSlotIds[i] = id
                return
            }
        }
        // All slots full — leave it in the Others list.
    }

    // MARK: - Route preferences

    func setAvoidHighways(_ v: Bool) { settings.avoidHighways = v; persist() }
    func setAvoidTolls(_ v: Bool)    { settings.avoidTolls = v;    persist() }

    /// Convenience for RoutingService.
    var routePreferences: RoutePreferences {
        RoutePreferences(avoidHighways: settings.avoidHighways,
                         avoidTolls: settings.avoidTolls)
    }
}

/// Bag of route prefs handed to RoutingService.
struct RoutePreferences: Sendable, Equatable {
    var avoidHighways: Bool
    var avoidTolls: Bool
}
