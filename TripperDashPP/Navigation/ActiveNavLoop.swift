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
        //
        // `nextStep` (departing) / `stepBeforeNext` (arriving) are kept for
        // the geometry-replay diagnostics in the log; the maneuver the
        // rider actually sees comes from the navigator's DERIVED model
        // (`upcomingManeuver` / `upcomingInstructions` / `lookaheadManeuver`),
        // which resolves Apple's end-of-polyline text convention in one
        // place so the bubble text can't drift a maneuver ahead of the arrow.
        let arrivingStep: MKRoute.Step? = nav.stepBeforeNext   // text + incoming leg
        let departingStep: MKRoute.Step? = nav.nextStep        // outgoing leg
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
        let upcomingInstructions: String? = nav.upcomingInstructions

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
        // The dash gets ONLY the FINAL-destination ETA, never the
        // per-leg one — `etaSec`/`nav.etaSeconds` is scoped to the
        // CURRENT LEG (see ActiveNavigator), which on a multi-stop plan
        // would make the bike's ETA field jump backward at every
        // intermediate waypoint. The phone HUD shows BOTH (etaCard's
        // per-leg ETA + the final-ETA pill); the dash bubble has no room
        // for two numbers, so it only ever shows the whole-trip arrival.
        // (Martin, 6/2026.) `etaSec` itself is untouched and still feeds
        // the ManeuverLog line below, so the debug trail keeps recording
        // the per-leg estimate alongside the other leg-scoped fields.
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
        // scoped to the CURRENT LEG (see ActiveNavigator's F5 doc-comment
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
            guard nav.remainingWaypoints > 1,
                  let nextName = nav.destination?.name,
                  etaSec > 0
            else { return nil }
            return Self.nextWaypointLabel(name: nextName, etaSeconds: etaSec)
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

        // 3. Internal file-based debug log of this nav tick (GPS + glyph +
        //    distances + reroute + active-route identity). Non-blocking:
        //    `record` only snapshots these values and hands them to its own
        //    serial queue for the file write. See `ManeuverLog`. Internal /
        //    local-only debug trail — never transmitted.
        ManeuverLog.shared.record(
            coordinate: nav.currentCoordinate,
            maneuver: kind,
            wireByte: kind.wireByte,
            // Log the CORRECTED upcoming text (arriving step's
            // instructions), so the recorded text matches the glyph and a
            // replay over this log is a faithful regression fixture rather
            // than re-capturing the old maneuver-ahead-of-arrow drift.
            instructions: upcomingInstructions,
            distanceToNextStep: distNext,
            remainingDistance: distTotal,
            etaSeconds: etaSec,
            isRerouting: isRerouting,
            destination: nav.destination?.name,
            routeStepCount: nav.activeRoute?.steps.count ?? 0,
            routeDistanceMeters: nav.activeRoute?.distance ?? 0,
            secondaryWireByte: secondaryManeuverByte,
            secondaryDistanceMeters: emitSecondary ? distSecond : nil,
            // Polyline diagnostics: only near the maneuver (≤150 m) so the
            // log doesn't bloat. Lets a replay recompute ManeuverGeometry's
            // exact angle. `prevPolyTail` is the ARRIVING leg (ends at the
            // node, incoming bearing); `nextPolyHead` is the DEPARTING leg
            // (leaves the node, outgoing bearing).
            prevPolyTail: distNext <= 150 ? Self.polyTail(arrivingStep?.polyline) : nil,
            nextPolyHead: distNext <= 150 ? Self.polyHead(departingStep?.polyline) : nil
        )
    }

    /// Vertices spanning ~25 m walking back from the polyline END (the
    /// maneuver node), [lat,lon] rounded to 6 dp (~0.1 m). Mirrors the
    /// incoming-bearing anchor in `ManeuverGeometry`.
    private static func polyTail(_ pl: MKPolyline?) -> [[Double]]? {
        coords(pl).map { Array($0.suffix(8)) }
    }

    /// Vertices spanning ~25 m forward from the polyline START. Mirrors the
    /// outgoing-bearing anchor.
    private static func polyHead(_ pl: MKPolyline?) -> [[Double]]? {
        coords(pl).map { Array($0.prefix(8)) }
    }

    private static func coords(_ pl: MKPolyline?) -> [[Double]]? {
        guard let pl, pl.pointCount > 0 else { return nil }
        var c = [CLLocationCoordinate2D](repeating: .init(), count: pl.pointCount)
        pl.getCoordinates(&c, range: NSRange(location: 0, length: pl.pointCount))
        return c.map { [Double(round($0.latitude * 1e6) / 1e6),
                        Double(round($0.longitude * 1e6) / 1e6)] }
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
