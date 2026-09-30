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
///
/// Runs OFF the main actor (`@concurrent`): the main actor also bakes map
/// tiles and renders the RTP stream, and a heartbeat queued behind a long
/// bake is exactly the gap the dash reads as "phone gone". Only the first
/// tick awaits the provider (which hops to main); after that each tick sends
/// the latest snapshot it has and refreshes it in the background, so a busy
/// main actor makes the phone status a few seconds stale instead of
/// stalling the keep-alive.
nonisolated struct HeartbeatLoop: Sendable {

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

    /// Latest phone status, refreshed off the send path.
    let latest = LatestTelemetry()

    private static let log = Logger(
        subsystem: "eu.kolaczek.tripperdashpp",
        category: "Heartbeat"
    )

    /// Consecutive transient send failures tolerated before the loop stops
    /// (and the caller treats it as a link drop).
    static let maxTransientSendFailures = 3

    /// True for `DashSocket.send` errnos that mean "buffer full, try later"
    /// on the non-blocking socket, rather than "the link is gone".
    static func isTransientSendError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == "DashSocket" else { return false }
        return ns.code == Int(ENOBUFS) || ns.code == Int(EAGAIN) || ns.code == Int(EWOULDBLOCK)
    }

    /// Heartbeats the dash must have had the chance to ACK before its
    /// silence counts. The dash only replies to what we send, so a stall on
    /// OUR side (busy main actor at tick 0, process suspension) is not a
    /// silent dash.
    static let minSentTicksForSilence = 5

    /// True when the dash has gone quiet: no RX for `K1G.rxSilenceTimeout`
    /// AND enough heartbeats went out since the last RX.
    static func isDashSilent(silence: TimeInterval, sentTicksWithoutRx: Int) -> Bool {
        silence > K1G.rxSilenceTimeout && sentTicksWithoutRx >= minSentTicksForSilence
    }

    /// Run until cancelled. Suspends on cancellation cleanly.
    @concurrent func run() async {
        Self.log.info("Heartbeat loop started (interval=\(K1G.heartbeatInterval)s, shape=0044+0030, live-telemetry)")
        var tick: UInt64 = 0
        var transientFailures = 0
        var sentTicksWithoutRx = 0
        while !Task.isCancelled {
            // Phone status: mirrors the OEM 1 Hz `REForeGroundService` timer
            // which re-reads BatteryManager + cell info each fire. The
            // provider hops to the main actor, so only the first tick waits
            // for it; later ticks send the latest snapshot and refresh it in
            // the background (at most one refresh in flight).
            if tick == 0 {
                latest.finish(await telemetryProvider())
            } else if latest.beginRefresh() {
                let box = latest, provider = telemetryProvider
                Task { box.finish(await provider()) }
            }
            let t = latest.get()

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
                transientFailures = 0
                sentTicksWithoutRx += 1
                tick &+= 1
                if tick == 1 {
                    Self.log.info("Heartbeat tick #1 sent (0044=\(hb.count)B + 0030=\(md.count)B)")
                } else {
                    Self.log.debug("Heartbeat tick #\(tick) sent")
                }
            } catch {
                // The socket is non-blocking, so a full send buffer (RTP on the
                // same interface, Wi-Fi power-save) is a normal hiccup, not a
                // drop. Tolerate a few in a row; anything else stops as before.
                if Self.isTransientSendError(error), transientFailures < Self.maxTransientSendFailures {
                    transientFailures += 1
                    Self.log.notice("Heartbeat send hiccup (\(transientFailures)/\(Self.maxTransientSendFailures)): \(error.localizedDescription, privacy: .public) — retrying next tick")
                } else {
                    Self.log.error("Heartbeat send failed: \(error.localizedDescription, privacy: .public) — stopping loop")
                    return
                }
            }
            // A dash that stopped talking is gone even if sends still succeed
            // (the caller treats this return as a link drop, like a send error).
            let silence = await socket.secondsSinceLastRx()
            // 2× the interval: the check runs right after our send, before this
            // tick's ACK, so an ACK-only dash reads just over 1 s every tick.
            if silence < 2 * K1G.heartbeatInterval { sentTicksWithoutRx = 0 }
            if Self.isDashSilent(silence: silence, sentTicksWithoutRx: sentTicksWithoutRx) {
                Self.log.error("No RX from dash for \(Int(silence), privacy: .public) s — stopping loop")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(K1G.heartbeatInterval * 1_000_000_000))
        }
        Self.log.info("Heartbeat loop cancelled (sent \(tick) ticks)")
    }
}

/// Latest `PhoneTelemetry` for the heartbeat, shared between the loop and
/// its background refresh task. `refreshing` stops refreshes piling up
/// while the main actor is busy.
nonisolated final class LatestTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var value = PhoneTelemetry.placeholder
    private var refreshing = false

    func get() -> PhoneTelemetry { lock.withLock { value } }

    /// True if the caller should start a refresh (none in flight).
    func beginRefresh() -> Bool {
        lock.withLock {
            if refreshing { return false }
            refreshing = true
            return true
        }
    }

    func finish(_ t: PhoneTelemetry) {
        lock.withLock { value = t; refreshing = false }
    }
}
