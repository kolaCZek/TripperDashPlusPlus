//
//  WiFiManager.swift
//  TripperDashPP
//
//  Thin wrapper around the two NetworkExtension capabilities used to
//  read and configure the dash Wi-Fi from inside the app:
//
//    • NEHotspotNetwork.fetchCurrent  → read the connected SSID
//        (entitlement: com.apple.developer.networking.wifi-info)
//    • NEHotspotConfigurationManager  → join / forget a network
//        (entitlement: com.apple.developer.networking.HotspotConfiguration)
//
//  ── IMPORTANT: paid Apple Developer Program requirement ──────────────
//  BOTH entitlements are PAID-ONLY. They cannot be enabled on a free
//  Personal Team — Apple's provisioning service refuses to issue a
//  profile containing them, so a build that DECLARES them fails to sign.
//  See docs/WIFI_MANAGEMENT.md for the one-time activation steps.
//
//  This wrapper is written so the app still COMPILES AND RUNS on a free
//  account with the entitlements absent: the NetworkExtension framework
//  is always linkable, and the APIs degrade at runtime rather than
//  crashing —
//    • fetchCurrent → calls back with nil  ⇒ currentSSID() returns nil
//    • apply(config) → calls back with an error ⇒ join() returns .failed
//  So on a free account: the SSID never reads (no green dots, auto-detect
//  is inert) and in-app join surfaces a friendly error. The moment the
//  entitlements are added on a paid account, every path lights up with no
//  code change. The manual UDP "connect to dash" handshake (BikeLink)
//  needs NEITHER entitlement and keeps working regardless.
//

import Foundation
import NetworkExtension
import os

@MainActor
@Observable
final class WiFiManager {

    /// Outcome of an in-app join attempt.
    enum JoinResult: Equatable, Sendable {
        /// iOS reports the device is now associated to the target SSID.
        /// NOTE: association ≠ a working dash link. The Tripper AP has no
        /// internet; the real proof is BikeLink's UDP handshake, which the
        /// caller runs next. This only means "Wi-Fi layer joined".
        case joined
        /// Device was already associated to the target SSID (treated as
        /// success — `apply` returns `.alreadyAssociated`).
        case alreadyConnected
        /// User dismissed the system "Join Wi-Fi?" confirmation.
        case userCancelled
        /// The join failed. `reason` is a short human-readable string.
        /// On a free account (missing entitlement) the join lands here.
        case failed(reason: String)
    }

    /// Last SSID we successfully read, surfaced for the UI. `nil` until the
    /// first successful `currentSSID()` — also stays `nil` forever on a
    /// free account where the read isn't permitted.
    private(set) var lastReadSSID: String?

    /// Flips `true` the first time `currentSSID()` returns a non-nil value.
    /// A durable hint that the wifi-info entitlement is actually live, so
    /// the UI can explain *why* SSID-dependent features (green dot,
    /// auto-connect) are dormant when it's `false`.
    private(set) var didReadSSIDAtLeastOnce = false

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "WiFiManager")

    init() {}

    // MARK: - Read current SSID

    /// Read the SSID of the currently-associated Wi-Fi network, or `nil`
    /// if not on Wi-Fi / not permitted (free account, Location off, etc.).
    ///
    /// Requires the `wifi-info` entitlement AND Location Services
    /// authorization at runtime — iOS gates SSID reads behind location
    /// privacy. Without either, the callback fires with `nil` (no crash).
    func currentSSID() async -> String? {
        let ssid: String? = await withCheckedContinuation { continuation in
            // Callback arrives on an arbitrary internal queue.
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
        if let ssid {
            lastReadSSID = ssid
            didReadSSIDAtLeastOnce = true
        }
        return ssid
    }

    /// True iff the device is currently associated to `ssid`
    /// (case-sensitive). Returns `false` when the SSID can't be read.
    func isConnected(toSSID ssid: String) async -> Bool {
        await currentSSID() == ssid
    }

    // MARK: - Join

    /// Apply a hotspot configuration to join `network`. iOS shows a
    /// one-time system "Join Wi-Fi Network?" confirmation the first time;
    /// thereafter it can join silently. The configuration is persistent
    /// (`joinOnce = false`) so iOS auto-rejoins the dash in future.
    ///
    /// On a free account (missing HotspotConfiguration entitlement) this
    /// resolves to `.failed`.
    func join(_ network: KnownNetwork) async -> JoinResult {
        guard let ssid = network.normalizedSSID else {
            return .failed(reason: "Empty SSID")
        }
        let configuration = NEHotspotConfiguration(ssid: ssid,
                                                   passphrase: network.passphrase,
                                                   isWEP: false)
        // Persist so iOS treats the dash as a known network and reconnects
        // automatically next time it's in range.
        configuration.joinOnce = false

        log.info("Applying hotspot config for SSID '\(ssid, privacy: .public)'")

        return await withCheckedContinuation { continuation in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                // Callback on an arbitrary queue — map to a Sendable result
                // and resume; the @MainActor hop happens at the await site.
                guard let error = error as NSError? else {
                    continuation.resume(returning: .joined)
                    return
                }
                // NEHotspotConfigurationError.alreadyAssociated == 13 means
                // we were already on this SSID — that's success for us.
                if error.domain == "NEHotspotConfigurationErrorDomain",
                   error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    continuation.resume(returning: .alreadyConnected)
                    return
                }
                if error.domain == "NEHotspotConfigurationErrorDomain",
                   error.code == NEHotspotConfigurationError.userDenied.rawValue {
                    continuation.resume(returning: .userCancelled)
                    return
                }
                continuation.resume(returning: .failed(reason: error.localizedDescription))
            }
        }
    }

    // MARK: - Forget

    /// Remove a previously-applied hotspot configuration so iOS stops
    /// auto-joining it. Best-effort; safe to call for an SSID we never
    /// configured.
    func forget(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        log.info("Removed hotspot config for SSID '\(ssid, privacy: .public)'")
    }
}
