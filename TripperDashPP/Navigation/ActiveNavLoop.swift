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

import Foundation
import MapKit
import os.log

@MainActor
final class ActiveNavLoop {
    private let log = Logger(subsystem: "cz.kolaczek.tripperdash", category: "ActiveNavLoop")

    private weak var bikeLink: BikeLink?
    private weak var navigator: ActiveNavigator?
    private weak var mapSource: MapViewSource?
    private let settings: DashNavSettings

    private var task: Task<Void, Never>?

    init(
        bikeLink: BikeLink,
        navigator: ActiveNavigator,
        mapSource: MapViewSource,
        settings: DashNavSettings
    ) {
        self.bikeLink = bikeLink
        self.navigator = navigator
        self.mapSource = mapSource
        self.settings = settings
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
    }

    // MARK: - Tick

    private func tick() async {
        guard let bikeLink = bikeLink,
              let nav = navigator
        else { return }

        // Snapshot — keep this synchronous so the values are consistent
        // across the wire packet and the overlay.
        let step: MKRoute.Step? = nav.nextStep
        let prevStep: MKRoute.Step? = nav.stepBeforeNext
        let distNext: Double = nav.distanceToNextStep
        let distTotal: Double = nav.remainingDistance
        let etaSec: TimeInterval = nav.etaSeconds
        // F2c: secondary snapshot. Always read, decision-to-emit
        // happens below.
        let secondStep: MKRoute.Step? = nav.secondNextStep
        let distSecond: Double = nav.distanceToSecondNextStep
        let isRerouting: Bool = nav.isRerouting

        // Classify maneuver for the dash bubble (and burned-in glyph, if
        // re-enabled). Direction comes from route geometry via the
        // incoming `prevStep` leg; if there's no active step we fall back
        // to "straight" so the rider sees a benign placeholder.
        //
        // While a reroute is in flight the upcoming step belongs to the
        // STALE route (we're off it, waiting for MKDirections), so showing
        // its arrow would point the rider the wrong way. Override the glyph
        // with the dash's spinning-compass "recalculating" icon (0x1C)
        // until the new route lands and isRerouting clears.
        let kind: ManeuverKind = {
            if isRerouting { return .recalculating }
            return step.map { ManeuverKind.classify($0, previousStep: prevStep) } ?? .straight
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
        //   2. There IS a step after `nextStep` (we're not on the last leg).
        //   3. The primary maneuver is close enough that a look-ahead is
        //      actually useful — far enough out, the chevron is just noise.
        // Distance/unit follow the same magnitude-based logic as the
        // primary block so units stay consistent across both chips.
        let emitSecondary = settings.lookaheadEnabled
            && !isRerouting   // stale route during reroute → no look-ahead
            && secondStep != nil
            && distNext <= settings.lookaheadThresholdMeters
        let secondaryManeuverByte: UInt8?
        let secondaryDistanceMeters: UInt16?
        let secondaryUnitByte: UInt8?
        if emitSecondary, let s2 = secondStep {
            // The secondary maneuver's incoming leg is the PRIMARY step
            // (the rider reaches s2 right after completing `step`).
            // Bucket its distance the same way as the primary so the
            // look-ahead chip's "in N m" doesn't twitch either.
            let kind2 = ManeuverKind.classify(s2, previousStep: step)
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
        // The previous code gated ETA vs remaining-time on `bottomLine`
        // (an XOR), which had two field-confirmed bugs (Martin, 6/2026):
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
        let etaDate: Date? = etaSec > 0 ? Date(timeIntervalSinceNow: etaSec) : nil
        let remainingSecs: TimeInterval? = etaSec > 0 ? etaSec : nil

        let roadName: String? = {
            // MKRoute.Step doesn't expose the road name directly. Apple
            // bakes it into `instructions`, but that string is full of
            // verbs ("Turn right onto Wenceslas Square") so it's noisy.
            // For now: use the navigator's exposed road name if it has
            // one, otherwise omit.
            // (When we get a real road-name extractor working we'll
            // wire it through `nav.currentRoadName`.)
            return nil
        }()

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

        // 3. Internal file-based debug log of this nav tick (GPS + glyph +
        //    distances + reroute + active-route identity). Non-blocking:
        //    `record` only snapshots these values and hands them to its own
        //    serial queue for the file write. See `ManeuverLog`. Internal /
        //    local-only debug trail — never transmitted.
        ManeuverLog.shared.record(
            coordinate: nav.currentCoordinate,
            maneuver: kind,
            wireByte: kind.wireByte,
            instructions: step?.instructions,
            distanceToNextStep: distNext,
            remainingDistance: distTotal,
            etaSeconds: etaSec,
            isRerouting: isRerouting,
            destination: nav.destination?.name,
            routeStepCount: nav.activeRoute?.steps.count ?? 0,
            routeDistanceMeters: nav.activeRoute?.distance ?? 0,
            secondaryWireByte: secondaryManeuverByte,
            secondaryDistanceMeters: emitSecondary ? distSecond : nil
        )
    }
}
