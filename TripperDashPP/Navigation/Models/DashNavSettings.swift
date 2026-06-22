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
//  Persisted in UserDefaults under "dashNavSettings.v3". v2 carried four
//  diagnostic toggles for the Bug 3 clock-shift A/B test; once the root
//  cause was found (initial-burst packet 3 carried a stale set-clock
//  TLV — fixed in 807081a) the toggles were retired and the key bumped
//  to v3. Old v2/v1 blobs are ignored on read; we just rewrite to v3.
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

    /// F2c: emit the secondary-maneuver TLV chain (look-ahead chevron)
    /// when the primary maneuver is closer than `lookaheadThresholdMeters`.
    /// Defaults to ON. Disable to drop the chevron entirely if the
    /// dash misrenders it on a particular Tripper firmware revision.
    var lookaheadEnabled: Bool = true {
        didSet { persist() }
    }

    /// F2c: distance threshold (m) below which we attach the
    /// secondary-maneuver TLV. Default 300 m — a normal city block
    /// or a typical motorway off-ramp lead-in. Higher = chevron
    /// appears earlier; lower = only stacks immediately consecutive
    /// turns.
    var lookaheadThresholdMeters: Double = 300 {
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

    // Bumped to v4 when the F2c lookahead toggles landed. v3 blobs
    // are silently ignored on first read; we just rewrite them under
    // the new key with current defaults (lookahead ON, threshold 300 m).
    private static let storeKey = "dashNavSettings.v4"

    private struct Persisted: Codable {
        var units: UnitSystem
        var decimalSeparator: DecimalSeparator
        var clockFormat: ClockFormat
        var bottomLine: BottomLineMode
        // Optional so we can still decode v3 blobs that lack these
        // fields — Codable's silent ignore handles forward additions
        // when the keys are optional. Defaults applied in load().
        var lookaheadEnabled: Bool?
        var lookaheadThresholdMeters: Double?
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
        self.lookaheadEnabled = p.lookaheadEnabled ?? true
        self.lookaheadThresholdMeters = p.lookaheadThresholdMeters ?? 300
    }

    private func persist() {
        let p = Persisted(
            units: units,
            decimalSeparator: decimalSeparator,
            clockFormat: clockFormat,
            bottomLine: bottomLine,
            lookaheadEnabled: lookaheadEnabled,
            lookaheadThresholdMeters: lookaheadThresholdMeters
        )
        if let raw = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(raw, forKey: Self.storeKey)
        }
    }
}
