//
//  RideHistoryStore.swift
//  TripperDashPP
//
//  Ride history: every ride session of the last `retentionDays` days, so a
//  ride that was never saved from the post-arrival panel is still there
//  to look at, save to Saved routes, or export as GPX.
//
//  One ride = one RideStatsService session (connect → bike off /
//  disconnect), the same unit the trip panel shows. `RideStatsService`
//  passes every teardown (`end()` / `pause()`) and mid-ride checkpoint
//  through `accept(_:)` and writes the file on `io`; `reset()` uses
//  `record(_:)`. A multi-leg session keeps one `startedAt`, so each write
//  overwrites the same file instead of adding a duplicate.
//
//  Storage: one JSON file per ride in Application Support/RideHistory,
//  named by the start time (`ride-<epoch>.json`). Not UserDefaults: a
//  2-hour ride's 1 Hz track is ~0.7 MB of JSON and a month of rides can
//  reach tens of MB. Pruning only reads filenames, so app launch never
//  decodes a track; `load()` decodes off the main actor, once per opening
//  of the history sheet. Sessions under 100 m aren't kept.
//

import Foundation
import os

@MainActor
@Observable
final class RideHistoryStore {

    nonisolated static let retentionDays = 30

    /// The one serial queue for every write/remove of a ride's file (except
    /// the >30-day prune, which never touches a live ride) AND the
    /// last-ride UserDefaults write/remove (`RideStatsService`). Off the
    /// main actor, so encoding + writing a long track never stalls the
    /// render loop; serial, so writes land in order — a late mid-ride
    /// checkpoint can't overwrite a newer teardown, resurrect a deleted
    /// file, or re-add a last-ride key that `reset()` just removed.
    nonisolated static let io = DispatchQueue(label: "eu.kolaczek.tripperdashpp.ridehistory", qos: .utility)

    /// Rides, newest first. Filled by `load()` (history sheet on appear)
    /// and kept in sync by `accept` / `delete`.
    private(set) var rides: [RideStats] = []

    private let directory: URL
    /// Files deleted by the rider this session → the ride's distance at
    /// deletion. The live RideStatsService still holds the same ride (same
    /// `startedAt`), so without this the next teardown (bike off) would
    /// write it straight back. Once the session rides on by another
    /// `minimumDistanceMeters` the ride is kept again — as the whole
    /// session, deleted part included, like any multi-leg ride. Distance,
    /// not track length: a stationary fix (restart, the replayed last fix)
    /// adds a track point but no distance.
    private var deleted: [String: Double] = [:]
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "RideHistory")

    init(directory: URL = URL.applicationSupportDirectory
            .appending(path: "RideHistory", directoryHint: .isDirectory),
         now: Date = .now) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(now: now)
    }

    // MARK: - Naming / retention (pure)

    nonisolated static func fileName(for startedAt: Date) -> String {
        "ride-\(Int(startedAt.timeIntervalSince1970)).json"
    }

    nonisolated static func startDate(fromFileName name: String) -> Date? {
        guard name.hasPrefix("ride-"), name.hasSuffix(".json"),
              let secs = Int(name.dropFirst(5).dropLast(5)) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }

    nonisolated static func isExpired(_ startedAt: Date, now: Date) -> Bool {
        startedAt < now.addingTimeInterval(-Double(retentionDays) * 86_400)
    }

    /// Connect-and-disconnect at home, a desk test, a stale replayed fix:
    /// not a ride worth a history entry.
    nonisolated static let minimumDistanceMeters = 100.0

    nonisolated static func isWorthKeeping(_ stats: RideStats) -> Bool {
        stats.startedAt != nil
            && stats.trackPoints.count >= 2
            && stats.distanceMeters >= minimumDistanceMeters
    }

    // MARK: - CRUD

    /// Main-actor half of a history write: the minimum-ride and tombstone
    /// checks plus the in-memory list. Returns the file to write on `io`,
    /// or nil to skip (too short, or deleted and not ridden on since).
    func accept(_ stats: RideStats, now: Date = .now) -> URL? {
        guard Self.isWorthKeeping(stats), let start = stats.startedAt else { return nil }
        let name = Self.fileName(for: start)
        if let distanceAtDeletion = deleted[name] {
            guard stats.distanceMeters >= distanceAtDeletion + Self.minimumDistanceMeters else { return nil }
            deleted[name] = nil
        }
        rides.removeAll { $0.startedAt.map { Self.fileName(for: $0) } == name }
        rides.append(stats)
        rides.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        prune(now: now)
        return directory.appending(path: name)
    }

    /// Write (or overwrite) the ride keyed by its start time, waiting for
    /// the write (session-end `reset()`). Mid-ride and teardown writes go
    /// through `RideStatsService.persistLastRide` instead.
    func record(_ stats: RideStats, now: Date = .now) {
        guard let url = accept(stats, now: now) else { return }
        let log = self.log
        let write: @Sendable () -> Void = {
            do {
                try JSONEncoder().encode(stats).write(to: url, options: .atomic)
            } catch {
                log.error("Failed to write ride \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        Self.io.sync(execute: write)
    }

    /// Decode every stored ride OFF the main actor (a month can be tens of
    /// MB of JSON). Unreadable files are skipped, not fatal.
    // ponytail: a ride recorded while this decode runs shows up on the next
    // open (its file is on disk); merge by name if that ever matters.
    func load(now: Date = .now) async {
        prune(now: now)
        let urls = files()
        rides = await Task.detached(priority: .userInitiated) {
            RideHistoryStore.decode(urls)
        }.value
    }

    nonisolated static func decode(_ urls: [URL]) -> [RideStats] {
        urls.compactMap { try? JSONDecoder().decode(RideStats.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    func delete(_ ride: RideStats) {
        guard let start = ride.startedAt else { return }
        let name = Self.fileName(for: start)
        deleted[name] = ride.distanceMeters
        let url = directory.appending(path: name)
        // On `io`, after any write of this ride still queued.
        let remove: @Sendable () -> Void = { try? FileManager.default.removeItem(at: url) }
        Self.io.sync(execute: remove)
        rides.removeAll { $0.startedAt.map { Self.fileName(for: $0) } == name }
    }

    // MARK: - Private

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func prune(now: Date) {
        for url in files() {
            if let start = Self.startDate(fromFileName: url.lastPathComponent),
               Self.isExpired(start, now: now) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        rides.removeAll { $0.startedAt.map { Self.isExpired($0, now: now) } ?? true }
    }
}
