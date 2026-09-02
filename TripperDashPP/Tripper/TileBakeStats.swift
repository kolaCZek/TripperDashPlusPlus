//
//  TileBakeStats.swift
//  TripperDashPP
//
//  ⚠️ DIAGNOSTIC BRANCH ONLY (`diag/connection-logging`) — NOT FOR MERGE.
//
//  Folds the per-composite tile-bake chatter into a periodic summary.
//
//  Why: `RouteTileCache.composite` logged one line per bake, ~91 lines/min,
//  which was 86% of every line in the diagnostic log. With ConnDiag's 5000-
//  line ring buffer that caps the log's reach at roughly 47 minutes — so a
//  rider who shares the log after a full ride finds the incident already
//  rotated out, while a rider who shares it immediately (to preserve the
//  incident) cuts off everything that happened afterwards. Both halves of
//  the 2026-09-02 investigation hit exactly that: the freeze was captured,
//  but the 40 minutes of healthy riding that followed it were not, and those
//  40 minutes are what rules the renderer in or out as a cause.
//
//  Summarised every 30 s this costs ~2 lines/min, putting the buffer's reach
//  in hours. The information that mattered is preserved in aggregate:
//
//    • bake rate            — renderer load over time, the thing being
//                             correlated against stalls
//    • cache hits vs HTTP   — whether bakes are cheap (disk) or expensive
//                             (network); a spike in fetches is a real signal
//    • zoom levels touched  — how many sibling layers are being baked
//    • last centre          — rough position, for lining the log up against
//                             a route
//
//  What is deliberately NOT aggregated: the anomaly lines in RouteTileCache
//  and MapViewSource (interpolator drift, tile-centre invariant violation,
//  non-finite centre). Those are rare and individually meaningful, so they
//  still log the moment they happen.
//
//  A silent window is itself evidence: if the renderer stalls, these
//  summaries stop appearing, and the gap in timestamps localises the stall
//  the same way the per-bake lines used to.
//
//  Remove this file and its call site before any merge.
//

import CoreLocation
import Foundation
import os.log

/// Accumulates tile-bake counters and emits a periodic ConnDiag summary.
///
/// Uses `os_unfair_lock` rather than an actor: `record` is called from the
/// tile bake path (a background render queue, potentially at high frequency)
/// and must stay cheap and non-suspending. Every member is explicitly
/// `nonisolated` because the project builds with default-MainActor isolation
/// — without it these would be inferred as `@MainActor` and each bake would
/// hop to the main actor just to bump a counter, adding main-thread load to
/// the very path being measured for main-thread stalls.
enum TileBakeStats {
    private nonisolated(unsafe) static var lock = os_unfair_lock()

    private nonisolated(unsafe) static var bakes = 0
    private nonisolated(unsafe) static var hits = 0
    private nonisolated(unsafe) static var misses = 0
    private nonisolated(unsafe) static var zoomLevels: Set<Int> = []
    private nonisolated(unsafe) static var lastCentre: CLLocationCoordinate2D?
    private nonisolated(unsafe) static var windowStart = Date()

    /// How often to emit a summary line.
    private nonisolated static let flushInterval: TimeInterval = 30

    /// Record one composite bake. Cheap; emits at most one log line per
    /// `flushInterval`.
    nonisolated static func record(hits h: Int, misses m: Int, z: Int, center: CLLocationCoordinate2D) {
        let now = Date()
        os_unfair_lock_lock(&lock)
        bakes += 1
        hits += h
        misses += m
        zoomLevels.insert(z)
        lastCentre = center
        let snapshot: (bakes: Int, hits: Int, misses: Int, zooms: [Int], centre: CLLocationCoordinate2D?, window: TimeInterval)?
        if now.timeIntervalSince(windowStart) >= flushInterval {
            snapshot = (bakes, hits, misses, zoomLevels.sorted(), lastCentre, now.timeIntervalSince(windowStart))
            bakes = 0
            hits = 0
            misses = 0
            zoomLevels.removeAll(keepingCapacity: true)
            windowStart = now
        } else {
            snapshot = nil
        }
        os_unfair_lock_unlock(&lock)

        guard let s = snapshot, s.window > 0 else { return }
        let rate = Double(s.bakes) / s.window * 60
        let zs = s.zooms.map(String.init).joined(separator: "/")
        let where_ = s.centre.map { String(format: "(%.4f,%.4f)", $0.latitude, $0.longitude) } ?? "—"
        // Flag network-heavy windows: routine riding runs almost entirely
        // from the disk cache, so a burst of fetches is worth seeing.
        let mark = s.misses > s.hits / 4 ? "⚠️ " : ""
        ConnDiag.log("tiles", String(
            format: "%@bakes: %d in %.0fs (%.0f/min), z=%@, %d cache / %d HTTP, at %@",
            mark, s.bakes, s.window, rate, zs, s.hits, s.misses, where_
        ))
    }
}
