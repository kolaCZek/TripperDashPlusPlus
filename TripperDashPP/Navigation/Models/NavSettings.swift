//
//  NavSettings.swift
//  TripperDashPP
//
//  Phase 7 — persisted navigation state: route preferences + favorites
//  + which favorites are pinned to the fixed Home/Work quick-access
//  slots. Codable JSON in UserDefaults under a single key, with a
//  schemaVersion so we can write one-shot migrators when the shape
//  changes.
//
//  Schema history:
//   - v1: `quickAccessSlotIds: [UUID?]` of length 4 (free-form pinning
//         with user-chosen names/icons).
//   - v2: `pinnedHomeId` / `pinnedWorkId` — exactly two hard-coded
//         pinned slots with fixed names ("Home", "Work") and fixed
//         icons (house.fill, briefcase.fill). NavigationStore migrates
//         v1 → v2 on load: first two non-nil v1 slots become Home/Work
//         in that order; the rest fall back into the unpinned list.
//

import Foundation

struct NavSettings: Codable, Sendable {
    /// Bump this when the shape changes incompatibly. NavigationStore
    /// runs migrators in `load()` on mismatch.
    var schemaVersion: Int = 2

    var favorites: [Favorite] = []

    /// Pinned Home slot (top-of-screen, fixed name + house icon).
    /// `nil` = empty slot, tap opens search to fill it.
    var pinnedHomeId: UUID?

    /// Pinned Work slot (top-of-screen, fixed name + briefcase icon).
    var pinnedWorkId: UUID?

    var avoidHighways: Bool = false
    var avoidTolls: Bool = false

    // MARK: - Custom decoding (v1 → v2 migration)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, favorites, pinnedHomeId, pinnedWorkId,
             avoidHighways, avoidTolls,
             // legacy v1
             quickAccessSlotIds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        self.schemaVersion = 2  // we always normalise on the way in
        self.favorites = (try? c.decode([Favorite].self, forKey: .favorites)) ?? []
        self.avoidHighways = (try? c.decode(Bool.self, forKey: .avoidHighways)) ?? false
        self.avoidTolls = (try? c.decode(Bool.self, forKey: .avoidTolls)) ?? false

        if version >= 2 {
            self.pinnedHomeId = try? c.decode(UUID?.self, forKey: .pinnedHomeId)
            self.pinnedWorkId = try? c.decode(UUID?.self, forKey: .pinnedWorkId)
        } else {
            // v1 migration: take the first two non-nil legacy slot ids
            // as Home/Work, in that order.
            let legacy = (try? c.decode([UUID?].self, forKey: .quickAccessSlotIds)) ?? []
            let nonNil = legacy.compactMap { $0 }
            self.pinnedHomeId = nonNil.indices.contains(0) ? nonNil[0] : nil
            self.pinnedWorkId = nonNil.indices.contains(1) ? nonNil[1] : nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(favorites, forKey: .favorites)
        try c.encode(pinnedHomeId, forKey: .pinnedHomeId)
        try c.encode(pinnedWorkId, forKey: .pinnedWorkId)
        try c.encode(avoidHighways, forKey: .avoidHighways)
        try c.encode(avoidTolls, forKey: .avoidTolls)
    }
}
