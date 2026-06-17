//
//  HeartbeatLoop.swift
//  TripperDashPP
//
//  1 Hz keep-alive ping while the link is in `.connected` state. The dash
//  doesn't strictly require it for the control plane (the auth status it
//  gave us is "sticky"), but the better-dash captures show a steady
//  trickle of empty K1G envelopes from the phone, which the dash uses to
//  detect when we've gone away. Mirror that.
//

import Foundation
import os

/// Sends an empty K1G envelope every `K1G.heartbeatInterval` seconds
/// until the task is cancelled.
struct HeartbeatLoop {

    let socket: DashSocket
    let seq: RollingSeq

    private static let log = Logger(
        subsystem: "eu.kolaczek.tripperdashpp",
        category: "Heartbeat"
    )

    /// Run until cancelled. Suspends on cancellation cleanly.
    func run() async {
        Self.log.info("Heartbeat loop started (interval=\(K1G.heartbeatInterval)s)")
        var tick: UInt64 = 0
        while !Task.isCancelled {
            let pkt = K1GPacket.encode(segments: [], seq: seq.consume())
            do {
                try await socket.send(pkt)
                tick &+= 1
                // First tick at INFO so we know the loop actually fired.
                // After that drop to DEBUG to avoid spamming once / sec.
                if tick == 1 {
                    Self.log.info("Heartbeat tick #1 sent (\(pkt.count) B)")
                } else {
                    Self.log.debug("Heartbeat tick #\(tick) sent (\(pkt.count) B)")
                }
            } catch {
                Self.log.error("Heartbeat send failed: \(error.localizedDescription, privacy: .public) — stopping loop")
                // Surface via socket logs; if the conn is dead we'll get
                // .failed in DashSocket and BikeLink will tear us down.
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(K1G.heartbeatInterval * 1_000_000_000))
        }
        Self.log.info("Heartbeat loop cancelled (sent \(tick) ticks)")
    }
}
