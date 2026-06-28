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
//   - `clockFormat` → how we format the local-time string handed to
//     `tlvEta`. NOTE: it no longer changes the `05 54` ETA-format byte —
//     that byte is pinned to `0x30` because the dash rejects any other
//     value (a 12h `0x31` guess blanked the ETA on the real dash, 6/2026).
//     So the ETA always renders 24-hour on the dash for now; driving a
//     true 12h render is blocked on a 12h-mode OEM capture.
//   - `bottomLine` → user's preferred bottom row (ETA vs distance). As of
//     6/2026 this is NOT enforced by omitting TLVs: the active-nav loop
//     mirrors the OEM app and sends ETA + total-distance + remaining-time
//     together every tick (the only wire layout the dash is known to
//     accept). The OLD code omitted the ETA TLV when bottomLine ==
//     .distance to make the bubble "pick" distance — that produced two
//     field-confirmed bugs (blank ETA, and "switch to km does nothing")
//     and diverged from the real-phone capture, so it was removed. Which
//     field the dash shows in its bottom row is a dash-side decision we
//     don't yet know how to drive deterministically (likely the
//     undecoded `05 0C` field); `includeEtaTlv` is retained below but is
//     currently advisory only.
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

    /// Phase 9f: push the phone's call state to the dash so it shows the OEM
    /// incoming-call card (the `05 21` / `05 4D` K1G burst — see
    /// `CallStateObserver` + the `call-notification-wire-protocol.md` skill
    /// reference). Defaults to ON. Disable to keep the dash quiet during
    /// calls — handy if a rider takes a lot of calls on the move and doesn't
    /// want the card stealing the nav bubble, or if a particular Tripper
    /// firmware misrenders it. When off, `BikeLink.sendCallState` becomes a
    /// no-op, so NOTHING call-related is ever put on the wire.
    var callStateEnabled: Bool = true {
        didSet { persist() }
    }

    // MARK: - Derived wire helpers

    /// Quantize a maneuver distance (meters) into human-friendly buckets
    /// so the dash bubble's "in N m" readout stops twitching every GPS
    /// tick. Far from the turn the rider only needs a coarse number; in
    /// the final approach they need fine granularity. Per Martin's field
    /// request (6/2026):
    ///
    ///   - `< 50 m`      → nearest 1 m   (42 → 42)   final approach
    ///   - `50 … <200 m` → nearest 25 m  (188 → 175, 73 → 75)
    ///   - `≥ 200 m`     → nearest 100 m (437 → 400)
    ///
    /// Bucketing is done in METERS — the physical maneuver distance — and
    /// the unit byte + wire value are then derived from the bucketed
    /// value, so the metric m↔km/10ths crossover stays consistent (e.g.
    /// 985 m buckets to 1000 m → "1.0 km", never a flickering "990 m").
    ///
    /// Only the PRIMARY/SECONDARY maneuver distances are bucketed (those
    /// drive the bubble's twitchy "in N m" line). The total-distance-to-
    /// destination is left continuous — it ticks down slowly and a round
    /// number there would actually look wrong on a long route.
    ///
    /// NOTE: thresholds are metric. Imperial riders get the same physical
    /// buckets converted to feet/miles downstream (stable, if not on
    /// round imperial numbers); a dedicated imperial bucket table can come
    /// later if anyone actually rides this in miles.
    func bucketedManeuverDistance(meters m: Double) -> Double {
        guard m.isFinite, m > 0 else { return 0 }
        let step: Double
        if m < 50 {
            step = 1
        } else if m < 200 {
            step = 25
        } else {
            step = 100
        }
        return (m / step).rounded() * step
    }

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
    /// ADVISORY ONLY as of 6/2026. The active-nav loop no longer omits the
    /// ETA TLV when this is false — it mirrors the OEM app and always sends
    /// ETA + total-distance + remaining-time together. Kept so the UI toggle
    /// still persists the user's preference and so a future, capture-verified
    /// bottom-row selector (likely the `05 0C` field) can consume it. Do NOT
    /// re-wire this to gate TLV emission — that was the blank-ETA / broken-km
    /// bug.
    var includeEtaTlv: Bool { bottomLine == .eta }

    // MARK: - Persistence

    // Bumped to v6 when the device-telemetry toggle (deviceTelemetryEnabled)
    // landed. Older blobs (v5 and earlier) are silently ignored on first
    // read; we just rewrite them under the new key with current defaults
    // (call-state card ON, lookahead ON, threshold 300 m). Phone-status
    // telemetry is no longer a setting — it's always reported (a dropped
    // `deviceTelemetryEnabled` key in an old blob is simply ignored).
    private static let storeKey = "dashNavSettings.v6"

    private struct Persisted: Codable {
        var units: UnitSystem
        var decimalSeparator: DecimalSeparator
        var clockFormat: ClockFormat
        var bottomLine: BottomLineMode
        // Optional so we can still decode older blobs that lack these
        // fields — Codable's silent ignore handles forward additions
        // when the keys are optional. Defaults applied in load().
        var lookaheadEnabled: Bool?
        var lookaheadThresholdMeters: Double?
        var callStateEnabled: Bool?
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
        self.callStateEnabled = p.callStateEnabled ?? true
    }

    private func persist() {
        let p = Persisted(
            units: units,
            decimalSeparator: decimalSeparator,
            clockFormat: clockFormat,
            bottomLine: bottomLine,
            lookaheadEnabled: lookaheadEnabled,
            lookaheadThresholdMeters: lookaheadThresholdMeters,
            callStateEnabled: callStateEnabled
        )
        if let raw = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(raw, forKey: Self.storeKey)
        }
    }
}
