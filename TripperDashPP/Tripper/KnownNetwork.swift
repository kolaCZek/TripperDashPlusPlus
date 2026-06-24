//
//  KnownNetwork.swift
//  TripperDashPP
//
//  A saved Royal Enfield Tripper dash Wi-Fi network. The app keeps a
//  list of these so the rider never has to retype the dash SSID, and
//  (on a paid Apple Developer account) can join the dash AP straight
//  from the app instead of detouring through iOS Settings.
//
//  Why per-network passphrase instead of one global constant:
//  the Tripper AP ships with a well-known factory passphrase
//  (`12345678` — documented in the better-dash project and the factory
//  firmware, i.e. NOT a secret), but the owner CAN change it in the
//  Royal Enfield app. Storing it per-network (device-local, in
//  UserDefaults — never in the public repo) covers both: the field is
//  pre-filled with the factory default so the common case is zero-typing,
//  yet a rider who rekeyed their dash can still save the right value.
//
//  The dash IP is deliberately NOT stored here — it is fixed at
//  `192.168.1.1` (`K1G.bikeIPv4`) for every Tripper, so a per-network
//  host field would only be a footgun. The connection layer always
//  targets the fixed gateway.
//

import Foundation

struct KnownNetwork: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// The dash Wi-Fi SSID, e.g. `RE_1A2B3C`. Stored verbatim — SSIDs
    /// are case-sensitive and iOS matches them exactly.
    var ssid: String
    /// WPA passphrase. Defaults to the factory value; editable for
    /// dashes whose owner changed it. Lives only in on-device
    /// UserDefaults.
    var passphrase: String
    var createdAt: Date

    init(id: UUID = UUID(),
         ssid: String,
         passphrase: String = KnownNetwork.factoryPassphrase,
         createdAt: Date = .now) {
        self.id = id
        self.ssid = ssid
        self.passphrase = passphrase
        self.createdAt = createdAt
    }

    /// Well-known Royal Enfield Tripper factory AP passphrase. This is a
    /// published default (better-dash, factory firmware), not a credential
    /// — it is safe to ship in the open-source binary the same way the
    /// SSID prefix and gateway IP already are. Used only as the pre-filled
    /// default when adding a network; the stored value can be overridden
    /// per network.
    static let factoryPassphrase = "12345678"

    /// Trimmed, non-empty SSID or nil. Guards against a user saving a
    /// blank/whitespace row.
    var normalizedSSID: String? {
        let t = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
