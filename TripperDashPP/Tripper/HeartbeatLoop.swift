//
//  HeartbeatLoop.swift
//  TripperDashPP
//
//  1 Hz keep-alive ping while the link is in `.connected` state. The dash
//  uses these to detect when we've gone away, and the *shape* matters —
//  earlier revisions sent an empty K1G envelope every tick and the real
//  Tripper dash dropped the link after a few seconds of "weird" heartbeats.
//
//  The Android REForeGroundService runs two parallel 1 Hz timer tasks:
//
//    - d.run(): 0044 packet (battery / GPS / charging / temp / volumes /
//               nav distance) — the canonical status frame.
//    - e.run(): 0030 packet (cell signal / volumes / nav distance) —
//               trimmed metadata update.
//
//  Both go out at 1 Hz, back-to-back. We mirror that here.
//

import Foundation
import os

/// Sends a `0044` heartbeat + `0030` metadata pair every
/// `K1G.heartbeatInterval` seconds until the task is cancelled. The two
/// packets carry their own rolling sequence bytes (consumed from `seq`).
///
/// Phone status (battery / charging / GPS-fix / cell-signal presence) is
/// pulled FRESH each tick from `telemetryProvider`, a `@Sendable` closure
/// that hops to the main actor and snapshots `DeviceTelemetry`. When the
/// app doesn't supply one (e.g. unit tests, or before the provider is
/// wired), the default provider returns `PhoneTelemetry.placeholder` — the
/// same "sane phone client" constants the loop shipped before live
/// telemetry existed — so the dash keep-alive is never affected.
struct HeartbeatLoop {

    let socket: DashSocket
    let seq: RollingSeq

    /// Live phone-status source. Defaults to the OEM-safe placeholder so
    /// existing call sites / tests keep their old behaviour unchanged.
    var telemetryProvider: @Sendable () async -> PhoneTelemetry = { .placeholder }

    /// Engine temperature stays a fixed placeholder — it's bike hardware
    /// the phone genuinely can't measure, so there's no live source to
    /// wire and the dash just needs a plausible constant.
    var fixedTempC: Int = 20
    var musicRatio0to1: Double = 0.3
    var alarmRatio0to1: Double = 0.3

    private static let log = Logger(
        subsystem: "eu.kolaczek.tripperdashpp",
        category: "Heartbeat"
    )

    /// Run until cancelled. Suspends on cancellation cleanly.
    func run() async {
        Self.log.info("Heartbeat loop started (interval=\(K1G.heartbeatInterval)s, shape=0044+0030, live-telemetry)")
        var tick: UInt64 = 0
        while !Task.isCancelled {
            // Fresh phone status every tick. Cheap (a struct copy on the
            // main actor); mirrors the OEM 1 Hz `REForeGroundService`
            // timer which re-reads BatteryManager + cell info each fire.
            let t = await telemetryProvider()

            let hb = K1GPacket.makeHeartbeat0044(
                seq: seq.consume(),
                fixedTempC: fixedTempC,
                cellSignal0to255: t.cellSignal0to255,
                batteryPct0to100: t.batteryPct0to100,
                gpsOn: t.gpsOn,
                charging: t.charging,
                signalPresent: t.signalPresent,
                musicRatio0to1: musicRatio0to1,
                navDistanceRounded: 0,
                alarmRatio0to1: alarmRatio0to1
            )
            let md = K1GPacket.makeMetadata0030(
                seq: seq.consume(),
                cellSignal0to255: t.cellSignal0to255,
                musicRatio0to1: musicRatio0to1,
                navDistanceRounded: 0,
                alarmRatio0to1: alarmRatio0to1
            )

            do {
                try await socket.send(hb)
                try await socket.send(md)
                tick &+= 1
                if tick == 1 {
                    Self.log.info("Heartbeat tick #1 sent (0044=\(hb.count)B + 0030=\(md.count)B)")
                } else {
                    Self.log.debug("Heartbeat tick #\(tick) sent")
                }
            } catch {
                Self.log.error("Heartbeat send failed: \(error.localizedDescription, privacy: .public) — stopping loop")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(K1G.heartbeatInterval * 1_000_000_000))
        }
        Self.log.info("Heartbeat loop cancelled (sent \(tick) ticks)")
    }
}
