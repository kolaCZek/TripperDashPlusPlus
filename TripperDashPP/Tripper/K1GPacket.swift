//
//  K1GPacket.swift
//  TripperDashPP
//
//  Encode and decode K1G envelopes. Mirrors fake_dash/protocol.py
//  (build_envelope, decode_packet, patch_seq) so tests on either side
//  speak the same bytes.
//
//  Wire layout (big-endian throughout):
//
//      [outer_len: u16]            ← patched after assembly
//      [seg_count: u16]
//      [pad: 4 bytes 0x00]
//      [marker: 02 01 00 05]
//      [magic: "K1G "]
//      [seq: u8]                   ← rolling, patched per-transmission
//      [segments…]
//
//  Each segment is a TLV:
//      [type: u8] [sub: u8] [seg_len: u16] [payload…]
//

import Foundation

struct K1GSegment: Equatable, Sendable {
    let type: UInt8
    let sub: UInt8
    let payload: Data

    init(type: UInt8, sub: UInt8, payload: Data) {
        self.type = type
        self.sub = sub
        self.payload = payload
    }

    init(type: K1G.SegType, sub: UInt8, payload: Data) {
        self.init(type: type.rawValue, sub: sub, payload: payload)
    }
}

enum K1GPacket {

    // MARK: - Encode

    /// Build a complete K1G envelope from one or more segments. The
    /// returned `Data` already has `outer_len` patched to the final size
    /// and the rolling sequence byte set to `seq`.
    ///
    /// The `seg_count` field is always emitted as `actual_count + 1`. This
    /// mirrors `better-dash/tripper_app_like_nav.py` (`seg_count = len(tlvs) + 1`
    /// in `active_nav_packet`, and a hardcoded `00 02` in every single-segment
    /// Q3C_* constant). The real Tripper dash appears to use this byte as a
    /// sanity check — packets with the "naive" count silently drop.
    static func encode(segments: [K1GSegment], seq: UInt8) -> Data {
        var body = Data(capacity: 17 + segments.reduce(0) { $0 + 4 + $1.payload.count })

        // outer_len placeholder (2B) — patched at the end
        body.append(contentsOf: [0x00, 0x00])

        // seg_count (2B BE) = actual_count + 1 — see doc comment above.
        body.append(contentsOf: u16BE(UInt16(segments.count + 1)))

        // pad (4B)
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // IC header marker (4B)
        body.append(contentsOf: K1G.icHeaderMarker)

        // K1G magic (4B)
        body.append(contentsOf: K1G.magic)

        // Rolling seq (1B)
        body.append(seq)

        // Segments — TLV each
        for seg in segments {
            body.append(seg.type)
            body.append(seg.sub)
            body.append(contentsOf: u16BE(UInt16(seg.payload.count)))
            body.append(seg.payload)
        }

        // Patch outer_len (2B BE at offset 0)
        let total = UInt16(body.count)
        body[0] = UInt8((total >> 8) & 0xFF)
        body[1] = UInt8(total & 0xFF)

        return body
    }

    // MARK: - Decode

    /// Split a wire-format K1G packet into its TLV segments. Returns an
    /// empty array if the packet is too short or doesn't carry the magic.
    static func decode(_ data: Data) -> [K1GSegment] {
        guard data.count >= 8 else { return [] }
        guard let magicRange = findMagic(in: data) else { return [] }

        // Walk past the magic + 1-byte seq.
        var off = magicRange.upperBound + 1
        var out: [K1GSegment] = []

        while off + 4 <= data.count {
            let type = data[data.index(data.startIndex, offsetBy: off)]
            let sub  = data[data.index(data.startIndex, offsetBy: off + 1)]
            let segLen = readU16BE(data, at: off + 2)
            off += 4
            let end = min(off + Int(segLen), data.count)
            let payload = data.subdata(in: data.index(data.startIndex, offsetBy: off)..<data.index(data.startIndex, offsetBy: end))
            out.append(K1GSegment(type: type, sub: sub, payload: payload))
            off = end
        }
        return out
    }

    // MARK: - Patch (rolling seq + outer_len refresh)

    /// Patch the rolling sequence byte in an already-encoded packet and
    /// refresh `outer_len`. Returns a new `Data` — does not mutate input.
    static func patchSeq(_ packet: Data, seq: UInt8) -> Data {
        guard let magicRange = findMagic(in: packet) else { return packet }
        var out = packet
        let seqIndex = magicRange.upperBound  // byte right after magic
        out[seqIndex] = seq
        let total = UInt16(out.count)
        out[0] = UInt8((total >> 8) & 0xFF)
        out[1] = UInt8(total & 0xFF)
        return out
    }

    // MARK: - Helpers

    private static func findMagic(in data: Data) -> Range<Int>? {
        guard data.count >= K1G.magic.count else { return nil }
        let magic = Data(K1G.magic)
        guard let r = data.range(of: magic) else { return nil }
        let lower = data.distance(from: data.startIndex, to: r.lowerBound)
        let upper = data.distance(from: data.startIndex, to: r.upperBound)
        return lower..<upper
    }

    private static func u16BE(_ v: UInt16) -> [UInt8] {
        return [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func readU16BE(_ data: Data, at offset: Int) -> UInt16 {
        let hi = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
        let lo = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
        return (hi << 8) | lo
    }
}

// MARK: - Rolling sequence

/// Thread-safe monotonic 0..255 counter (wraps on overflow). Mirrors
/// fake_dash/protocol.py:RollingSeq.
final class RollingSeq: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8

    init(start: UInt8 = 0) { self.value = start }

    /// Returns the current value and increments. Wraps at 256.
    func consume() -> UInt8 {
        lock.lock(); defer { lock.unlock() }
        let v = value
        value = value &+ 1
        return v
    }
}

// MARK: - Well-known segments / packets

extension K1GPacket {

    /// Phone → bike: q3c.e (request the bike's RSA pubkey).
    ///
    /// Wire form (matches `better-dash` `Q3C_E_REQUEST_AUTH`):
    /// `00 16  00 02  00 00 00 00  02 01 00 05  K1G   <seq>  08 04 00 01 01`
    ///
    /// Type byte is `0x08` (session, phone → bike), NOT `0x07` (auth, which
    /// is bike → phone only). Earlier revisions of this file used `0x07`
    /// and matched `tools/fake_dash/tests/test_integration.py:65` — but
    /// the real Tripper dash silently drops 0x07 from the phone side.
    static func makeRequestPubkey(seq: UInt8) -> Data {
        let seg = K1GSegment(
            type: .session,
            sub: K1G.SessionSub.requestPubkey.rawValue,
            payload: Data([0x01])
        )
        return encode(segments: [seg], seq: seq)
    }

    /// Phone → bike: q3c.d (RSA-PKCS1v1.5 ciphertext containing
    /// `ssid_bytes ‖ aes_key_bytes`).
    ///
    /// Wire form (matches `better-dash` `Q3C_D_PREFIX_HEX` + 128 B ct):
    /// `00 95  00 02  00 00 00 00  02 01 00 05  K1G   <seq>  08 00 00 80  <128 B ct>`
    static func makeSessionKey(ciphertext: Data, seq: UInt8) -> Data {
        precondition(ciphertext.count == K1G.rsaCiphertextLength,
                     "session key ciphertext must be 128 B (RSA-1024)")
        let seg = K1GSegment(
            type: .session,
            sub: K1G.SessionSub.sessionKey.rawValue,
            payload: ciphertext
        )
        return encode(segments: [seg], seq: seq)
    }
}

// MARK: - Status / heartbeat / metadata builders (raw bytes)
//
// These mirror the `REForeGroundService` 1 Hz timer tasks in the official
// Android Tripper app, captured in `better-dash/tripper_app_like_nav.py`.
// They DON'T go through `encode()` because the `seg_count` field is taken
// straight from the captured Android code (e.g. `0x000A` for the 0044
// heartbeat) rather than computed from segment count — the real dash
// validates this exact byte and drops packets where it doesn't match.

extension K1GPacket {

    /// Music volume bucket TLV (mute + 10 levels). Maps a 0..1 ratio to
    /// the same `054C 0001 1X` byte the Android `REForeGroundService` picks.
    static func musicVolumeTLV(ratio0to1: Double) -> [UInt8] {
        if ratio0to1 <= 0.0 {
            return [0x05, 0x4C, 0x00, 0x01, 0x10] // mute baseline (Q3C_N1)
        }
        let idx = max(0, min(9, Int(ratio0to1 * 10.0)))
        return [0x05, 0x4C, 0x00, 0x01, UInt8(0x11 + idx)]
    }

    /// Alarm volume bucket TLV (mute + 10 levels). `051B 0001 1X`.
    static func alarmVolumeTLV(ratio0to1: Double) -> [UInt8] {
        if ratio0to1 <= 0.0 {
            return [0x05, 0x1B, 0x00, 0x01, 0x10] // mute baseline (Q3C_Y1)
        }
        let idx = max(0, min(9, Int(ratio0to1 * 10.0)))
        return [0x05, 0x1B, 0x00, 0x01, UInt8(0x11 + idx)]
    }

    /// `REForeGroundService.d.run()` 0044 heartbeat (1 Hz). Phone → bike,
    /// reports baseline hardware status: cell signal, engine temp, GPS on,
    /// battery, charging, music + alarm volumes, current nav distance.
    ///
    /// Note: `seg_count = 0x000A` (= 10) is hardcoded — the Android code
    /// emits the same constant regardless of how many TLVs it appends.
    static func makeHeartbeat0044(
        seq: UInt8,
        fixedTempC: Int = 20,
        cellSignal0to255: Int = 160,
        batteryPct0to100: Int = 80,
        gpsOn: Bool = true,
        charging: Bool = false,
        musicRatio0to1: Double = 0.3,
        navDistanceRounded: Int = 0,
        alarmRatio0to1: Double = 0.3
    ) -> Data {
        var body = Data(capacity: 64)

        // Hardcoded header: outer_len placeholder | seg_count=10 | pad | marker | K1G  | seq
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: K1G.icHeaderMarker)
        body.append(contentsOf: K1G.magic)
        body.append(seq)

        // 06 08 00 01 <cell>     — cell signal
        body.append(contentsOf: [0x06, 0x08, 0x00, 0x01, UInt8(cellSignal0to255 & 0xFF)])
        // 06 10 00 01 <temp+40>  — engine temperature
        body.append(contentsOf: [0x06, 0x10, 0x00, 0x01, UInt8((fixedTempC + 40) & 0xFF)])
        // 06 03 00 01 <55|AA>    — GPS on (Q3C_V + Q3C_A/B)
        body.append(contentsOf: [0x06, 0x03, 0x00, 0x01, gpsOn ? 0x55 : 0xAA])
        // 06 04 00 01 <batt+100> — battery capacity (Q3C_U)
        body.append(contentsOf: [0x06, 0x04, 0x00, 0x01, UInt8((batteryPct0to100 + 100) & 0xFF)])
        // 06 0F 00 01 <55|AA>    — charging flag (Q3C_T)
        body.append(contentsOf: [0x06, 0x0F, 0x00, 0x01, charging ? 0x55 : 0xAA])
        // music bucket
        body.append(contentsOf: musicVolumeTLV(ratio0to1: musicRatio0to1))
        // 05 2D 00 02 <distance:u16BE> (Q3C_Q2)
        body.append(contentsOf: [0x05, 0x2D, 0x00, 0x02,
                                 UInt8((navDistanceRounded >> 8) & 0xFF),
                                 UInt8(navDistanceRounded & 0xFF)])
        // alarm bucket
        body.append(contentsOf: alarmVolumeTLV(ratio0to1: alarmRatio0to1))

        // Patch outer_len
        let total = UInt16(body.count)
        body[0] = UInt8((total >> 8) & 0xFF)
        body[1] = UInt8(total & 0xFF)
        return body
    }

    /// `REForeGroundService.e.run()` 0030 metadata (1 Hz). Phone → bike,
    /// trimmed status update sent alongside the 0044 heartbeat: cell
    /// signal, volumes, nav distance. `seg_count = 0x0006` hardcoded.
    static func makeMetadata0030(
        seq: UInt8,
        cellSignal0to255: Int = 160,
        musicRatio0to1: Double = 0.3,
        navDistanceRounded: Int = 0,
        alarmRatio0to1: Double = 0.3
    ) -> Data {
        var body = Data(capacity: 48)

        body.append(contentsOf: [0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: K1G.icHeaderMarker)
        body.append(contentsOf: K1G.magic)
        body.append(seq)

        body.append(contentsOf: [0x06, 0x08, 0x00, 0x01, UInt8(cellSignal0to255 & 0xFF)])
        body.append(contentsOf: musicVolumeTLV(ratio0to1: musicRatio0to1))
        body.append(contentsOf: [0x05, 0x2D, 0x00, 0x02,
                                 UInt8((navDistanceRounded >> 8) & 0xFF),
                                 UInt8(navDistanceRounded & 0xFF)])
        body.append(contentsOf: alarmVolumeTLV(ratio0to1: alarmRatio0to1))

        let total = UInt16(body.count)
        body[0] = UInt8((total >> 8) & 0xFF)
        body[1] = UInt8(total & 0xFF)
        return body
    }

    /// Hostname / Bluconnect identity announce (`0021` packet). Phone → bike,
    /// sent once in the initial burst so the dash can label the device on
    /// its pairing screen.
    static func makeHostnameAnnounce(hostname: String) -> Data {
        let raw = Array(hostname.utf8.prefix(200))
        var body = Data(capacity: 24 + raw.count)

        // Header: 0021 0002 0000 0000  02 01 00 05  K1G
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: K1G.icHeaderMarker)
        body.append(contentsOf: K1G.magic)

        // Tail: 01 06 0B 00 <len+1> <hostname bytes> 00
        body.append(contentsOf: [0x01, 0x06, 0x0B, 0x00, UInt8(raw.count + 1)])
        body.append(contentsOf: raw)
        body.append(0x00)

        let total = UInt16(body.count)
        body[0] = UInt8((total >> 8) & 0xFF)
        body[1] = UInt8(total & 0xFF)
        return body
    }
}

// MARK: - Initial burst

/// Captured 9-packet burst the real Tripper app sends immediately on
/// `REForeGroundService.onCreate`. The dash uses this exact sequence as
/// a discovery + capabilities handshake — if any are missing or out of
/// order it won't transition out of the "Connected to <phone>" pairing
/// state and the RSA handshake never completes.
///
/// Source: `better-dash/tripper_app_like_nav.py:INITIAL_BURST_HEX`.
/// Packet 1 is q3c.e (`makeRequestPubkey`). Packet 2 is the hostname
/// announce. Packets 3-7 are constant capability ACKs (`02060600…` /
/// `055700`/`0556`/`0605`/`0517` families). Packet 8 is a fixed init
/// hint (`08 0A 02 …`). Packet 9 is the initial 0044 status frame.
enum InitialBurst {

    /// Build the 9-packet sequence ready to send (in order, with their
    /// sequence bytes set from `seq`). Pause between sends is the
    /// caller's responsibility (better-dash uses 50–100 ms).
    static func packets(hostname: String, fixedTempC: Int, seq: RollingSeq) -> [Data] {
        let p1 = K1GPacket.makeRequestPubkey(seq: seq.consume())

        let p2 = K1GPacket.makeHostnameAnnounce(hostname: hostname)
        // p2 doesn't carry a K1G seq byte (no rolling counter in 0021),
        // so we don't patch one in.

        // Packets 3-7: capability ACK templates, captured verbatim. Each
        // already has its own embedded seq byte (03, 04, 05, 06) which
        // we leave alone — the dash treats these as a fixed greeting.
        let p3 = Self.hexToData("0018000200000000020100054b31472002060600030e3334")
        let p4 = Self.hexToData("0016000200000000020100054b314720030557000155")
        let p5 = Self.hexToData("0016000200000000020100054b3147200405560001aa")
        let p6 = Self.hexToData("0016000200000000020100054b3147200506050001aa")
        let p7 = Self.hexToData("0016000200000000020100054b3147200605170001aa")

        // Packet 8: init hint (08 0A 02 … aa 55 …). Carries seq 0x08
        // in the template.
        let p8 = Self.hexToData("001d000200000000020100054b314720080a020008aa55000000000000")

        // Packet 9: initial 0044 status frame. Use our heartbeat builder
        // with the same defaults the Android app uses (FF cell, 0x42 batt,
        // music bucket 0x13, alarm bucket 0x19, distance 0).
        var p9 = K1GPacket.makeHeartbeat0044(
            seq: 0x09,
            fixedTempC: fixedTempC,
            cellSignal0to255: 0xFF,
            batteryPct0to100: 2,        // 2 + 100 = 0xA2 (matches captured 0xA2)
            gpsOn: true,
            charging: false,
            musicRatio0to1: 0.3,        // bucket 0x13
            navDistanceRounded: 0,
            alarmRatio0to1: 0.9         // bucket 0x19
        )
        // Also append the captured "extra" tail TLVs the bursts ship:
        // 06 01 00 01 01 (call-state placeholder) + 05 21 00 01 32 (mode flag)
        // + 05 4D 00 01 32 (cell signal echo). These are present in the
        // captured packet but our heartbeat builder omits them because
        // the 1 Hz tick loop doesn't include them either.
        p9.append(contentsOf: [0x06, 0x01, 0x00, 0x01, 0x01,
                               0x05, 0x21, 0x00, 0x01, 0x32,
                               0x05, 0x4D, 0x00, 0x01, 0x32])
        let total9 = UInt16(p9.count)
        p9[0] = UInt8((total9 >> 8) & 0xFF)
        p9[1] = UInt8(total9 & 0xFF)

        return [p1, p2, p3, p4, p5, p6, p7, p8, p9]
    }

    private static func hexToData(_ hex: String) -> Data {
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            if let byte = UInt8(hex[idx..<next], radix: 16) {
                out.append(byte)
            }
            idx = next
        }
        return out
    }
}
