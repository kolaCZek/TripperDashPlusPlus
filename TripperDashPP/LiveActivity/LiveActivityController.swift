//
//  LiveActivityController.swift
//  TripperDashPP
//
//  App-side wrapper around `Activity<RideActivityAttributes>`. Owns the
//  lifecycle (start on ride begin, update each nav tick, end on teardown) and
//  does all the string formatting + update throttling so the widget extension
//  stays a dumb renderer.
//
//  Injected into `ActiveNavLoop` as an optional sink (same pattern as the demo
//  bubble and the voice navigator): the loop calls `update(...)` once per tick
//  with the same values it feeds the dash bubble, and this controller decides
//  whether the change is worth pushing to the system.
//
//  THROTTLING — ActivityKit silently drops updates pushed too frequently, so a
//  raw 1 Hz feed would waste the budget and could stall the Lock Screen. We
//  keep the last-pushed snapshot and only push when a rider would actually
//  notice a difference (maneuver glyph, reroute flag, distance bucket, ETA
//  minute, secondary line, remaining distance, or ≥1% progress). 1 Hz in,
//  ≪1 Hz out.
//
//  Availability: ActivityKit is iOS 16.1+. The app targets iOS 18.6, so the
//  APIs are always present; the `areActivitiesEnabled` gate still matters
//  because the USER can switch Live Activities off in Settings.
//

import ActivityKit
import Foundation
import os.log

@MainActor
final class LiveActivityController {
    private let log = Logger(subsystem: "cz.kolaczek.tripperdash", category: "LiveActivity")

    private var activity: Activity<RideActivityAttributes>?

    /// Last state we actually pushed — the throttle reference. nil until the
    /// first update after a start.
    private var lastPushed: RideActivityAttributes.ContentState?

    // MARK: - Lifecycle

    /// Begin a ride activity. No-op if one is already live or the user turned
    /// Live Activities off in Settings.
    func start(destinationName: String?) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.info("Live Activities disabled by user — skipping start")
            return
        }
        let attributes = RideActivityAttributes(destinationName: destinationName)
        // Seed with an empty-ish state; the first tick overwrites it ~1 s later.
        let initial = RideActivityAttributes.ContentState(
            maneuverSymbol: "location.fill",
            distanceText: "—",
            maneuverText: nil,
            etaText: nil,
            remainingText: nil,
            progress: 0,
            isRerouting: false,
            destinationName: nil
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initial, staleDate: nil)
            )
            lastPushed = initial
            log.info("Live Activity started")
        } catch {
            log.error("Live Activity start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Push a new nav snapshot, subject to throttling. Values arrive raw (metres,
    /// Date) and are formatted here honouring the rider's unit/clock settings so
    /// the strings match the in-app HUD / dash bubble exactly.
    func update(
        symbol: String,
        distanceMeters: Double,
        etaDate: Date?,
        maneuverText: String?,
        remainingMeters: Double?,
        progress: Double?,
        isRerouting: Bool,
        destinationName: String?,
        imperial: Bool,
        is24Hour: Bool
    ) {
        guard let activity else { return }

        let state = RideActivityAttributes.ContentState(
            maneuverSymbol: symbol,
            distanceText: Self.distanceText(meters: distanceMeters, imperial: imperial),
            maneuverText: maneuverText,
            etaText: Self.etaText(date: etaDate, is24Hour: is24Hour),
            remainingText: Self.remainingText(meters: remainingMeters, imperial: imperial),
            progress: (progress ?? 0).clampedUnit(),
            isRerouting: isRerouting,
            destinationName: destinationName
        )

        guard Self.shouldPush(old: lastPushed, new: state, imperial: imperial) else { return }
        lastPushed = state

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// End the activity immediately (streaming stopped).
    func end() {
        guard let activity else { return }
        self.activity = nil
        lastPushed = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        log.info("Live Activity ended")
    }

    /// End activities left by a previous process (crash / force-quit): the
    /// `activity` handle died with it, so nothing would end them and the
    /// card sits frozen on the Lock Screen for up to 8 h. Call once at app
    /// launch — the list is read synchronously there, before any view can
    /// start a ride, so it only ever holds orphans.
    ///
    /// No `staleDate` on the content instead: updates are change-driven
    /// (see `shouldPush`), so a rider stopped at a red light sends none and
    /// a stale date would grey out a perfectly live card.
    static func endOrphanedActivities() {
        let orphans = Activity<RideActivityAttributes>.activities
        guard !orphans.isEmpty else { return }
        Task {
            for orphan in orphans {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Throttling

    /// Whether the new state differs enough from the last-pushed one to be worth
    /// a system update. See file header for the rationale.
    nonisolated static func shouldPush(
        old: RideActivityAttributes.ContentState?,
        new: RideActivityAttributes.ContentState,
        imperial: Bool
    ) -> Bool {
        guard let old else { return true }
        if old.maneuverSymbol != new.maneuverSymbol { return true }
        if old.isRerouting != new.isRerouting { return true }
        if old.distanceText != new.distanceText { return true }   // already bucketed
        if old.etaText != new.etaText { return true }             // minute-resolution
        if old.maneuverText != new.maneuverText { return true }
        if old.remainingText != new.remainingText { return true }
        if old.destinationName != new.destinationName { return true }   // route edit retitle
        if abs(old.progress - new.progress) >= 0.01 { return true }
        return false
    }

    // MARK: - Formatting (also used by DashPreviewPanel; km/mi via RideStatsFormatting)

    /// Distance-to-next, rounded exactly like the dash's turn card.
    nonisolated static func distanceText(meters m: Double, imperial: Bool) -> String {
        guard m >= 0 else { return "—" }
        return DashNavSettings.maneuverDistanceText(meters: m, imperial: imperial)
    }

    nonisolated static func etaText(date: Date?, is24Hour: Bool) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: is24Hour ? "en_GB" : "en_US")
        f.dateFormat = is24Hour ? "HH:mm" : "h:mm a"
        return "ETA \(f.string(from: date))"
    }

    nonisolated static func remainingText(meters: Double?, imperial: Bool) -> String? {
        guard let meters, meters >= 0 else { return nil }
        return "\(RideStatsFormatting.distance(meters, imperial: imperial)) left"
    }
}

private extension Double {
    /// Clamp to 0…1 for the progress bar.
    func clampedUnit() -> Double { Swift.max(0, Swift.min(1, self)) }
}
