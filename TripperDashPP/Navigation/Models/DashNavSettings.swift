//
//  DashNavSettings.swift
//  TripperDashPP
//
//  Phase 9e / display-prefs — dash + app display preferences.
//
//  REAL-BIKE GROUND TRUTH (Martin road-tested, 8/2026): the Tripper dash
//  owns 12/24h, decimal separator, and km/miles through its OWN separate,
//  undocumented in-bike settings menu — NOT through our active-nav TLV
//  stream. Trying to drive them from the phone is pointless; the dash
//  formats whatever it receives per its local settings. So these are now
//  APP-GLOBAL DISPLAY PREFERENCES: they format every time / number /
//  distance shown in the app UI, and the rider is expected to set the
//  matching preference in the bike's own menu. Defaults are seeded from the
//  phone locale (`*.deviceDefault`): metric/imperial, decimal separator,
//  24/12h.
//
//   - `units` → app-wide distance/speed unit for the UI. We STILL send the
//     distance TLVs on the wire as before (`05 06`/`05 46`); the bike
//     re-chews them per its own unit setting. The toggle no longer pretends
//     to drive the wire — it drives the app UI.
//   - `decimalSeparator` → app-wide decimal separator for every UI number.
//     No wire effect (the bike formats its own numbers).
//   - `clockFormat` → formats every time string in the app UI, AND the ETA
//     string we build for the dash (24h → `14:33`, 12h → `2:33`, hour % 12,
//     no AM/PM, no extra leading zero) so our output matches the OEM app.
//     The dash then renders it per its own clock setting (observed quirk:
//     it shows ETA "humpácky" — 14:22 as `02:22`, bare hour, no AM/PM —
//     that formatting is dash-side and buggy, nothing we can fix on the
//     wire).
//
//  The old `bottomLine` (ETA-vs-distance bubble bottom row) preference was
//  REMOVED entirely: the road test confirmed flipping it changes neither
//  wire nor dash render — it did nothing. The active-nav loop already sent
//  ETA + total-distance + remaining-time together every tick (the only wire
//  layout the dash accepts) and no longer gated anything on `bottomLine`.
//
//  Persisted in UserDefaults under "dashNavSettings.v11". Removing the
//  `bottomLine` field from `Persisted` is decode-safe: an older blob just
//  carries an extra key that Codable ignores; a new blob simply omits it.
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

        /// Seed the default from the phone's region. `Locale.measurementSystem`
        /// reports `.metric`, `.us`, or `.uk` — treat US as imperial and
        /// everything else (incl. UK, which is mixed but road-distances-metric
        /// enough here) as metric. The rider can override in settings.
        static var deviceDefault: UnitSystem {
            Locale.current.measurementSystem == .us ? .imperial : .metric
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

        /// Seed from the phone's locale decimal separator. The rider can
        /// override in settings.
        static var deviceDefault: DecimalSeparator {
            Locale.current.decimalSeparator == "," ? .comma : .period
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

        /// Seed from the phone's clock preference. We probe a short
        /// time-format template for the current locale: if it lacks an "a"
        /// (AM/PM) designator the phone is on 24-hour time. The rider can
        /// override in settings.
        static var deviceDefault: ClockFormat {
            let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0,
                                               locale: Locale.current) ?? "HH"
            return fmt.contains("a") ? .h12 : .h24
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

    var units: UnitSystem = UnitSystem.deviceDefault {
        didSet { persist() }
    }

    var decimalSeparator: DecimalSeparator = DecimalSeparator.deviceDefault {
        didSet { persist() }
    }

    var clockFormat: ClockFormat = ClockFormat.deviceDefault {
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

    /// Voice guidance: speak turn-by-turn maneuver prompts through the
    /// phone speaker / connected headset while navigating. Offline
    /// (`AVSpeechSynthesizer`), keyless. Defaults OFF so a rider who
    /// doesn't want spoken cues (or has no intercom) never gets surprised
    /// by audio — they opt in. When OFF, `VoiceNavigator` is never asked to
    /// speak and its audio-session ducking never engages.
    var voiceEnabled: Bool = false {
        didSet { persist() }
    }

    /// Language for spoken guidance. Seeded from the PHONE'S language on
    /// first launch (`VoiceLanguage.deviceDefault`) — an unsupported phone
    /// language falls back to English. The rider can override in settings;
    /// once set, the stored choice wins on every subsequent launch.
    var voiceLanguage: VoiceLanguage = .deviceDefault {
        didSet { persist() }
    }

    /// Also speak a chime/prompt when approaching a speed camera. Gated
    /// additionally on `speedCamerasEnabled` (no cameras loaded → nothing to
    /// announce) and on `voiceEnabled`. Defaults ON — a rider who turned
    /// voice on generally wants the safety callout too. This is the
    /// previously-deferred camera chime (see the note on `speedCamerasEnabled`).
    var voiceSpeedCameraEnabled: Bool = true {
        didSet { persist() }
    }

    /// When to show the posted-speed-limit traffic sign. Defaults to
    /// `.always` — most riders want the current limit visible at a glance.
    /// `.off` skips the Overpass fetch entirely.
    var speedLimitDisplay: SpeedLimitDisplay = .always {
        didSet { persist() }
    }

    /// Live-traffic reroute: while ON the navigator periodically re-queries
    /// Apple `MKDirections` (traffic-aware `expectedTravelTime`) from the
    /// rider's live position and, if a faster alternative to the SAME
    /// destination now exists that saves at least
    /// `trafficRerouteSavingSeconds`, silently swaps navigation onto it —
    /// the same swap mechanism as an off-route reroute.
    ///
    /// Defaults OFF (opt-in) because it is nav-critical and Apple's
    /// traffic signal is best-effort (folds *some* current traffic into
    /// `expectedTravelTime` when online — no structured incidents). A
    /// rider opts in knowingly. When OFF, no extra MKDirections work is
    /// done beyond the existing ETA re-fetch, and no traffic swap can fire.
    var trafficRerouteEnabled: Bool = false {
        didSet { persist() }
    }

    /// Minimum time saving (seconds) a faster live-traffic alternative
    /// must beat the current route by before we auto-swap. Default 300 s
    /// (5 min): high enough that ordinary ETA jitter / GPS-position noise
    /// on the re-fetch never triggers a spurious reroute, low enough to
    /// catch a real jam forming ahead. The settings stepper drives this
    /// in whole minutes via `trafficRerouteSavingMinutes`.
    var trafficRerouteSavingSeconds: TimeInterval = 300 {
        didSet { persist() }
    }

    /// The saving threshold expressed in whole MINUTES, for the settings
    /// stepper. Clamps to a sane 1…30 min band — below 1 min the ETA
    /// re-fetch noise dominates, above 30 min the feature would never
    /// fire. Round-trips through the canonical seconds store.
    var trafficRerouteSavingMinutes: Int {
        get { max(1, min(30, Int((trafficRerouteSavingSeconds / 60).rounded()))) }
        set { trafficRerouteSavingSeconds = TimeInterval(max(1, min(30, newValue)) * 60) }
    }

    /// Route progress bar: draw a thin bar along the BOTTOM edge of the
    /// streamed map showing how far along the route the rider is (filled
    /// from the left) plus a coarse traffic-delay tint on the road AHEAD.
    /// Defaults ON — it's an at-a-glance ride gauge, non-critical, and
    /// costs nothing (all data is already local: breadcrumb distance vs.
    /// planned total, and the live Apple ETA vs. the trip's own baseline
    /// pace). When OFF, `drawProgressBar` is a no-op.
    ///
    /// IMPORTANT — honest scope (Martin, 8/2026): the "ahead" tint is a
    /// SINGLE coarse colour derived from whether the live ETA is running
    /// slower than the route's own start-of-trip average pace. It is NOT
    /// per-segment traffic flow — Apple `MKDirections` returns only a
    /// scalar `expectedTravelTime`, no geometry-resolved flow, so a true
    /// yellow/red "jam at km 12" colouring is impossible on Apple and
    /// waits on the BYOK TomTom provider (see routing-engines.md). This
    /// bar tells the rider "the road ahead is slower than this trip has
    /// been", not WHERE the slowdown is.
    var progressBarEnabled: Bool = true {
        didSet { persist() }
    }

    /// DIAGNOSTIC opt-in: persist every inbound K1G packet raw to the phone's
    /// disk (`Documents/button-logs/*.jsonl`) so a rider with ONLY a phone at
    /// the bike (no laptop) can capture the real joystick wire bytes and pull
    /// them off later via the Files app. **Default ON in DEBUG** (like
    /// ManeuverLog — zero setup at the bike), OFF in release (where the writer
    /// isn't compiled in anyway). The Settings toggle is there to turn it OFF.
    /// Mirrored into `ButtonLog.isEnabled` on set + at load.
    var buttonWireLoggingEnabled: Bool = DashNavSettings.buttonWireLoggingDefault {
        didSet {
            ButtonLog.isEnabled = buttonWireLoggingEnabled
            persist()
        }
    }

    /// DEBUG-aware default for `buttonWireLoggingEnabled` (see above).
    static var buttonWireLoggingDefault: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// DIAGNOSTIC opt-in: persist per-maneuver navigation state to the phone's
    /// disk (`Documents/maneuver-logs/*.jsonl`) so a route can be replayed /
    /// grepped offline after a ride. Same shape and rationale as
    /// `buttonWireLoggingEnabled`: **default ON in DEBUG** (zero setup at the
    /// bike), OFF in release (the writer isn't compiled in anyway). The
    /// Settings toggle exists to turn it OFF. Mirrored into
    /// `ManeuverLog.isEnabled` on set + at load.
    var maneuverLoggingEnabled: Bool = DashNavSettings.maneuverLoggingDefault {
        didSet {
            ManeuverLog.isEnabled = maneuverLoggingEnabled
            persist()
        }
    }

    /// DEBUG-aware default for `maneuverLoggingEnabled` (see above).
    static var maneuverLoggingDefault: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Tolerance (km/h) the rider must EXCEED the posted limit by before
    /// the `.overOnly` mode lights the sign. A few km/h of slop keeps the
    /// sign from flickering on/off as GPS speed jitters right at the limit
    /// (and matches the unwritten "nobody gets booked for +3" reality).
    var speedLimitOverToleranceKmh: Double = 3 {
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

    // MARK: - Persistence

    // Bumped to v11 when the route progress bar toggle (progressBarEnabled)
    // landed — on top of v10's live-traffic reroute toggles
    // (trafficRerouteEnabled / trafficRerouteSavingSeconds). Older blobs
    // (v10 and earlier) are silently ignored on first read; we just rewrite
    // them under the new key with current defaults (progress bar ON,
    // traffic reroute OFF, call-state ON, lookahead ON).
    private static let storeKey = "dashNavSettings.v11"

    private struct Persisted: Codable {
        var units: UnitSystem
        var decimalSeparator: DecimalSeparator
        var clockFormat: ClockFormat
        // Optional so we can still decode older blobs that lack these
        // fields — Codable's silent ignore handles forward additions
        // when the keys are optional. Defaults applied in load().
        var lookaheadEnabled: Bool?
        var lookaheadThresholdMeters: Double?
        var callStateEnabled: Bool?
        var weatherAlertsEnabled: Bool?
        var speedCamerasEnabled: Bool?
        var speedLimitDisplay: SpeedLimitDisplay?
        var speedLimitOverToleranceKmh: Double?
        var voiceEnabled: Bool?
        var voiceLanguage: VoiceLanguage?
        var voiceSpeedCameraEnabled: Bool?
        var trafficRerouteEnabled: Bool?
        var trafficRerouteSavingSeconds: TimeInterval?
        var progressBarEnabled: Bool?
        var buttonWireLoggingEnabled: Bool?
        var maneuverLoggingEnabled: Bool?
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
        self.lookaheadEnabled = p.lookaheadEnabled ?? true
        self.lookaheadThresholdMeters = p.lookaheadThresholdMeters ?? 300
        self.callStateEnabled = p.callStateEnabled ?? true
        self.weatherAlertsEnabled = p.weatherAlertsEnabled ?? true
        self.speedCamerasEnabled = p.speedCamerasEnabled ?? true
        self.speedLimitDisplay = p.speedLimitDisplay ?? .always
        self.speedLimitOverToleranceKmh = p.speedLimitOverToleranceKmh ?? 3
        self.voiceEnabled = p.voiceEnabled ?? false
        self.voiceLanguage = p.voiceLanguage ?? .deviceDefault
        self.voiceSpeedCameraEnabled = p.voiceSpeedCameraEnabled ?? true
        self.trafficRerouteEnabled = p.trafficRerouteEnabled ?? false
        self.trafficRerouteSavingSeconds = p.trafficRerouteSavingSeconds ?? 300
        self.progressBarEnabled = p.progressBarEnabled ?? true
        // Setting this fires the didSet (load() is a method, not the init
        // body), which mirrors into ButtonLog.isEnabled and re-persists the
        // same blob — harmless, same as every other observed field above.
        // The explicit mirror line is belt-and-suspenders.
        self.buttonWireLoggingEnabled = p.buttonWireLoggingEnabled ?? Self.buttonWireLoggingDefault
        ButtonLog.isEnabled = self.buttonWireLoggingEnabled
        self.maneuverLoggingEnabled = p.maneuverLoggingEnabled ?? Self.maneuverLoggingDefault
        ManeuverLog.isEnabled = self.maneuverLoggingEnabled
    }

    private func persist() {
        let p = Persisted(
            units: units,
            decimalSeparator: decimalSeparator,
            clockFormat: clockFormat,
            lookaheadEnabled: lookaheadEnabled,
            lookaheadThresholdMeters: lookaheadThresholdMeters,
            callStateEnabled: callStateEnabled,
            weatherAlertsEnabled: weatherAlertsEnabled,
            speedCamerasEnabled: speedCamerasEnabled,
            speedLimitDisplay: speedLimitDisplay,
            speedLimitOverToleranceKmh: speedLimitOverToleranceKmh,
            voiceEnabled: voiceEnabled,
            voiceLanguage: voiceLanguage,
            voiceSpeedCameraEnabled: voiceSpeedCameraEnabled,
            trafficRerouteEnabled: trafficRerouteEnabled,
            trafficRerouteSavingSeconds: trafficRerouteSavingSeconds,
            progressBarEnabled: progressBarEnabled,
            buttonWireLoggingEnabled: buttonWireLoggingEnabled,
            maneuverLoggingEnabled: maneuverLoggingEnabled
        )
        if let raw = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(raw, forKey: Self.storeKey)
        }
    }
}
