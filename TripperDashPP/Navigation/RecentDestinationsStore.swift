//
//  RecentDestinationsStore.swift
//  TripperDashPP
//
//  feat/search-history — main-actor owner of the recent-search list shown
//  in the destination search sheet before the rider types anything.
//
//  Mirrors SavedRoutesStore's shape: a Codable payload under a single
//  versioned UserDefaults key, tolerant decode that falls back to empty,
//  persistence on every mutation. Kept separate from NavigationStore so the
//  hot favorites/prefs blob stays small and a corrupt history can't take the
//  rider's Home/Work pins down with it.
//
//  We store our OWN record rather than `Destination` because Destination's
//  coordinate (CLLocationCoordinate2D) isn't Codable and Destination carries
//  a fresh UUID per instance — for de-duplication we want value identity
//  (name + coordinate), not reference identity.
//

import CoreLocation
import Foundation
import os

/// One remembered destination. Flat and Codable — lat/lon as plain doubles.
struct RecentDestination: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var addressLine: String?
    var latitude: Double
    var longitude: Double
    /// When it was last picked — drives recency ordering.
    var lastUsed: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Rebuild a routable Destination from history. A new UUID is fine —
    /// downstream identity is by coordinate, and the history id is only for
    /// the list.
    var destination: Destination {
        Destination(name: name, addressLine: addressLine, coordinate: coordinate)
    }

    init(from dest: Destination, lastUsed: Date = .now) {
        self.id = UUID()
        self.name = dest.name
        self.addressLine = dest.addressLine
        self.latitude = dest.coordinate.latitude
        self.longitude = dest.coordinate.longitude
        self.lastUsed = lastUsed
    }

    /// Two records are "the same place" if name + rounded coordinate match.
    /// Rounding to ~11 m (5 dp) absorbs the tiny coordinate jitter MapKit
    /// returns for the same POI across searches.
    func samePlace(as other: RecentDestination) -> Bool {
        name == other.name
            && (latitude * 1e5).rounded() == (other.latitude * 1e5).rounded()
            && (longitude * 1e5).rounded() == (other.longitude * 1e5).rounded()
    }
}

/// Codable envelope so the payload can be versioned independently.
struct RecentDestinationsPayload: Codable, Sendable {
    var schemaVersion: Int = 1
    var items: [RecentDestination] = []

    init(items: [RecentDestination] = []) {
        self.schemaVersion = 1
        self.items = items
    }
}

@MainActor
@Observable
final class RecentDestinationsStore {

    /// Most-recent-first, capped at `maxItems`.
    private(set) var items: [RecentDestination] = []

    /// Keep the list short — this is a convenience shortcut, not an archive.
    private let maxItems = 12

    private let defaults: UserDefaults
    private let storageKey = "RecentDestinationsStore.v1"
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "RecentDestinations")

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.items = load()?.items ?? []
    }

    // MARK: - Persistence

    private func load() -> RecentDestinationsPayload? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(RecentDestinationsPayload.self, from: data)
            log.info("Loaded \(decoded.items.count) recent destination(s) (v\(decoded.schemaVersion))")
            return decoded
        } catch {
            log.error("Failed to decode recent destinations: \(error.localizedDescription, privacy: .public) — starting empty")
            return nil
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(RecentDestinationsPayload(items: items))
            defaults.set(data, forKey: storageKey)
        } catch {
            log.error("Failed to persist recent destinations: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Mutation

    /// Record a picked destination. De-duplicates against the same place
    /// (moving it to the top and refreshing its timestamp) and trims to the
    /// cap. Called from the search sheet whenever a result is chosen.
    func record(_ dest: Destination) {
        var entry = RecentDestination(from: dest)
        // Drop any existing record for the same place; the new one goes on top.
        if let existing = items.first(where: { $0.samePlace(as: entry) }) {
            entry.id = existing.id   // keep a stable list id across re-picks
            items.removeAll { $0.samePlace(as: entry) }
        }
        items.insert(entry, at: 0)
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
        persist()
    }

    /// Remove one entry (swipe-to-delete in the list).
    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Clear the whole history.
    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        persist()
    }
}
