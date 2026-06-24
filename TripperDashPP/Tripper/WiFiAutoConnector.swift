//
//  WiFiAutoConnector.swift
//  TripperDashPP
//
//  Decides when to automatically start the dash connection based on the
//  Wi-Fi the phone is currently associated to. Two pieces:
//
//    1. `AutoConnectGate` — a PURE value-type state machine holding the
//       suppress-after-manual-disconnect logic. No iOS dependencies, so
//       it's unit-tested 1:1 by a Python mirror in
//       tools/fake_dash/tests/test_autoconnect_gate.py.
//
//    2. `WiFiAutoConnector` — the @MainActor glue that reads the live
//       SSID via WiFiManager, runs the gate, and fires a callback to
//       kick off the connect flow.
//
//  ── Behaviour (rider-confirmed, June 2026) ──────────────────────────
//   • If the phone is already on a Wi-Fi whose SSID is in the saved
//     known-networks list, auto-start the dash connection — no tap.
//   • Triggered on app-foreground and on a Wi-Fi "path became satisfied"
//     transition (the rider walked into range / toggled Wi-Fi).
//   • AFTER a manual Disconnect, suppress auto-connect for the SSID the
//     rider was on, until the SSID CHANGES (rode away) or Wi-Fi drops and
//     returns (off→on). Otherwise tapping Disconnect while parked next to
//     the bike would instantly reconnect and make Disconnect useless.
//
//  ── Free-account note ───────────────────────────────────────────────
//  Auto-connect depends on READING the current SSID, which needs the
//  paid `wifi-info` entitlement. On a free account WiFiManager.currentSSID()
//  always returns nil, so the gate never fires — the feature is simply
//  dormant (no crash, no misbehaviour) until the entitlement is added.
//

import Foundation
import Observation
import os

// MARK: - Pure decision core

/// Pure, dependency-free suppression/decision logic for auto-connect.
/// Deterministic and `Sendable` so it can be exercised by unit tests and
/// mirrored in Python. Holds no iOS types.
struct AutoConnectGate: Equatable, Sendable {

    /// The SSID for which auto-connect is currently suppressed because the
    /// rider hit Disconnect while associated to it. `nil` = not suppressed.
    private(set) var suppressedSSID: String?

    init(suppressedSSID: String? = nil) {
        self.suppressedSSID = suppressedSSID
    }

    /// Whether the live link is in a state where a fresh auto-connect is
    /// even meaningful. We only auto-start from a cold/idle-ish link.
    enum LinkActivity: Sendable, Equatable {
        case idle        // .idle / .error — free to start
        case busy        // .connecting / .handshaking / .connected / .reconnecting
    }

    /// Decision returned by `evaluate`.
    enum Decision: Equatable, Sendable {
        case connect(ssid: String)
        case doNothing
    }

    /// Record a user-initiated Disconnect. If the rider was on a known
    /// dash SSID, suppress auto-connect for exactly that SSID until it
    /// changes or Wi-Fi drops. A disconnect while not on a known network
    /// (or with no readable SSID) clears any prior suppression — there's
    /// nothing meaningful to suppress.
    mutating func noteManualDisconnect(currentSSID: String?, knownSSIDs: Set<String>) {
        if let s = currentSSID, knownSSIDs.contains(s) {
            suppressedSSID = s
        } else {
            suppressedSSID = nil
        }
    }

    /// Fold in the latest observed SSID and decide whether to auto-connect.
    ///
    /// Suppression is lifted the moment the observed SSID differs from the
    /// suppressed one — that covers both "rode away to another/again no
    /// network" (different or nil SSID) and "Wi-Fi off→on" (drops to nil,
    /// which already differs). After lifting, a later return to the same
    /// SSID is eligible again.
    mutating func evaluate(currentSSID: String?,
                           knownSSIDs: Set<String>,
                           link: LinkActivity) -> Decision {
        // Lift suppression once we're no longer sitting on the suppressed
        // SSID (changed network, or disassociated → nil).
        if let suppressed = suppressedSSID, currentSSID != suppressed {
            suppressedSSID = nil
        }

        guard let ssid = currentSSID, knownSSIDs.contains(ssid) else {
            return .doNothing
        }
        // Still suppressed for this exact SSID? Stay put.
        if suppressedSSID == ssid {
            return .doNothing
        }
        // Only kick a connect when the link is free.
        guard link == .idle else { return .doNothing }
        return .connect(ssid: ssid)
    }
}

// MARK: - Live coordinator

@MainActor
@Observable
final class WiFiAutoConnector {

    @ObservationIgnored private var gate = AutoConnectGate()
    @ObservationIgnored private let wifi: WiFiManager
    @ObservationIgnored private let store: KnownNetworksStore
    @ObservationIgnored private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "WiFiAutoConnector")

    /// Called when the gate decides the dash connection should start.
    /// Wired by AppStatus to its smart-connect entry point. The SSID that
    /// triggered it is passed for logging/UI.
    @ObservationIgnored var onShouldConnect: ((String) -> Void)?

    /// Snapshot of the last gate decision, for debugging / UI hints.
    private(set) var lastDecisionWasConnect = false

    init(wifi: WiFiManager, store: KnownNetworksStore) {
        self.wifi = wifi
        self.store = store
    }

    private var knownSSIDs: Set<String> {
        Set(store.networks.compactMap { $0.normalizedSSID })
    }

    /// Read the live SSID and run the gate. `linkIsIdle` reflects whether
    /// BikeLink is currently free to start a new connection. Safe to call
    /// often (app-foreground, Wi-Fi path change) — it no-ops unless the
    /// gate says connect.
    func evaluate(linkIsIdle: Bool) async {
        let ssid = await wifi.currentSSID()
        let decision = gate.evaluate(currentSSID: ssid,
                                     knownSSIDs: knownSSIDs,
                                     link: linkIsIdle ? .idle : .busy)
        switch decision {
        case .connect(let s):
            lastDecisionWasConnect = true
            log.info("Auto-connect: on known dash SSID '\(s, privacy: .public)', starting link")
            onShouldConnect?(s)
        case .doNothing:
            lastDecisionWasConnect = false
        }
    }

    /// Record that the user manually disconnected, so we don't immediately
    /// reconnect while still parked on the dash Wi-Fi. Reads the live SSID
    /// to know which network to suppress.
    func noteManualDisconnect() async {
        let ssid = await wifi.currentSSID()
        gate.noteManualDisconnect(currentSSID: ssid, knownSSIDs: knownSSIDs)
        if let ssid, knownSSIDs.contains(ssid) {
            log.info("Auto-connect suppressed for '\(ssid, privacy: .public)' until SSID changes / Wi-Fi cycles")
        }
    }
}
