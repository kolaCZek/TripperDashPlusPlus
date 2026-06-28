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
import Network
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
        case reconnecting     // dropped after being connected; auto-retrying
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

    // MARK: - Reconnect

    /// The running auto-reconnect retry loop, if any.
    private var reconnectTask: Task<Void, Never>?

    /// True while we should auto-reconnect on an unexpected drop. Armed
    /// when a connect succeeds; cleared by a user-initiated disconnect()
    /// so we never fight the user's explicit "stop".
    private var shouldAutoReconnect = false

    /// Absolute deadline for the CURRENT reconnect episode. Set once in
    /// `handleLinkDropped` and deliberately NOT reset by `wakeReconnect`,
    /// so toggling Wi-Fi can't extend the 10-min budget past the moment
    /// the link first dropped.
    private var reconnectDeadline: Date?

    /// Wi-Fi presence monitor. A dropped Wi-Fi path is a faster, cleaner
    /// drop signal than waiting for a heartbeat `sendto` to error, and
    /// its return lets us retry the instant the rider walks back in range
    /// instead of waiting out the retry interval.
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var pathMonitorStarted = false
    private var lastWifiSatisfied = true

    // MARK: - Init

    /// Optional reference to the user's dash-display settings.
    /// Currently consulted only for the wire-encoding helpers that live
    /// on `DashNavSettings` (units / formatting). BikeLink is created
    /// at AppStatus init time (inline stored property), but the
    /// settings object is itself a property of AppStatus — so we can't
    /// reference it from BikeLink's inline initializer. AppStatus
    /// assigns this right after both are constructed. `nil` is
    /// tolerated by all read paths.
    var settings: DashNavSettings?

    /// Live phone-status source for the 1 Hz heartbeat (battery / charging
    /// / GPS-fix / cell-signal presence). A `@Sendable` async closure so
    /// the heartbeat `Task` can snapshot `DeviceTelemetry` on the main
    /// actor each tick. AppStatus assigns this right after construction,
    /// alongside `settings`. `nil` → the heartbeat falls back to its
    /// built-in OEM-safe placeholder provider, so the link still beats
    /// normally before wiring (or in tests).
    var telemetryProvider: (@Sendable () async -> PhoneTelemetry)?

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
        startPathMonitorIfNeeded()
        switch state {
        case .idle:
            break
        case .error:
            // Clean slate before retrying — same cleanup as disconnect(),
            // minus the user-facing "disconnected" log line.
            connectTask?.cancel(); connectTask = nil
            reconnectTask?.cancel(); reconnectTask = nil
            inboundTask?.cancel(); inboundTask = nil
            heartbeatTask?.cancel(); heartbeatTask = nil
            Task { [socket] in await socket?.cancel() }
            socket = nil
            aesKey = nil
            lastError = nil
            state = .idle
        case .reconnecting:
            // User tapped Connect while we're already auto-retrying —
            // honour it as "retry now" instead of rejecting it.
            wakeReconnect()
            return
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
        // User-initiated stop: clear the auto-reconnect intent FIRST so a
        // drop signal racing in right now can't re-arm the retry loop.
        shouldAutoReconnect = false
        reconnectDeadline = nil
        reconnectTask?.cancel(); reconnectTask = nil
        connectTask?.cancel(); connectTask = nil
        inboundTask?.cancel(); inboundTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        Task { [socket] in await socket?.cancel() }
        socket = nil
        aesKey = nil
        lastError = nil
        state = .idle
        log.info("BikeLink disconnected (auto-reconnect cleared)")
    }

    // MARK: - Nav projection lifecycle
    //
    // Public hooks for the streamer. Fire-and-forget on the link's seq
    // counter — failures just log; the streamer will start anyway and
    // the worst case is the dash stays on the home screen, which is
    // recoverable by toggling streaming off+on.

    /// Kick the dash into nav projection mode. Call BEFORE starting the
    /// RTP stream. No-op if not connected.
    ///
    /// Sequence mirrors better-dash `send_nav_mode_kick`:
    /// `q3c.z2` (open nav screen) → `q3c.q` (enter nav context).
    func sendNavStart() async {
        guard state == .connected, let s = socket else { return }
        let z2 = K1GPacket.makeStartNav(seq: seq.consume())
        let q  = K1GPacket.makeNavContext(seq: seq.consume())
        do {
            try await s.send(z2)
            try await s.send(q)
            log.info("Sent nav-mode kick (q3c.z2 + q3c.q)")
        } catch {
            log.error("Nav-mode kick failed: \(error.localizedDescription)")
        }
    }

    /// Latch the "projection video is live" flag. Call right after the
    /// RTP UDP connection is .ready and the first H.264 frame is on the
    /// way. No-op if not connected.
    func sendProjectionOn() async {
        guard state == .connected, let s = socket else { return }
        let w = K1GPacket.makeProjectionOn(seq: seq.consume())
        do {
            try await s.send(w)
            log.info("Sent projection-on latch (q3c.w)")
        } catch {
            log.error("Projection-on send failed: \(error.localizedDescription)")
        }
    }

    /// Announce that a new H.264 frame was just pushed to UDP/5000. Call
    /// from the RTP streamer's per-frame callback. No-op if not connected.
    func sendProjectionFrame() async {
        guard state == .connected, let s = socket else { return }
        let g = K1GPacket.makeProjectionFrame(seq: seq.consume())
        try? await s.send(g)
    }

    /// Tear down the nav projection. Call BEFORE stopping the RTP stream.
    /// No-op if not connected.
    ///
    /// Sequence mirrors NavigationFragment.Y7:
    /// `q3c.h` (stop-frames) → `q3c.x` (projection off).
    func sendNavStop() async {
        guard state == .connected, let s = socket else { return }
        let h = K1GPacket.makeProjectionStop(seq: seq.consume())
        let x = K1GPacket.makeProjectionOff(seq: seq.consume())
        do {
            try await s.send(h)
            try await s.send(x)
            log.info("Sent nav-stop (q3c.h + q3c.x)")
        } catch {
            log.error("Nav-stop send failed: \(error.localizedDescription)")
        }
    }

    /// Push one active-navigation packet to the dash. Called ~1 Hz from
    /// `ActiveNavLoop` while the rider is following a route. Bundles
    /// maneuver code + distance + ETA + remaining time + road name into
    /// a single K1G envelope so the dash bubble updates atomically.
    ///
    /// All args are pre-encoded wire values (let the loop do the
    /// unit-system / decimal-separator math). No-op if not connected.
    func sendActiveNav(
        primaryManeuver: UInt8,
        primaryDistanceMeters: UInt16,
        primaryUnit: UInt8,
        secondaryManeuver: UInt8? = nil,
        secondaryDistanceMeters: UInt16? = nil,
        secondaryUnit: UInt8? = nil,
        totalDistanceMeters: UInt16,
        totalDistanceUnit: UInt8,
        useCommaDecimal: Bool,
        decimalFmtOn: Bool,
        roadName: String?,
        eta: Date?,
        is24Hour: Bool,
        remainingSeconds: TimeInterval?
    ) async {
        guard state == .connected, let s = socket else { return }
        let pkt = K1GPacket.makeActiveNav(
            seq: seq.consume(),
            primaryManeuver: primaryManeuver,
            primaryDistanceMeters: primaryDistanceMeters,
            primaryUnit: primaryUnit,
            secondaryManeuver: secondaryManeuver,
            secondaryDistanceMeters: secondaryDistanceMeters,
            secondaryUnit: secondaryUnit,
            totalDistanceMeters: totalDistanceMeters,
            totalDistanceUnit: totalDistanceUnit,
            useCommaDecimal: useCommaDecimal,
            projectionOn: true,
            decimalFmtOn: decimalFmtOn,
            roadName: roadName,
            eta: eta,
            is24Hour: is24Hour,
            remainingSeconds: remainingSeconds
        )
        try? await s.send(pkt)
    }

    // MARK: - Call-state notification
    //
    // Push the phone's current call state to the dash so it shows the OEM
    // incoming-call card (decoded from `km3.u()` — see the
    // `call-notification-wire-protocol.md` skill reference). Driven by
    // `CallStateObserver` off `CXCallObserver`. Like the nav hooks, this is
    // fire-and-forget on the link's seq counter and a no-op when not
    // connected — a missed call card is cosmetic and must never disrupt the
    // ride or the nav stream.

    /// The last call state we pushed, so we can suppress duplicate sends
    /// (CallKit can fire several `callChanged` events for one logical
    /// transition). `nil` until the first push.
    private var lastCallState: K1GPacket.CallState?

    /// Send a call-state change to the dash as the OEM 2-packet burst
    /// (`05 21 <state>` then the `05 4D 32` commit), mirroring `km3.u()`.
    /// De-duplicates against the previously-sent state. No-op if not
    /// connected (we simply drop the card — it'll re-sync on the next
    /// distinct state once the link is back).
    ///
    /// Honours the user's `callStateEnabled` preference: when the card is
    /// switched off we never light a NEW card, but a `.none` (clear) is
    /// always allowed through, so toggling the setting off mid-call wipes a
    /// card that's lit right now instead of leaving it stuck on the dash.
    ///
    /// Guard order matters: we check `.connected` BEFORE updating
    /// `lastCallState`, so a state that arrives while disconnected is not
    /// recorded as "sent". `lastCallState` is reset on every (re)connect
    /// (`runConnectFlow`) so a fresh link always re-pushes the live state.
    func sendCallState(_ state: K1GPacket.CallState) async {
        // Respect the user toggle — but always let a `.none` clear through
        // so disabling the feature (or ending a call) can zero a live card.
        if state != .none {
            guard settings?.callStateEnabled ?? true else { return }
        }
        guard self.state == .connected, let s = socket else { return }
        guard state != lastCallState else { return }
        lastCallState = state
        let pkt    = K1GPacket.makeCallState(state, seq: seq.consume())
        let commit = K1GPacket.makeCallStateCommit(seq: seq.consume())
        do {
            try await s.send(pkt)
            try await s.send(commit)
            log.info("Sent call-state \(String(describing: state)) (05 21 + 05 4D commit)")
        } catch {
            log.error("Call-state send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Incoming-message notification
    //
    // Push incoming messages to the dash as the OEM `km3.z()` burst: one
    // plaintext `06 09` unread-count packet, then — for every populated slot
    // (newest first, up to 5) — three AES-encrypted field packets
    // (content / sender / timestamp). Decoded from `bluconnect.km3`; see
    // `message-notification-wire-protocol.md`.
    //
    // Unlike call-state this is NOT driven by a clean iOS system source
    // (iOS exposes no general incoming-SMS API), so it's fed explicitly via
    // `AppStatus`/`MessageFeed` from the app's own push extension or a
    // user/test entry. The wire + crypto are byte-exact and round-trip
    // tested against `fake_dash`.
    //
    // Encryption uses the SAME `aesKey` negotiated by the RSA handshake and
    // already shared with the dash — so the dash can decrypt these fields
    // with the key we handed it in the `08 00` session-key packet.

    /// Send the current message list to the dash, mirroring `km3.z(list,
    /// unread)`. No-op (silently) when:
    ///   - the user's `messageNotifyEnabled` toggle is off,
    ///   - the link isn't `.connected`,
    ///   - we have no negotiated `aesKey` (can't encrypt → dash can't decrypt),
    ///   - the list is empty.
    /// Like the call card, a missed message is cosmetic and must never
    /// disrupt nav — every failure path just drops the push.
    func sendMessageNotification(_ messages: [MessageNotification], unreadCount: Int) async {
        guard settings?.messageNotifyEnabled ?? true else { return }
        guard self.state == .connected, let s = socket else { return }
        guard let key = aesKey else {
            log.error("Message notify skipped: no AES session key (handshake incomplete)")
            return
        }
        guard !messages.isEmpty else { return }

        // 1) Plaintext unread/missed count (`06 09`), sent first like km3.z().
        let count = UInt16(max(0, min(unreadCount, 0xFFFF)))
        do {
            try await s.send(K1GPacket.makeMessageCount(count, seq: seq.consume()))
        } catch {
            log.error("Message count send failed: \(error.localizedDescription)")
            return
        }

        // 2) Per slot (newest first, capped at the dash's 5), three encrypted
        //    field packets: content, sender, timestamp.
        let slots = K1GPacket.MessageSlot.all
        for (index, message) in messages.prefix(slots.count).enumerated() {
            let slot = slots[index]
            do {
                let contentEnc = try K1GCrypto.encryptField(message.contentField, key: key)
                let senderEnc  = try K1GCrypto.encryptField(message.senderField,  key: key)
                let tsString   = K1GPacket.formatMessageTimestamp(message.timestamp)
                let tsEnc      = try K1GCrypto.encryptField(tsString, key: key)

                try await s.send(K1GPacket.makeMessageField(
                    sub: slot.contentSub, encryptedPayload: contentEnc, seq: seq.consume()))
                try await s.send(K1GPacket.makeMessageField(
                    sub: slot.senderSub, encryptedPayload: senderEnc, seq: seq.consume()))
                try await s.send(K1GPacket.makeMessageField(
                    sub: slot.timestampSub, encryptedPayload: tsEnc, seq: seq.consume()))
            } catch {
                log.error("Message slot \(index) send failed: \(error.localizedDescription)")
                // Keep going — a later slot may still encrypt/send fine.
            }
        }
        log.info("Sent \(min(messages.count, slots.count)) message card(s) to dash (unread=\(count))")
    }

    @discardableResult
    private func runConnectFlow(isReconnect: Bool = false) async -> Bool {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        do {
            // On a fresh connect we own the `.connecting` → `.handshaking`
            // progression. During a reconnect the retry loop has already
            // set `.reconnecting` and we keep it until we either reach
            // `.connected` or give up — so the UI shows one steady
            // "Reconnecting…" instead of flickering through the sub-states.
            if !isReconnect { state = .connecting }
            // Reset the rolling K1G sequence for this connect episode. The
            // better-dash authority builds a fresh RollingSeq per connection;
            // we keep one long-lived counter on BikeLink, so we reset it here
            // to honour the same "new connection starts the handshake from a
            // fresh sequence" contract. Without this, a reconnect after the
            // bike is power-cycled replays a stale mid-ride seq and the
            // freshly-rebooted dash drops our initial burst — the link never
            // re-establishes and we time out after the 10-min budget.
            seq.reset()
            // Forget the last call state we pushed so a fresh link re-syncs
            // the live state (the dash reboots its own call card on a new
            // session; replaying our last in-memory state would otherwise be
            // suppressed by the de-dup guard in `sendCallState`).
            lastCallState = nil
            log.info("[\(ms(), privacy: .public)ms] Opening UDP socket to \(self.bikeHost, privacy: .public):\(K1G.txPort) (local-bind :\(K1G.rxPort)) on Wi-Fi (reconnect=\(isReconnect, privacy: .public))")
            let s = DashSocket(host: bikeHost, port: K1G.txPort, localPort: K1G.rxPort)
            try await s.start(timeout: 5.0)
            try Task.checkCancellation()
            self.socket = s
            log.info("[\(ms(), privacy: .public)ms] DashSocket ready, entering handshake")

            if !isReconnect { state = .handshaking }
            let outcome = try await runHandshake(socket: s, startedAt: t0)
            try Task.checkCancellation()
            self.aesKey = outcome.aesKey

            state = .connected
            // Arm auto-reconnect for any FUTURE unexpected drop now that we
            // have a real established link.
            shouldAutoReconnect = true
            reconnectDeadline = nil
            log.info("[\(ms(), privacy: .public)ms] BikeLink connected (ssid=\(self.ssid, privacy: .public))")
            startInboundLoop(socket: s)
            startHeartbeat(socket: s)
            self.connectTask = nil
            return true

        } catch is CancellationError {
            // disconnect() yanked us. State + cleanup already handled
            // there; just log and exit silently — no error pill.
            log.info("Connect flow cancelled by user")
            await self.socket?.cancel()
            self.socket = nil
            self.connectTask = nil
            return false
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Connect flow failed: \(msg, privacy: .public)")
            await self.socket?.cancel()
            self.socket = nil
            self.lastError = msg
            if isReconnect {
                // Stay in `.reconnecting`; the retry loop sleeps + tries
                // again (until it hits the 10-min deadline).
            } else {
                self.state = .error(msg)
            }
            self.connectTask = nil
            return false
        }
    }

    // MARK: - Reconnect machinery

    /// An established link went away unexpectedly (heartbeat send failed,
    /// or the Wi-Fi path dropped). Tear down the dead socket + loops but
    /// NOT the reconnect intent, then start the retry loop. Idempotent:
    /// a second drop signal while already `.reconnecting` is ignored.
    private func handleLinkDropped(reason: String) {
        guard shouldAutoReconnect else { return }
        guard state == .connected else {
            // Already reconnecting (or not in a droppable state) — ignore.
            return
        }
        log.warning("Link dropped (\(reason, privacy: .public)) — starting auto-reconnect")
        inboundTask?.cancel(); inboundTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        Task { [socket] in await socket?.cancel() }
        socket = nil
        aesKey = nil
        state = .reconnecting
        // Absolute 10-min budget from the moment we dropped — survives
        // `wakeReconnect` so repeated Wi-Fi toggles can't extend it.
        reconnectDeadline = Date().addingTimeInterval(K1G.reconnectMaxDuration)
        startReconnectLoop()
    }

    /// Retry `runConnectFlow(isReconnect:)` every `reconnectInterval`
    /// until it succeeds, the user cancels, or the 10-min deadline passes.
    private func startReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled, self.shouldAutoReconnect {
                // 10-min hard cap (rider-confirmed). Give up → `.error`
                // so the bottom bar offers Connect again instead of
                // spinning forever and draining the battery.
                if let deadline = self.reconnectDeadline, Date() >= deadline {
                    self.log.warning("Reconnect gave up after \(K1G.reconnectMaxDuration, privacy: .public)s")
                    self.shouldAutoReconnect = false
                    self.reconnectDeadline = nil
                    self.lastError = "Reconnect timed out after 10 min"
                    self.state = .error("Reconnect timed out after 10 min")
                    return
                }
                attempt += 1
                self.log.info("Reconnect attempt #\(attempt)")
                let ok = await self.runConnectFlow(isReconnect: true)
                if ok {
                    self.log.info("Reconnected after \(attempt) attempt(s)")
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(K1G.reconnectInterval * 1_000_000_000))
            }
        }
    }

    /// Short-circuit the retry interval — restart the loop immediately so
    /// we attempt a connection right now (e.g. the rider walked back into
    /// Wi-Fi range, or tapped Connect). Preserves the existing
    /// `reconnectDeadline`, so the 10-min budget is not extended.
    func wakeReconnect() {
        guard state == .reconnecting, shouldAutoReconnect else { return }
        log.info("Reconnect woken (retry now)")
        startReconnectLoop()
    }

    /// Start the Wi-Fi path monitor once. A `.unsatisfied` Wi-Fi path on
    /// an established link is treated as a drop; a `.satisfied` transition
    /// while reconnecting wakes the retry immediately.
    private func startPathMonitorIfNeeded() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                defer { self.lastWifiSatisfied = satisfied }
                if !satisfied, self.state == .connected {
                    self.handleLinkDropped(reason: "wifi-path-down")
                } else if satisfied, !self.lastWifiSatisfied, self.state == .reconnecting {
                    // Wi-Fi came back — try right now instead of waiting
                    // out the interval. NOTE: a `.satisfied` Wi-Fi path
                    // only means "associated to *a* Wi-Fi", not necessarily
                    // the bike's AP (it has no internet). The handshake is
                    // the real test; a wrong-network attempt just fails and
                    // the loop keeps retrying. This is a latency win, not a
                    // correctness gate.
                    self.wakeReconnect()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "BikeLink.pathMonitor"))
        log.info("Wi-Fi path monitor started")
    }

    private func runHandshake(socket: DashSocket, startedAt t0: Date) async throws -> HandshakeOutcome {
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

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
        log.info("[\(ms(), privacy: .public)ms] Sending initial burst (\(burst.count) packets, hostname=\(hostname, privacy: .public))")
        for (i, pkt) in burst.enumerated() {
            try Task.checkCancellation()
            try await socket.send(pkt)
            log.info("[\(ms(), privacy: .public)ms] TX burst #\(i + 1)/\(burst.count) (\(pkt.count) B): \(pkt.hexPreview, privacy: .public)")
            // 60 ms gap matches better-dash's default --burst-pause.
            // Skip the gap after the last packet so the handshake can start
            // listening immediately.
            if i + 1 < burst.count {
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
        log.info("[\(ms(), privacy: .public)ms] Initial burst done, waiting for modulus+exponent (timeout=\(K1G.handshakeStepTimeout, privacy: .public)s)")

        // 1) Wait for modulus + exponent. The bike replies to q3c.e (which
        //    was packet #1 in the burst above) with two segments. They may
        //    arrive in one packet or split across two.
        var modulus: Data?
        var exponent: Data?
        var rxCount = 0
        let deadline = Date().addingTimeInterval(K1G.handshakeStepTimeout)

        for await packet in socket.inbound {
            rxCount += 1
            let segs = K1GPacket.decode(packet)
            let segSummary = segs.isEmpty
                ? "no decodable segments"
                : segs.map { String(format: "%02X/%02X(\($0.payload.count)B)", $0.type, $0.sub) }.joined(separator: " ")
            log.info("[\(ms(), privacy: .public)ms] RX #\(rxCount) handshake-step1 (\(packet.count) B): \(packet.hexPreview, privacy: .public) | segs=\(segSummary, privacy: .public)")
            for seg in segs {
                if seg.type == K1G.SegType.auth.rawValue {
                    if seg.sub == K1G.AuthSub.modulus.rawValue { modulus = seg.payload }
                    if seg.sub == K1G.AuthSub.exponent.rawValue { exponent = seg.payload }
                }
            }
            if modulus != nil && exponent != nil { break }
            if Date() > deadline {
                log.error("[\(ms(), privacy: .public)ms] handshake step1 timed out — received \(rxCount) packets, modulus=\(modulus != nil ? "yes" : "NO"), exponent=\(exponent != nil ? "yes" : "NO")")
                throw HandshakeError.missingSegment("modulus+exponent within \(K1G.handshakeStepTimeout)s")
            }
        }
        guard let modulus, let exponent else {
            log.error("[\(ms(), privacy: .public)ms] inbound stream ended before modulus+exponent arrived (rx=\(rxCount), mod=\(modulus != nil ? "yes" : "NO"), exp=\(exponent != nil ? "yes" : "NO"))")
            throw HandshakeError.missingSegment("modulus or exponent")
        }
        log.info("[\(ms(), privacy: .public)ms] Got bike pubkey: modulus=\(modulus.count)B, exponent=\(exponent.hexString, privacy: .public)")

        // 2) Build SecKey, generate AES key, encrypt session payload.
        let pub = try RsaHandshake.makePublicKey(modulus: modulus, exponent: exponent)
        let aesKey = try RsaHandshake.makeAesKey()
        let ct = try RsaHandshake.encryptSessionKey(ssid: ssid, aesKey: aesKey, bikePublicKey: pub)
        let q3cd = K1GPacket.makeSessionKey(ciphertext: ct, seq: seq.consume())
        try await socket.send(q3cd)
        log.info("[\(ms(), privacy: .public)ms] TX q3c.d (\(q3cd.count) B, ciphertext=\(ct.count) B): \(q3cd.hexPreview, privacy: .public)")

        // 3) Wait for auth-OK (07 01 01).
        let okDeadline = Date().addingTimeInterval(K1G.handshakeStepTimeout)
        var step3Rx = 0
        for await packet in socket.inbound {
            step3Rx += 1
            let segs = K1GPacket.decode(packet)
            let segSummary = segs.isEmpty
                ? "no decodable segments"
                : segs.map { String(format: "%02X/%02X(\($0.payload.count)B)", $0.type, $0.sub) }.joined(separator: " ")
            log.info("[\(ms(), privacy: .public)ms] RX #\(step3Rx) handshake-step3 (\(packet.count) B): \(packet.hexPreview, privacy: .public) | segs=\(segSummary, privacy: .public)")
            if RsaHandshake.isAuthOK(segs) {
                log.info("[\(ms(), privacy: .public)ms] Got auth OK (07 01 01)")
                return HandshakeOutcome(aesKey: aesKey, ssid: ssid)
            }
            if Date() > okDeadline {
                log.error("[\(ms(), privacy: .public)ms] handshake step3 timed out — received \(step3Rx) packets, no auth-OK")
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
        let provider = telemetryProvider
        heartbeatTask = Task { [weak self, seq] in
            var loop = HeartbeatLoop(socket: socket, seq: seq)
            if let provider { loop.telemetryProvider = provider }
            await loop.run()
            // `run()` returns on cancellation (clean — disconnect or a
            // drop we already handled) OR on a send error (the link is
            // gone and nobody told us yet). Distinguish via the task's
            // own cancellation flag: only an UNcancelled return is a real
            // unexpected drop worth reconnecting on.
            guard let self else { return }
            if !Task.isCancelled {
                await MainActor.run { self.handleLinkDropped(reason: "heartbeat") }
            }
        }
    }
}

// MARK: - Helpers

private extension Data {
    var hexString: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }

    /// Short, log-friendly hex preview: first 32 bytes as space-separated
    /// hex pairs, with "… +N more" suffix if longer. Designed for OSLog
    /// where we want enough bytes to identify K1G headers + first TLV but
    /// not spam the log with 800 B RSA ciphertext.
    var hexPreview: String {
        let cap = 32
        if count <= cap {
            return self.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        let head = self.prefix(cap).map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(head) … +\(count - cap) more"
    }
}
