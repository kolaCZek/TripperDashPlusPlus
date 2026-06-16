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

/// Sends an empty K1G envelope every `K1G.heartbeatInterval` seconds
/// until the task is cancelled.
struct HeartbeatLoop {

    let socket: DashSocket
    let seq: RollingSeq

    /// Run until cancelled. Suspends on cancellation cleanly.
    func run() async {
        while !Task.isCancelled {
            let pkt = K1GPacket.encode(segments: [], seq: seq.consume())
            do {
                try await socket.send(pkt)
            } catch {
                // Surface via socket logs; if the conn is dead we'll get
                // .failed in DashSocket and BikeLink will tear us down.
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(K1G.heartbeatInterval * 1_000_000_000))
        }
    }
}
