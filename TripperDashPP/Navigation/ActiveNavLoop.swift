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
        let primaryUnit = settings.primaryUnitWireByte(forMeters: distNext)
        let totalUnit = settings.totalDistanceUnitWireByte(forMeters: distTotal)
        let primaryDist = settings.distanceWireValue(meters: distNext, unitByte: primaryUnit)
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
            let kind2 = ManeuverKind.classify(s2, previousStep: step)
            let unit2 = settings.primaryUnitWireByte(forMeters: distSecond)
            secondaryManeuverByte = kind2.wireByte
            secondaryDistanceMeters = settings.distanceWireValue(meters: distSecond, unitByte: unit2)
            secondaryUnitByte = unit2
        } else {
            secondaryManeuverByte = nil
            secondaryDistanceMeters = nil
            secondaryUnitByte = nil
        }

        let etaDate: Date? = settings.includeEtaTlv && etaSec > 0
            ? Date(timeIntervalSinceNow: etaSec)
            : nil
        let remainingSecs: TimeInterval? = settings.includeEtaTlv
            ? nil  // when bottom row shows ETA we omit remaining-time
            : (etaSec > 0 ? etaSec : nil)

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
    }
}
