//
//  DashNavSettings.swift
//  TripperDashPP
//
//  Phase 9e — dash display preferences for the active-nav TLV stream.
//
//  These four settings control how the dash renders the active-nav bubble
//  during navigation. Each one maps to a specific TLV in
//  `K1GPacket.makeActiveNav`:
//
//   - `units` → primary/total distance unit byte (`05 06`, `05 46`)
//   - `decimalSeparator` → comma vs period (`05 0A`)
//   - `clockFormat` → ETA format flag (`05 54`) plus how we format the
//     local-time string we hand to `tlvEta`
//   - `bottomLine` → mutex toggle: the dash bubble can show ETA OR total
//     distance in its bottom row, not both. We always send the total
//     distance TLV (the dash needs it for route progress), but we omit
//     the ETA TLV when bottomLine == .distance so the bubble picks
//     distance to render.
//
//  Persisted in UserDefaults under "dashNavSettings.v2" (v1 → v2 added
//  Bug 3 diagnostic toggles below). Observable so StreamingView's
//  settings sheet binds cleanly.
//

import Foundation
import Observation

@Observable
final class DashNavSettings {
    // MARK: - User-facing knobs

    enum UnitSystem: String, Codable, CaseIterable, Identifiable {
        case metric   // km / m
        case imperial // mi / ft
        var id: String { rawValue }
        var label: String {
            switch self {
            case .metric:   return "Metric (km / m)"
            case .imperial: return "Imperial (mi / ft)"
            }
        }
    }

    enum DecimalSeparator: String, Codable, CaseIterable, Identifiable {
        case period   // 1.2 km
        case comma    // 1,2 km
        var id: String { rawValue }
        var label: String {
            switch self {
            case .period: return "Period (1.2 km)"
            case .comma:  return "Comma (1,2 km)"
            }
        }
    }

    enum ClockFormat: String, Codable, CaseIterable, Identifiable {
        case h24  // 18:32
        case h12  //  6:32 PM
        var id: String { rawValue }
        var label: String {
            switch self {
            case .h24: return "24-hour"
            case .h12: return "12-hour"
            }
        }
    }

    /// Mutex toggle for the bottom row of the active-nav bubble on the
    /// dash. The dash bubble has room for ONE of ETA or total distance,
    /// not both. Riders typically prefer ETA on long highway stretches
    /// and remaining distance in town.
    enum BottomLineMode: String, Codable, CaseIterable, Identifiable {
        case eta
        case distance
        var id: String { rawValue }
        var label: String {
            switch self {
            case .eta:      return "ETA (arrival time)"
            case .distance: return "Distance remaining"
            }
        }
    }

    // MARK: - Diagnostics (Bug 3 — clock-shift A/B isolation)
    //
    // Field-test 2026-06-21 caught a reproducible bug: connecting the
    // phone to the dash shifts the dash clock by a few hours (e.g.
    // 11:25 → 14:52, +3h27m; 11:33 → 14:51, +3h18m). The offset is
    // NOT constant, so it's not a hardcoded byte or a timezone error.
    // The two observed target values are within 1 minute of each
    // other — the suspect is a stale ETA value the dash interprets as
    // a clock-sync.
    //
    // We can't isolate the culprit without a packet capture from the
    // real Android Tripper app, so these toggles let us A/B test on
    // the bike: flip one off, reconnect, watch whether the clock still
    // drifts. The shipping defaults match the current (broken)
    // behaviour so we don't regress anything that works today.

    /// Skip every TLV with type 0x05 sub 0x08 (the "ETA HH:MM" tag).
    /// If the dash stops drifting when this is off, the ETA TLV is
    /// being treated as a set-time payload.
    var suppressEtaTlv: Bool = false {
        didSet { persist() }
    }

    /// Skip the 1 Hz `0044` heartbeat once the handshake is done.
    /// The heartbeat carries two undocumented tags (`05 21` and
    /// `05 4D`); we don't know what they do. If the dash stops
    /// drifting with this off, one of them is the culprit.
    var sendHeartbeat0044: Bool = true {
        didSet { persist() }
    }

    /// Skip the very last packet of the initial handshake burst — the
    /// captured `0044` status frame with 10 TLVs incl. the two
    /// undocumented tags. The dash MAY refuse to complete pairing
    /// without it; in that case flip back on.
    var sendInitialBurstPacket9: Bool = true {
        didSet { persist() }
    }

    /// Log every outbound K1G packet with its hex preview to os_log.
    /// Use `log stream --predicate 'subsystem == "eu.kolaczek.tripperdashpp"'`
    /// on the Mac to watch the traffic in real time and correlate
    /// against the dash's clock movement.
    var verbosePacketLogging: Bool = false {
        didSet { persist() }
    }

    // MARK: - State

    var units: UnitSystem = .metric {
        didSet { persist() }
    }

    var decimalSeparator: DecimalSeparator = .period {
        didSet { persist() }
    }

    var clockFormat: ClockFormat = .h24 {
        didSet { persist() }
    }

    var bottomLine: BottomLineMode = .eta {
        didSet { persist() }
    }

    // MARK: - Derived wire helpers

    /// Wire byte for the primary distance TLV (`05 06`).
    /// 10 = km/10ths, 20 = mi/10ths, 30 = metres, 50 = feet.
    /// Chosen based on `units` AND distance magnitude — short distances
    /// render as plain metres / feet (no decimal), longer ones as tenths
    /// so the dash can show "1.2" or "0.7".
    func primaryUnitWireByte(forMeters m: Double) -> UInt8 {
        switch units {
        case .metric:
            return m < 1000 ? 0x30 : 0x10
        case .imperial:
            // 1 mile = 1609.34 m. Switch to miles/10ths above ~0.1 mi.
            return m < 160 ? 0x50 : 0x20
        }
    }

    /// Wire byte for the total distance TLV (`05 46`). Uses the same
    /// magnitude-based logic.
    func totalDistanceUnitWireByte(forMeters m: Double) -> UInt8 {
        primaryUnitWireByte(forMeters: m)
    }

    /// Render the distance VALUE that goes into the matching TLV's u16.
    /// The dash interprets the u16 according to the unit byte:
    ///   - unit 0x10 (km/10) → value = (m / 100) ; "1.2" comes from 12
    ///   - unit 0x20 (mi/10) → value = (m / 160.934)
    ///   - unit 0x30 (m)     → value = round(m)
    ///   - unit 0x50 (ft)    → value = round(m * 3.28084)
    func distanceWireValue(meters m: Double, unitByte: UInt8) -> UInt16 {
        let raw: Double
        switch unitByte {
        case 0x10: raw = m / 100.0          // km × 10 (tenths of km)
        case 0x20: raw = m / 160.9344       // mi × 10 (tenths of mile)
        case 0x30: raw = m                  // metres
        case 0x50: raw = m * 3.280839895    // feet
        default:   raw = m
        }
        let clamped = max(0, min(Double(UInt16.max), raw.rounded()))
        return UInt16(clamped)
    }

    var useCommaDecimal: Bool { decimalSeparator == .comma }
    var is24Hour: Bool { clockFormat == .h24 }
    var includeEtaTlv: Bool { bottomLine == .eta }

    // MARK: - Persistence

    // Bumped to v2 when we added the Bug 3 diagnostic toggles. The
    // optional fields below are decoded with `decodeIfPresent` so an
    // old v1 blob still loads cleanly — we just keep the defaults
    // (everything as it was) and ignore the missing keys.
    private static let storeKey = "dashNavSettings.v2"

    // Note: scan* fields used to be persisted here. Removed in the
    // settings-cleanup refactor (catalog complete 2026-06-21) — old
    // v2 blobs with those keys still decode cleanly because Codable
    // silently ignores unknown JSON keys on decode.
    private struct Persisted: Codable {
        var units: UnitSystem
        var decimalSeparator: DecimalSeparator
        var clockFormat: ClockFormat
        var bottomLine: BottomLineMode
        var suppressEtaTlv: Bool?
        var sendHeartbeat0044: Bool?
        var sendInitialBurstPacket9: Bool?
        var verbosePacketLogging: Bool?
    }

    init() {
        load()
    }

    private func load() {
        guard let raw = UserDefaults.standard.data(forKey: Self.storeKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: raw)
        else { return }
        self.units = p.units
        self.decimalSeparator = p.decimalSeparator
        self.clockFormat = p.clockFormat
        self.bottomLine = p.bottomLine
        if let v = p.suppressEtaTlv          { self.suppressEtaTlv = v }
        if let v = p.sendHeartbeat0044       { self.sendHeartbeat0044 = v }
        if let v = p.sendInitialBurstPacket9 { self.sendInitialBurstPacket9 = v }
        if let v = p.verbosePacketLogging    { self.verbosePacketLogging = v }
    }

    private func persist() {
        let p = Persisted(
            units: units,
            decimalSeparator: decimalSeparator,
            clockFormat: clockFormat,
            bottomLine: bottomLine,
            suppressEtaTlv: suppressEtaTlv,
            sendHeartbeat0044: sendHeartbeat0044,
            sendInitialBurstPacket9: sendInitialBurstPacket9,
            verbosePacketLogging: verbosePacketLogging
        )
        if let raw = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(raw, forKey: Self.storeKey)
        }
    }
}
