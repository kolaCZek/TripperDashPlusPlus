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
//  hands every teardown snapshot (`end()` / `pause()`) to `record(_:)`; a
//  multi-leg session keeps one `startedAt`, so each teardown overwrites
//  the same file instead of adding a duplicate.
//
//  Storage: one JSON file per ride in Application Support/RideHistory,
//  named by the start time (`ride-<epoch>.json`). Not UserDefaults: a
//  2-hour ride's 1 Hz track is ~0.7 MB of JSON and a month of rides can
//  reach tens of MB. Pruning only reads filenames, so app launch never
//  decodes a track; `load()` decodes on demand when the history sheet
//  opens.
//

import Foundation
import os

@MainActor
@Observable
final class RideHistoryStore {

    nonisolated static let retentionDays = 30

    /// Rides, newest first. Filled by `load()` (history sheet on appear)
    /// and kept in sync by `record` / `delete`.
    private(set) var rides: [RideStats] = []

    private let directory: URL
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

    // MARK: - CRUD

    /// Write (or overwrite) the ride keyed by its start time. No-op for a
    /// ride without a fix.
    // ponytail: synchronous main-actor write (~0.7 MB for a 2 h ride), same
    // cost as the existing last-ride UserDefaults write at teardown; move
    // to a background task if teardown ever stutters.
    func record(_ stats: RideStats, now: Date = .now) {
        guard let start = stats.startedAt else { return }
        let name = Self.fileName(for: start)
        do {
            try JSONEncoder().encode(stats).write(to: directory.appending(path: name), options: .atomic)
        } catch {
            log.error("Failed to write ride \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        rides.removeAll { $0.startedAt.map { Self.fileName(for: $0) } == name }
        rides.append(stats)
        rides.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        prune(now: now)
    }

    /// Decode every stored ride. Unreadable files are skipped, not fatal.
    func load(now: Date = .now) {
        prune(now: now)
        rides = files()
            .compactMap { try? JSONDecoder().decode(RideStats.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    func delete(_ ride: RideStats) {
        guard let start = ride.startedAt else { return }
        let name = Self.fileName(for: start)
        try? FileManager.default.removeItem(at: directory.appending(path: name))
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
