//
//  LocationDiag.swift
//  TripperDashPP
//
//  ⚠️ DIAGNOSTIC BRANCH ONLY (`diag/connection-logging`) — NOT FOR MERGE.
//
//  Answers one question the 2026-09-02 field log could not:
//  *when the app goes quiet in the background, is it because CoreLocation
//  stopped delivering fixes, or because the app is being starved of CPU
//  while still receiving them?*
//
//  Why it matters: the CoreLocation `Always` subscription is this app's ONLY
//  wakelock (see CLAUDE.md). If iOS stops delivering fixes, the render loop
//  has no heartbeat and everything else stalling follows automatically. If
//  fixes keep arriving but the app still stalls, the wakelock is intact and
//  the fault is downstream (main-actor contention, thermal/CPU throttling,
//  the renderer itself) — a completely different bug with a completely
//  different fix. The existing logs cannot tell those apart.
//
//  What the 2026-09-02 log showed, and why a plain "fix received" counter is
//  not enough: during the 91.6 s silence the encoder still emitted 28 frames
//  (0.29 fps against a 6 fps target — ~20× slow, not stopped) and the
//  1 Hz metrics timer fired twice 19 ms apart, the second reporting 207 fps.
//  Coalesced timer callbacks like that are the signature of a blocked main
//  actor. So this records BOTH sides of the delegate hop:
//
//    • `recordDelivery`        — on CoreLocation's own callback thread,
//                                i.e. did iOS hand us a fix at all?
//    • `recordMainActorArrival`— after the `Task { @MainActor }` hop,
//                                i.e. how long did we then wait for the
//                                main actor to actually run us?
//
//  A large gap between the two is direct evidence of main-actor starvation;
//  no deliveries at all is evidence the wakelock itself lapsed.
//
//  Deliberately quiet — ConnDiag is a 5000-line ring buffer shared with the
//  handshake/reconnect history, and fixes arrive at ~1 Hz, so per-fix logging
//  would evict everything useful within minutes. Instead: one aggregate line
//  every 10 s, plus immediate lines for the two events that actually matter
//  (a gap in deliveries, or a slow hop).
//
//  Remove this file and its call sites before any merge.
//

import Foundation
import os.log

/// Thread-safe counters for CoreLocation delivery health.
///
/// Uses a plain lock rather than an actor: `recordDelivery` runs on
/// CoreLocation's delegate thread and must not hop isolation to do its work,
/// because the hop is precisely what is under suspicion here — measuring it
/// through the thing being measured would hide the stall.
enum LocationDiag {
    private nonisolated(unsafe) static var lock = os_unfair_lock()

    /// Fixes handed to us by CoreLocation since the last flush.
    private nonisolated(unsafe) static var deliveries = 0
    /// Fixes that completed the main-actor hop since the last flush.
    private nonisolated(unsafe) static var arrivals = 0
    /// Worst main-actor hop latency seen since the last flush, in seconds.
    private nonisolated(unsafe) static var worstHopDelay: TimeInterval = 0
    /// Cumulative hop latency, for reporting an average alongside the worst.
    private nonisolated(unsafe) static var totalHopDelay: TimeInterval = 0

    private nonisolated(unsafe) static var lastDeliveryAt: Date?
    private nonisolated(unsafe) static var lastFlushAt = Date()

    /// Latches once a delivery outage has been reported, so a long silence
    /// logs one line instead of one per second from `tick()`. Cleared by the
    /// next delivery, which then reports the outage's total length.
    private nonisolated(unsafe) static var starvationWarned = false

    /// Report an aggregate line at most this often.
    private static let flushInterval: TimeInterval = 10

    /// A delivery gap longer than this is logged immediately — CoreLocation
    /// `Always` updates on a moving vehicle arrive at roughly 1 Hz, so
    /// several seconds of nothing means the wakelock's heartbeat has lapsed.
    private static let gapAlertThreshold: TimeInterval = 5

    /// A main-actor hop slower than this is logged immediately. The hop is
    /// normally sub-millisecond; a full second means the main actor is
    /// backed up behind other work.
    private static let hopAlertThreshold: TimeInterval = 1.0

    /// Called from the streamer's 1 Hz metrics tick.
    ///
    /// Load-bearing: every other entry point here fires only when a fix is
    /// DELIVERED, so a total stop in deliveries — the exact failure being
    /// hunted — would produce silence rather than evidence. This is driven by
    /// an independent timer, so it can still report when CoreLocation has
    /// gone quiet.
    ///
    /// (If the main actor is fully blocked this tick is delayed too, and the
    /// gap is then visible as coalesced timestamps in the log — the effect
    /// seen on 2026-09-02.)
    nonisolated static func tick() {
        let now = Date()
        os_unfair_lock_lock(&lock)
        let gap = lastDeliveryAt.map { now.timeIntervalSince($0) }
        let due = now.timeIntervalSince(lastFlushAt) >= flushInterval
        let alreadyWarned = starvationWarned
        // Latch the warning so a long outage logs once, not once per second.
        if let gap, gap >= gapAlertThreshold { starvationWarned = true }
        let snapshot = due ? takeSnapshotLocked(now: now) : nil
        os_unfair_lock_unlock(&lock)

        if let gap, gap >= gapAlertThreshold, !alreadyWarned {
            ConnDiag.log("gps", String(format: "⚠️ NO fixes for %.1fs — CoreLocation has gone quiet (wakelock at risk)", gap))
        }
        if let snapshot { emit(snapshot) }
    }

    /// Called on CoreLocation's delegate thread, before any isolation hop.
    nonisolated static func recordDelivery(at now: Date) {
        os_unfair_lock_lock(&lock)
        deliveries += 1
        let gap = lastDeliveryAt.map { now.timeIntervalSince($0) }
        lastDeliveryAt = now
        let resumed = starvationWarned
        starvationWarned = false
        let due = now.timeIntervalSince(lastFlushAt) >= flushInterval
        let snapshot = due ? takeSnapshotLocked(now: now) : nil
        os_unfair_lock_unlock(&lock)

        if let gap, gap >= gapAlertThreshold {
            let verb = resumed ? "resumed after" : "gap of"
            ConnDiag.log("gps", String(format: "⚠️ fixes %@ %.1fs", verb, gap))
        }
        if let snapshot { emit(snapshot) }
    }

    /// Called once the `Task { @MainActor }` hop actually runs.
    ///
    /// `deliveredAt` is the timestamp captured in `recordDelivery`, so the
    /// difference is exactly how long this fix waited for the main actor.
    nonisolated static func recordMainActorArrival(deliveredAt: Date) {
        let delay = Date().timeIntervalSince(deliveredAt)
        os_unfair_lock_lock(&lock)
        arrivals += 1
        totalHopDelay += delay
        if delay > worstHopDelay { worstHopDelay = delay }
        os_unfair_lock_unlock(&lock)

        if delay >= hopAlertThreshold {
            ConnDiag.log("gps", String(format: "⚠️ main-actor hop took %.2fs — main thread is backed up", delay))
        }
    }

    // MARK: - Flushing

    private struct Snapshot {
        let deliveries: Int
        let arrivals: Int
        let worstHop: TimeInterval
        let avgHop: TimeInterval
        let window: TimeInterval
    }

    /// Read and reset the counters. Caller must hold the lock.
    private static func takeSnapshotLocked(now: Date) -> Snapshot {
        let window = now.timeIntervalSince(lastFlushAt)
        let snap = Snapshot(
            deliveries: deliveries,
            arrivals: arrivals,
            worstHop: worstHopDelay,
            avgHop: arrivals > 0 ? totalHopDelay / Double(arrivals) : 0,
            window: window
        )
        deliveries = 0
        arrivals = 0
        worstHopDelay = 0
        totalHopDelay = 0
        lastFlushAt = now
        return snap
    }

    private static func emit(_ s: Snapshot) {
        let rate = s.window > 0 ? Double(s.deliveries) / s.window : 0
        // A backlog (delivered but not yet arrived) is the clearest single
        // number for "the main actor is behind", so call it out by name.
        let backlog = s.deliveries - s.arrivals
        let mark = (s.deliveries == 0 || backlog > 2 || s.worstHop >= hopAlertThreshold) ? "⚠️ " : ""
        ConnDiag.log("gps", String(
            format: "%@fixes: %d delivered (%.1f/s), %d reached main actor, backlog=%d, hop avg %.0fms / worst %.0fms",
            mark, s.deliveries, rate, s.arrivals, backlog,
            s.avgHop * 1000, s.worstHop * 1000
        ))
    }
}
