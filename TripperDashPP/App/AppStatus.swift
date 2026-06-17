//
//  AppStatus.swift
//  TripperDashPP
//
//  Shared application state — observable, injected as @Environment.
//
//  Phase 1: minimal placeholders so the UI compiles. Real implementations
//  arrive incrementally in Phases 3 (BikeLink → connectionState),
//  4 (encoder → fps / kbps), and 6 (Nav → currentDestination, route).
//

import Foundation
import Observation

/// High-level connection lifecycle as seen by the UI. Mirrors the
/// `BikeLink` state machine that lands in Phase 3.
enum BikeConnectionState: String, Sendable {
    case disconnected
    case wifiJoining       // Waiting for the user to join the Tripper AP
    case handshaking       // RSA exchange in flight
    case connected         // Heartbeats flowing, no video yet
    case streaming         // RTP video in flight
    case error             // See AppStatus.lastError
}

/// Live counters from the encoder + RTP packetizer (Phase 4).
struct StreamMetrics: Sendable, Equatable {
    var encodedFps: Double = 0
    var kbpsOut: Double = 0
    var packetsSent: UInt64 = 0
    var packetsDropped: UInt64 = 0
    var nalsEmitted: UInt64 = 0
    var idrCount: UInt64 = 0
    var lastError: String?

    static let zero = StreamMetrics()
}

/// A destination the user picked from search (Phase 6).
struct Destination: Sendable, Equatable, Identifiable {
    let id: UUID
    let label: String
    let latitude: Double
    let longitude: Double
}

@MainActor
@Observable
final class AppStatus {

    // MARK: - Connection

    /// Live K1G control-plane orchestrator. Phase 3+ reads `bikeLink.state`
    /// and mirrors it into `connectionState` for the UI.
    let bikeLink: BikeLink = BikeLink()

    /// Computed view of the link state in UI-friendly terms.
    var connectionState: BikeConnectionState {
        if streamer?.state == .running { return .streaming }
        switch bikeLink.state {
        case .idle:         return .disconnected
        case .connecting:   return .wifiJoining
        case .handshaking:  return .handshaking
        case .connected:    return .connected
        case .error:        return .error
        }
    }

    var bikeSsid: String? { bikeLink.ssid }
    var lastError: String? { bikeLink.lastError ?? metrics.lastError }

    // MARK: - Streaming

    var metrics: StreamMetrics = .zero
    private(set) var streamer: RtpStreamer?
    var isStreaming: Bool { streamer?.state == .running }

    /// Spin up the RTP pipeline pointed at the currently-connected dash.
    /// No-op if the link isn't connected yet.
    func startStreaming() {
        guard streamer == nil, let host = bikeLink.dashHost else { return }
        let s = RtpStreamer(bikeHost: host)
        s.onMetrics = { [weak self] m in
            guard let self else { return }
            self.metrics = StreamMetrics(
                encodedFps: m.encodedFps,
                kbpsOut: m.kbpsOut,
                packetsSent: m.packetsSent,
                packetsDropped: m.packetsDropped,
                nalsEmitted: m.nalsEmitted,
                idrCount: m.idrCount,
                lastError: m.lastError
            )
        }
        streamer = s
        s.start()
    }

    func stopStreaming() {
        streamer?.stop()
        streamer = nil
        metrics = .zero
    }

    // MARK: - Navigation

    var destination: Destination? = nil

    // MARK: - Build info (handy in the diagnostics overlay)

    let buildVersion: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let buildNumber: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
}
