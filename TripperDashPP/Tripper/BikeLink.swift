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

    /// Configuration — defaults match the real Tripper AP.
    var bikeHost: String = K1G.bikeIPv4
    var ssid: String = "RE_FAKE_260616"  // overridden by user / tests

    // MARK: - Private

    private var socket: DashSocket?
    private var inboundTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private let seq = RollingSeq()
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "BikeLink")

    // MARK: - API

    /// Begin the connect → handshake → connected transition. Returns
    /// immediately; observe `state` for progress.
    func connect() {
        guard state == .idle else {
            log.warning("connect() called while in state \(String(describing: self.state))")
            return
        }
        Task { await self.runConnectFlow() }
    }

    /// Tear everything down and return to `.idle`.
    func disconnect() {
        inboundTask?.cancel(); inboundTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        Task { [socket] in await socket?.cancel() }
        socket = nil
        aesKey = nil
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
            self.socket = s

            state = .handshaking
            let outcome = try await runHandshake(socket: s)
            self.aesKey = outcome.aesKey

            state = .connected
            log.info("BikeLink connected (ssid=\(self.ssid, privacy: .public))")
            startInboundLoop(socket: s)
            startHeartbeat(socket: s)

        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Connect flow failed: \(msg, privacy: .public)")
            self.lastError = msg
            self.state = .error(msg)
            await self.socket?.cancel()
            self.socket = nil
        }
    }

    private func runHandshake(socket: DashSocket) async throws -> HandshakeOutcome {
        // 1) Send q3c.e
        let req = K1GPacket.makeRequestPubkey(seq: seq.consume())
        try await socket.send(req)
        log.debug("Sent q3c.e (\(req.count) B)")

        // 2) Wait for modulus + exponent (may arrive as one packet with two segments,
        //    or two packets — accept either).
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

        // 3) Build SecKey, generate AES key, encrypt session payload.
        let pub = try RsaHandshake.makePublicKey(modulus: modulus, exponent: exponent)
        let aesKey = try RsaHandshake.makeAesKey()
        let ct = try RsaHandshake.encryptSessionKey(ssid: ssid, aesKey: aesKey, bikePublicKey: pub)
        let q3cd = K1GPacket.makeSessionKey(ciphertext: ct, seq: seq.consume())
        try await socket.send(q3cd)
        log.debug("Sent q3c.d (\(q3cd.count) B, ciphertext=\(ct.count) B)")

        // 4) Wait for auth-OK (07 01 01).
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
