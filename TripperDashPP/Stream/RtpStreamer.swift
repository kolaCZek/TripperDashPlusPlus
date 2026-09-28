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
//  Threading: the FrameSource fires its callback (MapViewSource: on the
//  main actor); the encoder callback runs on a VideoToolbox-managed
//  thread and hops onto `sendQueue`, where `RtpSendPipe` packetizes and
//  sends without touching the main actor. The pipe's counters sit behind
//  a lock; the main actor reads them once a second (`flushMetrics`). The
//  only main-actor hop left on the path is the once-per-frame q3c.g kick
//  to BikeLink (6 Hz).
//

import Foundation
import Network
import CoreMedia
import os.log

/// Live counters surfaced to the UI. Updated and read on the main actor.
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
    /// Packetize + send, on `sendQueue`. One per streamer, so the RTP
    /// sequence number, SSRC and timestamp base survive a stop/start.
    private let pipe = RtpSendPipe(
        packetizer: RtpPacketizer(),
        // RTP timestamp base (90 kHz, per RFC 6184)
        timestampBase: UInt32.random(in: 0..<UInt32.max)
    )

    /// Hook into the BikeLink so the streamer can announce per-frame
    /// `q3c.g` (projection-frame) TLVs over the K1G control plane (UDP
    /// TX :2000). Weak to avoid a retain cycle — the link outlives any
    /// single streamer instance.
    weak var bikeLink: BikeLink?

    // MARK: - Networking

    private var connection: NWConnection?
    private let sendQueue = DispatchQueue(label: "TripperDashPP.RtpStreamer.send", qos: .userInitiated)

    // MARK: - State

    private(set) var state: State = .idle
    private(set) var metrics = RtpStreamerMetrics()
    /// Hook the UI uses to redraw when metrics change. Fires on the main actor.
    var onMetrics: ((RtpStreamerMetrics) -> Void)?

    // Throughput accounting (the counters themselves live in `pipe`)
    private var lastTickAt = Date()
    private var metricsTimer: Timer?

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "RtpStreamer")

    init(bikeHost: String, bikePort: UInt16 = K1G.rtpPort, source: FrameSource) {
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
        pipe.end()
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
            Task { @MainActor [weak self] in self?.handleConnectionState(s) }
        }
        conn.start(queue: sendQueue)
        self.connection = conn

        // 2. Encoder callback → packetize → send, all on `sendQueue`.
        //    Tell the dash a new map bitmap was rendered (q3c.g) once per
        //    frame — without it the dash never refreshes the projection
        //    surface even though the RTP packets are arriving. That kick is
        //    BikeLink's (main actor), so it is the one hop per frame.
        pipe.begin(connection: conn, onFrame: { [weak self] in
            Task { @MainActor [weak self] in
                await self?.bikeLink?.sendProjectionFrame()
            }
        })
        lastTickAt = Date()
        let pipe = self.pipe
        let queue = sendQueue
        encoder.onNAL = { @Sendable nal in
            queue.async { pipe.handle(nal) }
        }
        do {
            try encoder.start()
        } catch {
            fail(reason: "Encoder start failed: \(error)")
            return
        }

        // 3. Source → encoder. Callback thread is the source's choice
        //    (MapViewSource: main actor); encoder serialises onto its own
        //    VideoToolbox queue.
        source.start { [weak self] pixelBuffer, pts in
            self?.encoder.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
        }

        // 4. Metrics tick — once per second on main
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushMetrics() }
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
        // NALs still queued on `sendQueue` now count as dropped, as they
        // did when `send` found `connection == nil`.
        pipe.end()
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

    // MARK: - Metrics

    /// 1 Hz (the Timer in `start`): the only place the send path's
    /// counters reach the main actor.
    private func flushMetrics() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTickAt), 0.001)
        let c = pipe.takeWindow()
        let fps = Double(c.windowNALs) / dt
        let kbps = Double(c.windowBytes * 8) / dt / 1000.0
        // We count *NALs* per second here; for the dashboard this is a
        // close enough proxy for fps because parameter sets are rare
        // compared to coded slices. A bit of overcounting is fine.
        metrics.encodedFps = fps
        metrics.kbpsOut = kbps
        metrics.packetsSent = c.packetsSent
        metrics.packetsDropped = c.packetsDropped
        metrics.nalsEmitted = c.nalsEmitted
        metrics.idrCount = c.idrCount
        lastTickAt = now
        onMetrics?(metrics)
    }


    /// Human-readable NWConnection state — tells a "never became ready"
    /// failure apart from "ready but nothing to send". Currently unused.
    private var connectionStateLabel: String {
        guard let connection else { return "nil" }
        switch connection.state {
        case .setup:      return "setup"
        case .waiting:    return "waiting"
        case .preparing:  return "preparing"
        case .ready:      return "ready"
        case .failed:     return "failed"
        case .cancelled:  return "cancelled"
        @unknown default: return "unknown"
        }
    }
}

/// Encoded NAL → RTP datagrams → UDP, entirely on the streamer's
/// `sendQueue`. Replaces the old per-NAL hop onto the main actor (and the
/// per-datagram completion hop back to it): at 6 fps × several FU-A
/// fragments that was dozens of main-actor jobs a second, and any of them
/// queued behind a tile bake delayed the stream.
///
/// `@unchecked Sendable`: `connection`, `onFrame` and `counters` are only
/// touched under `lock`; `packetizer` is not locked and is only used from
/// `handle`, which runs on the one serial `sendQueue`.
nonisolated final class RtpSendPipe: @unchecked Sendable {

    nonisolated struct Counters: Sendable {
        /// Reset by every `takeWindow` (the 1 Hz fps / kbps window).
        var windowNALs: UInt64 = 0
        var windowBytes: UInt64 = 0
        /// Cumulative since `begin`.
        var packetsSent: UInt64 = 0
        var packetsDropped: UInt64 = 0
        var nalsEmitted: UInt64 = 0
        var idrCount: UInt64 = 0
    }

    private let packetizer: RtpPacketizer
    private let timestampBase: UInt32
    private let lock = NSLock()
    private var connection: NWConnection?
    private var onFrame: (@Sendable () -> Void)?
    private var counters = Counters()
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "RtpStreamer")

    init(packetizer: RtpPacketizer, timestampBase: UInt32) {
        self.packetizer = packetizer
        self.timestampBase = timestampBase
    }

    /// Start sending on `connection`; `onFrame` fires once per coded frame.
    func begin(connection: NWConnection, onFrame: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.connection = connection
            self.onFrame = onFrame
            counters = Counters()
        }
    }

    /// Stop sending: later NALs are packetized and counted as dropped.
    func end() {
        lock.withLock {
            connection = nil
            onFrame = nil
        }
    }

    /// Snapshot of the counters; restarts the fps / kbps window.
    func takeWindow() -> Counters {
        lock.withLock {
            let snapshot = counters
            counters.windowNALs = 0
            counters.windowBytes = 0
            return snapshot
        }
    }

    /// Send-queue only.
    func handle(_ nal: EncodedNAL) {
        // 90 kHz RTP timestamp = PTS seconds × 90000, plus the base.
        let ptsSeconds = CMTimeGetSeconds(nal.timestamp)
        let rtpTs = timestampBase &+ UInt32(truncatingIfNeeded: Int64(ptsSeconds * 90_000))

        // Mark the last fragment of an access unit (the IDR / non-IDR
        // frame itself) with the marker bit, per RFC 3550.
        let markerOnLast: Bool
        let isFrame: Bool
        let isIDR: Bool
        switch nal.kind {
        case .idr:
            markerOnLast = true
            isFrame = true
            isIDR = true
        case .nonIDR:
            markerOnLast = true
            isFrame = true
            isIDR = false
        default:
            markerOnLast = false
            isFrame = false
            isIDR = false
        }

        let datagrams = packetizer.packetize(
            nal: nal.bytes, timestamp90kHz: rtpTs, markerOnLast: markerOnLast
        )

        let link: (connection: NWConnection?, onFrame: (@Sendable () -> Void)?) = lock.withLock {
            counters.windowNALs += 1
            if isIDR { counters.idrCount += 1 }
            counters.nalsEmitted += 1
            return (connection: connection, onFrame: onFrame)
        }

        for datagram in datagrams {
            send(datagram, on: link.connection)
        }

        // Once per frame, not once per NAL — parameter sets don't count.
        if isFrame {
            link.onFrame?()
        }
    }

    private func send(_ datagram: RtpDatagram, on connection: NWConnection?) {
        guard let connection else {
            lock.withLock { counters.packetsDropped += 1 }
            return
        }
        lock.withLock { counters.windowBytes += UInt64(datagram.bytes.count) }
        connection.send(content: datagram.bytes, completion: .contentProcessed { err in
            if let err {
                self.lock.withLock { self.counters.packetsDropped += 1 }
                self.log.warning("UDP send failed (seq=\(datagram.sequence)): \(err.localizedDescription)")
            } else {
                self.lock.withLock { self.counters.packetsSent += 1 }
            }
        })
    }
}
