//
//  ActiveNavLoop.swift
//  TripperDashPP
//
//  Phase 9e — 1 Hz active-navigation pump.
//
//  While the rider is following a route this loop fires once per second
//  and does two things:
//
//   1. Snapshots the current navigation state from `ActiveNavigator`,
//      applies the user's dash-display preferences (`DashNavSettings`),
//      and sends a full active-nav K1G packet via `BikeLink.sendActiveNav`.
//
//   2. Pushes the same snapshot into `MapViewSource.setNavOverlay(...)`
//      so the maneuver glyph + distance + road name overlay on the
//      video stream stays in sync with the bubble.
//
//  Lifecycle is tied to streaming, not to having a route: when the
//  rider isn't navigating but we're still streaming the map (e.g.
//  free-roam preview), the loop sends a "no maneuver" heartbeat so
//  the dash keeps its projection latch open.
//
//  All actor isolation: @MainActor. `ActiveNavigator` and `BikeLink`
//  are both MainActor-isolated so async calls go through cleanly with
//  no thread-hop.
//

import CoreLocation
import Foundation
import MapKit
import os.log

@MainActor
final class ActiveNavLoop {
    private let log = Logger(subsystem: "cz.kolaczek.tripperdash", category: "ActiveNavLoop")

    private weak var bikeLink: BikeLink?
    private weak var navigator: ActiveNavigator?
    private weak var mapSource: MapViewSource?
    /// Live GPS source for the speed-camera announcer: it needs the rider's
    /// coordinate AND course-over-ground each tick to reject cameras that
    /// sit behind the rider (already passed). The navigator only retains the
    /// coordinate, not the heading, so the loop reads the fix directly.
    private weak var location: LocationService?
    private let settings: DashNavSettings

    /// Tracks the previous tick's "next waypoint" label presence so the
    /// diagnostic only logs on a nil↔non-nil transition (feat/nav-polish
    /// investigation into the label vanishing mid-leg). `nil` = no tick yet.
    private var lastRoadNameWasNil: Bool?

    /// Optional spoken-guidance sink. Nil when the app was built/wired
    /// without voice; otherwise AppStatus injects the shared instance.
    /// Prompts only actually speak when `settings.voiceEnabled` is on —
    /// the loop re-checks that flag each tick so toggling voice mid-ride
    /// takes effect immediately.
    private weak var voice: VoiceNavigator?

    /// Optional demo-mode sink. Nil in normal (real-dash) operation; when the
    /// link is faked (`BikeLink.isDemo`), AppStatus injects the shared
    /// `DemoDashModel` so each tick also publishes a native-bubble snapshot
    /// (maneuver + ETA + distance-to-next) for the on-screen dash preview. This
    /// mirrors the values that would otherwise ride the K1G TLV bytes to the
    /// real dash firmware, which the video frame does NOT contain.
    private let demo: DemoDashModel?

    /// Optional Live Activity sink. When present (real ride AND the user hasn't
    /// disabled Live Activities), each tick pushes the same maneuver + distance
    /// + ETA snapshot that feeds the dash bubble to the Lock Screen / Dynamic
    /// Island. The controller throttles internally, so the raw 1 Hz feed here is
    /// fine. Lifecycle (start/end) is owned by AppStatus, not this loop.
    private let liveActivity: LiveActivityController?

    /// Pure "when to speak" decision state (per-maneuver fired tiers). Reset
    /// on stop() and whenever the upcoming maneuver identity changes.
    private var promptScheduler = VoicePromptScheduler()

    /// Last reroute state we spoke a "recalculating" prompt for, so we say
    /// it once per reroute episode, not every tick while it's in flight.
    private var spokeReroutingForEpisode = false

    /// Pure "when to warn about a speed camera" decision state. Fires the
    /// spoken camera callout ONCE per camera as the rider closes in on it
    /// from ahead. Reset on stop() and on reroute, same discipline as the
    /// maneuver prompt scheduler.
    private var cameraAnnouncer = SpeedCameraAnnouncer()

    /// Speed cameras loaded for the current route, in the primitive form the
    /// announcer consumes. Pushed by AppStatus via `setSpeedCameras(_:)`
    /// whenever the camera prefetch completes or the toggle flips. Held as a
    /// plain value so the announcer stays CoreLocation-free and the tick is a
    /// cheap array read.
    private var speedCameraTargets: [SpeedCameraAnnouncer.Target] = []

    private var task: Task<Void, Never>?

    init(
        bikeLink: BikeLink,
        navigator: ActiveNavigator,
        mapSource: MapViewSource,
        settings: DashNavSettings,
        location: LocationService? = nil,
        voice: VoiceNavigator? = nil,
        demo: DemoDashModel? = nil,
        liveActivity: LiveActivityController? = nil
    ) {
        self.bikeLink = bikeLink
        self.navigator = navigator
        self.mapSource = mapSource
        self.settings = settings
        self.location = location
        self.voice = voice
        self.demo = demo
        self.liveActivity = liveActivity
    }

    /// Start the 1 Hz pump. Idempotent — calling start twice without a
    /// stop in between is a no-op.
    func start() {
        guard task == nil else { return }
        log.info("ActiveNavLoop start")
        task = Task { [weak self] in
            // First tick fires immediately so the dash sees nav data
            // before the user has a chance to notice the lag.
            await self?.tick()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
    }

    /// Cancel the pump and clear the overlay state on the map source.
    func stop() {
        log.info("ActiveNavLoop stop")
        task?.cancel()
        task = nil
        mapSource?.setNavOverlay(nil)
        mapSource?.setRideProgress(nil)
        // Demo mode: clear the on-screen native-bubble snapshot so the preview
        // stops showing a stale maneuver after the ride ends.
        demo?.bubble = nil
        // Silence any tier prompt in flight and reset the "when to speak"
        // state so the next ride starts clean. NOTE: this fires on EVERY
        // teardown including final arrival — the arrival prompt is spoken
        // from AppStatus.onArrived AFTER stopStreaming has already run, so
        // it is not clipped by this stop (a fresh utterance re-arms audio).
        promptScheduler.reset()
        spokeReroutingForEpisode = false
        cameraAnnouncer.reset()
    }

    // MARK: - Speed cameras

    /// Update the set of speed cameras the announcer considers each tick.
    /// Called by AppStatus when the camera prefetch completes, when the
    /// route changes (reroute / leg advance), or when the toggle flips.
    /// Passing an empty array (toggle off) silences camera callouts. A fresh
    /// camera set also re-arms the announcer so a camera that was already
    /// fired against the OLD list can warn again if it reappears — matches
    /// the "new route → new warnings" expectation on a reroute.
    func setSpeedCameras(_ cameras: [SpeedCamera]) {
        speedCameraTargets = cameras.map {
            SpeedCameraAnnouncer.Target(
                id: $0.id,
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude
            )
        }
        cameraAnnouncer.reset()
    }

    private func tick() async {
        guard let bikeLink = bikeLink,
              let nav = navigator
        else { return }

        // Free-ride / no-route heartbeat: while streaming WITHOUT active
        // navigation (AppStatus.startFreeRide), there is no maneuver to
        // show. The dash keeps its projection latch open purely from the
        // RTP streamer's per-frame `sendProjectionFrame`, so the map keeps
        // flowing — we just must NOT push an active-nav bubble packet
        // (that would draw a bogus "straight ahead, 0 m" turn card on the
        // dash) and must clear any stale video overlay so the composited
        // frame is a clean map. Speed-limit config is still refreshed so
        // the limit sign / camera pills keep tracking the rider's settings.
        guard nav.isNavigating else {
            mapSource?.setNavOverlay(nil)
            mapSource?.setRideProgress(nil)   // free-ride / arrived → no bar
            // Demo: no maneuver while free-riding / arrived → clear the
            // on-screen native bubble so the preview shows a clean map.
            demo?.bubble = nil
            // Not navigating (free-ride / arrived) → drop any speak state so
            // a later route start doesn't inherit stale fired tiers.
            promptScheduler.reset()
            spokeReroutingForEpisode = false
            cameraAnnouncer.reset()
            mapSource?.setSpeedLimitConfig(
                mode: settings.speedLimitDisplay.rawValue,
                toleranceKmh: settings.speedLimitOverToleranceKmh,
                imperial: settings.units == .imperial
            )
            return
        }

        // Snapshot — keep this synchronous so the values are consistent
        // across the wire packet and the overlay.
        //
        // `stepBeforeNext` (arriving) provides the maneuver text + incoming
        // leg; the maneuver the rider actually sees comes from the
        // navigator's DERIVED model (`upcomingManeuver` / `lookaheadManeuver`),
        // which resolves Apple's end-of-polyline text convention in one
        // place so the bubble text can't drift a maneuver ahead of the arrow.
        let arrivingStep: MKRoute.Step? = nav.stepBeforeNext   // text + incoming leg
        let distNext: Double = nav.distanceToNextStep
        let distTotal: Double = nav.remainingDistance
        let etaSec: TimeInterval = nav.etaSeconds
        // F2c: secondary snapshot. Always read, decision-to-emit
        // happens below.
        let distSecond: Double = nav.distanceToSecondNextStep
        let isRerouting: Bool = nav.isRerouting

        // The upcoming maneuver (text-family + geometry-direction) resolved
        // by the navigator. While a reroute is in flight the upcoming step
        // belongs to the STALE route (we're off it, waiting for
        // MKDirections), so showing its arrow would point the rider the
        // wrong way — override with the dash's spinning-compass
        // "recalculating" icon (0x1C) until the new route lands. Falls back
        // to `.straight` only in the brief pre-first-fix transient.
        let kind: ManeuverKind = {
            if isRerouting { return .recalculating }
            return nav.upcomingManeuver ?? .straight
        }()

        // Pre-compute wire values.
        //
        // Bucket the PRIMARY maneuver distance first (nearest 1/25/100 m
        // by proximity — see `bucketedManeuverDistance`) so the bubble's
        // "in N m" line stops twitching every GPS tick. The unit byte and
        // wire value are both derived from the BUCKETED meters so the
        // metric m↔km crossover stays consistent. The total-distance-to-
        // destination is intentionally NOT bucketed — it ticks down slowly
        // and a rounded value there would look wrong on a long route.
        let primaryBucketed = settings.bucketedManeuverDistance(meters: distNext)
        let primaryUnit = settings.primaryUnitWireByte(forMeters: primaryBucketed)
        let totalUnit = settings.totalDistanceUnitWireByte(forMeters: distTotal)
        let primaryDist = settings.distanceWireValue(meters: primaryBucketed, unitByte: primaryUnit)
        let totalDist = settings.distanceWireValue(meters: distTotal, unitByte: totalUnit)

        // F2c: secondary wire values. Only attach the chevron when:
        //   1. The feature is enabled in settings (default: yes).
        //   2. There IS a maneuver after the upcoming one (look-ahead
        //      exists — `nav.lookaheadManeuver != nil`; nil on the last leg).
        //   3. The primary maneuver is close enough that a look-ahead is
        //      actually useful — far enough out, the chevron is just noise.
        // Distance/unit follow the same magnitude-based logic as the
        // primary block so units stay consistent across both chips.
        let lookahead: ManeuverKind? = nav.lookaheadManeuver
        let emitSecondary = settings.lookaheadEnabled
            && !isRerouting   // stale route during reroute → no look-ahead
            && lookahead != nil
            && distNext <= settings.lookaheadThresholdMeters
        let secondaryManeuverByte: UInt8?
        let secondaryDistanceMeters: UInt16?
        let secondaryUnitByte: UInt8?
        if emitSecondary, let kind2 = lookahead {
            // `distanceToSecondNextStep` is already the rider→secondary-node
            // distance (distance-to-primary + the departing leg's length),
            // resolved in the navigator. Bucket it the same way as the
            // primary so the look-ahead chip's "in N m" doesn't twitch.
            let secondBucketed = settings.bucketedManeuverDistance(meters: distSecond)
            let unit2 = settings.primaryUnitWireByte(forMeters: secondBucketed)
            secondaryManeuverByte = kind2.wireByte
            secondaryDistanceMeters = settings.distanceWireValue(meters: secondBucketed, unitByte: unit2)
            secondaryUnitByte = unit2
        } else {
            secondaryManeuverByte = nil
            secondaryDistanceMeters = nil
            secondaryUnitByte = nil
        }

        // Mirror the OEM Tripper app's active-nav packet. The only
        // real-phone capture we have authority for (`_NAV_FULL` in
        // better-dash) sends the ETA (05 08), the total distance (05 09)
        // AND the remaining-time (05 0B) TLVs together in EVERY packet —
        // it does NOT omit one of them to pick the dash's bottom row.
        //
        // The previous code gated ETA vs remaining-time on a `bottomLine`
        // preference (an XOR), which had two field-confirmed bugs (Martin,
        // 6/2026):
        //   * choosing "distance remaining" dropped ETA and sent a
        //     remaining-TIME duration instead of letting the dash show the
        //     km-to-destination total — "switch to km doesn't work";
        //   * it diverged from the OEM capture, the one wire layout we know
        //     the dash accepts.
        //
        // Always emit ETA + remaining-time together whenever we have a
        // positive estimate (total distance is already sent unconditionally
        // downstream). The dash then renders its standard bubble exactly as
        // it does for the OEM app. Selecting WHICH field occupies the bottom
        // row (ETA vs km) is a dash-side concern we cannot drive by omitting
        // TLVs — the likely lever is the still-undecoded `05 0C` "extra
        // counter" field (see the skill's open-questions list); do NOT guess
        // it blind against the real dash.
        // The dash gets ONLY the FINAL-destination ETA, never the
        // per-leg one — `etaSec`/`nav.etaSeconds` is scoped to the
        // CURRENT LEG (see ActiveNavigator), which on a multi-stop plan
        // would make the bike's ETA field jump backward at every
        // intermediate waypoint. The phone HUD shows BOTH (etaCard's
        // per-leg ETA + the final-ETA pill); the dash bubble has no room
        // for two numbers, so it only ever shows the whole-trip arrival.
        // (Martin, 6/2026.) `etaSec` itself is untouched and still feeds
        // the bike ETA bubble below alongside the other leg-scoped fields.
        let finalEtaSec: TimeInterval = nav.finalDestinationEtaSeconds
        let etaDate: Date? = finalEtaSec > 0 ? Date(timeIntervalSinceNow: finalEtaSec) : nil
        let remainingSecs: TimeInterval? = finalEtaSec > 0 ? finalEtaSec : nil

        // Multi-stop "next waypoint" label (Martin, 7/2026 field request).
        // Repurposes the roadName TLV (`05 01`) — MKRoute.Step doesn't
        // expose a real road name (Apple bakes it into verb-heavy
        // `instructions`), so this field sits unused/nil on a classic
        // single-destination ride, same as always. `docs/maneuver-glyphs/
        // README.md` confirms this exact TLV is what rendered the burned
        // "SCAN 0xNN" label at the BOTTOM of the active-nav bubble during
        // the glyph-capture sessions — the same spot Martin's screenshot
        // shows — so it's the natural home for "how long to the next stop"
        // on a multi-stop plan.
        //
        // `remainingWaypoints > 1` means at least one MORE leg follows the
        // one ending at `nav.destination` — i.e. `destination` is an
        // INTERMEDIATE stop, not the final destination. On the last leg
        // (remainingWaypoints == 1) or a single-destination route
        // (remainingWaypoints == 0) this stays nil: showing "next
        // waypoint" there would just repeat the final-ETA the dash's own
        // ETA/remaining-time fields already render.
        //
        // `nav.destination` / `etaSec` (== `nav.etaSeconds`) are already
        // scoped to the CURRENT LEG (see ActiveNavigator's F6 doc-comment
        // and the k1g-active-nav-tlv-chain skill reference), so this is
        // exactly "time to the next waypoint", never the whole-trip ETA
        // the dash gets separately via `finalDestinationEtaSeconds`.
        //
        // NOTE: exact wording/length is a first guess, not field-verified.
        // The best hardware evidence for how much text the field renders
        // is better-dash's real capture (`_NAV_FULL`, road "Taille de Mas
        // du Gr" — 19 characters) — this template can run a few
        // characters longer than that for a long waypoint name, but the
        // 60-byte wire cap in `K1GPacket.tlvRoadName` is the only actual
        // safety net today. `nextWaypointLabel` puts the TIME first for
        // exactly this reason (Martin, 7/2026): if the real dash clips
        // narrower than our budget guess, only the waypoint NAME's tail
        // gets cut — the ETA a rider actually glances at can never be
        // pushed off-screen by a long name.
        let roadName: String? = {
            // Suppress the multi-stop "next waypoint" label for track routes:
            // their via-points are pass-through shape, not stops, so the dash
            // reads as a single start→finish leg (matches the phone HUD).
            guard nav.plan?.isTrack != true,
                  let nextName = nav.destination?.name,
                  etaSec > 0
            else { return nil }
            // Show the label whenever there IS a named target ahead:
            //   • remainingWaypoints > 1 → an intermediate stop ("… to Kokořín")
            //   • remainingWaypoints == 1 → the FINAL destination on the last
            //     leg. Previously suppressed (the dash's own ETA field already
            //     shows time-to-arrival), but the rider wanted the "N min to
            //     <place>" text to persist all the way to the goal, not vanish
            //     after the last via-point (field request, 8/2026). On a
            //     single-destination ride (remainingWaypoints == 0) the label
            //     stays suppressed — no via-points, the ETA field is enough.
            guard nav.remainingWaypoints >= 1 else { return nil }
            return Self.nextWaypointLabel(name: nextName, etaSeconds: etaSec)
        }()

        // DIAGNOSTIC (feat/nav-polish): the "next waypoint" label vanished
        // mid-leg with ~30 min still to the stop (field report, Praha→Kokořín
        // →Sítná→Zvoleněves, 8/2026) — NOT at a leg boundary. Log every
        // transition of the label's presence with all four gating inputs so
        // the next ride pinpoints which one dropped (isTrack flip? waypoint
        // count? nil destination name? etaSec→0?). Cheap: fires only on change.
        if (roadName == nil) != (lastRoadNameWasNil ?? false) || lastRoadNameWasNil == nil {
            log.info("nextWaypointLabel \(roadName == nil ? "CLEARED" : "set", privacy: .public) — isTrack=\(nav.plan?.isTrack == true, privacy: .public) remainingWaypoints=\(nav.remainingWaypoints, privacy: .public) destName=\(nav.destination?.name ?? "nil", privacy: .public) etaSec=\(Int(etaSec), privacy: .public)")
            lastRoadNameWasNil = (roadName == nil)
        }

        // 1. Push to wire.
        await bikeLink.sendActiveNav(
            primaryManeuver: kind.wireByte,
            primaryDistanceMeters: primaryDist,
            primaryUnit: primaryUnit,
            secondaryManeuver: secondaryManeuverByte,
            secondaryDistanceMeters: secondaryDistanceMeters,
            secondaryUnit: secondaryUnitByte,
            totalDistanceMeters: totalDist,
            totalDistanceUnit: totalUnit,
            useCommaDecimal: settings.useCommaDecimal,
            decimalFmtOn: true,  // we DO want decimal formatting in the bubble
            roadName: roadName,
            eta: etaDate,
            is24Hour: settings.is24Hour,
            remainingSeconds: remainingSecs
        )

        // 2. Push to video compositor.
        let overlay = MapViewSource.NavOverlayState(
            kind: kind,
            distanceMeters: distNext,
            roadName: roadName,
            unitsImperial: settings.units == .imperial
        )
        mapSource?.setNavOverlay(overlay)

        // 2-demo. Push the SAME semantic values to the on-screen dash preview's
        //     native-bubble snapshot. On real hardware these ride the K1G TLV
        //     bytes to the dash firmware (which draws the glyph-in-a-circle +
        //     ETA itself); the video frame does NOT contain them, so demo mode
        //     reproduces them here from the exact values we'd have sent. No-op
        //     (nil sink) in normal operation.
        demo?.bubble = DemoNavBubble(
            maneuver: kind,
            etaDate: etaDate,
            distanceToNextMeters: distNext,
            roadName: roadName,
            imperial: settings.units == .imperial,
            is24Hour: settings.is24Hour
        )

        // 2-live. Push the SAME snapshot to the Live Activity (Lock Screen +
        //     Dynamic Island). No-op (nil sink) unless this is a real ride with
        //     Live Activities enabled. The controller throttles internally, so
        //     the raw 1 Hz feed is fine — it only forwards changes a rider would
        //     notice (glyph, distance bucket, ETA minute, ≥1% progress).
        liveActivity?.update(
            symbol: kind.sfSymbol,
            distanceMeters: distNext,
            etaDate: etaDate,
            maneuverText: roadName,
            remainingMeters: distTotal,
            progress: nav.rideProgressFraction,
            isRerouting: isRerouting,
            imperial: settings.units == .imperial,
            is24Hour: settings.is24Hour
        )

        // 2a-pre. Travelled breadcrumb → grey "already ridden" line under the
        //     blue route. Pushed every tick (cheap array handoff); the
        //     renderer paints it before the active route so the road ahead
        //     stays blue even on an out-and-back over the same segment.
        mapSource?.setTraveled(nav.traveledCoordinates)

        // 2a. Ride progress bar (feat/route-progress-bar). Push the trip
        //     fraction only when the rider has opted in; when off, clear it
        //     so the bar disappears the same tick the toggle flips. The
        //     fraction is a pure read off the navigator (breadcrumb vs.
        //     planned total) — no MapKit work here.
        if settings.progressBarEnabled {
            // Locate a known weather hazard on the bar. `distanceAhead` is
            // how far along the route ahead of the rider the hazard sits; the
            // rider is at `rideProgressFraction` of `plannedTotalDistance`,
            // so the hazard's trip fraction is current + ahead/total. Only
            // when we have a positive planned total AND an ahead-distance
            // (a hazard AT the rider's position has distanceAhead == nil and
            // isn't a "somewhere on the route" marker).
            var hazardFraction: Double? = nil
            var hazardIsWarning = false
            var hazardStartFraction: Double? = nil
            var hazardEndFraction: Double? = nil
            if let alert = mapSource?.weatherAlert,
               let ahead = alert.distanceAhead,
               nav.plannedTotalDistance > 0 {
                let base = nav.rideProgressFraction
                let total = nav.plannedTotalDistance
                let hf = base + ahead / total
                hazardFraction = max(0, min(1, hf))
                hazardIsWarning = alert.severity == .warning
                // A contiguous hazard stretch → start/end fractions so the
                // bar paints the whole band, not just the near point.
                if let s = alert.spanStartMeters, let e = alert.spanEndMeters, e > s {
                    hazardStartFraction = max(0, min(1, base + s / total))
                    hazardEndFraction = max(0, min(1, base + e / total))
                }
            }
            mapSource?.setRideProgress(
                MapViewSource.RideProgress(
                    fraction: nav.rideProgressFraction,
                    waypointFractions: nav.plannedWaypointFractions,
                    hazardFraction: hazardFraction,
                    hazardStartFraction: hazardStartFraction,
                    hazardEndFraction: hazardEndFraction,
                    hazardIsWarning: hazardIsWarning
                )
            )
        } else {
            mapSource?.setRideProgress(nil)
        }

        // 2b. Spoken guidance (feat/voice-nav). Re-check the enable flag
        //     every tick so toggling voice mid-ride takes effect at once.
        //     `voice` is a shared @MainActor sink; the phrase + "when to
        //     speak" decisions are pure (VoicePhrase / VoicePromptScheduler)
        //     and unit-tested off-device.
        emitVoice(kind: kind, distNext: distNext, isRerouting: isRerouting,
                  arrivingStep: arrivingStep)

        // 2b-cam. Spoken speed-camera proximity warning
        //     (feat/speed-camera-voice-alert). The camera phrase existed but
        //     nothing ever spoke it; this fires it ONCE per camera as the
        //     rider closes in on one that's ahead. Suppressed during a
        //     reroute (stale route → don't chase cameras off the old line).
        if !isRerouting {
            emitCameraVoice()
        }

        // Keep the speed-limit sign's policy in sync with settings every
        // tick — a few cheap value writes, so flipping the display mode,
        // the over-limit tolerance, or km/h ⇄ mph mid-ride re-evaluates the
        // sign on the next frame without waiting for a route re-prefetch.
        // `imperial` here also re-labels the speed-camera pills, which read
        // the same `speedLimitImperial` flag (shared `displayLimit`).
        mapSource?.setSpeedLimitConfig(
            mode: settings.speedLimitDisplay.rawValue,
            toleranceKmh: settings.speedLimitOverToleranceKmh,
            imperial: settings.units == .imperial
        )

        // 3. (Removed) the per-maneuver file-based diagnostic writer.
    }

    // MARK: - Spoken guidance

    /// Decide + fire spoken prompts for this tick. Pure decision logic lives
    /// in `VoicePromptScheduler` (when) and `VoicePhrase` (what); this method
    /// just wires them to the navigator state and the `VoiceNavigator` sink.
    ///
    /// Priority order on the wire:
    ///   - reroute "recalculating" → `.critical` (once per reroute episode)
    ///   - maneuver tier prompts   → `.maneuver`
    /// Arrival is spoken separately off `ActiveNavigator.onArrived` (wired in
    /// AppStatus), not here, because by the time `isNavigating` flips false
    /// this loop has already stopped.
    private func emitVoice(kind: ManeuverKind,
                           distNext: Double,
                           isRerouting: Bool,
                           arrivingStep: MKRoute.Step?) {
        guard let voice, settings.voiceEnabled else { return }
        let lang = settings.voiceLanguage

        // Reroute: announce once when an episode begins; re-arm when it ends.
        if isRerouting {
            if !spokeReroutingForEpisode {
                spokeReroutingForEpisode = true
                voice.speak(VoicePhrase.rerouting(lang),
                            language: lang.rawValue, priority: .critical)
            }
            // While rerouting the upcoming maneuver belongs to the stale
            // route — don't voice tier prompts for it.
            return
        }
        spokeReroutingForEpisode = false

        // Don't voice a bogus arrival/straight heartbeat far out.
        if case .arrive = kind { return }
        if case .arriveLeft = kind { return }
        if case .arriveRight = kind { return }

        // Stable identity for the current maneuver so each tier fires once.
        let token = Self.maneuverToken(arrivingStep)
        guard let tier = promptScheduler.onTick(token: token, distanceMeters: distNext) else {
            return
        }
        guard let phrase = VoicePhrase.maneuver(kind, tier: tier, language: lang) else {
            return
        }
        voice.speak(phrase, language: lang.rawValue, priority: .maneuver)
    }

    // MARK: - Speed-camera voice

    /// Decide + fire the spoken speed-camera warning for this tick. Pure
    /// decision logic lives in `SpeedCameraAnnouncer` (when/which camera);
    /// this method wires it to the live GPS fix and the `VoiceNavigator`.
    ///
    /// Gated on THREE settings: voice output on, the camera map layer on
    /// (no layer → no cameras loaded), and the dedicated camera-voice
    /// toggle. Spoken at `.maneuver` priority — a safety callout worth
    /// hearing, but it must not cut through a `.critical` reroute/arrival
    /// sentence mid-word.
    private func emitCameraVoice() {
        guard let voice,
              settings.voiceEnabled,
              settings.speedCamerasEnabled,
              settings.voiceSpeedCameraEnabled,
              !speedCameraTargets.isEmpty,
              let fix = location?.lastFix
        else { return }

        guard let cam = cameraAnnouncer.onTick(
            riderLat: fix.coordinate.latitude,
            riderLon: fix.coordinate.longitude,
            headingDegrees: fix.course,
            cameras: speedCameraTargets
        ) else { return }
        _ = cam   // the phrase is camera-agnostic; the target only drives timing

        let lang = settings.voiceLanguage
        voice.speak(VoicePhrase.speedCamera(lang),
                    language: lang.rawValue, priority: .maneuver)
    }

    /// Stable per-maneuver identity token from the arriving step's polyline.
    /// Uses the endpoint coordinate (the maneuver node) quantised to ~1 m so
    /// GPS-driven polyline re-fetches don't spuriously reset the fired-tier
    /// set. Falls back to a sentinel when no step is known yet.
    private static func maneuverToken(_ step: MKRoute.Step?) -> Int {
        guard let pl = step?.polyline, pl.pointCount > 0 else { return -1 }
        var last = CLLocationCoordinate2D()
        pl.getCoordinates(&last, range: NSRange(location: pl.pointCount - 1, length: 1))
        let latq = Int((last.latitude * 1e5).rounded())
        let lonq = Int((last.longitude * 1e5).rounded())
        var hasher = Hasher()
        hasher.combine(latq)
        hasher.combine(lonq)
        return hasher.finalize()
    }

    /// "<time> to <name>" for the multi-stop roadName-TLV label — TIME
    /// FIRST, name last (Martin, 7/2026: a long waypoint name must never
    /// push the ETA out of view). Clips the NAME (never the time — the
    /// countdown is the actionable part a rider glances at) to fit a
    /// conservative total character budget. Because the time is always
    /// emitted whole and first, an overlong name can only ever eat into
    /// its OWN tail — the ETA's position and content are structurally
    /// unaffected by name length, independent of whether our character
    /// budget guess matches the real dash's render width. Time format
    /// mirrors `NavigationHUD.timeRemaining` ("1h 23m" / "15 min") so the
    /// phone and dash never show the same leg's ETA in different shapes.
    ///
    /// Clipping is by `Character` count (grapheme clusters), not UTF-8
    /// bytes — safe here because the budget (28) times the worst case for
    /// a Czech name (diacritics are 2 bytes in UTF-8) is still well inside
    /// `K1GPacket.tlvRoadName`'s 60-byte wire cap, so this call site never
    /// exercises that function's byte-prefix (which can otherwise split a
    /// multi-byte character at the boundary).
    ///
    /// `nonisolated` — pure function of its arguments, no navigator/actor
    /// state touched. Mirrors the `RideStatsFormatting` / `MapViewSource.
    /// formatAheadDistance` convention so `RideStatsFormattingTests`-style
    /// unit tests can call it synchronously despite `ActiveNavLoop` being
    /// `@MainActor`. The character budget is a local constant (not a
    /// class-level `static let`) specifically so this function has zero
    /// dependency on the enclosing `@MainActor` type's isolation rules.
    nonisolated static func nextWaypointLabel(name: String, etaSeconds: TimeInterval) -> String {
        // Total characters targeted for the WHOLE label. Chosen
        // conservatively: the only real-hardware evidence for how much of
        // the roadName field the dash actually RENDERS (as opposed to
        // merely accepts on the wire) is better-dash's `_NAV_FULL`
        // capture, a 19-character road name ("Taille de Mas du Gr") that
        // already reads like it was trimmed rather than naturally short.
        // 28 gives the waypoint name a bit more room since we control
        // the whole template (unlike a real road name), but needs
        // on-bike confirmation — see the k1g-active-nav-tlv-chain skill
        // reference's open-questions list. Thanks to the time-first
        // ordering below, underestimating this only costs name
        // legibility — it can never cost the ETA.
        let dashLabelCharBudget = 28
        let total = Int(max(0, etaSeconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let timePart = h > 0 ? "\(h)h \(m)m" : "\(m) min"
        let joiner = " to "
        let nameBudget = max(3, dashLabelCharBudget - timePart.count - joiner.count)
        let clippedName = name.count > nameBudget
            ? String(name.prefix(nameBudget - 1)) + "…"
            : name
        return timePart + joiner + clippedName
    }
}
