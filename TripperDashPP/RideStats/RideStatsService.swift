//
//  RideStatsService.swift
//  TripperDashPP
//
//  Live half of the GPS trip computer. A @MainActor @Observable service
//  that folds the shared LocationService fix stream into a running
//  RideStats, owns start/pause/reset lifecycle, and persists the
//  in-progress ride so an OS kill mid-ride resumes the same numbers.
//
//  No second CLLocationManager — it subscribes to the same fix stream the
//  map, nav, and telemetry already share (LocationService.subscribeFixes),
//  so there's no authorization race and no extra battery draw. The pure
//  math lives in RideStats; this type is just wiring + persistence.
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
    private var lastPersistAt: Date?

    private let store: UserDefaults
    private static let key = "rideStats.inProgress.v1"

    /// Max age of a persisted ride we'll silently resume on launch.
    static let resumeWindowSeconds: TimeInterval = 6 * 3600

    init(location: LocationService, store: UserDefaults = .standard) {
        self.location = location
        self.store = store
        restore()
    }

    // MARK: - Lifecycle

    /// Begin folding fixes into the accumulator. Called when streaming
    /// starts. Idempotent — a second call while running is a no-op.
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

    /// Zero the ride (rider-facing "Reset").
    func reset() {
        stats = RideStats()
        persist(force: true)
    }

    /// Streaming stopped — drop the subscription, keep totals on screen.
    func end() {
        sub = nil
        if state == .running { state = .paused }
    }

    // MARK: - Fold

    private func ingest(_ fix: Fix) {
        guard state == .running else { return }
        stats = stats.folding(fix)
        persist(force: false)
    }

    // MARK: - Persistence

    private func persist(force: Bool) {
        let now = Date()
        if !force, let last = lastPersistAt,
           now.timeIntervalSince(last) < 5 { return } // throttle flash writes
        lastPersistAt = now
        if let data = try? JSONEncoder().encode(stats) {
            store.set(data, forKey: Self.key)
        }
    }

    private func restore() {
        guard let data = store.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(RideStats.self, from: data),
              Self.isResumable(lastFixAt: saved.lastFixAt, now: Date()) else { return }
        stats = saved
        state = .paused // resume on next begin(); rider can Reset
    }

    /// A persisted ride is resumable only if its last fix is recent
    /// (< resumeWindowSeconds old). `nonisolated static` + pure so the
    /// 6 h boundary is unit-testable without the actor or UserDefaults.
    nonisolated static func isResumable(lastFixAt: Date?, now: Date) -> Bool {
        guard let last = lastFixAt else { return false }
        let age = now.timeIntervalSince(last)
        return age >= 0 && age < resumeWindowSeconds
    }
}
