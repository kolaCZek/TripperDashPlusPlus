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

    /// When to burn the posted-speed-limit sign (traffic-sign disc in the
    /// bottom-right of the dash) into the stream.
    ///   - `off`        → never drawn, no Overpass fetch.
    ///   - `always`     → drawn whenever a limit is map-matched for the
    ///                    current road.
    ///   - `overOnly`   → drawn only while the rider is over the limit
    ///                    (by more than `speedLimitOverToleranceKmh`), so
    ///                    the sign acts as a "you're speeding" warning.
    enum SpeedLimitDisplay: String, Codable, CaseIterable, Identifiable {
        case off
        case always
        case overOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off:      return "Off"
            case .always:   return "Always"
            case .overOnly: return "Only when speeding"
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

    /// Phase 9h: mirror incoming MESSAGES onto the dash the same way the OEM
    /// app does — the `km3.z()` burst of a plaintext `06 09` unread count plus
    /// up to five AES-encrypted slots (content `0524…`, sender `0527…`,
    /// timestamp `052A…`). See `MessageNotification` + the
    /// `message-notification-wire-protocol.md` skill reference. Defaults to
    /// ON. When OFF, `BikeLink.sendMessageNotification` is a no-op so nothing
    /// message-related ever reaches the wire.
    ///
    /// NOTE: unlike call-state, iOS has no general incoming-SMS API, so this
    /// only surfaces messages from whatever source the app actually feeds
    /// into `MessageFeed` (its own push extension, or a user/test entry) —
    /// the toggle gates the wire path regardless of where the message came
    /// from.
    var messageNotifyEnabled: Bool = true {
        didSet { persist() }
    }

    /// Ride-alerts: surface ride-relevant WEATHER (rain/ice/storm/strong
    /// gusts/fog) as a compact pill burned into the bottom-right of the
    /// streamed map. Sourced keyless from Open-Meteo (WeatherKit needs a
    /// paid entitlement we don't have — see CLAUDE.md). Defaults ON.
    /// When OFF, `WeatherAlertService` is never polled and the pill never
    /// draws. Mirrors the OEM app's "Weather Alerts" notification.
    var weatherAlertsEnabled: Bool = true {
        didSet { persist() }
    }

    /// Ride-alerts: plot SPEED CAMERAS (OSM `highway=speed_camera`, fetched
    /// via Overpass) as map markers along the route. Best-effort — OSM
    /// coverage is crowd-sourced and incomplete, so this is map enrichment,
    /// NOT a guaranteed enforcement warning (the settings footer says so
    /// too). Defaults ON. When OFF, no Overpass fetch happens and no
    /// markers draw.
    ///
    /// NOTE (6/2026): a proximity CHIME for approaching cameras is
    /// intentionally deferred until the app has voice/audio guidance — see
    /// the `royal-enfield-tripper-dash` skill's open-items. For now this is
    /// purely the visual map layer.
    var speedCamerasEnabled: Bool = true {
        didSet { persist() }
    }

    /// When to show the posted-speed-limit traffic sign. Defaults to
    /// `.always` — most riders want the current limit visible at a glance.
    /// `.off` skips the Overpass fetch entirely.
    var speedLimitDisplay: SpeedLimitDisplay = .always {
        didSet { persist() }
    }

    /// Tolerance (km/h) the rider must EXCEED the posted limit by before
    /// the `.overOnly` mode lights the sign. A few km/h of slop keeps the
    /// sign from flickering on/off as GPS speed jitters right at the limit
    /// (and matches the unwritten "nobody gets booked for +3" reality).
    var speedLimitOverToleranceKmh: Double = 3 {
        didSet { persist() }
    }

    /// GPS trip computer: show the live ride panel (distance / moving time
    /// / avg + max speed / ascent) on the streaming screen. Defaults ON.
    /// Phone-side only — this gates the on-phone panel, nothing on the
    /// wire (the trip computer is never sent to the dash). When OFF the
    /// RideStatsService still accumulates (cheap, shares the fix stream);
    /// only the panel is hidden.
    var tripComputerEnabled: Bool = true {
        didSet { persist() }
    }

    /// The same tolerance EXPRESSED IN THE RIDER'S DISPLAY UNIT, for the
    /// settings stepper. The canonical store above stays km/h — the
    /// over-limit comparison in `MapViewSource` is km/h end-to-end and
    /// physically unit-independent (a rider doing 54 in a 50 is speeding
    /// whether the dash shows km/h or mph). But an imperial rider should
    /// DIAL the slop in mph, not km/h, and SEE it in mph. Get/set converts;
    /// the value round-trips through km/h, so toggling units can nudge it
    /// by the rounding — fine for a deliberately fuzzy "nobody gets booked
    /// for +N" number. Default 3 km/h shows as 2 mph.
    var speedLimitOverToleranceDisplay: Int {
        get { Self.toleranceToDisplay(kmh: speedLimitOverToleranceKmh,
                                      imperial: units == .imperial) }
        set { speedLimitOverToleranceKmh = Self.toleranceToKmh(display: newValue,
                                                               imperial: units == .imperial) }
    }

    /// Unit suffix for the tolerance stepper label ("km/h" / "mph").
    var speedLimitToleranceUnit: String { units == .imperial ? "mph" : "km/h" }

    /// km/h → shown tolerance value in the rider's unit (rounded to a whole
    /// km/h or mph step). Pure + static so it's unit-testable and mirrored.
    static func toleranceToDisplay(kmh: Double, imperial: Bool) -> Int {
        imperial ? Int((kmh / 1.609344).rounded()) : Int(kmh.rounded())
    }

    /// Shown tolerance value (km/h or mph) → canonical km/h store. Clamps
    /// negatives to zero so a stepper can't push the slop below 0.
    static func toleranceToKmh(display: Int, imperial: Bool) -> Double {
        let v = max(0, display)
        return imperial ? Double(v) * 1.609344 : Double(v)
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
    /// NOTE: buckets are proximity-scaled AND unit-aware. A metric rider
    /// gets 1/25/100 m steps; an imperial rider gets feet / tenths-of-a-
    /// mile steps so the converted "in N ft" / "in N.N mi" readout lands
    /// on round imperial numbers instead of the ragged conversion of a
    /// metric bucket (e.g. 400 m → 1312 ft). The imperial feet↔miles
    /// threshold mirrors `primaryUnitWireByte`'s 160 m crossover so the
    /// bucket and the unit byte can never disagree.
    func bucketedManeuverDistance(meters m: Double) -> Double {
        guard m.isFinite, m > 0 else { return 0 }
        switch units {
        case .metric:
            let step: Double
            if m < 50 {
                step = 1
            } else if m < 200 {
                step = 25
            } else {
                step = 100
            }
            return (m / step).rounded() * step
        case .imperial:
            // Bucket in the rider's actual display unit, then convert the
            // rounded value back to metres (the wire/unit-byte helpers
            // re-derive feet/miles from it). Thresholds match the unit
            // byte's 160 m feet↔miles crossover.
            let ftPerM = 3.280839895
            if m < 160 {
                // Feet domain: 10 ft on final approach, 50 ft mid.
                let feet = m * ftPerM
                let step = feet < 150 ? 10.0 : 50.0
                return ((feet / step).rounded() * step) / ftPerM
            } else {
                // Miles domain: nearest 0.1 mi.
                let stepM = 1609.344 / 10.0
                return (m / stepM).rounded() * stepM
            }
        }
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

    // Bumped to v7 when the message-notify toggle (messageNotifyEnabled)
    // landed. Older blobs (v6 and earlier) are silently ignored on first
    // read; we just rewrite them under the new key with current defaults
    // (message notify ON, call-state card ON, lookahead ON, threshold 300 m).
    // Phone-status telemetry is no longer a setting — it's always reported
    // (a dropped `deviceTelemetryEnabled` key in an old blob is simply ignored).
    private static let storeKey = "dashNavSettings.v8"

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
        var messageNotifyEnabled: Bool?
        var weatherAlertsEnabled: Bool?
        var speedCamerasEnabled: Bool?
        var speedLimitDisplay: SpeedLimitDisplay?
        var speedLimitOverToleranceKmh: Double?
        var tripComputerEnabled: Bool?
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
        self.messageNotifyEnabled = p.messageNotifyEnabled ?? true
        self.weatherAlertsEnabled = p.weatherAlertsEnabled ?? true
        self.speedCamerasEnabled = p.speedCamerasEnabled ?? true
        self.speedLimitDisplay = p.speedLimitDisplay ?? .always
        self.speedLimitOverToleranceKmh = p.speedLimitOverToleranceKmh ?? 3
        self.tripComputerEnabled = p.tripComputerEnabled ?? true
    }

    private func persist() {
        let p = Persisted(
            units: units,
            decimalSeparator: decimalSeparator,
            clockFormat: clockFormat,
            bottomLine: bottomLine,
            lookaheadEnabled: lookaheadEnabled,
            lookaheadThresholdMeters: lookaheadThresholdMeters,
            callStateEnabled: callStateEnabled,
            messageNotifyEnabled: messageNotifyEnabled,
            weatherAlertsEnabled: weatherAlertsEnabled,
            speedCamerasEnabled: speedCamerasEnabled,
            speedLimitDisplay: speedLimitDisplay,
            speedLimitOverToleranceKmh: speedLimitOverToleranceKmh,
            tripComputerEnabled: tripComputerEnabled
        )
        if let raw = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(raw, forKey: Self.storeKey)
        }
    }
}
