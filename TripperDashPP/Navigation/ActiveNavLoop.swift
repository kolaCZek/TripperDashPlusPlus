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
        let distNext: Double = nav.distanceToNextStep
        let distTotal: Double = nav.remainingDistance
        let etaSec: TimeInterval = nav.etaSeconds

        // Classify maneuver for the burned-in glyph. If there's no
        // active step we fall back to "straight" so the rider sees a
        // benign placeholder rather than a blank.
        let kind: ManeuverKind = step.map(ManeuverKind.classify(_:)) ?? .straight

        // Pre-compute wire values.
        let primaryUnit = settings.primaryUnitWireByte(forMeters: distNext)
        let totalUnit = settings.totalDistanceUnitWireByte(forMeters: distTotal)
        let primaryDist = settings.distanceWireValue(meters: distNext, unitByte: primaryUnit)
        let totalDist = settings.distanceWireValue(meters: distTotal, unitByte: totalUnit)

        let etaDate: Date? = settings.includeEtaTlv && !settings.suppressEtaTlv && etaSec > 0
            ? Date(timeIntervalSinceNow: etaSec)
            : nil
        let remainingSecs: TimeInterval? = settings.includeEtaTlv
            ? nil  // when bottom row shows ETA we omit remaining-time
            : (etaSec > 0 ? etaSec : nil)

        // Bug 4 instrumentation: log ETA pipeline state each tick so we
        // can correlate against what the dash actually shows. Filter
        // with `log stream --predicate 'category == "ActiveNavLoop"'`.
        if settings.verbosePacketLogging || settings.suppressEtaTlv {
            log.info("nav tick: etaSec=\(etaSec, format: .fixed(precision: 0)) includeEtaTlv=\(settings.includeEtaTlv, privacy: .public) suppressEtaTlv=\(settings.suppressEtaTlv, privacy: .public) → tlvEta=\(etaDate?.description ?? "nil", privacy: .public)")
        }

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
