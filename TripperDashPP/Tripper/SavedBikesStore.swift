//
//  SavedBikesStore.swift
//  TripperDashPP
//
//  The rider's "garage": a managed list of bikes, each identified by its
//  Tripper AP Wi-Fi SSID (RE_XXXX_XXXXX). Replaces the single free-text SSID
//  field in the Connection settings — the rider adds/removes bikes and picks
//  which one to connect to.
//
//  Mirrors RecentDestinationsStore's shape: a Codable envelope under a single
//  versioned UserDefaults key, tolerant decode that falls back to empty, and
//  persistence on every mutation. Kept separate from other stores so a corrupt
//  garage can't take unrelated prefs down with it.
//
//  The dash IP is intentionally NOT stored per bike — every Tripper AP hands
//  the phone the same gateway (192.168.1.1 = K1G.bikeIPv4), so it's a global
//  constant, not a per-bike setting.
//

import Foundation
import os

/// One bike in the garage. Flat and Codable. `name` is the rider-facing
/// label shown everywhere (e.g. "Guerrilla"); `ssid` is the Tripper AP
/// Wi-Fi network used to connect. `name` decodes tolerantly so older
/// records written before names existed still load (falling back to the
/// SSID via `displayName`).
struct SavedBike: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var ssid: String
    var addedAt: Date

    /// What to show in lists/banners: the rider's name, or the SSID when
    /// the name is empty (legacy records / not yet named).
    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ssid : name
    }

    init(name: String, ssid: String, addedAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.ssid = ssid
        self.addedAt = addedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.ssid = try c.decode(String.self, forKey: .ssid)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? .now
    }
}

/// Codable envelope so the payload can be versioned independently.
struct SavedBikesPayload: Codable, Sendable {
    var schemaVersion: Int = 1
    var bikes: [SavedBike] = []
    var selectedID: UUID?

    init(bikes: [SavedBike] = [], selectedID: UUID? = nil) {
        self.schemaVersion = 1
        self.bikes = bikes
        self.selectedID = selectedID
    }
}

@MainActor
@Observable
final class SavedBikesStore {

    /// The saved bikes, in insertion order (oldest first).
    private(set) var bikes: [SavedBike] = []

    /// The currently-active bike — the one Connect targets and the banner
    /// names. nil only when the garage is empty.
    private(set) var selectedID: UUID?

    private let defaults: UserDefaults
    private let storageKey = "SavedBikes.v1"
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "SavedBikes")

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let payload = load() {
            self.bikes = payload.bikes
            // Guard against a dangling selectedID (e.g. hand-edited defaults):
            // fall back to the first bike if the stored selection is gone.
            if let sel = payload.selectedID, payload.bikes.contains(where: { $0.id == sel }) {
                self.selectedID = sel
            } else {
                self.selectedID = payload.bikes.first?.id
            }
        }
    }

    // MARK: - Derived

    /// The active bike, or nil when the garage is empty.
    var selected: SavedBike? {
        guard let selectedID else { return nil }
        return bikes.first { $0.id == selectedID }
    }

    // MARK: - Persistence

    private func load() -> SavedBikesPayload? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(SavedBikesPayload.self, from: data)
            log.info("Loaded \(decoded.bikes.count) saved bike(s) (v\(decoded.schemaVersion))")
            return decoded
        } catch {
            log.error("Failed to decode saved bikes: \(error.localizedDescription, privacy: .public) — starting empty")
            return nil
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(SavedBikesPayload(bikes: bikes, selectedID: selectedID))
            defaults.set(data, forKey: storageKey)
        } catch {
            log.error("Failed to persist saved bikes: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Mutation

    /// Add a bike with a rider-facing name + its Wi-Fi SSID. Trims both,
    /// ignores an empty SSID, and de-duplicates case-insensitively by SSID
    /// (adding an existing network just re-selects that bike, and refreshes
    /// its name if a non-empty one was given). The first bike added becomes
    /// the active one. Returns the resulting bike (new or existing).
    @discardableResult
    func add(name rawName: String, ssid rawSSID: String) -> SavedBike? {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { return nil }

        // Already in the garage (same network)? Re-select it, update its name.
        if let idx = bikes.firstIndex(where: { $0.ssid.caseInsensitiveCompare(ssid) == .orderedSame }) {
            if !name.isEmpty { bikes[idx].name = name }
            selectedID = bikes[idx].id
            persist()
            return bikes[idx]
        }

        let bike = SavedBike(name: name, ssid: ssid)
        bikes.append(bike)
        if selectedID == nil { selectedID = bike.id } // first bike is active
        persist()
        return bike
    }

    /// Remove a bike (swipe-to-delete). If it was the active one, selection
    /// falls to the first remaining bike (or nil when the garage is emptied).
    func remove(id: UUID) {
        bikes.removeAll { $0.id == id }
        if selectedID == id { selectedID = bikes.first?.id }
        persist()
    }

    /// Make a bike active (rider tapped its Connect row / picked it).
    func select(id: UUID) {
        guard bikes.contains(where: { $0.id == id }) else { return }
        selectedID = id
        persist()
    }
}
