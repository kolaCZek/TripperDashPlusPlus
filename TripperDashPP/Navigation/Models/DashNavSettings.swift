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
//  Persisted in UserDefaults under "dashNavSettings.v1". Observable so
//  StreamingView's settings sheet binds cleanly.
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

    private static let storeKey = "dashNavSettings.v1"

    private struct Persisted: Codable {
        var units: UnitSystem
        var decimalSeparator: DecimalSeparator
        var clockFormat: ClockFormat
        var bottomLine: BottomLineMode
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
    }

    private func persist() {
        let p = Persisted(
            units: units,
            decimalSeparator: decimalSeparator,
            clockFormat: clockFormat,
            bottomLine: bottomLine
        )
        if let raw = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(raw, forKey: Self.storeKey)
        }
    }
}
