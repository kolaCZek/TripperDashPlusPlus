//
//  RtpStreamer.swift
//  TripperDashPP
//
//  High-level orchestrator for the Phase 4 video pipeline:
//
//    FrameSource → H264Encoder → RtpPacketizer → UDP socket on bike:5000
//
//  Owns the lifecycle (start/stop), wires the components together, and
//  publishes live metrics that the AppStatus / StreamingView read.
//
//  Threading: the FrameSource fires on its own queue; the encoder
//  callback runs on a VideoToolbox-managed thread; the packetizer and
//  UDP send happen on the streamer's serial queue to keep RTP sequence
//  numbers monotonic without locks.
//

import Foundation
import Network
import CoreMedia
import os.log

/// Live counters surfaced to the UI. Updated from the streamer's serial
/// queue; consumers read on the main actor.
struct RtpStreamerMetrics: Sendable, Equatable {
    var encodedFps: Double = 0
    var kbpsOut: Double = 0
    var packetsSent: UInt64 = 0
    var packetsDropped: UInt64 = 0
    var nalsEmitted: UInt64 = 0
    var idrCount: UInt64 = 0
    var lastError: String?
}

@MainActor
final class RtpStreamer {

    enum State: String, Sendable {
        case idle
        case starting
        case running
        case stopping
        case failed
    }

    // MARK: - Inputs

    private let bikeHost: String
    private let bikePort: UInt16
    private let source: FrameSource
    private let encoder: H264Encoder
    private let packetizer = RtpPacketizer()

    /// Hook into the BikeLink so the streamer can announce per-frame
    /// `q3c.g` (projection-frame) TLVs over UDP/2002. Weak to avoid a
    /// retain cycle — the link outlives any single streamer instance.
    weak var bikeLink: BikeLink?

    // MARK: - Networking

    private var connection: NWConnection?
    private let sendQueue = DispatchQueue(label: "TripperDashPP.RtpStreamer.send", qos: .userInitiated)

    // MARK: - State

    private(set) var state: State = .idle
    private(set) var metrics = RtpStreamerMetrics()
    /// Hook the UI uses to redraw when metrics change. Fires on the main actor.
    var onMetrics: ((RtpStreamerMetrics) -> Void)?

    // Throughput accounting
    private var bytesAccumulator: UInt64 = 0
    private var nalsAccumulator: UInt64 = 0
    private var lastTickAt = Date()
    private var metricsTimer: Timer?

    // RTP timestamp base (90 kHz, per RFC 6184)
    private let timestampBase: UInt32 = UInt32.random(in: 0..<UInt32.max)

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "RtpStreamer")

    init(bikeHost: String, bikePort: UInt16 = K1G.rtpPort, source: FrameSource = TestPatternSource()) {
        self.bikeHost = bikeHost
        self.bikePort = bikePort
        self.source = source
        self.encoder = H264Encoder(
            width: Int32(source.frameSize.width),
            height: Int32(source.frameSize.height),
            fps: Int32(source.targetFps)
        )
    }

    deinit {
        // deinit may run off-main; tear down inline.
        connection?.cancel()
    }

    // MARK: - Lifecycle

    func start() {
        guard state == .idle || state == .failed else { return }
        state = .starting
        metrics = RtpStreamerMetrics()
        log.info("RtpStreamer starting → udp://\(self.bikeHost):\(self.bikePort)")

        // 1. UDP connection via Network.framework
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bikeHost),
            port: NWEndpoint.Port(integerLiteral: bikePort)
        )
        let params = NWParameters.udp
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in self?.handleConnectionState(s) }
        }
        conn.start(queue: sendQueue)
        self.connection = conn

        // 2. Encoder callback → packetize → send
        encoder.onNAL = { [weak self] nal in
            self?.sendQueue.async {
                Task { @MainActor in self?.handleEncodedNAL(nal) }
            }
        }
        do {
            try encoder.start()
        } catch {
            fail(reason: "Encoder start failed: \(error)")
            return
        }

        // 3. Source → encoder. Callback is on the source's background
        //    queue; encoder serialises onto its own VideoToolbox queue.
        source.start { [weak self] pixelBuffer, pts in
            self?.encoder.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
        }

        // 4. Metrics tick — once per second on main
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushMetrics() }
        }

        state = .running
    }

    func stop() {
        guard state == .running || state == .starting else { return }
        state = .stopping
        log.info("RtpStreamer stopping")
        metricsTimer?.invalidate()
        metricsTimer = nil
        source.stop()
        encoder.stop()
        connection?.cancel()
        connection = nil
        state = .idle
    }

    // MARK: - Networking events

    private func handleConnectionState(_ s: NWConnection.State) {
        switch s {
        case .ready:
            log.info("UDP connection ready (\(self.bikeHost):\(self.bikePort))")
        case .failed(let err):
            fail(reason: "UDP failed: \(err.localizedDescription)")
        case .waiting(let err):
            log.warning("UDP waiting: \(err.localizedDescription)")
        case .cancelled:
            log.info("UDP cancelled")
        default:
            break
        }
    }

    private func fail(reason: String) {
        log.error("\(reason)")
        metrics.lastError = reason
        onMetrics?(metrics)
        state = .failed
        stop()
    }

    // MARK: - Encode → packetize → send

    private func handleEncodedNAL(_ nal: EncodedNAL) {
        // 90 kHz RTP timestamp = PTS seconds × 90000, plus the base.
        let ptsSeconds = CMTimeGetSeconds(nal.timestamp)
        let rtpTs = timestampBase &+ UInt32(truncatingIfNeeded: Int64(ptsSeconds * 90_000))

        // Mark the last fragment of an access unit (the IDR / non-IDR
        // frame itself) with the marker bit, per RFC 3550.
        let markerOnLast: Bool
        let isFrame: Bool
        switch nal.kind {
        case .idr, .nonIDR:
            markerOnLast = true
            isFrame = true
        default:
            markerOnLast = false
            isFrame = false
        }

        let datagrams = packetizer.packetize(
            nal: nal.bytes, timestamp90kHz: rtpTs, markerOnLast: markerOnLast
        )

        nalsAccumulator += 1
        if case .idr = nal.kind { metrics.idrCount += 1 }
        metrics.nalsEmitted += 1

        for datagram in datagrams {
            send(datagram)
        }

        // Tell the dash a new map bitmap was rendered (q3c.g). Once per
        // frame, not once per NAL — parameter sets don't count. Without
        // this the dash never refreshes the projection surface even
        // though the RTP packets are arriving.
        if isFrame, let link = bikeLink {
            Task { await link.sendProjectionFrame() }
        }
    }

    private func send(_ datagram: RtpDatagram) {
        guard let connection else {
            metrics.packetsDropped += 1
            return
        }
        bytesAccumulator += UInt64(datagram.bytes.count)
        connection.send(content: datagram.bytes, completion: .contentProcessed { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if let err {
                    self.metrics.packetsDropped += 1
                    self.log.warning("UDP send failed (seq=\(datagram.sequence)): \(err.localizedDescription)")
                } else {
                    self.metrics.packetsSent += 1
                }
            }
        })
    }

    private func flushMetrics() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTickAt), 0.001)
        let fps = Double(nalsAccumulator) / dt
        let kbps = Double(bytesAccumulator * 8) / dt / 1000.0
        // We count *NALs* per second here; for the dashboard this is a
        // close enough proxy for fps because parameter sets are rare
        // compared to coded slices. A bit of overcounting is fine.
        metrics.encodedFps = fps
        metrics.kbpsOut = kbps
        nalsAccumulator = 0
        bytesAccumulator = 0
        lastTickAt = now
        onMetrics?(metrics)
    }
}
