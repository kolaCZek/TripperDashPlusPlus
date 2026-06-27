//
//  NavigationStore.swift
//  TripperDashPP
//
//  Phase 7d — main-actor owner of NavSettings. Handles persistence,
//  favorites CRUD, fixed-pin quick-access slot management. UI observes
//  it via @Environment(NavigationStore.self).
//
//  Quick Access redesign (Phase 7g — June 2026): the v1 free-form
//  4-slot system was replaced by exactly two hard-coded pinned slots,
//  Home and Work. Names and icons are fixed (house.fill / briefcase.fill),
//  the user just picks the coordinate. Everything else lives in the
//  `Others` list as a regular favorite with a user-chosen name + icon.
//
//  Why a separate store (not a property on AppStatus): AppStatus is
//  already big (bike link, location, streaming pipeline, wakelock).
//  Navigation is a wholly separate concern that doesn't touch the
//  streaming path.
//

import CoreLocation
import Foundation
import os
import SwiftUI

/// Identifies one of the two fixed pinned quick-access slots.
enum QuickAccessSlot: String, CaseIterable, Sendable {
    case home
    case work

    /// Display label shown in tile + editor sheets. Hard-coded: the
    /// user does NOT get to rename a pinned slot.
    var displayName: String {
        switch self {
        case .home: "Home"
        case .work: "Work"
        }
    }

    /// SF Symbol shown in the tile. Hard-coded.
    var iconSymbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        }
    }
}

@MainActor
@Observable
final class NavigationStore {

    private(set) var settings: NavSettings = NavSettings()

    private let defaults: UserDefaults
    private let storageKey = "NavigationStore.settings.v1"  // key kept stable across schema bumps
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "NavigationStore")

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = load() ?? NavSettings()
        // Drop dangling pin references to deleted favorites (e.g.
        // hand-edited payload or a crash mid-delete).
        prunePinnedRefs()
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

    private func prunePinnedRefs() {
        let existing = Set(settings.favorites.map(\.id))
        if let h = settings.pinnedHomeId, !existing.contains(h) { settings.pinnedHomeId = nil }
        if let w = settings.pinnedWorkId, !existing.contains(w) { settings.pinnedWorkId = nil }
    }

    // MARK: - Favorites CRUD

    /// Insert at end. Returns the newly-created favorite (includes id).
    @discardableResult
    func addFavorite(_ fav: Favorite) -> Favorite {
        settings.favorites.append(fav)
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
        // Clear any pin pointing at it.
        if settings.pinnedHomeId == id { settings.pinnedHomeId = nil }
        if settings.pinnedWorkId == id { settings.pinnedWorkId = nil }
        persist()
    }

    // MARK: - Quick Access (fixed Home/Work)

    /// Favorite pinned to a slot (or nil if empty).
    func favorite(in slot: QuickAccessSlot) -> Favorite? {
        let id: UUID?
        switch slot {
        case .home: id = settings.pinnedHomeId
        case .work: id = settings.pinnedWorkId
        }
        return id.flatMap { fid in settings.favorites.first { $0.id == fid } }
    }

    /// Fill a quick-access slot from a search result. Creates a fresh
    /// Favorite with the slot's fixed name + icon, replacing whatever
    /// was previously pinned there (the old one becomes a regular
    /// favorite available in the Others list — or, if it was created
    /// purely as a pin, the caller can decide to remove it).
    ///
    /// The fixed-name/icon design means we never reuse an existing
    /// favorite for the Home/Work pin — each slot owns its own Favorite
    /// record so the user can move a pin around (e.g. set a temporary
    /// Home while travelling) without renaming what's in the Others
    /// list.
    @discardableResult
    func setQuickAccess(_ slot: QuickAccessSlot, from destination: Destination) -> Favorite {
        // Drop the previous pin (it was slot-owned, no point keeping it).
        if let oldId = pinnedId(for: slot) {
            settings.favorites.removeAll { $0.id == oldId }
        }
        let fav = Favorite(
            name: slot.displayName,
            iconSymbol: slot.iconSymbol,
            coordinate: destination.coordinate,
            addressLine: destination.addressLine
        )
        settings.favorites.append(fav)
        switch slot {
        case .home: settings.pinnedHomeId = fav.id
        case .work: settings.pinnedWorkId = fav.id
        }
        persist()
        return fav
    }

    /// Unpin and delete the favorite in the given slot. Tile becomes
    /// empty again.
    func clearQuickAccess(_ slot: QuickAccessSlot) {
        if let id = pinnedId(for: slot) {
            settings.favorites.removeAll { $0.id == id }
        }
        switch slot {
        case .home: settings.pinnedHomeId = nil
        case .work: settings.pinnedWorkId = nil
        }
        persist()
    }

    private func pinnedId(for slot: QuickAccessSlot) -> UUID? {
        switch slot {
        case .home: settings.pinnedHomeId
        case .work: settings.pinnedWorkId
        }
    }

    /// Favorites that are NOT pinned to a quick-access slot. Used by
    /// the "Others" list under the tiles.
    var otherFavorites: [Favorite] {
        let pinned: Set<UUID> = [settings.pinnedHomeId, settings.pinnedWorkId].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
        return settings.favorites.filter { !pinned.contains($0.id) }
    }

    // MARK: - Favorite membership

    /// Whether a destination is already saved as a favorite (pinned or
    /// in the Others list). Used to hide the "Add to favorites" action in
    /// the preview card when it would be a no-op.
    ///
    /// Matches first by stable id (a favorite tapped via QuickAccess /
    /// Others carries its own UUID through `asDestination`), then falls
    /// back to coordinate proximity (~25 m) so a freshly searched or
    /// tapped point that happens to sit on an existing favorite is still
    /// recognised. Proximity uses equirectangular metres — cheap and
    /// plenty accurate at city scale.
    func isFavorited(_ destination: Destination) -> Bool {
        matchingFavorite(for: destination) != nil
    }

    /// The favorite matching this destination by id or proximity, if any.
    func matchingFavorite(for destination: Destination) -> Favorite? {
        if let byId = settings.favorites.first(where: { $0.id == destination.id }) {
            return byId
        }
        let c = destination.coordinate
        return settings.favorites.first { fav in
            Self.metersBetween(fav.coordinate, c) < 25
        }
    }

    /// Equirectangular-approximation distance in metres. Adequate for the
    /// short distances (<1 km) this is used for.
    private static func metersBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let earth = 6_371_000.0
        let latRad = (a.latitude + b.latitude) / 2 * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let x = dLon * cos(latRad)
        return earth * (x * x + dLat * dLat).squareRoot()
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
