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

enum K1G {

    // MARK: - Network endpoints

    /// UDP port the dash listens on for control-plane traffic.
    static let controlPort: UInt16 = 2002

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
    static let handshakeStepTimeout: TimeInterval = 3.0

    /// Total time we'll keep retrying the handshake before giving up.
    static let handshakeOverallTimeout: TimeInterval = 10.0
}
