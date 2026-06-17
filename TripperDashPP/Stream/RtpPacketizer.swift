//
//  RtpPacketizer.swift
//  TripperDashPP
//
//  Pack raw H.264 NAL units into RFC 6184 RTP payloads:
//   - NALs ≤ MTU-12 (RTP header) ride alone as "single-NAL" packets.
//   - Bigger NALs split into FU-A fragments (NAL type 28) with the standard
//     S/E/R bits in the FU header.
//
//  Each call to `packetize()` returns one or more ready-to-send UDP
//  datagrams. The streamer manages sequence numbers and the RTP timestamp
//  base; we just produce the byte layout.
//
//  We mirror fake_dash/rtp_sink.py's expectations (PT 96, NTP-style 90 kHz
//  timestamps) so the round-trip works against the existing server.
//

import Foundation

/// One RTP/UDP datagram ready for transmission.
struct RtpDatagram {
    let bytes: Data
    let marker: Bool
    let sequence: UInt16
}

final class RtpPacketizer {

    /// Per RFC 6184, payload type for H.264 is dynamically assigned; we
    /// match better-dash + fake_dash on PT 96.
    static let payloadType: UInt8 = 96

    /// Roughly safe MTU after IP+UDP+RTP overhead on Wi-Fi. Tripper has
    /// a tiny jitter buffer; smaller packets reduce reordering risk.
    let maxPayloadSize: Int

    /// RTP SSRC — picked once at construction, stable across the session.
    let ssrc: UInt32

    private var sequence: UInt16

    init(maxPayloadSize: Int = 1200, ssrc: UInt32 = UInt32.random(in: 1..<UInt32.max)) {
        self.maxPayloadSize = maxPayloadSize
        self.ssrc = ssrc
        self.sequence = UInt16.random(in: 0...UInt16.max)
    }

    /// Convert a single NAL into one or more RTP datagrams. The encoder
    /// is expected to feed SPS/PPS/IDR as separate NALs in that order;
    /// we emit them as plain single-NAL packets so the dash can build a
    /// decoder before the IDR arrives.
    func packetize(nal: Data, timestamp90kHz: UInt32, markerOnLast: Bool) -> [RtpDatagram] {
        guard !nal.isEmpty else { return [] }

        let rtpHeaderSize = 12
        let bodyBudget = maxPayloadSize - rtpHeaderSize

        if nal.count <= bodyBudget {
            // Single-NAL packet
            let seq = nextSequence()
            let datagram = buildHeader(
                marker: markerOnLast, sequence: seq, timestamp: timestamp90kHz
            ) + nal
            return [RtpDatagram(bytes: datagram, marker: markerOnLast, sequence: seq)]
        }

        // FU-A fragmentation
        return fragmentFUA(nal: nal, timestamp: timestamp90kHz, markerOnLast: markerOnLast)
    }

    // MARK: - Internals

    private func fragmentFUA(nal: Data, timestamp: UInt32, markerOnLast: Bool) -> [RtpDatagram] {
        // RFC 6184 §5.8 FU-A:
        //   FU indicator = (NAL header & 0xE0) | 28
        //   FU header    = S/E/R bits + (NAL header & 0x1F)
        let nalHeader = nal[0]
        let fNri = nalHeader & 0xE0
        let nalType = nalHeader & 0x1F
        let fuIndicator: UInt8 = fNri | 28

        // We strip the NAL header from the payload (its bits live in the
        // FU header instead).
        let body = nal.dropFirst()
        let chunkSize = maxPayloadSize - 12 /* RTP */ - 2 /* FU ind+hdr */

        var datagrams: [RtpDatagram] = []
        var offset = 0
        let total = body.count
        while offset < total {
            let remaining = total - offset
            let size = min(chunkSize, remaining)
            let isFirst = offset == 0
            let isLast = offset + size == total

            var fuHeader: UInt8 = nalType
            if isFirst { fuHeader |= 0x80 }
            if isLast  { fuHeader |= 0x40 }

            let seq = nextSequence()
            var datagram = buildHeader(
                marker: isLast && markerOnLast,
                sequence: seq,
                timestamp: timestamp
            )
            datagram.append(fuIndicator)
            datagram.append(fuHeader)
            datagram.append(body.subdata(in: (body.startIndex + offset)..<(body.startIndex + offset + size)))

            datagrams.append(RtpDatagram(
                bytes: datagram,
                marker: isLast && markerOnLast,
                sequence: seq
            ))
            offset += size
        }
        return datagrams
    }

    private func buildHeader(marker: Bool, sequence: UInt16, timestamp: UInt32) -> Data {
        var d = Data(count: 12)
        d[0] = 0x80  // V=2, P=0, X=0, CC=0
        d[1] = (marker ? 0x80 : 0x00) | (Self.payloadType & 0x7F)
        d[2] = UInt8((sequence >> 8) & 0xFF)
        d[3] = UInt8(sequence & 0xFF)
        d[4] = UInt8((timestamp >> 24) & 0xFF)
        d[5] = UInt8((timestamp >> 16) & 0xFF)
        d[6] = UInt8((timestamp >> 8) & 0xFF)
        d[7] = UInt8(timestamp & 0xFF)
        d[8] = UInt8((ssrc >> 24) & 0xFF)
        d[9] = UInt8((ssrc >> 16) & 0xFF)
        d[10] = UInt8((ssrc >> 8) & 0xFF)
        d[11] = UInt8(ssrc & 0xFF)
        return d
    }

    private func nextSequence() -> UInt16 {
        let s = sequence
        sequence = sequence &+ 1
        return s
    }
}
