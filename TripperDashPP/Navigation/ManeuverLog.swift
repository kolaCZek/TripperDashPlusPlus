//
//  ManeuverLog.swift
//  TripperDashPP
//
//  Internal, file-based navigation debug logger.
//
//  WHY THIS EXISTS
//  ---------------
//  The 1 Hz active-nav loop (`ActiveNavLoop.tick`) already emits a few
//  lines to `os.Logger`/Console, but those evaporate the moment the ride
//  ends (and Console is unusable with the phone locked in a pocket). When
//  the dash shows the *wrong* arrow at a junction we need to reconstruct,
//  after the fact: WHERE the rider was (GPS), WHICH glyph/instruction we
//  pushed, the distances, whether a reroute was in flight, and WHICH route
//  was active at that instant — including the moment a reroute swapped the
//  route out from under us ("bacha na rerouting pri sjeti z trasy").
//
//  This logger writes one JSON object per line (JSON Lines / `.jsonl`) to a
//  per-session file under the app's Documents directory, so the trail
//  survives the ride and can be pulled off the device (Files app / Xcode
//  container) and replayed / grepped offline.
//
//  PRIVACY
//  -------
//  This is an INTERNAL DEBUG log and it contains the rider's raw GPS
//  coordinates. It is written to the app sandbox (local Documents) ONLY and
//  is never uploaded, transmitted, or shared anywhere. It is gated behind
//  `isEnabled` and intended for debug builds / field diagnosis. Do not wire
//  it to any network sink.
//
//  CONCURRENCY (Swift 6 strict)
//  ----------------------------
//  `record(...)` is called from the @MainActor nav loop and MUST NOT block
//  it. It only snapshots the supplied values into a `Sendable` value-type
//  `Entry` on the caller's thread, then hands that off to a private serial
//  `DispatchQueue` which owns ALL file IO and the small amount of mutable
//  bookkeeping state (file handle, last-route key, byte counter). Nothing
//  but `Sendable` value types crosses the queue boundary — never an
//  `MKRoute`, `MKRoute.Step`, or other reference object. The class is
//  `@unchecked Sendable` because that serial queue is the single point of
//  serialization for its mutable state.
//

import CoreLocation
import Foundation
import os.log

/// Internal file-based maneuver/instruction logger. See file header.
///
/// Usage (from `ActiveNavLoop.tick`, once per tick, after the overlay push):
///
/// ```swift
/// ManeuverLog.shared.record(
///     coordinate: nav.currentCoordinate,
///     maneuver: kind, wireByte: kind.wireByte,
///     instructions: step?.instructions,
///     distanceToNextStep: distNext, remainingDistance: distTotal,
///     etaSeconds: etaSec, isRerouting: isRerouting,
///     destination: nav.destination?.name,
///     routeStepCount: nav.activeRoute?.steps.count ?? 0,
///     routeDistanceMeters: nav.activeRoute?.distance ?? 0,
///     ...)
/// ```
final class ManeuverLog: @unchecked Sendable {

    /// Process-wide singleton.
    static let shared = ManeuverLog()

    /// Master on/off switch. Default **ON** so debug builds capture a trail
    /// without any wiring. Flip to `false` to disable all file IO; `record`
    /// early-returns before doing any work. `nonisolated(unsafe)` because
    /// this is a coarse debug toggle, not hot-path mutable shared state.
    nonisolated(unsafe) static var isEnabled = true

    /// Subsystem kept consistent with `ActiveNavLoop` (`cz.kolaczek.tripperdash`).
    private let log = Logger(subsystem: "cz.kolaczek.tripperdash", category: "ManeuverLog")

    /// Serial queue: the single owner of all mutable state below and all
    /// file IO. `.utility` so it never competes with the render/nav path.
    private let queue = DispatchQueue(
        label: "cz.kolaczek.tripperdash.maneuverlog",
        qos: .utility
    )

    // MARK: - State owned exclusively by `queue`

    /// Open handle to the current session file. Lazily opened on first write.
    private var handle: FileHandle?
    /// URL of the current session file (for diagnostics).
    private var fileURL: URL?
    /// Identity of the route seen on the previous tick. When it changes we
    /// emit a standalone `route_changed` line so logs split cleanly per route
    /// (a reroute / leg-advance produces a new key → a new boundary marker).
    private var lastRouteKey: String?
    /// Bytes written to the current session file — drives the size cap.
    private var bytesWritten: Int = 0

    /// Per-session file size cap. When exceeded we roll over to a fresh
    /// session file so a very long ride can't produce an unbounded log.
    private let maxBytes = 8 * 1024 * 1024   // 8 MiB

    /// ISO8601 timestamp formatter. Touched ONLY on `queue`, so the fact
    /// that `ISO8601DateFormatter` isn't documented thread-safe is moot.
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Filename-safe session-start stamp, e.g. `20260626-143501`.
    private let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Stable key order keeps diffs / greps readable; slashes unescaped
        // keeps instruction strings legible.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private init() {}

    // MARK: - Sendable snapshot

    /// Immutable value-type snapshot of one nav tick. Built on the caller's
    /// (MainActor) thread and the ONLY thing handed to the serial queue, so
    /// no reference type ever crosses the isolation boundary.
    private struct Entry: Sendable {
        let timestamp: Date
        let lat: Double?
        let lon: Double?
        let maneuver: String
        let wireByte: UInt8
        let instructions: String?
        let distanceToNextStep: Double
        let remainingDistance: Double
        let etaSeconds: Double
        let isRerouting: Bool
        let destination: String?
        let routeStepCount: Int
        let routeDistanceMeters: Double
        let secondaryManeuver: String?
        let secondaryWireByte: UInt8?
        let secondaryDistanceMeters: Double?

        /// Compact route fingerprint. A reroute or leg-advance changes the
        /// destination, step count, or total distance, so any of those
        /// shifting marks a genuine route boundary in the log.
        var routeKey: String {
            "\(destination ?? "?")|\(routeStepCount)|\(Int(routeDistanceMeters.rounded()))"
        }
    }

    // MARK: - Codable line shapes

    /// On-disk shape of a single `.jsonl` line. One struct serves both event
    /// kinds; `nil` fields are omitted by `JSONEncoder`, so a `route_changed`
    /// line stays lean and a `nav_tick` line carries the full context.
    private struct Line: Encodable {
        var event: String
        var timestamp: String
        var lat: Double?
        var lon: Double?
        var maneuver: String?
        var wireByte: String?            // hex, e.g. "0x15"
        var instructions: String?
        var distanceToNextStep: Double?
        var remainingDistance: Double?
        var etaSeconds: Double?
        var isRerouting: Bool?
        var routeId: String?
        var destination: String?
        var routeStepCount: Int?
        var routeDistanceMeters: Double?
        var secondaryManeuver: String?
        var secondaryWireByte: String?
        var secondaryDistanceMeters: Double?
        // route_changed only:
        var fromRouteId: String?
        var toRouteId: String?
    }

    // MARK: - Public API

    /// Begin a fresh logging session (new file). Called implicitly on the
    /// first `record(...)`; exposed so a caller can force a new file at the
    /// start of each navigation session (rotation per ride).
    func startSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closeLocked()
            self.openSessionLocked()
        }
    }

    /// Flush and close the current session file. Safe to call when idle.
    func endSession() {
        queue.async { [weak self] in
            self?.closeLocked()
        }
    }

    /// Record one navigation tick. Cheap and non-blocking: snapshots the
    /// values and returns; the file write happens asynchronously on the
    /// serial queue. Safe to call every tick from the @MainActor nav loop.
    ///
    /// - Parameters:
    ///   - coordinate: rider's GPS position at the moment this glyph was
    ///     shown. `nil` if no fix is available yet.
    ///   - maneuver: the classified primary maneuver (its `String(describing:)`
    ///     is logged — `ManeuverKind` has no `rawValue` because of the
    ///     roundabout associated values).
    ///   - wireByte: the K1G byte actually pushed for `maneuver` (logged hex).
    ///   - instructions: raw `MKRoute.Step.instructions`, if any.
    ///   - distanceToNextStep: metres to the next maneuver.
    ///   - remainingDistance: metres remaining to the destination.
    ///   - etaSeconds: live ETA in seconds.
    ///   - isRerouting: whether a reroute is in flight (recalculating glyph).
    ///   - destination: active destination name (route identity).
    ///   - routeStepCount: number of steps in the active route (route identity).
    ///   - routeDistanceMeters: total length of the active route (route identity).
    ///   - secondaryManeuver / secondaryWireByte / secondaryDistanceMeters:
    ///     the look-ahead maneuver, present only when one was emitted.
    func record(
        coordinate: CLLocationCoordinate2D?,
        maneuver: ManeuverKind,
        wireByte: UInt8,
        instructions: String?,
        distanceToNextStep: Double,
        remainingDistance: Double,
        etaSeconds: Double,
        isRerouting: Bool,
        destination: String?,
        routeStepCount: Int,
        routeDistanceMeters: Double,
        secondaryManeuver: ManeuverKind? = nil,
        secondaryWireByte: UInt8? = nil,
        secondaryDistanceMeters: Double? = nil
    ) {
        guard Self.isEnabled else { return }

        // Build the Sendable snapshot HERE, on the caller's (MainActor)
        // thread. Convert the non-value-type bits (enum → label, coord →
        // doubles) now so the closure below only captures value types.
        let entry = Entry(
            timestamp: Date(),
            lat: coordinate?.latitude,
            lon: coordinate?.longitude,
            maneuver: String(describing: maneuver),
            wireByte: wireByte,
            instructions: instructions,
            distanceToNextStep: distanceToNextStep,
            remainingDistance: remainingDistance,
            etaSeconds: etaSeconds,
            isRerouting: isRerouting,
            destination: destination,
            routeStepCount: routeStepCount,
            routeDistanceMeters: routeDistanceMeters,
            secondaryManeuver: secondaryManeuver.map { String(describing: $0) },
            secondaryWireByte: secondaryWireByte,
            secondaryDistanceMeters: secondaryDistanceMeters
        )

        queue.async { [weak self] in
            self?.write(entry)
        }
    }

    // MARK: - Queue-confined implementation

    /// Append one tick to the log, emitting a `route_changed` boundary line
    /// first whenever the active route's identity has shifted. Runs ONLY on
    /// `queue`.
    private func write(_ entry: Entry) {
        openSessionLocked()
        guard handle != nil else { return }

        let key = entry.routeKey
        if key != lastRouteKey {
            // A new route became active (fresh start, reroute, or leg
            // advance). Emit a standalone marker so the log splits per route
            // and reroute events stand out. `lastRouteKey == nil` is the very
            // first tick of the session — still useful to mark the route in.
            let marker = Line(
                event: "route_changed",
                timestamp: isoFormatter.string(from: entry.timestamp),
                isRerouting: entry.isRerouting,
                routeId: key,
                destination: entry.destination,
                routeStepCount: entry.routeStepCount,
                routeDistanceMeters: entry.routeDistanceMeters,
                fromRouteId: lastRouteKey,
                toRouteId: key
            )
            append(marker)
            lastRouteKey = key
        }

        let tick = Line(
            event: "nav_tick",
            timestamp: isoFormatter.string(from: entry.timestamp),
            lat: entry.lat,
            lon: entry.lon,
            maneuver: entry.maneuver,
            wireByte: Self.hex(entry.wireByte),
            instructions: entry.instructions,
            distanceToNextStep: entry.distanceToNextStep,
            remainingDistance: entry.remainingDistance,
            etaSeconds: entry.etaSeconds,
            isRerouting: entry.isRerouting,
            routeId: key,
            destination: entry.destination,
            routeStepCount: entry.routeStepCount,
            routeDistanceMeters: entry.routeDistanceMeters,
            secondaryManeuver: entry.secondaryManeuver,
            secondaryWireByte: entry.secondaryWireByte.map(Self.hex),
            secondaryDistanceMeters: entry.secondaryDistanceMeters
        )
        append(tick)
    }

    /// Encode + append a single line (JSON object + `\n`). Rolls the session
    /// file when the size cap is hit. Runs ONLY on `queue`.
    private func append(_ line: Line) {
        guard let data = try? encoder.encode(line) else {
            log.error("ManeuverLog: failed to encode a log line")
            return
        }
        // Size cap: roll to a fresh session file before the write that would
        // push us over, so no single file grows without bound.
        if bytesWritten + data.count + 1 > maxBytes {
            closeLocked()
            openSessionLocked()
        }
        guard let handle else { return }
        do {
            try handle.seekToEnd()
            handle.write(data)
            handle.write(Data([0x0A]))   // newline → JSON Lines
            bytesWritten += data.count + 1
        } catch {
            log.error("ManeuverLog: write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ensure a session file is open. Runs ONLY on `queue`.
    private func openSessionLocked() {
        guard handle == nil else { return }

        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            log.error("ManeuverLog: no Documents directory — logging disabled this session")
            return
        }
        let dir = docs.appendingPathComponent("maneuver-logs", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("ManeuverLog: cannot create log dir: \(error.localizedDescription, privacy: .public)")
            return
        }

        let stamp = fileStampFormatter.string(from: Date())
        let url = dir.appendingPathComponent("nav-\(stamp).jsonl", isDirectory: false)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            log.error("ManeuverLog: cannot open \(url.lastPathComponent, privacy: .public) for writing")
            return
        }
        // Append-only: jump to the end so a reopened same-second file keeps
        // its earlier lines.
        let end = (try? h.seekToEnd()) ?? 0
        handle = h
        fileURL = url
        bytesWritten = Int(end)
        lastRouteKey = nil   // new file → re-emit the route marker on next tick
        log.info("ManeuverLog: session file \(url.lastPathComponent, privacy: .public)")
    }

    /// Close the current session file. Runs ONLY on `queue`.
    private func closeLocked() {
        try? handle?.close()
        handle = nil
        fileURL = nil
        bytesWritten = 0
    }

    /// Lowercase-free 2-digit hex, e.g. `0x15`.
    private static func hex(_ byte: UInt8) -> String {
        String(format: "0x%02X", byte)
    }
}
