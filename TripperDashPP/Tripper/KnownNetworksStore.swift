//
//  KnownNetworksStore.swift
//  TripperDashPP
//
//  Main-actor owner of the saved dash Wi-Fi list. Handles persistence
//  (UserDefaults JSON blob) and CRUD. UI observes it via
//  `@Environment(KnownNetworksStore.self)` / through AppStatus.
//
//  Why a dedicated store (not a property bag on BikeLink): the network
//  list is UI-facing config that outlives any single connection and is
//  edited from Settings, whereas BikeLink is the live connection state
//  machine. Keeping them apart mirrors the NavigationStore/BikeLink
//  split already used elsewhere in the app.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class KnownNetworksStore {

    private(set) var networks: [KnownNetwork] = []

    private let defaults: UserDefaults
    private let storageKey = "KnownNetworksStore.v1"
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "KnownNetworksStore")

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.networks = load() ?? []
        migrateLegacySSIDIfNeeded()
    }

    // MARK: - Persistence

    private func load() -> [KnownNetwork]? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            let decoded = try JSONDecoder().decode([KnownNetwork].self, from: data)
            log.info("Loaded \(decoded.count) known network(s)")
            return decoded
        } catch {
            log.error("Failed to decode known networks: \(error.localizedDescription, privacy: .public) — starting empty")
            return nil
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(networks)
            defaults.set(data, forKey: storageKey)
        } catch {
            log.error("Failed to persist known networks: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-time migration: earlier builds stored a single SSID under the
    /// `BikeLink.ssid` UserDefaults key and a free-form text field in
    /// Settings. If the user had dialed in a real SSID there and has no
    /// saved list yet, seed the list with it so the upgrade is seamless.
    /// The dev placeholder (`RE_FAKE_…`) is intentionally skipped.
    private func migrateLegacySSIDIfNeeded() {
        guard networks.isEmpty else { return }
        let legacyKey = "BikeLink.ssid"
        guard let legacy = defaults.string(forKey: legacyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacy.isEmpty,
              !legacy.hasPrefix("RE_FAKE_") else { return }
        let seeded = KnownNetwork(ssid: legacy)
        networks = [seeded]
        persist()
        log.info("Migrated legacy SSID '\(legacy, privacy: .public)' into known-networks list")
    }

    // MARK: - CRUD

    /// True if an SSID (case-sensitive, trimmed) is already saved.
    func contains(ssid: String) -> Bool {
        let t = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        return networks.contains { $0.ssid == t }
    }

    /// Add a network. No-ops (returns the existing one) if the SSID is
    /// already saved, so the Add dialog and auto-seed can't create dupes.
    @discardableResult
    func add(ssid: String, passphrase: String = KnownNetwork.factoryPassphrase) -> KnownNetwork? {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = networks.first(where: { $0.ssid == trimmed }) {
            return existing
        }
        let net = KnownNetwork(ssid: trimmed, passphrase: passphrase)
        networks.append(net)
        persist()
        return net
    }

    func remove(id: UUID) {
        networks.removeAll { $0.id == id }
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        networks.remove(atOffsets: offsets)
        persist()
    }

    func update(_ network: KnownNetwork) {
        guard let idx = networks.firstIndex(where: { $0.id == network.id }) else { return }
        networks[idx] = network
        persist()
    }

    // MARK: - Queries used by the connect flow

    var isEmpty: Bool { networks.isEmpty }
    var count: Int { networks.count }
    /// Convenience for the single-network fast path in the connect button.
    var sole: KnownNetwork? { networks.count == 1 ? networks.first : nil }
}
