//
//  RideStatsService.swift
//  TripperDashPP
//
//  Live half of the GPS trip computer. A @MainActor @Observable service
//  that folds the shared LocationService fix stream into a running
//  RideStats and owns the ride lifecycle.
//
//  No second CLLocationManager — it subscribes to the same fix stream the
//  map, nav, and telemetry already share (LocationService.subscribeFixes),
//  so there's no authorization race and no extra battery draw. The pure
//  math lives in RideStats; this type is just wiring.
//
//  Session lifetime (rider-confirmed model):
//    • Totals accumulate across back-to-back rides — arriving and then
//      planning a fresh route KEEPS folding onto the same numbers, so a
//      multi-leg day reads as one ride.
//    • Totals are held frozen on screen after arrival until the rider
//      starts moving again (a new route) or the session ends.
//    • The accumulator is in-memory ONLY. Killing the app zeroes it —
//      there is deliberately no cross-launch persistence, so a fresh
//      launch always starts a fresh ride.
//    • reset() zeroes mid-session; AppStatus calls it when the bike link
//      goes fully down (user disconnect, or auto-reconnect gives up after
//      the 10-min budget = motorcycle switched off).
//

import Foundation

@MainActor
@Observable
final class RideStatsService {

    /// The live accumulator. Views read this; all math is in RideStats.
    private(set) var stats = RideStats()

    enum State: Equatable { case idle, running, paused }
    private(set) var state: State = .idle

    private weak var location: LocationService?
    private var sub: LocationSubscription?

    init(location: LocationService) {
        self.location = location
    }

    // MARK: - Lifecycle

    /// Begin folding fixes into the accumulator. Called when streaming
    /// starts. Idempotent — a second call while running is a no-op.
    ///
    /// Deliberately does NOT reset: starting a new route after an arrival
    /// resumes onto the existing totals (the held, frozen numbers), so a
    /// day of back-to-back legs reads as one continuous ride. Zeroing is
    /// reset()'s job and only happens when the whole session ends.
    func begin() {
        guard state != .running else { return }
        state = .running
        sub = location?.subscribeFixes { [weak self] fix in
            // LocationService fires subscribers on the main actor (fresh
            // fixes via `Task { @MainActor }`, replay synchronously from
            // this @MainActor method), so assuming isolation is safe —
            // same pattern as DeviceTelemetry's notification handlers.
            MainActor.assumeIsolated { self?.ingest(fix) }
        }
    }

    /// Keep totals but stop folding new fixes.
    func pause() {
        guard state == .running else { return }
        state = .paused
    }

    /// Resume folding after a pause.
    func resume() {
        guard state == .paused else { return }
        state = .running
    }

    /// Zero the ride. Called when the session ends — the bike link goes
    /// fully down (user disconnect, or auto-reconnect exhausts its budget
    /// = motorcycle off). Drops any live subscription and returns to idle
    /// so the post-arrival panel (gated on `stats.startedAt`) disappears.
    func reset() {
        sub = nil
        stats = RideStats()
        state = .idle
    }

    /// Streaming stopped — drop the subscription, keep totals on screen.
    /// The frozen numbers stay visible (via the post-arrival panel) until
    /// the next ride resumes folding or reset() ends the session.
    func end() {
        sub = nil
        if state == .running { state = .paused }
    }

    // MARK: - Fold

    private func ingest(_ fix: Fix) {
        guard state == .running else { return }
        stats = stats.folding(fix)
    }
}
