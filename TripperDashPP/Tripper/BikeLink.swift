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
import NetworkExtension
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

    /// Consecutive reconnect attempts where the datagrams left the phone but
    /// the dash never answered. Reset by any attempt that fails differently,
    /// and by a successful connect.
    ///
    /// The distinction matters because the two failure shapes need opposite
    /// things from the rider. `sendto` failing (`Host is down`, `No route to
    /// host`) means the phone cannot reach the dash's address at all —
    /// normal when riding away from the bike, and it fixes itself on return.
    /// `sendto` succeeding while the handshake times out with rx=0 means
    /// something IS at 192.168.1.1 answering at the link layer, but the K1G
    /// control plane is not replying: the dash's Wi-Fi and network stack are
    /// alive while its app-level server is wedged. No amount of retrying
    /// fixes that — only power-cycling the dash does.
    private(set) var consecutiveSilentAttempts = 0

    /// True when the dash looks reachable but its K1G server has stopped
    /// answering, so the UI can say something more useful than
    /// "Reconnecting…".
    ///
    /// Threshold is deliberately above the dash's own boot time: per
    /// `K1G.bootRaceMaxAttempts`, the Tripper brings its Wi-Fi AP up ~28 s
    /// before its control-plane task is ready, and every ordinary ignition-on
    /// produces exactly this rx=0 shape while that happens. At roughly
    /// `handshakeStepTimeout + bootRaceRetryInterval` (~7 s) per attempt,
    /// 8 attempts is ~56 s — twice the boot window, so a normal start never
    /// trips it.
    ///
    /// Field case that motivated it (2026-09-02, 16:23-16:36): a heartbeat
    /// drop after 63 minutes of a healthy link, then 110 reconnect attempts
    /// over 13 minutes, most of them sendto-OK/rx=0. The rider had no way to
    /// tell that from "out of range" and was left checking iOS Settings,
    /// which correctly showed Wi-Fi connected.
    var dashUnresponsive: Bool {
        consecutiveSilentAttempts >= Self.silentAttemptsBeforeUnresponsive
    }

    /// See `dashUnresponsive`.
    static let silentAttemptsBeforeUnresponsive = 8

    /// True only while `runConnectFlow` is blocked waiting for the Wi-Fi
    /// interface to become usable (DHCP lease) right after association, before
    /// the socket opens. Drives a distinct "Waiting for Wi-Fi…" label so the
    /// rider knows the app is waiting on the network handoff, not stalled. The
    /// coarse `state` stays `.connecting` throughout (no new enum case to thread
    /// through every switch).
    private(set) var isWaitingForWifi = false

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


    /// Demo mode: when true, `connect()` FAKES an established link — no UDP
    /// socket, no RSA handshake, no heartbeat/reconnect — so the app can run
    /// its full real pipeline (real GPS, real routing, real map compositing,
    /// real voice) without the physical dash. The composited video frame and
    /// the native nav bubble are mirrored on-screen instead of shoved into the
    /// void over Wi-Fi (see `DemoDashModel` + `AppStatus` frame mirror).
    /// Persisted like `bikeHost`/`ssid` so a reviewer's choice survives relaunch.
    var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: Self.demoModeKey)
        }
    }

    private static let bikeHostKey = "BikeLink.bikeHost"
    private static let ssidKey = "BikeLink.ssid"
    private static let demoModeKey = "BikeLink.demoMode"

    /// True while the link is a faked demo link (persisted flag). Used by
    /// `AppStatus` to route the streaming path to the on-screen mirror instead
    /// of the UDP streamer, and by the UI to relabel the connect CTA / banner.
    var isDemo: Bool { demoMode }

    /// Convenience for downstream components (RTP streamer) that need
    /// the dash IP without poking at the link's internals. In demo mode we
    /// still return `bikeHost` while "connected" so callers that gate on a
    /// non-nil host (e.g. `AppStatus.startStreaming`) proceed — nothing real
    /// is ever sent to it.
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
    /// so toggling Wi-Fi can't extend the reconnect budget past the moment
    /// the link first dropped.
    private var reconnectDeadline: Date?

    /// Wi-Fi presence monitor. A dropped Wi-Fi path is a faster, cleaner
    /// drop signal than waiting for a heartbeat `sendto` to error, and
    /// its return lets us retry the instant the rider walks back in range
    /// instead of waiting out the retry interval.
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var pathMonitorStarted = false
    private var lastWifiSatisfied = true

    /// True while `runConnectFlow` is actively executing (socket open,
    /// handshake in progress). Guards `wakeReconnect()` against tearing down
    /// and restarting the reconnect loop while an attempt is already live.
    /// Task cancellation is cooperative and NOT observed inside the
    /// handshake's `for await packet in socket.inbound` receive loop, so
    /// cancelling `reconnectTask` while a `runConnectFlow` call is mid-flight
    /// does NOT stop it — the abandoned flow keeps its own DashSocket alive
    /// on the same local port (:2002, allowed to coexist via SO_REUSEADDR),
    /// racing the brand-new flow's socket for the dash's replies. Field-tested
    /// 8/2026 (bike switched off/on mid free-ride, Wi-Fi flapping while the
    /// dash's AP came back up): the reconnect attempt counter visibly reset
    /// mid-sequence — proof of a second overlapping loop — with rx=0
    /// handshake timeouts on both flows, while the dash itself reported
    /// "iPhone connected" (one of the racing flows DID complete a real
    /// pairing) and the app stayed stuck cycling through `.reconnecting`.
    private var connectFlowInFlight = false

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

    /// Called on the main actor for each decoded joystick / button event
    /// from the dash (after the wire ack has been sent). AppStatus wires
    /// this to drive map zoom etc. `nil` → events are still acked and
    /// logged, just not routed anywhere (e.g. before wiring, or in tests).
    var onButton: ((K1GPacket.DashButton) -> Void)?

    init() {
        let d = UserDefaults.standard
        self.bikeHost = d.string(forKey: Self.bikeHostKey) ?? K1G.bikeIPv4
        self.ssid = d.string(forKey: Self.ssidKey) ?? ""
        self.demoMode = d.bool(forKey: Self.demoModeKey)
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
        case .connecting where connectTask == nil:
            // Pre-join state set by `beginWifiJoin()` before the Wi-Fi
            // associate completes — no connect flow is running yet, so this
            // is the real start of the handshake, not a duplicate. Fall
            // through and begin the connect flow.
            break
        case .connecting, .handshaking, .connected:
            log.warning("connect() called while in state \(String(describing: self.state))")
            return
        }
        // Demo mode: fake an established link. We skip the socket + RSA
        // handshake entirely, jump straight to `.connected`, and start NONE of
        // the real machinery (path monitor already armed above is harmless — it
        // never drives a demo link because we never arm `shouldAutoReconnect`).
        // Everything downstream keys off `state == .connected` and the demo
        // guards on the send helpers, so the rest of the app runs its real
        // pipeline against a link that quietly swallows nothing (no socket).
        if demoMode {
            lastError = nil
            state = .connected
            // Deliberately do NOT set shouldAutoReconnect / heartbeat /
            // inbound loop — there is no socket to beat on or listen to.
            log.info("Demo mode: fake link connected (no socket, no handshake)")
            return
        }
        connectTask = Task { await self.runInitialConnect() }
    }

    /// Drive a FRESH (non-reconnect) connect attempt, silently retrying up to
    /// `K1G.bootRaceMaxAttempts` times if — and only if — the failure is the
    /// dash-still-booting race (`.bootRaceMissingReply`, covering BOTH
    /// `HandshakeError.noReplyAtAll` — step1 got zero reply packets at all —
    /// AND `.authNotReady` — step3 got no auth-OK despite the dash actively
    /// sending other traffic the whole time). Any OTHER failure (bad reply,
    /// wrong Wi-Fi, cancellation) surfaces immediately as before — this is
    /// narrowly scoped to race conditions that are expected and self-
    /// resolving within a few seconds of the dash finishing its own boot.
    ///
    /// Field evidence (8/2026): connecting right as the dash's screen showed
    /// "iPhone connected" (Wi-Fi/AP layer ready) but its K1G control-plane
    /// task wasn't listening yet — step 1 got rx=0 and timed out after 5s.
    /// Previously that single failure dropped straight to `.error`, forcing
    /// the rider to notice and tap Connect again by hand. A second flavour
    /// surfaced later the same month: step1 succeeded (pubkey exchanged)
    /// but step3 timed out with rx=33 — the dash was chattering normally
    /// (status/telemetry broadcasts) while still finishing its OWN internal
    /// auth processing, so 07/01 never arrived in time. Same root cause
    /// (dash mid-boot), same fix (retry the whole handshake fresh).
    private func runInitialConnect() async {
        var attempt = 0
        while true {
            attempt += 1
            let result = await runConnectFlow(isReconnect: false)
            switch result {
            case .connected, .cancelled:
                connectTask = nil
                return
            case .otherFailure:
                connectTask = nil
                return
            case .bootRaceMissingReply(let msg):
                if attempt >= K1G.bootRaceMaxAttempts {
                    log.warning("Boot-race retries exhausted (\(attempt) attempts) — surfacing error")
                    lastError = msg
                    state = .error(msg)
                    connectTask = nil
                    return
                }
                log.info("Dash not answering yet (boot race, attempt \(attempt)/\(K1G.bootRaceMaxAttempts)) — retrying silently")
                try? await Task.sleep(nanoseconds: UInt64(K1G.bootRaceRetryInterval * 1_000_000_000))
                // `try?` swallows CancellationError from the sleep above, so
                // disconnect() cancelling this Task mid-pause would otherwise
                // be silently ignored and the loop would keep retrying after
                // the user backed out. Check explicitly and bail like the
                // `.cancelled` branch would.
                if Task.isCancelled {
                    log.info("Boot-race retry loop cancelled by user")
                    connectTask = nil
                    return
                }
                // Loop: state stays .connecting/.handshaking, no error flash.
            }
        }
    }

    /// Report a Wi-Fi join failure from the app layer (AppStatus.connect):
    /// the phone couldn't associate with the bike's AP, so there's no point
    /// starting the handshake. Surface it as a normal link error so the UI
    /// shows the reason and offers a retry.
    func reportJoinFailure(_ message: String) {
        log.error("Wi-Fi join failed: \(message, privacy: .public)")
        lastError = message
        state = .error(message)
    }

    /// Move the link into the "connecting" (Wi-Fi joining) state up front, so
    /// the UI shows "Connecting…" during the several-second AP join+verify
    /// BEFORE the socket/handshake begins. Without this the state stays
    /// `.idle` through the whole join and the button reads "Connect to…"
    /// until the join finally fails/succeeds — looking like nothing happened.
    func beginWifiJoin() {
        lastError = nil
        state = .connecting
        log.info("Wi-Fi join starting — state → connecting")
    }

    /// Tear everything down and return to `.idle`. Safe to call at any
    /// time — including mid-handshake, in which case it cancels the
    /// in-flight connect Task so the user isn't stuck staring at a
    /// "Connecting…" pill until the K1G timeout fires.
    func disconnect() {
        // User-initiated stop: clear the auto-reconnect intent FIRST so a
        // drop signal racing in right now can't re-arm the retry loop.
        log.info("BikeLink disconnected (auto-reconnect cleared)")
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
    }

    // MARK: - Nav projection lifecycle
    //
    // Public hooks for the streamer. Fire-and-forget on the link's seq
    // counter — failures just log; the streamer will start anyway and
    // the worst case is the dash stays on the home screen, which is
    // recoverable by toggling streaming off+on.

    /// Phone → bike: `0x007E` route card, announcing a destination BEFORE
    /// `sendNavStart()`'s q3c.z2. See `K1GPacket.makeRouteCard`'s doc for
    /// why this exists — TL;DR: the dash refuses to allocate its
    /// nav-decoder surface without it, and `ActiveNavLoop` only reaches
    /// for a route-shaped packet (`sendActiveNav`) while actually
    /// navigating, which silently starved free-ride of ANY destination
    /// announcement. Sends `K1G.routeCardBurstCount` copies with
    /// `K1G.routeCardBurstGap` between them, matching the reference
    /// implementation's captured cadence ("the real phone sends 4 copies
    /// over ~1.3s before nav-start" — `better-dash --route-card-pre-z2`
    /// help text). Call BEFORE `sendNavStart()`, not after — order matters
    /// the same way it does for nav-start vs. the RTP stream.
    func sendRouteCard(title: String, includeManeuverPlaceholders: Bool = true) async {
        guard !demoMode else { return }   // demo link has no socket — nothing to kick
        guard state == .connected, let s = socket else {
            // Silent no-op before this fix. `startStreaming` awaits this
            // call assuming it either sent the burst or is a clean no-op
            // (demo mode) — a guard failure here (state raced away from
            // .connected between the reconnect handler's check and this
            // call, or the socket was torn down concurrently) looked
            // IDENTICAL to success from the caller's side, with nothing in
            // any log to say the dash never got a single 0x007E.
            return
        }
        do {
            for i in 0..<K1G.routeCardBurstCount {
                let pkt = K1GPacket.makeRouteCard(
                    title: title,
                    projectionOn: false,
                    seq: seq.consume(),
                    includeManeuverPlaceholders: includeManeuverPlaceholders
                )
                try await s.send(pkt)
                if i < K1G.routeCardBurstCount - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(K1G.routeCardBurstGap * 1_000_000_000))
                }
            }
            log.info("Sent 0x007e route card x\(K1G.routeCardBurstCount, privacy: .public) (title=\(title, privacy: .public))")
        } catch {
            log.error("Route-card send failed: \(error.localizedDescription)")
            // This previously went to os.log only — invisible in a field
            // diagnosis. A send failure here means the dash's
            // nav-decoder-surface gate never even got asked to open.
        }
    }

    /// Resend ONE `0x007E` route card as a keep-alive, with the
    /// projection-on flag SET (`0x55`) — unlike `sendRouteCard`'s pre-z2
    /// burst, which sends it clear (`0xAA`). Mirrors the reference
    /// implementation's split: `route_pkt` for the pre-z2 burst,
    /// `route_pkt_proj_on` for the keep-alive loop
    /// (`better-dash/dash_ui/bike_link.py` `_enter_nav_mode`).
    ///
    /// MUST be called at ~1 Hz for the WHOLE time the stream is live. The
    /// reference's `route_card_keepalive_loop` documents why, from a real
    /// packet capture: "Without this, the dash accepts the initial route
    /// card, allocates the nav decoder surface and starts consuming our
    /// RTP, but its 'destination still valid' watchdog fires after ~15-20s
    /// of no 007E refresh and tears the decoder back down → the user sees
    /// loading dots → timeout even though UDP/5000 was open the whole
    /// time." The real phone's cadence in `nav_open_ok.pcap` is ~1s
    /// (t=18.824, 19.830, 20.830, 21.850, 22.819, 23.860, 24.813).
    ///
    /// Sends the packet WITHOUT its HUD-bearing TLVs
    /// (`includeHudFields: false`) — see `K1GPacket.makeRouteCard`'s doc.
    /// The captured template carries a placeholder maneuver glyph and a
    /// placeholder ETA ("0303"), which at 1 Hz painted a bogus turn arrow
    /// and "ETA 03:03" onto the dash during free-ride (field report,
    /// 8/2026), and during real navigation would have fought
    /// `sendActiveNav`'s genuine values at the same rate. The watchdog only
    /// needs to see a route card; it does not need the HUD fields.
    func sendRouteCardKeepalive(title: String) async {
        guard !demoMode else { return }   // demo link has no socket
        guard state == .connected, let s = socket else {
            // This is the 1 Hz watchdog refresh — if THIS silently no-ops
            // while the rest of the app still thinks it's streaming, the
            // dash's "destination still valid" timer runs out with nobody
            // aware it was ever unfed. Rate-limit isn't needed: state only
            // flips out of .connected occasionally, not every tick.
            return
        }
        let pkt = K1GPacket.makeRouteCard(
            title: title,
            projectionOn: true,
            seq: seq.consume(),
            includeHudFields: false
        )
        try? await s.send(pkt)
    }

    /// Kick the dash into nav projection mode. Call BEFORE starting the
    /// RTP stream. No-op if not connected.
    ///
    /// Sequence mirrors better-dash `send_nav_mode_kick`:
    /// `q3c.z2` (begin nav projection) → `q3c.q` (enter nav context) →
    /// `q3c.r` (favourite lists are empty).
    ///
    /// NOTE on q3c.r: the reference sends all THREE of these together
    /// (`for hex_str in (Q3C_Z2_START_NAV, Q3C_Q_NAV_CTX,
    /// Q3C_R_EMPTY_LISTS)`), and its fuller `_enter_nav_mode` path sends
    /// q3c.q + q3c.r as a pair too. We were only sending z2 + q, silently
    /// dropping q3c.r since this function was written. Added while
    /// auditing the whole nav-entry sequence against the reference
    /// (8/2026) after the route-card discovery — the official app's
    /// `NavigationRootFragment.F0()` pairs q + r unconditionally, and
    /// "lists are empty" is permanently true for this app (no favourites
    /// feature), so there is no case where omitting it is correct.
    func sendNavStart() async {
        guard !demoMode else { return }   // demo link has no socket — nothing to kick
        guard state == .connected, let s = socket else {
            return
        }
        let z2 = K1GPacket.makeStartNav(seq: seq.consume())
        let q  = K1GPacket.makeNavContext(seq: seq.consume())
        let r  = K1GPacket.makeEmptyLists(seq: seq.consume())
        do {
            try await s.send(z2)
            try await s.send(q)
            try await s.send(r)
            log.info("Sent nav-mode kick (q3c.z2 + q3c.q + q3c.r)")
        } catch {
            log.error("Nav-mode kick failed: \(error.localizedDescription)")
        }
    }

    /// Latch the "projection video is live" flag. Call right after the
    /// RTP UDP connection is .ready and the first H.264 frame is on the
    /// way. No-op if not connected.
    func sendProjectionOn() async {
        guard !demoMode else { return }   // demo: no socket, nothing to latch
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

    /// Handle one decoded button event from the inbound loop: echo the
    /// wire ack (fire-and-forget) so the firmware keeps sending events,
    /// then route the recognised button to `onButton`. Unrecognised codes
    /// are still acked (the dash asked for it) but not routed.
    private func handleButton(code: UInt8) {
        // Ack every code the dash sends, recognised or not — the ack is
        // what keeps the event stream flowing on picky firmwares.
        if let s = socket {
            let ack = K1GPacket.makeButtonAck(code: code, seq: seq.consume())
            #if DEBUG
            self.log.info("BTN pipeline: code=0x\(String(format: "%02X", code), privacy: .public) → sending ack \(ack.prefix(16).hexString, privacy: .public)")
            #endif
            Task { try? await s.send(ack) }
        } else {
            #if DEBUG
            self.log.info("BTN pipeline: code=0x\(String(format: "%02X", code), privacy: .public) but socket==nil → NO ack sent")
            #endif
        }
        guard let button = K1GPacket.DashButton(code: code) else {
            log.info("RX button code 0x\(String(format: "%02X", code), privacy: .public) NOT mapped to a DashButton — acked only, no action")
            return
        }
        #if DEBUG
        self.log.info("BTN pipeline: code=0x\(String(format: "%02X", code), privacy: .public) → \(String(describing: button), privacy: .public) → routing to onButton (hooked=\(self.onButton != nil, privacy: .public))")
        #endif
        onButton?(button)
    }

    /// Tear down the nav projection. Call BEFORE stopping the RTP stream.
    /// No-op if not connected.
    ///
    /// Sequence mirrors NavigationFragment.Y7:
    /// `q3c.h` (stop-frames) → `q3c.x` (projection off).
    func sendNavStop() async {
        guard !demoMode else { return }   // demo: no socket, nothing to tear down
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
        guard !demoMode else { return }   // demo: bubble is mirrored on-screen, not sent
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

    /// Outcome of one `runConnectFlow` attempt, distinguishing a failure
    /// where the dash likely just hasn't finished booting yet from any other
    /// failure. See `runInitialConnect`'s doc for why this distinction
    /// matters.
    private enum ConnectAttemptResult {
        case connected
        case cancelled
        /// Step 1 (waiting for the dash's RSA modulus+exponent reply) got
        /// NO usable reply at all before the timeout. On a FRESH (non-
        /// reconnect) connect this is the classic dash-still-booting race:
        /// the phone associates to the AP and the phone-side K1G socket
        /// opens well before the dash's own K1G control-plane task is alive
        /// to answer the handshake — meanwhile the dash's Wi-Fi/AP layer
        /// (a lower level, independent of K1G readiness) already reports
        /// "iPhone connected" on its screen. Retryable without surfacing an
        /// error to the rider.
        case bootRaceMissingReply(String)
        case otherFailure(String)
    }

    @discardableResult
    private func runConnectFlow(isReconnect: Bool = false) async -> ConnectAttemptResult {
        // Mark this attempt as live for the whole call, including every exit
        // path (return / throw) below. See connectFlowInFlight's doc: this is
        // what lets wakeReconnect() refuse to overlap a second attempt on top
        // of one that's still mid-handshake.
        connectFlowInFlight = true
        defer { connectFlowInFlight = false }
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
            // re-establishes and we time out after the reconnect budget.
            seq.reset()
            // Forget the last call state we pushed so a fresh link re-syncs
            // the live state (the dash reboots its own call card on a new
            // session; replaying our last in-memory state would otherwise be
            // suppressed by the de-dup guard in `sendCallState`).
            lastCallState = nil
            // Preflight: verify we're actually associated with the bike's AP
            // BEFORE opening the socket and firing the handshake burst.
            // Without this, a "connect" attempted away from the bike (Wi-Fi
            // joined to some OTHER network, or NEHotspotConfiguration.apply
            // having merely *saved* the config without truly associating) sails
            // into the handshake and hangs — the dash never answers, rx stays
            // 0, and the UI spins on "Handshaking…" until the whole budget
            // elapses. Checking the live SSID up front turns that silent hang
            // into an immediate, honest error.
            if !isReconnect {
                // Only abort if we can positively confirm we're on a
                // DIFFERENT network. `NEHotspotNetwork.fetchCurrent` frequently
                // returns nil even while genuinely associated (Location cache
                // lag right after a join, precise-location quirks), so nil must
                // mean "SSID unknown" — NOT "not on Wi-Fi". Treating nil as a
                // failure false-negatived real bikes: WiFiJoiner reported
                // "Already associated" yet the preflight read nil and aborted
                // before the handshake ever ran. When the SSID is unreadable we
                // proceed and let the handshake's rx=0 timeout catch a network
                // that's genuinely dead.
                let liveSSID = await Self.currentWifiSSID()
                if let liveSSID, liveSSID != ssid {
                    log.error("[\(ms(), privacy: .public)ms] Preflight failed: expected SSID \"\(self.ssid, privacy: .public)\" but on \"\(liveSSID, privacy: .public)\"")
                    throw HandshakeError.notOnDashNetwork(expected: ssid, actual: liveSSID)
                }
                let onNote = liveSSID.map { "on \"\($0)\"" } ?? "SSID unreadable — proceeding on WiFiJoiner's confirmation"
            }
            // Wait for the Wi-Fi path to become usable before opening the
            // socket. Association (WiFiJoiner's "Already associated") only means
            // the link-layer is up — DHCP can still be in flight for another
            // 1-3s, so the phone may not yet have an IPv4 lease / default route
            // on en0. Firing the handshake burst into a not-yet-ready interface
            // means the datagrams go nowhere, the dash never answers, and we eat
            // the full rx=0 handshake timeout for no reason. Blocking briefly on
            // a dash-subnet IPv4 check closes that gap. Best-effort: if the wait
            // times out we proceed anyway and let the handshake timeout be the
            // backstop.
            //
            // ALSO run this on reconnect, not just a fresh connect. Field
            // evidence (8/2026): a `wifi-path-down` drop → reconnect while
            // mid-ride hit the EXACT same rx=0-forever pattern this wait was
            // built to fix, but every reconnect attempt skipped it on the
            // (wrong, for THIS trigger) assumption that "the path is already
            // up" on reconnect. A `wifi-path-down` drop means the radio itself
            // flapped — en0 has to re-associate AND re-acquire its DHCP lease
            // on the way back, same as a cold join, yet the dash's screen
            // already shows "iPhone connected" (AP/L2 layer) well before that
            // finishes, so there's no on-screen signal telling the rider
            // anything is still wrong. Without this wait the reconnect loop
            // burned its whole reconnect budget re-sending the burst into a dead
            // interface every 5s, always rx=0, never recovering on its own.
            isWaitingForWifi = true
            await waitForWifiReady(startedAt: t0)
            isWaitingForWifi = false
            try Task.checkCancellation()
            // NOTE: no AP re-join here, deliberately. An earlier revision
            // called `WiFiJoiner.ensureJoined()` from this point when the
            // interface check failed, which did fix the "reconnect never
            // recovers" bug — but `NEHotspotConfigurationManager.apply` can
            // raise a system "Do you want to join the Wi-Fi network …?"
            // dialog, and rate-limiting it was not enough: the rider's actual
            // scenario is walking up to the bike at a petrol station,
            // starting it and riding off WITHOUT taking the phone out of
            // their pocket, so nobody is ever there to tap "Join". A dialog
            // nobody can answer is worse than no dialog.
            //
            // We rely on iOS auto-join instead, which is sound because the
            // network is already persisted: `WiFiJoiner.register` runs when
            // the rider adds the bike and applies the configuration with
            // `joinOnce = false` precisely so iOS knows the AP and
            // re-associates on its own whenever the bike powers up in range.
            // The reconnect loop's job is therefore to WAIT for that to
            // happen, not to force it — `waitForWifiReady` above polls for a
            // dash-subnet address, and the retry loop keeps re-entering this
            // flow for the full reconnect budget, so a late auto-join is
            // picked up as soon as it lands.
            if isReconnect, !Self.wifiHasDashSubnetIPv4() {
                log.notice("[\(ms(), privacy: .public)ms] No dash-subnet IPv4 — waiting for iOS auto-join (no dialog)")
            }
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
            return .connected

        } catch is CancellationError {
            // disconnect() yanked us. State + cleanup already handled
            // there; just log and exit silently — no error pill.
            log.info("Connect flow cancelled by user")
            isWaitingForWifi = false
            await self.socket?.cancel()
            self.socket = nil
            return .cancelled
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Connect flow failed: \(msg, privacy: .public)")
            isWaitingForWifi = false
            await self.socket?.cancel()
            self.socket = nil
            self.lastError = msg
            let isBootRace = (error as? HandshakeError).map {
                switch $0 {
                case .noReplyAtAll, .authNotReady: return true
                // `missingSegment` during step 1 (dash sent SOME traffic —
                // its own boot-time housekeeping segments, e.g. the field
                // log's 0C/03, 0C/05, 0C/06 — but not modulus+exponent
                // yet) is the SAME "K1G control-plane task still catching
                // up" race as `noReplyAtAll`/`authNotReady`, just with a
                // couple of stray packets landing first. Treating it as a
                // plain failure denied it the fast boot-race retry
                // interval on reconnect and the silent-retry treatment on
                // a fresh connect. Field log (8/2026): a reconnect's 2nd
                // attempt got exactly this (dash chattering `0C/xx`
                // housekeeping while the K1G handshake task wasn't ready)
                // and paid the full 5.0s `reconnectInterval` instead of
                // the 2.0s `bootRaceRetryInterval` — one contributor to a
                // reconnect during active navigation taking 50s and 5
                // attempts while the dash's own screen already showed
                // "iPhone connected" (AP/L2 layer, independent of K1G
                // readiness) the whole time.
                case .missingSegment: return true
                default: return false
                }
            } ?? false
            if isReconnect {
                // Stay in `.reconnecting`; the retry loop sleeps + tries
                // again (until it hits the reconnect deadline). Still tag
                // `bootRaceMissingReply` here too (not just on a fresh
                // connect) so the retry loop can use the SAME short
                // `bootRaceRetryInterval` for this specific failure shape
                // instead of the full `reconnectInterval` — see
                // `startReconnectLoop`'s doc for the field evidence this
                // fixes (rider reconnect during free-ride timed out on the
                // dash's own screen while the phone was still slow-
                // cycling through 5s handshake-timeout + 5s sleep pairs).
                return isBootRace ? .bootRaceMissingReply(msg) : .otherFailure(msg)
            } else if isBootRace {
                // Leave `state` as `.connecting`/`.handshaking` — the caller
                // (`runInitialConnect`) silently retries a few times before
                // ever surfacing an error pill. Setting `.error` here would
                // flash it on screen for the ~2s gap between attempts.
                return .bootRaceMissingReply(msg)
            } else {
                self.state = .error(msg)
                return .otherFailure(msg)
            }
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
        // Fresh drop episode — don't inherit a stale silent-attempt run from
        // an earlier one, or the UI could claim the dash is wedged on this
        // episode's very first attempt.
        consecutiveSilentAttempts = 0
        // Absolute reconnect budget from the moment we dropped — survives
        // `wakeReconnect` so repeated Wi-Fi toggles can't extend it.
        reconnectDeadline = Date().addingTimeInterval(K1G.reconnectMaxDuration)
        startReconnectLoop()
    }

    /// Retry `runConnectFlow(isReconnect:)` every `reconnectInterval`
    /// until it succeeds, the user cancels, or the reconnect deadline passes.
    /// A `bootRaceMissingReply` result (dash's K1G task not answering
    /// yet — same failure shape `runInitialConnect` silently fast-retries
    /// on a fresh connect) uses the shorter `bootRaceRetryInterval`
    /// instead of the full `reconnectInterval`. Field evidence (8/2026):
    /// a `wifi-path-down` drop mid-free-ride needed 2-3 reconnect attempts
    /// to succeed, EVERY one of them rx=0 (classic boot-race — the radio
    /// itself has to re-associate + the dash's K1G task has to notice and
    /// come back up, same as a cold connect), but each attempt was paying
    /// the full 5.0s handshake timeout PLUS the full 5.0s reconnectInterval
    /// sleep — 20-35s total before the phone recovered, well past the
    /// dash's own connection-timeout screen. Using the 2.0s
    /// bootRaceRetryInterval for this specific shape (unrelated to
    /// giving up early: the reconnect deadline check above still applies
    /// every iteration) cuts that gap roughly in half without touching
    /// the failure-classification logic itself.
    private func startReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled, self.shouldAutoReconnect {
                // reconnect-budget hard cap. Give up → `.error`
                // so the bottom bar offers Connect again instead of
                // spinning forever and draining the battery.
                if let deadline = self.reconnectDeadline, Date() >= deadline {
                    self.log.warning("Reconnect gave up after \(K1G.reconnectMaxDuration, privacy: .public)s")
                    self.shouldAutoReconnect = false
                    self.reconnectDeadline = nil
                    // Derive the user-facing text from the constant rather
                    // than hardcoding a duration: it read "after 10 min" and
                    // silently became a lie when the budget was raised.
                    let mins = Int(K1G.reconnectMaxDuration / 60)
                    self.lastError = "Reconnect timed out after \(mins) min"
                    self.state = .error("Reconnect timed out after \(mins) min")
                    return
                }
                attempt += 1
                self.log.info("Reconnect attempt #\(attempt)")
                let result = await self.runConnectFlow(isReconnect: true)
                let retryDelay: TimeInterval
                switch result {
                case .connected:
                    self.log.info("Reconnected after \(attempt) attempt(s)")
                    self.consecutiveSilentAttempts = 0
                    return
                case .bootRaceMissingReply:
                    // Datagrams left the phone; the dash never replied. On a
                    // fresh ignition this is just the dash still booting, so
                    // only a sustained run of these means it is wedged — see
                    // `dashUnresponsive`.
                    self.consecutiveSilentAttempts += 1
                    retryDelay = K1G.bootRaceRetryInterval
                case .cancelled, .otherFailure:
                    // A different failure shape (sendto refused, cancelled,
                    // handshake error): whatever we were seeing before, this
                    // is not the wedged-dash pattern any more.
                    self.consecutiveSilentAttempts = 0
                    retryDelay = K1G.reconnectInterval
                }
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
    }

    /// Short-circuit the retry interval — restart the loop immediately so
    /// we attempt a connection right now (e.g. the rider walked back into
    /// Wi-Fi range, or tapped Connect). Preserves the existing
    /// `reconnectDeadline`, so the reconnect budget is not extended.
    ///
    /// Guarded on `!connectFlowInFlight`: cancelling `reconnectTask` here does
    /// NOT stop an attempt that's already inside `runConnectFlow` — Swift task
    /// cancellation is cooperative and the handshake's receive loop never
    /// checks it — so restarting the loop while one is live would open a
    /// SECOND DashSocket on the same port and race the abandoned one for the
    /// dash's replies, corrupting both (field-tested 8/2026: visible attempt-
    /// counter reset + rx=0 timeouts on both flows while the dash itself
    /// reported "iPhone connected"). If a wake signal arrives mid-attempt we
    /// just let that attempt run to completion; the path-monitor / heartbeat
    /// triggers that call this are best-effort nudges, not a queue.
    func wakeReconnect() {
        guard state == .reconnecting, shouldAutoReconnect else { return }
        guard !connectFlowInFlight else {
            log.info("Reconnect wake skipped — an attempt is already in flight")
            return
        }
        log.info("Reconnect woken (retry now)")
        startReconnectLoop()
    }

    /// Wait (best-effort, bounded) for the Wi-Fi interface to become usable
    /// after association — i.e. DHCP has handed us an IPv4 lease on en0 in the
    /// dash's subnet — before we open the socket and fire the handshake. The
    /// dash AP is a fixed `192.168.1.x` network, so "usable" means en0 has a
    /// `192.168.1.*` address (not just any Wi-Fi address, and not a stale
    /// cellular/other-network one). Polls every 250 ms up to ~4 s. Returns as
    /// soon as the interface is ready; on timeout it returns anyway and lets the
    /// handshake's rx=0 timeout be the real backstop — we never want to block a
    /// genuine connect just because the address probe was unlucky.
    private func waitForWifiReady(startedAt t0: Date) async {
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        let maxTries = 20          // 20 × 250 ms ≈ 5 s
        for attempt in 0..<maxTries {
            if Self.wifiHasDashSubnetIPv4() {
                if attempt > 0 {
                    log.info("[\(ms(), privacy: .public)ms] Wi-Fi ready after \(attempt * 250, privacy: .public)ms wait (en0 has dash-subnet IPv4)")
                }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        log.notice("[\(ms(), privacy: .public)ms] Wi-Fi not confirmed ready after \(self.maxWifiWaitMs, privacy: .public)ms — proceeding, handshake timeout is the backstop")
    }

    private let maxWifiWaitMs = 5000

    /// True when the Wi-Fi interface (en0) currently has an IPv4 address in the
    /// dash's `192.168.1.0/24` subnet — the positive signal that DHCP finished
    /// and the interface is routable to the bike. Uses `getifaddrs`; no
    /// permissions needed (unlike SSID reads). `nonisolated` so the poll loop
    /// doesn't thrash the actor.
    nonisolated static func wifiHasDashSubnetIPv4() -> Bool {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return false }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            guard name == "en0", let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var addr = sockaddr_in()
            memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if ip.hasPrefix("192.168.1.") { return true }
        }
        return false
    }

    /// The SSID of the Wi-Fi network the phone is currently associated with,
    /// or nil when not on Wi-Fi (or the SSID can't be read). Backed by
    /// `NEHotspotNetwork.fetchCurrent`, which reports the *actual* associated
    /// network — unlike `NWPathMonitor`, which only says "Wi-Fi is up" without
    /// telling us *which* AP. Reading the SSID needs Location permission, which
    /// the app already holds for navigation. `nonisolated` so the preflight can
    /// await it without hopping actors.
    nonisolated static func currentWifiSSID() async -> String? {
        await withCheckedContinuation { cont in
            NEHotspotNetwork.fetchCurrent { network in
                cont.resume(returning: network?.ssid)
            }
        }
    }

    /// Start the Wi-Fi path monitor once. A `.unsatisfied` Wi-Fi path on
    /// an established link is treated as a drop; a `.satisfied` transition
    /// while reconnecting wakes the retry immediately.
    private func startPathMonitorIfNeeded() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
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
        //
        //    The wait is a wall-clock timeout race. A plain
        //    `for await packet in socket.inbound` blocks on the NEXT element,
        //    so when the dash never answers (rx=0) an in-loop deadline check
        //    never runs and we'd hang until the socket is torn down (~18s in
        //    the field log). Racing the consume against a sleep guarantees we
        //    bail after handshakeStepTimeout even with zero packets. The
        //    consumer task RETURNS the pubkey (no shared-state mutation across
        //    the actor boundary — Swift 6 safe), but a `rxCountBox` is shared
        //    (NSLock-guarded, mirrors `RollingSeq`) so the TIMEOUT task can
        //    also tell "dash never replied at all" (rx=0 — the dash-boot
        //    race, retryable) from "dash replied but never sent a usable
        //    pair" (a real failure) when IT is the one that wins the race.
        let rxCountBox = RxCountBox()
        let pubkey = try await withThrowingTaskGroup(of: (modulus: Data, exponent: Data).self) { group in
            group.addTask { [socket] in
                var modulus: Data?
                var exponent: Data?
                var rxCount = 0
                for await packet in socket.inbound {
                    try Task.checkCancellation()
                    rxCount += 1
                    rxCountBox.value = rxCount
                    let segs = K1GPacket.decode(packet)
                    let segSummary = segs.isEmpty
                        ? "no decodable segments"
                        : segs.map { String(format: "%02X/%02X(\($0.payload.count)B)", $0.type, $0.sub) }.joined(separator: " ")
                    for seg in segs where seg.type == K1G.SegType.auth.rawValue {
                        if seg.sub == K1G.AuthSub.modulus.rawValue { modulus = seg.payload }
                        if seg.sub == K1G.AuthSub.exponent.rawValue { exponent = seg.payload }
                    }
                    if let modulus, let exponent { return (modulus, exponent) }
                }
                // Stream ended before we got both segments.
                if rxCount == 0 {
                    throw HandshakeError.noReplyAtAll("modulus or exponent (inbound stream ended)")
                }
                throw HandshakeError.missingSegment("modulus or exponent (inbound stream ended, rx=\(rxCount))")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(K1G.handshakeStepTimeout * 1_000_000_000))
                if rxCountBox.value == 0 {
                    throw HandshakeError.noReplyAtAll("modulus+exponent within \(K1G.handshakeStepTimeout)s")
                }
                throw HandshakeError.missingSegment("modulus+exponent within \(K1G.handshakeStepTimeout)s")
            }
            // First task to finish wins; cancel the other (the timeout, or the
            // still-blocked stream consumer).
            do {
                guard let result = try await group.next() else {
                    throw HandshakeError.missingSegment("modulus or exponent")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                log.error("[\(ms(), privacy: .public)ms] handshake step1 failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        let modulus = pubkey.modulus
        let exponent = pubkey.exponent
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
                throw HandshakeError.authNotReady("auth-OK within \(K1G.handshakeStepTimeout)s (rx=\(step3Rx) other packets)")
            }
        }
        throw HandshakeError.authNotReady("auth-OK (stream ended)")
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
                #if DEBUG
                let rawPreview = packet.prefix(64).hexString
                self.log.info("RX raw #\(packetCount, privacy: .public): \(packet.count, privacy: .public) B  \(rawPreview, privacy: .public)\(packet.count > 64 ? " …" : "", privacy: .public)")
                #endif
                let segs = K1GPacket.decode(packet)
                if segs.isEmpty {
                    #if DEBUG
                    // Promote the "nothing decoded" case to .info WITH the bytes:
                    // if the dash's button frame doesn't match our K1G decoder,
                    // this is the line that reveals its true shape.
                    self.log.info("RX packet #\(packetCount, privacy: .public): \(packet.count, privacy: .public) B, NO decodable segments — bytes: \(packet.prefix(64).hexString, privacy: .public)")
                    #else
                    self.log.debug("RX packet #\(packetCount): \(packet.count) B, no decodable segments")
                    #endif
                    continue
                }
                for seg in segs {
                    // Button segments (0x09 0x00 …) are the whole reason
                    // this loop exists during bring-up. Log them at INFO
                    // so they're visible in the default Xcode console.
                    if seg.type == 0x09 && seg.sub == 0x00 {
                        // The button code is the LAST byte of the segment
                        // payload — as the DashButton doc says: "the trailing
                        // byte of the 09 00 0001 XX segment". The REAL dash
                        // sends len=0x0001 → a 1-byte payload (e.g. 0900 0001
                        // 14 = LEFT), NOT the 3-byte shape fake_dash happened
                        // to emit. Reading a fixed offset 2 dropped every real
                        // button on the floor (all unmapped → dead zoom). Take
                        // the last byte so both the 1-byte bike frame and the
                        // longer harness frame decode identically.
                        if let byte = seg.payload.last {
                            self.log.info("RX button: code=0x\(String(format: "%02X", byte), privacy: .public) (payload=\(seg.payload.hexString, privacy: .public))")
                            self.handleButton(code: byte)
                        } else {
                            self.log.info("RX button: EMPTY payload (0900 with no code byte)")
                        }
                    } else if seg.type == 0x09 {
                        // A 0x09 event with a DIFFERENT sub-type — the real dash
                        // may frame joystick events under a sub we don't handle.
                        // Surface it so we learn the actual sub byte.
                        self.log.info("RX 0x09 event with sub=0x\(String(format: "%02X", seg.sub), privacy: .public) (NOT 0x00): payload=\(seg.payload.hexString, privacy: .public)")
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
    nonisolated var hexString: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }

    /// Short, log-friendly hex preview: first 32 bytes as space-separated
    /// hex pairs, with "… +N more" suffix if longer. Designed for OSLog
    /// where we want enough bytes to identify K1G headers + first TLV but
    /// not spam the log with 800 B RSA ciphertext.
    nonisolated var hexPreview: String {
        let cap = 32
        if count <= cap {
            return self.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        let head = self.prefix(cap).map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(head) … +\(count - cap) more"
    }
}
