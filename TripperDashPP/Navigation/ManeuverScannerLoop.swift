//
//  ManeuverScannerLoop.swift
//  TripperDashPP
//
//  Empirical maneuver-enum discovery loop.
//
//  Background:
//  -----------
//  The Royal Enfield Q3C protocol encodes the primary maneuver as a
//  single byte in TLV `05 02 00 01 XX`. Only two values are documented
//  in the Python authority (`0x0B` = continue, `0x3C` = bear-right);
//  the rest of the enum is unknown.
//
//  Android decompile (2026-06-21) confirmed the official RE app does
//  NOT send maneuver TLVs over K1G — the symbol is delegated to a
//  private BluConnect bitmap channel. There's no source we can pull
//  the table from, so we have to discover it ourselves.
//
//  How this loop works:
//  --------------------
//  When `maneuverScanEnabled` is true, `AppStatus.startStreaming()`
//  swaps the regular map source for `ManeuverScanSource` (huge byte
//  drawn into the H.264 stream) and constructs this loop instead of
//  `ActiveNavLoop`. The state machine cycles:
//
//      send(byte=N) → hold(scanHoldMs) → pause(scanPauseMs, black frame)
//                                       → advance to N+1
//
//  Each transition is logged to:
//   - os_log: `subsystem == "cz.kolaczek.tripperdash" category ==
//     "ManeuverScanner"`
//   - CSV file in the app's Documents/ dir, one row per byte with
//     ISO 8601 timestamp + hex + decimal. The rider exports this via
//     the Share button next to the scan toggle and pairs it against
//     the camera video to map byte → glyph.
//
//  The packet still carries enough nav metadata that the dash bubble
//  stays alive (distance = 100 m, total = 100 m, ETA = now + 5 min,
//  unit = metric tenths). Otherwise the dash drops back to the home
//  screen and the maneuver glyph never gets a chance to render.
//

import Foundation
import Observation
import os.log

@MainActor
@Observable
final class ManeuverScannerLoop {
    @ObservationIgnored private let log = Logger(subsystem: "cz.kolaczek.tripperdash", category: "ManeuverScanner")

    @ObservationIgnored private weak var bikeLink: BikeLink?
    @ObservationIgnored private weak var mapSource: ManeuverScanSource?
    @ObservationIgnored private let settings: DashNavSettings

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Where the CSV log is written. Public so the UI can build a
    /// Share sheet against it. `nil` before the first byte is sent.
    private(set) var csvLogURL: URL?

    /// Current byte being sent (UI mirrors this in the banner).
    private(set) var currentByte: UInt8 = 0

    /// 0.0...1.0 progress fraction. UI binds a ProgressView to this.
    private(set) var progress: Double = 0

    /// True while the scan is running. Drives banner + Stop button.
    private(set) var isRunning: Bool = false

    /// Set on completion or stop; UI sheet uses it to decide whether
    /// to surface the "scan done — export CSV" pill.
    private(set) var finishedAt: Date?

    init(
        bikeLink: BikeLink,
        mapSource: ManeuverScanSource,
        settings: DashNavSettings
    ) {
        self.bikeLink = bikeLink
        self.mapSource = mapSource
        self.settings = settings
    }

    /// Begin the scan from `settings.scanStartByte` to
    /// `settings.scanEndByte`, inclusive. Idempotent.
    func start() {
        guard task == nil else { return }
        let startB = settings.scanStartByte
        let endB = settings.scanEndByte
        let holdMs = max(500, settings.scanHoldMs)
        let pauseMs = max(0, settings.scanPauseMs)

        guard startB <= endB else {
            log.error("Invalid scan range: start=0x\(String(startB, radix: 16)) > end=0x\(String(endB, radix: 16))")
            return
        }

        isRunning = true
        finishedAt = nil
        currentByte = startB
        progress = 0
        csvLogURL = makeCsvLogURL()
        writeCsvHeader()

        log.info("Maneuver scan START: range 0x\(String(startB, radix: 16))..0x\(String(endB, radix: 16)), hold=\(holdMs)ms, pause=\(pauseMs)ms, log=\(self.csvLogURL?.path ?? "nil", privacy: .public)")

        task = Task { [weak self] in
            guard let self else { return }
            await self.runSweep(start: startB, end: endB, holdMs: holdMs, pauseMs: pauseMs)
        }
    }

    /// Stop the scan immediately. Safe to call mid-byte. Surfaces the
    /// finished-at timestamp so the UI knows to show the export pill.
    func stop() {
        log.info("Maneuver scan STOP at byte 0x\(String(self.currentByte, radix: 16))")
        task?.cancel()
        task = nil
        isRunning = false
        finishedAt = Date()
        mapSource?.setBlackFrame(true)
    }

    // MARK: - Sweep state machine

    private func runSweep(start: UInt8, end: UInt8, holdMs: Int, pauseMs: Int) async {
        // Map source draws the current byte; sender posts the TLV.
        // We sequence by sleeping in the loop so the hold/pause times
        // are exact regardless of how fast the 1 Hz nav pump is.
        let total = Int(end) - Int(start) + 1
        var sentIndex = 0

        for b in start...end {
            if Task.isCancelled { break }

            // 1) HOLD phase — show byte on stream, send nav packets.
            currentByte = b
            progress = Double(sentIndex) / Double(max(1, total))
            mapSource?.setBlackFrame(false)
            mapSource?.setCurrentByte(b, index: sentIndex, total: total)

            // Send the first packet immediately so the dash sees the
            // new byte even if the rider blinks during the transition.
            await sendNavPacket(byte: b)
            logCsvRow(byte: b, phase: "hold")

            // Then 1 Hz pumps for the rest of the hold.
            let pumpsRemaining = max(0, (holdMs / 1000) - 1)
            for _ in 0..<pumpsRemaining {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await sendNavPacket(byte: b)
            }
            // Round off the remainder (e.g. 5500ms → 1000+1000+1000+1000+500).
            let remainder = holdMs - (pumpsRemaining + 1) * 1000
            if remainder > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(remainder) * 1_000_000)
            }

            // 2) PAUSE phase — black frame between bytes so video
            // review has an unmistakable delimiter.
            if pauseMs > 0 && !Task.isCancelled {
                mapSource?.setBlackFrame(true)
                logCsvRow(byte: b, phase: "pause")
                try? await Task.sleep(nanoseconds: UInt64(pauseMs) * 1_000_000)
            }

            sentIndex += 1

            if b == end { break }  // UInt8 overflow guard if end == 0xFF
        }

        progress = 1.0
        isRunning = false
        finishedAt = Date()
        mapSource?.setBlackFrame(true)
        log.info("Maneuver scan DONE, \(sentIndex) bytes sent. CSV at \(self.csvLogURL?.path ?? "nil", privacy: .public)")
    }

    // MARK: - Wire

    private func sendNavPacket(byte: UInt8) async {
        guard let link = bikeLink else { return }
        // Minimal active-nav: dash needs distance + unit + decimal + ETA
        // + projection flag set or the bubble falls back to no-glyph.
        // Use trivial constants so we don't introduce variability that
        // could itself trigger interesting dash behaviour.
        await link.sendActiveNav(
            primaryManeuver: byte,
            primaryDistanceMeters: 100,
            primaryUnit: 0x30,  // 0x30 = metres
            totalDistanceMeters: 100,
            totalDistanceUnit: 0x30,
            useCommaDecimal: settings.useCommaDecimal,
            decimalFmtOn: false,
            roadName: String(format: "SCAN 0x%02X", byte),
            eta: Date(timeIntervalSinceNow: 300),
            is24Hour: settings.is24Hour,
            remainingSeconds: nil
        )
    }

    // MARK: - CSV

    private func makeCsvLogURL() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return docs.appendingPathComponent("maneuver-scan-\(ts).csv")
    }

    private func writeCsvHeader() {
        guard let url = csvLogURL else { return }
        let header = "timestamp_iso,phase,byte_hex,byte_dec\n"
        try? header.data(using: .utf8)?.write(to: url)
    }

    private func logCsvRow(byte: UInt8, phase: String) {
        guard let url = csvLogURL else { return }
        let iso = ISO8601DateFormatter().string(from: Date())
        let row = String(format: "%@,%@,0x%02X,%d\n", iso, phase, byte, byte)
        guard let data = row.data(using: .utf8) else { return }
        // Append. Open the file each row — slow, but a 128-byte run
        // writes 256 rows tops, so it's not on a hot path.
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
