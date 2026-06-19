//
//  BikeLink.swift
//  TripperDashPP
//
//  Top-level orchestrator that owns the K1G control-plane state machine.
//
//      idle ─→ connecting ─→ handshaking ─→ connected ─┐
//        ↑                                              │
//        └──────────────────── error / cancel ──────────┘
//
//  - `connect()` opens the UDP socket, runs the RSA handshake, and starts
//    the heartbeat loop. On success, `state` becomes `.connected` and we
//    expose the negotiated `aesKey` (used by Phase 4+ for encrypted
//    payloads, if needed).
//  - `disconnect()` cancels everything and returns to `.idle`.
//
//  We deliberately keep the API on the main actor because UI binds to
//  `@Observable` state. The actual networking lives in `DashSocket`
//  (own actor) and is called via `await`.
//

import Foundation
import os
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class BikeLink {

    // MARK: - Public state

    enum LinkState: Equatable, Sendable {
        case idle
        case connecting
        case handshaking
        case connected
        case error(String)
    }

    private(set) var state: LinkState = .idle

    /// AES-256 session key the bike now also has (for Phase 4+).
    private(set) var aesKey: Data?

    /// Last error description for the UI.
    private(set) var lastError: String?

    /// Configuration — defaults match the real Tripper AP. Both are
    /// persisted in UserDefaults so we don't reset to dev placeholders
    /// every launch once the user has dialed in the real values.
    var bikeHost: String {
        didSet {
            UserDefaults.standard.set(bikeHost, forKey: Self.bikeHostKey)
        }
    }
    var ssid: String {
        didSet {
            UserDefaults.standard.set(ssid, forKey: Self.ssidKey)
        }
    }

    private static let bikeHostKey = "BikeLink.bikeHost"
    private static let ssidKey = "BikeLink.ssid"

    /// Convenience for downstream components (RTP streamer) that need
    /// the dash IP without poking at the link's internals.
    var dashHost: String? { state == .connected ? bikeHost : nil }

    // MARK: - Private

    private var socket: DashSocket?
    private var inboundTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// The connect→handshake flow itself, so `disconnect()` can yank it
    /// out of the middle of a `for await` on the inbound stream. Without
    /// this, a stuck handshake (e.g. user forgot to join the dash Wi-Fi)
    /// runs the full `K1G.handshakeStepTimeout` with no way to abort.
    private var connectTask: Task<Void, Never>?
    private let seq = RollingSeq()
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "BikeLink")

    // MARK: - Init

    init() {
        let d = UserDefaults.standard
        self.bikeHost = d.string(forKey: Self.bikeHostKey) ?? K1G.bikeIPv4
        self.ssid = d.string(forKey: Self.ssidKey) ?? "RE_FAKE_260616"
    }

    // MARK: - API

    /// Begin the connect → handshake → connected transition. Returns
    /// immediately; observe `state` for progress.
    ///
    /// Allowed from `.idle` or `.error` — in the latter case we do a
    /// silent teardown first (same as `disconnect()` would do) so the
    /// retry is clean. Rejected from any in-progress or connected state
    /// because that's almost always a UI double-tap.
    func connect() {
        switch state {
        case .idle:
            break
        case .error:
            // Clean slate before retrying — same cleanup as disconnect(),
            // minus the user-facing "disconnected" log line.
            connectTask?.cancel(); connectTask = nil
            inboundTask?.cancel(); inboundTask = nil
            heartbeatTask?.cancel(); heartbeatTask = nil
            Task { [socket] in await socket?.cancel() }
            socket = nil
            aesKey = nil
            lastError = nil
            state = .idle
        case .connecting, .handshaking, .connected:
            log.warning("connect() called while in state \(String(describing: self.state))")
            return
        }
        connectTask = Task { await self.runConnectFlow() }
    }

    /// Tear everything down and return to `.idle`. Safe to call at any
    /// time — including mid-handshake, in which case it cancels the
    /// in-flight connect Task so the user isn't stuck staring at a
    /// "Connecting…" pill until the K1G timeout fires.
    func disconnect() {
        connectTask?.cancel(); connectTask = nil
        inboundTask?.cancel(); inboundTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        Task { [socket] in await socket?.cancel() }
        socket = nil
        aesKey = nil
        lastError = nil
        state = .idle
        log.info("BikeLink disconnected")
    }

    // MARK: - Flow

    private func runConnectFlow() async {
        do {
            state = .connecting
            log.info("Opening UDP socket to \(self.bikeHost):\(K1G.controlPort) on Wi-Fi")
            let s = DashSocket(host: bikeHost, port: K1G.controlPort)
            try await s.start(timeout: 5.0)
            try Task.checkCancellation()
            self.socket = s

            state = .handshaking
            let outcome = try await runHandshake(socket: s)
            try Task.checkCancellation()
            self.aesKey = outcome.aesKey

            state = .connected
            log.info("BikeLink connected (ssid=\(self.ssid, privacy: .public))")
            startInboundLoop(socket: s)
            startHeartbeat(socket: s)

        } catch is CancellationError {
            // disconnect() yanked us. State + cleanup already handled
            // there; just log and exit silently — no error pill.
            log.info("Connect flow cancelled by user")
            await self.socket?.cancel()
            self.socket = nil
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Connect flow failed: \(msg, privacy: .public)")
            self.lastError = msg
            self.state = .error(msg)
            await self.socket?.cancel()
            self.socket = nil
        }
        self.connectTask = nil
    }

    private func runHandshake(socket: DashSocket) async throws -> HandshakeOutcome {
        // 0) Initial burst — 9 capability/identity packets the real Tripper
        //    app fires on startup. The dash uses this exact sequence as a
        //    discovery handshake; if any are missing it never transitions
        //    out of "Connected to <phone>" pairing and the RSA handshake
        //    never completes. See InitialBurst doc + better-dash.
        let hostname = await Self.deviceHostname()
        let burst = InitialBurst.packets(
            hostname: hostname,
            fixedTempC: 20,
            seq: seq
        )
        log.info("Sending initial burst (\(burst.count) packets, hostname=\(hostname, privacy: .public))")
        for (i, pkt) in burst.enumerated() {
            try Task.checkCancellation()
            try await socket.send(pkt)
            log.debug("Burst #\(i + 1)/\(burst.count) sent (\(pkt.count) B)")
            // 60 ms gap matches better-dash's default --burst-pause.
            // Skip the gap after the last packet so the handshake can start
            // listening immediately.
            if i + 1 < burst.count {
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }

        // 1) Wait for modulus + exponent. The bike replies to q3c.e (which
        //    was packet #1 in the burst above) with two segments. They may
        //    arrive in one packet or split across two.
        var modulus: Data?
        var exponent: Data?
        let deadline = Date().addingTimeInterval(K1G.handshakeStepTimeout)

        for await packet in socket.inbound {
            let segs = K1GPacket.decode(packet)
            for seg in segs {
                if seg.type == K1G.SegType.auth.rawValue {
                    if seg.sub == K1G.AuthSub.modulus.rawValue { modulus = seg.payload }
                    if seg.sub == K1G.AuthSub.exponent.rawValue { exponent = seg.payload }
                }
            }
            if modulus != nil && exponent != nil { break }
            if Date() > deadline {
                throw HandshakeError.missingSegment("modulus+exponent within \(K1G.handshakeStepTimeout)s")
            }
        }
        guard let modulus, let exponent else {
            throw HandshakeError.missingSegment("modulus or exponent")
        }
        log.info("Got bike pubkey: modulus=\(modulus.count)B, exponent=\(exponent.hexString, privacy: .public)")

        // 2) Build SecKey, generate AES key, encrypt session payload.
        let pub = try RsaHandshake.makePublicKey(modulus: modulus, exponent: exponent)
        let aesKey = try RsaHandshake.makeAesKey()
        let ct = try RsaHandshake.encryptSessionKey(ssid: ssid, aesKey: aesKey, bikePublicKey: pub)
        let q3cd = K1GPacket.makeSessionKey(ciphertext: ct, seq: seq.consume())
        try await socket.send(q3cd)
        log.debug("Sent q3c.d (\(q3cd.count) B, ciphertext=\(ct.count) B)")

        // 3) Wait for auth-OK (07 01 01).
        let okDeadline = Date().addingTimeInterval(K1G.handshakeStepTimeout)
        for await packet in socket.inbound {
            let segs = K1GPacket.decode(packet)
            if RsaHandshake.isAuthOK(segs) {
                log.info("Got auth OK (07 01 01)")
                return HandshakeOutcome(aesKey: aesKey, ssid: ssid)
            }
            if Date() > okDeadline {
                throw HandshakeError.missingSegment("auth-OK within \(K1G.handshakeStepTimeout)s")
            }
        }
        throw HandshakeError.missingSegment("auth-OK (stream ended)")
    }

    /// Build the hostname the dash will show on its pairing screen.
    /// Mirrors the Android app: prefers the device's user-set name,
    /// falls back to "TripperDashPP" if iOS denies access.
    private static func deviceHostname() async -> String {
        await MainActor.run {
            #if canImport(UIKit)
            let name = UIDevice.current.name
            if !name.isEmpty { return name }
            #endif
            return "TripperDashPP"
        }
    }

    private func startInboundLoop(socket: DashSocket) {
        inboundTask?.cancel()
        inboundTask = Task { [weak self] in
            guard let self else { return }
            self.log.info("Inbound loop started — waiting for bike → phone segments")
            var packetCount: UInt64 = 0
            for await packet in socket.inbound {
                packetCount &+= 1
                let segs = K1GPacket.decode(packet)
                if segs.isEmpty {
                    self.log.debug("RX packet #\(packetCount): \(packet.count) B, no decodable segments")
                    continue
                }
                for seg in segs {
                    // Button segments (0x09 0x00 …) are the whole reason
                    // this loop exists during bring-up. Log them at INFO
                    // so they're visible in the default Xcode console.
                    if seg.type == 0x09 && seg.sub == 0x00 {
                        let code: String
                        if seg.payload.count >= 3 {
                            let byte = seg.payload[seg.payload.index(seg.payload.startIndex, offsetBy: 2)]
                            code = String(format: "%02X", byte)
                        } else {
                            code = "??"
                        }
                        self.log.info("RX button: code=0x\(code, privacy: .public) (payload=\(seg.payload.hexString, privacy: .public))")
                    } else {
                        self.log.info("RX seg type=0x\(String(format: "%02X", seg.type), privacy: .public) sub=0x\(String(format: "%02X", seg.sub), privacy: .public) len=\(seg.payload.count)")
                    }
                }
            }
            self.log.info("Inbound loop ended (received \(packetCount) packets)")
        }
    }

    private func startHeartbeat(socket: DashSocket) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [seq] in
            await HeartbeatLoop(socket: socket, seq: seq).run()
        }
    }
}

// MARK: - Helpers

private extension Data {
    var hexString: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
}
