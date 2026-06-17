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
import UIKit

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

    // MARK: - Background keep-alive (Phase 6)

    /// User-controlled: when true, we hold a CoreLocation Always +
    /// silent-audio wakelock while streaming so the iPhone screen can
    /// lock without iOS suspending the app (which kills the
    /// VTCompressionSession with `kVTInvalidSessionErr` / -12903).
    /// Defaults to ON — the whole point of Phase 6 is that this is the
    /// supported default mode of operation.
    var keepAwakeWhileStreaming: Bool = true {
        didSet { applyKeepAwake() }
    }

    /// Reflects whether the location + audio wakelocks are active right
    /// now. Used by the UI to show a "Background mode active" badge.
    var backgroundKeepAliveActive: Bool {
        locationKeeper.isRunning || audioKeeper.isRunning
    }

    private let locationKeeper = BackgroundLocationKeeper()
    private let audioKeeper = SilentAudioKeeper()

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
        applyKeepAwake()
    }

    func stopStreaming() {
        streamer?.stop()
        streamer = nil
        metrics = .zero
        applyKeepAwake()
    }

    /// Re-evaluate whether the wakelocks should be active. Called any
    /// time `keepAwakeWhileStreaming` toggles or the streaming state
    /// changes, so the keepers are only running while they're actually
    /// needed (battery hygiene).
    private func applyKeepAwake() {
        let shouldRun = keepAwakeWhileStreaming && isStreaming
        if shouldRun {
            locationKeeper.start()
            audioKeeper.start()
            // The idle timer is a soft hint to iOS — disabling it keeps
            // the display awake while the app is foregrounded, which is
            // useful when the rider explicitly keeps the phone visible.
            // It does NOT prevent suspension after a manual lock; the
            // location + audio keepers cover that case.
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            locationKeeper.stop()
            audioKeeper.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Navigation

    var destination: Destination? = nil

    // MARK: - Build info (handy in the diagnostics overlay)

    let buildVersion: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let buildNumber: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
}
