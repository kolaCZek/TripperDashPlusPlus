//
//  WiFiJoiner.swift
//  TripperDashPP
//
//  Joins the phone to a Tripper's Wi-Fi AP from inside the app, so the rider
//  doesn't have to leave for iOS Settings. Wraps NEHotspotConfigurationManager
//  (NetworkExtension).
//
//  ENTITLEMENT: this requires `com.apple.developer.networking.HotspotConfiguration`,
//  which is a PAID Apple Developer Program capability. The rest of the app runs
//  on a free Personal Team, but this feature does not — see CLAUDE.md.
//
//  Tripper APs all use the same fixed passphrase ("12345678", WPA2) and the
//  same gateway (192.168.1.1). We register the network (persisted, not
//  join-once) so iOS keeps auto-joining it on later rides, and we can also
//  force a join on demand right before connecting to the dash.
//

import Foundation
import NetworkExtension
import os

/// Result of a join attempt, so callers can tell "already there" from "just
/// joined" from a real failure.
enum WiFiJoinOutcome: Sendable, Equatable {
    case alreadyJoined      // phone was already on this SSID
    case joined             // we successfully joined it
    case failed(String)     // join failed (reason for logging/UI)
}

/// Thin async wrapper over NEHotspotConfigurationManager. All Tripper APs share
/// one WPA2 passphrase, so callers only pass the SSID.
@MainActor
final class WiFiJoiner {

    /// The fixed passphrase every Tripper AP ships with.
    static let tripperPassphrase = "12345678"

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "WiFiJoiner")

    /// Register a Tripper network with iOS so it's known and auto-joined on
    /// future rides. Persisted (joinOnce = false). Applying a configuration
    /// for an SSID that's already registered is a harmless no-op refresh.
    ///
    /// Called when the rider adds a bike, so the network is set up ahead of
    /// the first connect — exactly the "save the Wi-Fi too" behaviour.
    @discardableResult
    func register(ssid: String) async -> WiFiJoinOutcome {
        await apply(ssid: ssid)
    }

    /// Ensure the phone is on `ssid`, joining it if necessary. If we're already
    /// on that network, returns `.alreadyJoined` without touching the radio.
    /// Otherwise applies the configuration (which also joins) and returns
    /// `.joined` / `.failed`.
    @discardableResult
    func ensureJoined(ssid: String) async -> WiFiJoinOutcome {
        if await currentSSID() == ssid {
            log.info("Already on \(ssid, privacy: .public) — no join needed")
            return .alreadyJoined
        }
        return await apply(ssid: ssid)
    }

    /// The SSID of the Wi-Fi network the phone is currently on, or nil when
    /// not on Wi-Fi / the SSID can't be read (needs Location permission, which
    /// the app already holds for navigation).
    func currentSSID() async -> String? {
        await withCheckedContinuation { cont in
            NEHotspotNetwork.fetchCurrent { network in
                cont.resume(returning: network?.ssid)
            }
        }
    }

    /// Apply (and thereby join) a Tripper hotspot configuration for `ssid`.
    private func apply(ssid: String) async -> WiFiJoinOutcome {
        let config = NEHotspotConfiguration(ssid: ssid,
                                            passphrase: Self.tripperPassphrase,
                                            isWEP: false)
        config.joinOnce = false // persist so iOS auto-joins on later rides

        return await withCheckedContinuation { cont in
            NEHotspotConfigurationManager.shared.apply(config) { error in
                if let error = error as NSError? {
                    // "already associated" is success, not a failure: iOS
                    // returns it when the phone is already on the network.
                    if error.domain == NEHotspotConfigurationErrorDomain,
                       error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        self.log.info("Already associated with \(ssid, privacy: .public)")
                        cont.resume(returning: .alreadyJoined)
                        return
                    }
                    self.log.error("Join \(ssid, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    cont.resume(returning: .failed(error.localizedDescription))
                    return
                }
                self.log.info("Joined \(ssid, privacy: .public)")
                cont.resume(returning: .joined)
            }
        }
    }

    /// Remove a Tripper network from iOS's known list (called when the rider
    /// deletes a bike, so we don't leave orphan Wi-Fi configs behind).
    func unregister(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        log.info("Removed Wi-Fi configuration for \(ssid, privacy: .public)")
    }
}
