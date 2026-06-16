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
    static func encode(segments: [K1GSegment], seq: UInt8) -> Data {
        var body = Data(capacity: 17 + segments.reduce(0) { $0 + 4 + $1.payload.count })

        // outer_len placeholder (2B) — patched at the end
        body.append(contentsOf: [0x00, 0x00])

        // seg_count (2B BE)
        body.append(contentsOf: u16BE(UInt16(segments.count)))

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
    /// Mirrors fake_dash/tests/test_integration.py:65.
    static func makeRequestPubkey(seq: UInt8) -> Data {
        let seg = K1GSegment(
            type: .auth,
            sub: K1G.AuthSub.requestPubkey.rawValue,
            payload: Data([0x01])
        )
        return encode(segments: [seg], seq: seq)
    }

    /// Phone → bike: q3c.d (RSA-PKCS1v1.5 ciphertext containing
    /// `ssid_bytes ‖ aes_key_bytes`).
    static func makeSessionKey(ciphertext: Data, seq: UInt8) -> Data {
        precondition(ciphertext.count == K1G.rsaCiphertextLength,
                     "session key ciphertext must be 128 B (RSA-1024)")
        let seg = K1GSegment(
            type: .session,
            sub: 0x00,
            payload: ciphertext
        )
        return encode(segments: [seg], seq: seq)
    }
}
