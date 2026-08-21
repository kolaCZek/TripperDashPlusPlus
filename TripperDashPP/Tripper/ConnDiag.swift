//
//  ConnDiag.swift
//  TripperDashPP
//
//  ⚠️ DIAGNOSTIC BRANCH ONLY (`diag/connection-logging`) — NOT FOR MERGE.
//
//  Field-test connection diagnostics recorder. The connect / handshake /
//  reconnect path already logs richly through `os.Logger`, but a tester on a
//  motorcycle cannot pull the unified system log off a locked iPhone and send
//  it back. This records the SAME events into an in-memory ring buffer that is
//  also appended to a plain-text file in the app's Documents dir, so the rider
//  can open Settings → Connection diagnostics and share the log with one tap
//  right after a failed connect at the bike.
//
//  Design:
//  - `ConnDiag.shared.log(_:)` is cheap, synchronous-looking (hops to an actor),
//    and safe to call from any isolation context (nonisolated entry point).
//  - Every line is timestamped (wall clock, ms) + tagged with a category.
//  - Lines are mirrored to os.Logger too (so Console.app still works on a Mac).
//  - The file is capped (ring-trim on load) so it can't grow unbounded across
//    many rides.
//
//  Remove this file (and its call sites) before the feature work is merged —
//  this whole branch is a throwaway diagnostic aid.
//

import Foundation
import os.log

/// Serial actor guarding the diagnostic buffer + file handle.
actor ConnDiagStore {
    private var lines: [String] = []
    private let fileURL: URL
    private let maxLines = 5_000
    private let iso: ISO8601DateFormatter

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent("connection-diagnostics.log")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        self.iso = f
        // Load the tail of any previous log so a share includes recent history.
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8) {
            lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init).suffix(maxLines))
        }
    }

    func append(category: String, message: String) {
        let stamp = iso.string(from: Date())
        let line = "\(stamp) [\(category)] \(message)"
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        // Append to disk. Best-effort — diagnostics must never crash the app.
        if let data = (line + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    func snapshot() -> String { lines.joined(separator: "\n") }

    func clear() {
        lines.removeAll()
        try? "".data(using: .utf8)?.write(to: fileURL)
    }

    nonisolated var url: URL { fileURL }
}

/// Global entry point. `log()` is nonisolated + fire-and-forget so it can be
/// dropped into any connection code path (actors, MainActor, nonisolated
/// delegates) without ceremony. Explicitly `nonisolated` so it stays callable
/// from actor contexts even under the project's default-MainActor isolation.
enum ConnDiag {
    nonisolated static let store = ConnDiagStore()
    nonisolated private static let mirror = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "ConnDiag")

    /// Record a diagnostic line. Safe from any context.
    nonisolated static func log(_ category: String, _ message: String) {
        mirror.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        Task { await store.append(category: category, message: message) }
    }

    /// Full buffered log text for the share sheet.
    nonisolated static func snapshot() async -> String { await store.snapshot() }

    /// On-disk log file URL (for ShareLink / file export).
    nonisolated static var fileURL: URL { store.url }

    nonisolated static func clear() { Task { await store.clear() } }
}
