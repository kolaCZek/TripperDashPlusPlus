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
    /// empty array if the packet is too short.
    ///
    /// **Important**: segments start at offset 8, IMMEDIATELY after the
    /// `outer_len(2) + seg_count(2) + pad(4)` header — NOT after the K1G
    /// magic. Outbound (phone → bike) packets do carry the magic + IC
    /// header + rolling seq between offsets 8 and 17, but inbound packets
    /// from the bike typically OMIT them and start the first TLV at
    /// offset 8 directly. The authoritative reference is better-dash
    /// `decode_ic_to_app_segments()` (`tripper_app_like_nav.py:506`),
    /// which slices unconditionally from offset 8.
    ///
    /// An earlier revision of this function searched for the magic
    /// (`4B 31 47 20`) before parsing segments. This worked for the
    /// outbound encode/decode round-trip but silently dropped almost
    /// every inbound packet from the real dash — including the
    /// `07 00 <128B>` RSA modulus reply — because the bike does NOT
    /// include the magic in its handshake replies. Symptom: handshake
    /// step 1 times out with "no decodable segments" on every RX line
    /// even though the modulus byte sequence is clearly present in the
    /// hex dump. See `references/k1g-wire-protocol.md` and the regression
    /// note at the end of `K1GPacket.swift`.
    static func decode(_ data: Data) -> [K1GSegment] {
        guard data.count >= 8 else { return [] }

        // Parse from the fixed-shape header at offsets 0-7.
        let outerLen = Int(readU16BE(data, at: 0))
        let segCount = Int(readU16BE(data, at: 2))
        // pad at 4..7 ignored

        // Trust outer_len when it agrees with the buffer; otherwise fall
        // back to data.count so we don't lose tail TLVs from a slightly
        // mis-sized envelope.
        let limit = (outerLen > 0 && outerLen <= data.count) ? outerLen : data.count

        var off = 8
        var out: [K1GSegment] = []
        // Defensive cap — bike packets in the wild carry at most ~16
        // segments. seg_count is wire-format magic (often 0x0001 or
        // 0x0002 even with more TLVs), so don't trust it as a count;
        // just walk until we run out of bytes or hit a hard sanity cap.
        let maxSegments = max(segCount, 64)

        while off + 4 <= limit && out.count < maxSegments {
            let type = data[data.index(data.startIndex, offsetBy: off)]
            let sub  = data[data.index(data.startIndex, offsetBy: off + 1)]
            let segLen = Int(readU16BE(data, at: off + 2))
            off += 4
            let end = min(off + segLen, limit)
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

    // MARK: - Navigation projection lifecycle
    //
    // Authority: better-dash `tripper_app_like_nav.py:107-130` and the
    // `references/k1g-wire-protocol.md` "Navigation lifecycle" table.
    //
    // The dash gates the nav-video surface on these TLVs regardless of
    // whether RTP packets are arriving on UDP/5000 — without `q3c.q +
    // q3c.z2` it never switches to the projection screen, and without
    // `q3c.w` latched + `q3c.g` per frame it treats the incoming UDP
    // stream as noise and keeps the home widgets visible.
    //
    // Recommended start sequence (mirrors better-dash `send_nav_mode_kick`):
    //   1. `q3c.z2` (START_NAV)        — open the nav projection screen
    //   2. `q3c.q`  (NAV_CTX)          — enter nav context
    //   3. start the RTP/H.264 stream
    //   4. `q3c.w`  (PROJ_ON)          — latch projection-live flag
    //   5. then per frame, send `q3c.g` (PROJ_FRAME) right after each
    //      H.264 frame goes out so the dash knows a new bitmap landed
    //
    // Recommended stop sequence (mirrors NavigationFragment.Y7):
    //   1. `q3c.h`  (PROJ_STOP)        — "no more bitmaps coming"
    //   2. `q3c.x`  (PROJ_OFF)         — "projection video stopped"
    //   3. tear down the RTP stream

    /// Phone → bike: q3c.q "enter nav context". TLV `05 2E 00 01 1E`.
    static func makeNavContext(seq: UInt8) -> Data {
        let seg = K1GSegment(
            type: .navInfo,
            sub: 0x2E,
            payload: Data([0x1E])
        )
        return encode(segments: [seg], seq: seq)
    }

    /// Phone → bike: q3c.z2 "begin nav projection". TLV `06 80 00 01 0B`.
    static func makeStartNav(seq: UInt8) -> Data {
        let seg = K1GSegment(
            type: .status,
            sub: 0x80,
            payload: Data([0x0B])
        )
        return encode(segments: [seg], seq: seq)
    }

    /// Phone → bike: q3c.w "projection video is live". TLV `06 05 00 01 55`.
    /// Latched once when the RTP stream starts producing frames.
    static func makeProjectionOn(seq: UInt8) -> Data {
        let seg = K1GSegment(
            type: .status,
            sub: 0x05,
            payload: Data([0x55])
        )
        return encode(segments: [seg], seq: seq)
    }

    /// Phone → bike: q3c.g "new map bitmap was rendered this tick".
    /// TLV `05 56 00 01 55`. Send this once per encoded H.264 frame.
    static func makeProjectionFrame(seq: UInt8) -> Data {
        let seg = K1GSegment(
            type: .navInfo,
            sub: 0x56,
            payload: Data([0x55])
        )
        return encode(segments: [seg], seq: seq)
    }

    /// Phone → bike: q3c.h "no more bitmaps coming" (stop-frames).
    /// TLV `05 56 00 01 AA`.
    static func makeProjectionStop(seq: UInt8) -> Data {
        let seg = K1GSegment(
            type: .navInfo,
            sub: 0x56,
            payload: Data([0xAA])
        )
        return encode(segments: [seg], seq: seq)
    }

    /// Phone → bike: q3c.x "projection video stopped". TLV `06 05 00 01 AA`.
    static func makeProjectionOff(seq: UInt8) -> Data {
        let seg = K1GSegment(
            type: .status,
            sub: 0x05,
            payload: Data([0xAA])
        )
        return encode(segments: [seg], seq: seq)
    }

    // MARK: - Active navigation TLVs (1 Hz during nav)
    //
    // Authority: `better-dash/tripper_app_like_nav.py` `_nav_tlv_*` builders
    // + skill `references/k1g-wire-protocol.md` "Active navigation" table.
    // All TLVs are nav-info (type 0x05) except the two trailing flags which
    // are status (type 0x06).
    //
    // Each helper here returns a SEGMENT, not a full envelope; combine them
    // through `makeActiveNav(...)` which prefixes the K1G header and computes
    // outer_len / seg_count.

    /// `05 02 0001 <code>` — t3c.g(): primary maneuver glyph code.
    /// The full enum is now cataloged and user-verified against a
    /// Guerrilla 450 (see `docs/maneuver-glyphs/README.md`, 90 entries).
    /// Callers should pass the byte from `ManeuverKind.wireByte`; the
    /// dash renders the matching bubble glyph (turn / roundabout / U-turn
    /// / merge / exit / arrive / …). `0x5A..0xFF` hide the bubble.
    static func tlvPrimaryManeuver(_ code: UInt8) -> K1GSegment {
        K1GSegment(type: .navInfo, sub: 0x02, payload: Data([code]))
    }

    /// `05 04 0002 <meters_BE>` — t3c.h(): distance to the next turn.
    static func tlvPrimaryDistance(meters: UInt16) -> K1GSegment {
        var be = meters.bigEndian
        return K1GSegment(
            type: .navInfo, sub: 0x04,
            payload: Data(bytes: &be, count: 2)
        )
    }

    /// `05 06 0001 <unit>` — t3c.j(): unit byte for primary distance.
    /// Encoded as decimal-ASCII-digit: `10`=km/10ths, `20`=mi/10ths,
    /// `30`=metres, `50`=feet. Pass the wire byte directly (not the
    /// integer 10/20/30/50 — that would be a different value).
    static func tlvPrimaryUnit(_ wireByte: UInt8) -> K1GSegment {
        K1GSegment(type: .navInfo, sub: 0x06, payload: Data([wireByte]))
    }

    /// `05 03 0002 <code> <flags>` — t3c.n(): secondary maneuver glyph,
    /// the look-ahead chevron the dash renders when two turns are
    /// stacked within a few hundred meters (e.g. "turn right onto X,
    /// then immediately left onto Y"). The first byte is the same
    /// glyph enum as the primary maneuver TLV (0x02). The second
    /// byte is undocumented in better-dash and in the Tripper Android
    /// decomp; we send 0x00 as a safe placeholder.
    ///
    /// **F2c TODO**: field-test to determine the second byte's
    /// semantics. Hypotheses worth pcap-bisecting:
    ///   - reserved / padding (most likely, since `0x00` works for the
    ///     primary case and the dash silently accepts it)
    ///   - exit counter for a secondary roundabout (so the rider sees
    ///     "1st exit, then 2nd exit" stacked)
    ///   - bit-flags (CW vs CCW for the secondary glyph, mirrored
    ///     handedness, etc.)
    /// Until field test, treat as 0x00.
    static func tlvSecondaryManeuver(code: UInt8, flags: UInt8 = 0x00) -> K1GSegment {
        K1GSegment(type: .navInfo, sub: 0x03, payload: Data([code, flags]))
    }

    /// `05 05 0002 <meters_BE>` — t3c.o(): distance to the secondary
    /// maneuver. Same wire shape as `tlvPrimaryDistance` (2-byte BE
    /// meters). The dash uses this to render the small "in 1.2 km"
    /// chip next to the secondary chevron.
    static func tlvSecondaryDistance(meters: UInt16) -> K1GSegment {
        var be = meters.bigEndian
        return K1GSegment(
            type: .navInfo, sub: 0x05,
            payload: Data(bytes: &be, count: 2)
        )
    }

    /// `05 07 0001 <unit>` — t3c.p(): unit byte for secondary
    /// distance. Same decimal-ASCII encoding as `tlvPrimaryUnit`
    /// (`0x10`/`0x20`/`0x30`/`0x50`).
    static func tlvSecondaryUnit(_ wireByte: UInt8) -> K1GSegment {
        K1GSegment(type: .navInfo, sub: 0x07, payload: Data([wireByte]))
    }

    /// `05 09 0002 <meters_BE>` — t3c.q(): total distance remaining.
    static func tlvTotalDistance(meters: UInt16) -> K1GSegment {
        var be = meters.bigEndian
        return K1GSegment(
            type: .navInfo, sub: 0x09,
            payload: Data(bytes: &be, count: 2)
        )
    }

    /// `05 46 0001 <unit>` — t3c.r(): unit byte for total distance.
    static func tlvTotalDistanceUnit(_ wireByte: UInt8) -> K1GSegment {
        K1GSegment(type: .navInfo, sub: 0x46, payload: Data([wireByte]))
    }

    /// `05 0A 0001 <55|AA>` — t3c.d() with q3c.A/B: decimal separator.
    /// `useComma=true` → `0xAA` (","), `false` → `0x55` (".").
    static func tlvDecimalSeparator(useComma: Bool) -> K1GSegment {
        K1GSegment(type: .navInfo, sub: 0x0A,
                   payload: Data([useComma ? 0xAA : 0x55]))
    }

    /// `05 08 0004 <ascii_HHMM>` — t3c.e(): ETA as 4 ASCII bytes, e.g.
    /// "18:32" → `31 38 33 32`. Caller passes a Date; we format in the
    /// device's local timezone, 24-hour, zero-padded.
    static func tlvEta(date: Date, calendar: Calendar = .current) -> K1GSegment {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        let s = String(format: "%02d%02d", h, m)
        return K1GSegment(type: .navInfo, sub: 0x08,
                          payload: Data(s.utf8))
    }

    /// `05 54 0001 <byte>` — t3c.f(): ETA format flag.
    ///
    /// **Always `0x30`.** This is the only value the real dash is known to
    /// accept: it is what the real-phone capture `_NAV_FULL` in better-dash
    /// carries (`05 54 0001 30`, road "Taille de Mas du Gr", ETA "0303"),
    /// and the byte lives in the decimal-ASCII-digit family (same `t3c.f` /
    /// `sb.append(int)` encoding as the unit bytes), NOT the `0x55`/`0xAA`
    /// separator-flag family.
    ///
    /// History of this byte, both field-confirmed by Martin:
    ///   * `0x55`/`0xAA` (borrowed from the decimal-SEPARATOR flag) made the
    ///     dash drop the whole ETA block → blank ETA (the original 6/2026
    ///     bug). Fixed to `0x30` for 24h.
    ///   * `0x31` for 12-hour was an UNVERIFIED guess (inferred from the
    ///     digit encoding, no 12h pcap). On a 6/2026 ride Martin set the dash
    ///     to 12-hour and the ETA went BLANK — same failure mode: the dash
    ///     rejects `0x31` and drops the ETA block. So `0x31` is confirmed
    ///     WRONG, not merely unconfirmed.
    ///
    /// We therefore send `0x30` unconditionally. The `0x08` ETA payload is
    /// always 24-hour HH:MM, so on a dash set to 12-hour the rider still sees
    /// the arrival time, rendered in 24-hour form, instead of a blank field.
    /// Driving a genuine 12-hour render is blocked on a real 12h-mode capture
    /// of the OEM app (or a HW bisection) to learn the correct flag — we will
    /// NOT ship another blind guess to the dash. `is24Hour` is retained in the
    /// signature for call-site compatibility but no longer changes the byte.
    static func tlvEtaFormat(is24Hour: Bool) -> K1GSegment {
        _ = is24Hour  // intentionally ignored — see doc comment (0x31 blanks the dash)
        return K1GSegment(type: .navInfo, sub: 0x54,
                          payload: Data([0x30]))
    }

    /// `05 0B 0006 <ascii_DDHHMM>` — q3c.S2: remaining travel time, 6 ASCII
    /// bytes, e.g. 1 day 23 h 45 m → "012345".
    static func tlvRemainingTime(seconds: TimeInterval) -> K1GSegment {
        let total = max(0, Int(seconds.rounded()))
        let days = (total / 86_400) % 100
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let s = String(format: "%02d%02d%02d", days, hours, minutes)
        return K1GSegment(type: .navInfo, sub: 0x0B,
                          payload: Data(s.utf8))
    }

    /// `05 55 0001 20` — q3c.T2: remaining-time unit byte. Always 0x20
    /// per the skill, but the dash also accepts the absence of this TLV.
    static func tlvRemainingUnit() -> K1GSegment {
        K1GSegment(type: .navInfo, sub: 0x55, payload: Data([0x20]))
    }

    /// `05 01 <len> <ascii+0x00>` — t3c.m(): current road name. Truncated
    /// to 60 bytes UTF-8 + null terminator to match the Python authority.
    static func tlvRoadName(_ name: String) -> K1GSegment {
        var bytes = Array(name.utf8.prefix(60))
        bytes.append(0)
        return K1GSegment(type: .navInfo, sub: 0x01,
                          payload: Data(bytes))
    }

    /// `06 05 0001 <55|AA>` — t3c.s(): projection ON flag (mirror of
    /// the standalone `q3c.w` / `q3c.x` latches).
    static func tlvProjectionFlag(on: Bool) -> K1GSegment {
        K1GSegment(type: .status, sub: 0x05,
                   payload: Data([on ? 0x55 : 0xAA]))
    }

    /// `06 0D 0001 <55|AA>` — t3c.t(): decimal-notation flag.
    /// `on=true` (`0x55`) tells the dash to format distances with the
    /// decimal separator. The Python authority defaults to OFF so that
    /// whole-metre values like "500 m" render as integers.
    static func tlvDecimalFlag(on: Bool) -> K1GSegment {
        K1GSegment(type: .status, sub: 0x0D,
                   payload: Data([on ? 0x55 : 0xAA]))
    }

    /// Phone → bike: active-navigation status packet, sent at ~1 Hz while
    /// the rider is following a route. Mirrors
    /// `better-dash` `build_active_nav_packet` but exposes more optional
    /// TLVs (ETA + remaining time + road name + ETA format) so the dash
    /// can render its full nav bubble.
    ///
    /// Caller passes any subset of optional fields. `primaryManeuver`,
    /// `primaryDistanceMeters`, `primaryUnit`, `totalDistanceMeters`,
    /// `totalDistanceUnit`, `useCommaDecimal`, `projectionOn` and
    /// `decimalFmtOn` are required — they form the minimum viable
    /// 8-TLV packet. Order of TLVs is fixed and matches the Python
    /// authority byte-for-byte.
    static func makeActiveNav(
        seq: UInt8,
        primaryManeuver: UInt8 = 0x0B,
        primaryDistanceMeters: UInt16,
        primaryUnit: UInt8,
        secondaryManeuver: UInt8? = nil,
        secondaryFlags: UInt8 = 0x00,
        secondaryDistanceMeters: UInt16? = nil,
        secondaryUnit: UInt8? = nil,
        totalDistanceMeters: UInt16,
        totalDistanceUnit: UInt8,
        useCommaDecimal: Bool,
        projectionOn: Bool = true,
        decimalFmtOn: Bool = false,
        roadName: String? = nil,
        eta: Date? = nil,
        is24Hour: Bool = true,
        remainingSeconds: TimeInterval? = nil
    ) -> Data {
        var segs: [K1GSegment] = []
        if let rn = roadName, !rn.isEmpty {
            segs.append(tlvRoadName(rn))
        }
        segs.append(tlvPrimaryManeuver(primaryManeuver))
        segs.append(tlvPrimaryDistance(meters: primaryDistanceMeters))
        segs.append(tlvPrimaryUnit(primaryUnit))
        // F2c: secondary maneuver chevron (look-ahead). All three
        // sub-TLVs go together — sending just one without the other
        // two would be ill-defined. Insert immediately after the
        // primary block, before ETA, to match the better-dash field
        // ordering from `q3c.java`.
        if let code = secondaryManeuver,
           let dist = secondaryDistanceMeters,
           let unit = secondaryUnit
        {
            segs.append(tlvSecondaryManeuver(code: code, flags: secondaryFlags))
            segs.append(tlvSecondaryDistance(meters: dist))
            segs.append(tlvSecondaryUnit(unit))
        }
        if let eta = eta {
            segs.append(tlvEta(date: eta))
            // ETA format flag MUST immediately follow the ETA value —
            // the dash reads the 0x54 flag to interpret the 0x08 HH:MM
            // payload, and drops a "dangling" ETA whose format flag
            // arrives later in the chain. Matches the better-dash
            // `t3c.w` field order (08 → 54), NOT a trailing flag block.
            segs.append(tlvEtaFormat(is24Hour: is24Hour))
        }
        segs.append(tlvTotalDistance(meters: totalDistanceMeters))
        // Total-distance unit MUST immediately follow the total-distance
        // value, for the same reason: the dash pairs 0x09 (value) with
        // 0x46 (unit) positionally and hides the remaining-distance field
        // when the unit doesn't arrive right after. The old order pushed
        // 0x46 to the end of the chain (after the decimal separator and
        // remaining-time block), so the dash never rendered total
        // distance OR ETA. Authority: better-dash `t3c.w` (09 → 46).
        segs.append(tlvTotalDistanceUnit(totalDistanceUnit))
        segs.append(tlvDecimalSeparator(useComma: useCommaDecimal))
        if let secs = remainingSeconds {
            segs.append(tlvRemainingTime(seconds: secs))
            segs.append(tlvRemainingUnit())
        }
        segs.append(tlvProjectionFlag(on: projectionOn))
        segs.append(tlvDecimalFlag(on: decimalFmtOn))
        return encode(segments: segs, seq: seq)
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
        //
        // Packet 3 carries the **wall-clock set-time TLV** (06/06, 3 B):
        //   - byte 0: hour   (binary, 0..23)
        //   - byte 1: minute (binary, 0..59)
        //   - byte 2: second (binary, 0..59)
        //
        // Decoding history (the captured byte triplet was misinterpreted
        // **twice**, leading to two failed fixes before this one):
        //   1. better-dash captured `0E 33 34` from the stock Android app
        //      and inlined it verbatim. We replayed it on every connect.
        //   2. First fix (commit a632150, 2026-06-21) assumed ASCII for
        //      the minute bytes (`HH '5' '2'`) and parsed `0E 33 34` as
        //      "14:34". Field test at 20:08 sent `14 30 38` ('0','8')
        //      and the dash latched onto **20:48** — proving the byte
        //      isn't ASCII but raw binary (0x30 == 48 dec).
        //   3. This fix: write minutes/seconds as plain binary. Re-reading
        //      the original capture under that decoder yields 14:51:52,
        //      which matches the field observation of 14:51 / 14:52.
        //
        // The dash unconditionally adopts this value as its own RTC and
        // then free-runs forward — that's why the stock RE app keeps the
        // clock right (it sends the real HH:MM:SS here) and any captured
        // replay freezes our clock at the capture moment plus drift.
        let p3 = Self.makePacket3SetClock(now: Date())
        let p4 = Self.hexToData("0016000200000000020100054b314720030557000155")
        let p5 = Self.hexToData("0016000200000000020100054b3147200405560001aa")
        let p6 = Self.hexToData("0016000200000000020100054b3147200506050001aa")
        let p7 = Self.hexToData("0016000200000000020100054b3147200605170001aa")

        // Packet 8: init hint (08 0A 02 … aa 55 …). Carries seq 0x08
        // in the template.
        let p8 = Self.hexToData("001d000200000000020100054b314720080a020008aa55000000000000")

        // Packet 9: initial 0044 status frame — verbatim from
        // `better-dash/tripper_app_like_nav.py:INITIAL_BURST_HEX[8]`. This
        // is the EXACT byte sequence the Android Tripper app emits in the
        // pairing burst and the real dash silently drops anything else.
        //
        // Critically different from a `makeHeartbeat0044` payload:
        //   - 10 TLVs, NOT 11 (no `06 10` engine-temp TLV here)
        //   - TLV order: 06 08, 06 03, 06 04, 06 0F, 06 01, 05 4C,
        //                05 2D, 05 1B, 05 21, 05 4D
        //   - `seg_count = 0x000A` matches the actual TLV count
        //
        // Earlier revisions reused `makeHeartbeat0044` + tail TLVs, which
        // produced an 11-TLV / 73 B packet with `seg_count=10`. The real
        // dash treats that as malformed, never replies to packet #1 (q3c.e),
        // and the phone times out with "missing modulus or exponent". The
        // emulator (fake_dash) doesn't validate seg_count so the bug only
        // shows up against real hardware. See SKILL pitfall "Initial burst
        // p9 must be verbatim, NOT generated".
        let p9 = Self.hexToData(
            "0044000a00000000020100054b3147200906080001ff060300015506040001a2" +
            "060f0001aa0601000101054c000113052d00020000051b0001190521000132054d000132"
        )
        // fixedTempC is intentionally unused for the initial burst — engine
        // temp shows up only in the 1 Hz heartbeat ticks (makeHeartbeat0044
        // sends it under `06 10`), not the pairing handshake.
        _ = fixedTempC

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

    /// Build initial-burst packet 3 with the live wall-clock baked into
    /// the 06/06 set-clock TLV. Layout matches the captured Android app
    /// byte-for-byte except the three payload bytes are derived from
    /// `now` (interpreted in the user's current calendar/time-zone):
    ///
    ///   24 B total:  00 18  00 02  00 00 00 00  02 01 00 05
    ///                4B 31 47 20  02  06 06 00 03  HH MM SS
    ///
    /// All three payload bytes are **plain binary** in the range 0…59
    /// (hour 0…23). Field-verified by sending `14 30 38` (hour=20, min
    /// as ASCII '0','8') and watching the dash latch on to 20:48 instead
    /// of 20:08 — `0x30 = 48 dec`, proving the dash treats the byte as
    /// raw binary, not ASCII.
    ///
    /// The dash adopts this value as its RTC the moment it receives the
    /// pairing burst; sending stale captured bytes (`0E 33 34` decodes
    /// to 14:51:52 under the corrected reader) is exactly what caused
    /// Bug 3 — the "fixed wrong time after pair" symptom.
    static func makePacket3SetClock(now: Date) -> Data {
        let calendar = Calendar.current
        let hour = UInt8(calendar.component(.hour, from: now) & 0xFF)
        let minute = UInt8(calendar.component(.minute, from: now) & 0xFF)
        let second = UInt8(calendar.component(.second, from: now) & 0xFF)
        return makePacket3SetClock(hour: hour, minute: minute, second: second)
    }

    /// Test seam — same as `makePacket3SetClock(now:)` but lets fake_dash
    /// unit tests inject deterministic clock bytes without stubbing Date.
    static func makePacket3SetClock(hour: UInt8, minute: UInt8, second: UInt8) -> Data {
        var p = Data(capacity: 24)
        // Header + K1G magic + seq 0x02 (matches the captured greeting).
        p.append(contentsOf: [
            0x00, 0x18,                   // outer length = 24
            0x00, 0x02,                   // seg_count = 2 (TLV + tail trio)
            0x00, 0x00, 0x00, 0x00,       // reserved
            0x02, 0x01, 0x00, 0x05,       // const tail
            0x4B, 0x31, 0x47, 0x20,       // "K1G "
            0x02                          // seq byte (greeting slot 3)
        ])
        // 06/06 set-clock TLV — 3 byte payload (hour, minute, second all binary).
        p.append(contentsOf: [0x06, 0x06, 0x00, 0x03])
        p.append(hour)
        p.append(minute)
        p.append(second)
        return p
    }
}
