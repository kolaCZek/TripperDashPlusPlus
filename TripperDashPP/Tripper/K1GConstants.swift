//
//  K1GConstants.swift
//  TripperDashPP
//
//  Wire-format constants for the K1G protocol Royal Enfield uses between
//  the Tripper TFT dash and the companion phone. These match
//  fake_dash/protocol.py byte-for-byte — when the bike-side test harness
//  changes, this file changes with it.
//
//  References:
//   - tools/fake_dash/fake_dash/protocol.py
//   - better-dash/tripper_app_like_nav.py (decode_ic_to_app_segments,
//     patch_k1g_seq)
//

import Foundation

// Pure compile-time constant namespace. Marked `nonisolated` so these values
// stay readable from nonisolated contexts (e.g. `RtpStreamer.init` default
// args, `deinit`) under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated enum K1G {

    // MARK: - Network endpoints

    /// UDP port the dash actually LISTENS on for the K1G control-plane
    /// (initial burst, heartbeats, nav commands). This is the destination
    /// port for all phone→dash traffic.
    ///
    /// **Watch out**: an earlier revision set this to 2002, because the
    /// `fake_dash` test harness for convenience also listened on 2002.
    /// The real dash does NOT — it listens on 2000, and a phone sending
    /// to 2002 gets silently dropped (rx=0 in the BikeLink log). The
    /// authority is `better-dash/tripper_app_like_nav.py:1572`
    /// (`--udp-port default=2000`). Don't "fix" this back to 2002.
    static let txPort: UInt16 = 2000

    /// UDP port the dash REPLIES on (auth segments, ack frames, status).
    /// We must bind locally to this port so the dash's responses are
    /// delivered to us instead of generating ICMP port-unreachable, which
    /// confuses the dash's protocol state machine. Source of truth:
    /// `better-dash/tripper_app_like_nav.py:1856` (`rx_sock =
    /// open_listen_socket_2002`).
    static let rxPort: UInt16 = 2002

    /// UDP port the dash listens on for the H.264 RTP stream.
    static let rtpPort: UInt16 = 5000

    /// Default address of the Tripper AP. The dash is the gateway/router
    /// when the phone joins the bike's Wi-Fi network.
    static let bikeIPv4: String = "192.168.1.1"

    // MARK: - Wire constants

    /// 4-byte ASCII magic that prefixes the rolling-sequence byte in
    /// every K1G envelope.
    static let magic: [UInt8] = [0x4B, 0x31, 0x47, 0x20]  // "K1G "

    /// 4-byte "IC header marker" that sits between the pad and the magic.
    static let icHeaderMarker: [UInt8] = [0x02, 0x01, 0x00, 0x05]

    // MARK: - Segment types

    /// Top-level segment type byte. Combine with a sub-type for the full
    /// message identity.
    ///
    /// Direction matters: `0x07` (auth) is **bike → phone only** — the dash
    /// uses it for handshake replies (modulus / exponent / status). The
    /// phone never originates a 0x07 segment; outbound auth requests live
    /// under `session` (0x08).
    ///
    /// Confirmed against `better-dash/tripper_app_like_nav.py` outbound
    /// constants (Q3C_E_REQUEST_AUTH starts `… 00 08 04 00 01 01`, not
    /// `… 00 07 04 …`). Sending 0x07 outbound to the real Tripper dash
    /// causes a silent drop and the handshake times out.
    enum SegType: UInt8 {
        case navInfo = 0x05  // phone → bike, nav-info TLVs (q3c.q, q3c.g, q3c.h, active_nav)
        case status  = 0x06  // phone → bike, status TLVs (q3c.w, q3c.x, q3c.z2, button ACKs)
        case auth   = 0x07   // bike → phone, auth replies (sub-types below)
        case session = 0x08  // phone → bike, auth + session payloads (q3c.e, q3c.d)
        case button = 0x09   // bike → phone, joystick / button events
        case nav    = 0x0A   // Turn-by-turn payloads (Phase 6)
    }

    /// Sub-type bytes scoped to `SegType.auth` (bike → phone replies).
    enum AuthSub: UInt8 {
        case modulus  = 0x00  // bike → phone, 128-byte RSA-1024 modulus
        case status   = 0x01  // bike → phone, 0x01=OK, 0x00=fail
        case exponent = 0x03  // bike → phone, RSA exponent (00 01 00 01)
    }

    /// Sub-type bytes scoped to `SegType.session` (phone → bike outbound).
    enum SessionSub: UInt8 {
        case sessionKey   = 0x00  // q3c.d: 128-byte RSA-PKCS1v1.5(ssid ‖ aesKey)
        case requestPubkey = 0x04  // q3c.e: "give me your RSA pubkey" (payload = [0x01])
    }

    /// AES session key length the phone packs at the tail of the
    /// RSA-encrypted q3c.d payload.
    static let aesKeyLength: Int = 32

    /// RSA-1024 ciphertext length. The dash hardcodes this when it sizes
    /// the q3c.d segment (outer_len = 0x95, seg_len = 0x80).
    static let rsaCiphertextLength: Int = 128

    // MARK: - Timing

    /// Heartbeat cadence once the link reaches `.connected`.
    static let heartbeatInterval: TimeInterval = 1.0

    /// Single-step timeout for the handshake exchange (pubkey request → modulus).
    static let handshakeStepTimeout: TimeInterval = 5.0

    /// Total time we'll keep retrying the handshake before giving up.
    static let handshakeOverallTimeout: TimeInterval = 10.0

    /// Delay between auto-reconnect attempts after an established link
    /// drops unexpectedly (heartbeat send error or Wi-Fi path down).
    static let reconnectInterval: TimeInterval = 5.0

    /// Post-z2 warm-up: how long to wait after `sendNavStart()` (q3c.z2 +
    /// q3c.q) before starting the RTP stream, giving the dash time to
    /// actually ALLOCATE ITS NAV-DECODER SURFACE — not just receive the
    /// UDP packet. Captured from the reference `better-dash`
    /// `tripper_app_like_nav.py --pre-z2-wait` (default 0.45s, "captured
    /// from nav_open_ok.pcap: the real phone waits ~450ms" — see that
    /// script's argparse help text, which is the byte-level source of
    /// truth for this protocol).
    ///
    /// Awaiting the z2/q UDP SEND (see `startStreaming()`) closes the
    /// ordering race but NOT this timing gap: a `send()` completing only
    /// means our packet left the socket, not that the dash's firmware
    /// has finished the (apparently non-trivial, ~450ms) work of setting
    /// up a decoder surface for the incoming H.264 stream. Field report
    /// (8/2026), even AFTER the `await sendNavStart()` ordering fix: the
    /// dash still showed its "Press the cast button on RE App!" idle
    /// screen instead of entering nav projection on a reconnect during
    /// free-ride — RTP packets arrived at the dash before its decoder
    /// surface existed to receive them, so it silently dropped back to
    /// idle. Without this the whole q3c.z2/q3c.q kick was, in practice,
    /// advisory rather than a real precondition.
    static let postZ2Warmup: TimeInterval = 0.45

    /// Route-card (`0x007E`) pre-z2 burst count and inter-packet gap.
    /// Reference value ("the real phone sends 4 copies over ~1.3s before
    /// nav-start (frames 1414/1422/1446/1468 in nav_open_ok.pcap). Without
    /// this burst the dash enters nav mode but never allocates the
    /// UDP/5000 decoder surface (observed as continuous port-unreachable
    /// ICMPs)" — `better-dash --route-card-pre-z2`/`--route-card-gap` help
    /// text, defaults 4 / 0.35s). See `K1GPacket.makeRouteCard`'s doc for
    /// the full story of why this packet type exists at all in this app.
    static let routeCardBurstCount = 4
    static let routeCardBurstGap: TimeInterval = 0.35

    /// Minimum gap between two `rejoinWifi` attempts inside one reconnect
    /// episode. `NEHotspotConfigurationManager.apply` can raise a system
    /// "Do you want to join the Wi-Fi network …?" dialog; the reconnect loop
    /// retries every `bootRaceRetryInterval` (2s), so without a cooldown a
    /// stubborn drop turns into an undismissable dialog storm (field report
    /// 8/2026). 30s is long enough that a real association attempt has had
    /// time to complete or fail, short enough not to strand a rider who
    /// genuinely walked out of range and back.
    static let rejoinCooldown: TimeInterval = 30.0

    /// Hard cap on how long we keep auto-reconnecting before giving up
    /// and dropping to `.error`. Rider-confirmed: 10 minutes — long
    /// enough to walk into a petrol station, pay, and walk back.
    static let reconnectMaxDuration: TimeInterval = 600.0

    /// How many times a FRESH connect (not an auto-reconnect) silently
    /// retries after a step-1 handshake timeout with ZERO reply packets
    /// (the "dash still booting" race — see BikeLink.ConnectAttemptResult
    /// .bootRaceMissingReply). 4 attempts × handshakeStepTimeout(5s) +
    /// bootRaceRetryInterval(2s) gaps ≈ 28s, comfortably inside how long
    /// the Tripper's own boot sequence takes to bring its K1G control-plane
    /// task up after its Wi-Fi AP (which is what let the phone associate
    /// and the dash show "iPhone connected") is already alive.
    static let bootRaceMaxAttempts = 4

    /// Delay between silent boot-race retries on a fresh connect.
    static let bootRaceRetryInterval: TimeInterval = 2.0
}
