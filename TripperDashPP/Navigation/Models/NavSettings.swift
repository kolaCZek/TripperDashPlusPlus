//
//  NavSettings.swift
//  TripperDashPP
//
//  Phase 7 — persisted navigation state: route preferences + favorites
//  + which 4 favorites are pinned to Quick Access. Codable JSON in
//  UserDefaults under a single key, with a schemaVersion so we can
//  write one-shot migrators when the shape changes.
//

import Foundation

struct NavSettings: Codable, Sendable {
    /// Bump this when the shape changes incompatibly. NavigationStore
    /// runs migrators in `load()` on mismatch.
    var schemaVersion: Int = 1

    var favorites: [Favorite] = []

    /// Exactly four slots, identifying favorites by id. nil = empty
    /// slot. Length is enforced by NavigationStore on read/write.
    var quickAccessSlotIds: [UUID?] = [nil, nil, nil, nil]

    var avoidHighways: Bool = false
    var avoidTolls: Bool = false
}
