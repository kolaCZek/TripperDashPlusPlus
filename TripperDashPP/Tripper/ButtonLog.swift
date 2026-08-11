//
//  ButtonLog.swift
//  TripperDashPP
//
//  Internal, file-based joystick-button diagnostic logger.
//
//  WHY THIS EXISTS
//  ---------------
//  The zoom buttons work against `fake_dash` but do nothing on the real
//  bike. The decode→ack→route→zoom pipeline is unit-tested, so the most
//  likely cause is that the real dash frames button events differently
//  than fake_dash's textbook `09 00 0001 XX`. We need the actual inbound
//  bytes off the hardware — but the rider can only bring a PHONE to the
//  bike (no laptop for `log stream`, Console is unusable with the phone
//  in a pocket). So the raw wire bytes must land ON THE PHONE'S DISK,
//  retrievable afterwards via the Files app / AirDrop.
//
//  This logger writes one JSON object per line (JSON Lines / `.jsonl`) to
//  a per-session file under the app's Documents directory, mirroring
//  `ManeuverLog`. `Documents/button-logs/btn-<timestamp>.jsonl` can be
//  pulled off the device (Files app → On My iPhone → TripperDashPP, or
//  AirDrop / share sheet) and grepped offline to pin down the real frame.
//
//  PRIVACY
//  -------
//  INTERNAL DEBUG log. It records raw K1G control-plane bytes (button
//  events + a sample of other inbound segments) only — no GPS, no PII.
//  Written to the app sandbox (local Documents) ONLY, never uploaded or
//  transmitted. Gated behind `isEnabled` (DEBUG-on / release-off) and the
//  runtime `DashNavSettings.buttonWireLoggingEnabled` opt-in.
//
//  CONCURRENCY (Swift 6 strict)
//  ----------------------------
//  Same pattern as `ManeuverLog`: `record(...)` is called from the inbound
//  loop and MUST NOT block it. It snapshots the supplied values into a
//  `Sendable` value-type `Entry` on the caller's thread, then hands that
//  off to a private serial `DispatchQueue` that owns ALL file IO and
//  mutable bookkeeping. Nothing but `Sendable` value types crosses the
//  queue boundary. `@unchecked Sendable` because the serial queue is the
//  single point of serialization for its mutable state.
//

import Foundation
import os.log

/// Internal file-based joystick-button wire logger. See file header.
///
/// Usage (from `BikeLink.startInboundLoop`, per inbound packet):
///
/// ```swift
/// ButtonLog.shared.recordRaw(packet)                 // every inbound packet
/// ButtonLog.shared.recordEvent(kind: "button",       // decoded/routed stages
///                              code: byte, detail: "routed .right")
/// ```
final class ButtonLog: @unchecked Sendable {

    /// Process-wide singleton.
    static let shared = ButtonLog()

    /// Master compile-time switch. **ON in DEBUG builds only** so field-debug
    /// builds capture a trail with no wiring, while release builds never
    /// write to disk. Combined with the runtime opt-in below (both must be
    /// true to write), so even a DEBUG build stays silent until the rider
    /// flips the diagnostics toggle. `nonisolated(unsafe)` — coarse debug
    /// toggle, not hot-path shared state.
    #if DEBUG
    nonisolated(unsafe) static var isCompiledIn = true
    #else
    nonisolated(unsafe) static var isCompiledIn = false
    #endif

    /// Runtime opt-in, mirrored from `DashNavSettings.buttonWireLoggingEnabled`.
    /// **Default ON in DEBUG** so a debug build captures a button trail with
    /// zero setup — exactly like `ManeuverLog` — instead of making the rider
    /// hunt for a toggle at the bike. Release builds never compile the writer
    /// in (`isCompiledIn == false`), so this default is DEBUG-only in effect.
    /// The Settings toggle exists to turn it OFF, not ON. `nonisolated(unsafe)`
    /// — coarse debug toggle, not hot-path shared state.
    #if DEBUG
    nonisolated(unsafe) static var isEnabled = true
    #else
    nonisolated(unsafe) static var isEnabled = false
    #endif

    /// Both gates must be true to write anything.
    private static var isActive: Bool { isCompiledIn && isEnabled }

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "ButtonLog")

    /// Serial queue: single owner of all mutable state + file IO. `.utility`
    /// so it never competes with the render/nav path.
    private let queue = DispatchQueue(
        label: "eu.kolaczek.tripperdashpp.buttonlog",
        qos: .utility
    )

    // MARK: - State owned exclusively by `queue`

    private var handle: FileHandle?
    private var fileURL: URL?
    private var bytesWritten: Int = 0

    /// Per-session file size cap → roll over so a long ride can't grow it
    /// without bound. Button logs are tiny; 4 MiB is plenty.
    private let maxBytes = 4 * 1024 * 1024

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private init() {}

    // MARK: - Sendable snapshot

    /// Immutable value-type snapshot of one log entry. Built on the caller's
    /// thread; the ONLY thing handed to the serial queue.
    private struct Entry: Sendable {
        let timestamp: Date
        let event: String          // "rx_raw" | "button" | "unmapped" | "note"
        let hex: String?           // packet / segment bytes, hex
        let byteCount: Int?
        let code: String?          // button code, hex e.g. "0x13"
        let detail: String?        // free-form stage note
    }

    /// On-disk `.jsonl` line shape. `nil` fields omitted by the encoder.
    private struct Line: Encodable {
        var event: String
        var timestamp: String
        var hex: String?
        var byteCount: Int?
        var code: String?
        var detail: String?
    }

    // MARK: - Public API

    /// Begin a fresh session file. Called implicitly on first write; call
    /// explicitly at connect to rotate per ride.
    func startSession() {
        guard Self.isActive else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.closeLocked()
            self.openSessionLocked()
        }
    }

    /// Flush and close the current session file. Safe when idle.
    func endSession() {
        queue.async { [weak self] in
            self?.closeLocked()
        }
    }

    /// Record a raw inbound packet (the ground-truth line). Cheap: snapshots
    /// a hex preview and returns; the write happens on the serial queue.
    /// `previewCap` bounds the hex so a stray large packet can't bloat a line.
    func recordRaw(_ packet: Data, previewCap: Int = 128) {
        guard Self.isActive else { return }
        let slice = packet.prefix(previewCap)
        let hex = slice.map { String(format: "%02x", $0) }.joined()
        let entry = Entry(
            timestamp: Date(),
            event: "rx_raw",
            hex: hex,
            byteCount: packet.count,
            code: nil,
            detail: packet.count > previewCap ? "truncated" : nil
        )
        queue.async { [weak self] in self?.write(entry) }
    }

    /// Record a decoded/routed button stage, or any diagnostic note. `code`
    /// is the button byte (logged hex) when relevant; `detail` names the
    /// pipeline stage ("decoded", "acked", "routed .right", "unmapped", …).
    func recordEvent(event: String, code: UInt8? = nil, detail: String? = nil) {
        guard Self.isActive else { return }
        let entry = Entry(
            timestamp: Date(),
            event: event,
            hex: nil,
            byteCount: nil,
            code: code.map { String(format: "0x%02X", $0) },
            detail: detail
        )
        queue.async { [weak self] in self?.write(entry) }
    }

    // MARK: - Queue-confined implementation

    private func write(_ entry: Entry) {
        openSessionLocked()
        guard handle != nil else { return }
        let line = Line(
            event: entry.event,
            timestamp: isoFormatter.string(from: entry.timestamp),
            hex: entry.hex,
            byteCount: entry.byteCount,
            code: entry.code,
            detail: entry.detail
        )
        append(line)
    }

    private func append(_ line: Line) {
        guard let data = try? encoder.encode(line) else {
            log.error("ButtonLog: failed to encode a log line")
            return
        }
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
            log.error("ButtonLog: write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openSessionLocked() {
        guard handle == nil else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            log.error("ButtonLog: no Documents directory — logging disabled this session")
            return
        }
        let dir = docs.appendingPathComponent("button-logs", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("ButtonLog: cannot create log dir: \(error.localizedDescription, privacy: .public)")
            return
        }
        let stamp = fileStampFormatter.string(from: Date())
        let url = dir.appendingPathComponent("btn-\(stamp).jsonl", isDirectory: false)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            log.error("ButtonLog: cannot open \(url.lastPathComponent, privacy: .public) for writing")
            return
        }
        let end = (try? h.seekToEnd()) ?? 0
        handle = h
        fileURL = url
        bytesWritten = Int(end)
        log.info("ButtonLog: session file \(url.lastPathComponent, privacy: .public)")
    }

    private func closeLocked() {
        try? handle?.close()
        handle = nil
        fileURL = nil
        bytesWritten = 0
    }
}
