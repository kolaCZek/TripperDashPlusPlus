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
//    • The LIVE accumulator is in-memory. To survive the arrival→sleep→
//      kill cycle (iOS suspends and then terminates the app once the
//      streaming wakelock drops at arrival), the LAST ride summary is
//      persisted to UserDefaults at each teardown (`end()`/`pause()`) and
//      restored on launch, so reopening the app shows the last ride's
//      summary panel instead of a blank picker. The restored ride is
//      STALE, not a continuation: the first `begin()` of a genuinely new
//      ride zeroes it (see `restoredFromDisk`).
//    • reset() zeroes mid-session AND clears the persisted copy; AppStatus
//      calls it when the bike link goes fully down (user disconnect, or
//      auto-reconnect gives up after the 10-min budget = motorcycle off).
//
//  Why persist only at teardown (not per-fix): a long ride's `trackPoints`
//  is thousands of points, so writing it on every 1 Hz fix would be wasteful.
//  The reported failure is arrival → app killed while backgrounded, and
//  `end()` runs at that arrival teardown — so the summary is on disk before
//  the app can be terminated. A crash mid-ride loses at most the current
//  in-flight leg, which is acceptable for a summary panel.
//

import Foundation
import os

@MainActor
@Observable
final class RideStatsService {

    private static let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "RideStats")

    /// UserDefaults key holding the last ride's persisted `RideStats` (JSON).
    private static let storageKey = "RideStats.lastRide.v1"

    /// The live accumulator. Views read this; all math is in RideStats.
    private(set) var stats = RideStats()

    enum State: Equatable { case idle, running, paused }
    private(set) var state: State = .idle

    private weak var location: LocationService?
    private var sub: LocationSubscription?
    private let defaults: UserDefaults

    /// True when `stats` was rehydrated from disk on launch and no new ride
    /// has begun yet. The restored ride is a FINISHED ride from a previous
    /// app session shown for reference — the next `begin()` must zero it so a
    /// new ride doesn't fold onto last time's totals. Cleared by `begin()`.
    private var restoredFromDisk = false

    init(location: LocationService, defaults: UserDefaults = .standard) {
        self.location = location
        self.defaults = defaults
        restoreLastRide()
    }

    // MARK: - Lifecycle

    /// Begin folding fixes into the accumulator. Called when streaming
    /// starts. Idempotent — a second call while running is a no-op.
    ///
    /// Deliberately does NOT reset for an in-memory continuation: starting a
    /// new route after an arrival WITHIN the same app session resumes onto
    /// the existing totals (the held, frozen numbers), so a day of
    /// back-to-back legs reads as one continuous ride.
    ///
    /// EXCEPTION: if the totals were rehydrated from disk on launch
    /// (`restoredFromDisk`), they belong to a PREVIOUS app session and must
    /// NOT be continued — zero them first so the new ride starts clean.
    func begin() {
        guard state != .running else { return }
        if restoredFromDisk {
            // The on-screen numbers are last session's ride, shown for
            // reference. A genuinely new ride starts fresh.
            stats = RideStats()
            restoredFromDisk = false
        }
        state = .running
        sub = location?.subscribeFixes { [weak self] fix in
            // LocationService fires subscribers on the main actor (fresh
            // fixes via `Task { @MainActor }`, replay synchronously from
            // this @MainActor method), so assuming isolation is safe —
            // same pattern as DeviceTelemetry's notification handlers.
            MainActor.assumeIsolated { self?.ingest(fix) }
        }
    }

    /// Keep totals but stop folding new fixes. Persists the frozen summary so
    /// it survives an app kill (e.g. iOS terminating the backgrounded app).
    func pause() {
        guard state == .running else { return }
        state = .paused
        persistLastRide()
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
    /// Also clears the persisted copy — the session is over, so a relaunch
    /// should NOT resurrect this ride's summary.
    func reset() {
        sub = nil
        stats = RideStats()
        state = .idle
        restoredFromDisk = false
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// The rider dismissed the post-arrival summary panel (its close
    /// button). Drop the persisted copy so a relaunch doesn't resurrect a
    /// summary the rider has already seen and closed — without this the
    /// on-disk record would re-hydrate and the panel would reappear on the
    /// next launch. Only clears disk + the restored flag: the live in-memory
    /// `stats` stay (the UI hides the panel via its own transient
    /// `rideStatsDismissed` flag), so a back-to-back next leg still resumes
    /// onto the same totals within this session.
    func acknowledgeSummary() {
        defaults.removeObject(forKey: Self.storageKey)
        restoredFromDisk = false
    }

    /// Streaming stopped — drop the subscription, keep totals on screen.
    /// The frozen numbers stay visible (via the post-arrival panel) until
    /// the next ride resumes folding or reset() ends the session. Persists
    /// the summary so it survives the arrival→sleep→kill cycle: this runs at
    /// the arrival teardown, before iOS can terminate the backgrounded app.
    func end() {
        sub = nil
        if state == .running { state = .paused }
        persistLastRide()
    }

    // MARK: - Persistence

    /// Write the current `stats` to disk as the "last ride" summary. Called
    /// at each teardown (`end()`/`pause()`). Skips empty rides (no
    /// `startedAt`) so a stop before any fix doesn't leave a blank record.
    private func persistLastRide() {
        guard stats.startedAt != nil else { return }
        do {
            let data = try JSONEncoder().encode(stats)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            Self.log.error("Failed to persist last ride: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rehydrate the last ride's summary from disk on launch. The restored
    /// ride is a finished, reference-only summary (`restoredFromDisk = true`,
    /// state stays `.idle`) — the picker shows its RideStatsPanel, and the
    /// next `begin()` zeroes it for a fresh ride.
    private func restoreLastRide() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            stats = try JSONDecoder().decode(RideStats.self, from: data)
            restoredFromDisk = true
            Self.log.info("Restored last ride summary from disk")
        } catch {
            Self.log.error("Failed to restore last ride: \(error.localizedDescription, privacy: .public) — clearing")
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    // MARK: - Fold

    private func ingest(_ fix: Fix) {
        guard state == .running else { return }
        stats = stats.folding(fix)
    }

    // MARK: - Save ride to the route library

    /// True when there is a recorded track worth saving. The UI gates the
    /// "Save ride" affordance on this so an empty ride never creates a
    /// route.
    var hasRecordedTrack: Bool { !stats.trackPoints.isEmpty }

    /// Build a `.track` `SavedRoute` from the recorded ride, ready to hand
    /// to `SavedRoutesStore.add(_:)`. Returns `nil` when nothing was
    /// recorded.
    ///
    /// The FULL, precise breadcrumb is stored verbatim in `points` — no
    /// Douglas–Peucker reduction here (a 2-hour ride keeps its thousands of
    /// points) so the preview map and GPX export reproduce the real ride
    /// exactly. The reduction to ≤`RoutePoint.navigableCap` via-points is
    /// applied transiently at navigation time (`beginPlanningFromSavedRoute`),
    /// where MKDirections needs a sane number of legs. `totalDistanceMeters`
    /// is measured along the full trace.
    func makeSavedRoute(name: String? = nil, now: Date = Date()) -> SavedRoute? {
        let track = stats.trackPoints
        guard !track.isEmpty else { return nil }

        let points = track.map {
            RoutePoint(latitude: $0.latitude, longitude: $0.longitude)
        }
        let fullDistance = GPXGeometry.pathLength(points.map(\.coordinate))

        return SavedRoute(
            name: name ?? Self.defaultRideName(start: stats.startedAt ?? now),
            kind: .track,
            points: points,
            totalDistanceMeters: fullDistance,
            sourceFilename: nil
        )
    }

    /// A default, human-readable ride name derived from the start time,
    /// e.g. "Ride 2026-07-27 09:41".
    static func defaultRideName(start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Ride \(f.string(from: start))"
    }
}
