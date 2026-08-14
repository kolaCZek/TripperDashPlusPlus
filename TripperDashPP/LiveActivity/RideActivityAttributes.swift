//
//  RideActivityAttributes.swift
//  TripperDashPP
//
//  Shared Live Activity contract (ActivityKit). Compiled into BOTH the app
//  target (which starts/updates/ends the activity) AND the widget extension
//  (which renders it). Because it is shared, this type deliberately carries
//  ONLY plain value types — strings, doubles, bools — already formatted by the
//  app using the rider's unit/clock settings. No app models (ManeuverKind,
//  MKRoute, DashNavSettings) leak across the target boundary, so the widget
//  extension stays tiny and links neither MapKit nor the navigation stack.
//
//  Phase 1: iPhone Lock Screen + Dynamic Island only. Apple Watch (a watchOS
//  companion + complication) is intentionally deferred — Live Activities only
//  mirror into the Watch Smart Stack today, not a custom Watch UI.
//

import ActivityKit
import Foundation

/// Attributes for the "ride in progress" Live Activity.
struct RideActivityAttributes: ActivityAttributes {

    /// Per-update state. Everything here is pre-formatted in the app so the
    /// widget is a dumb renderer — it never does unit math or date formatting.
    public struct ContentState: Codable, Hashable {
        /// SF Symbol name for the upcoming maneuver glyph (from
        /// `ManeuverKind.sfSymbol`), e.g. `arrow.turn.up.right`. While a reroute
        /// is in flight the app sends the recalculating spinner symbol.
        var maneuverSymbol: String

        /// Distance to the next maneuver, pre-formatted honouring the rider's
        /// units + the HUD's close-in bucketing, e.g. `300 m` / `0.4 mi`.
        var distanceText: String

        /// Optional secondary line — the multi-stop "N min to <place>" label or
        /// the next road name. nil on a classic single-destination ride.
        var maneuverText: String?

        /// Optional ETA clock string honouring 24/12-hour, e.g. `ETA 14:30`.
        var etaText: String?

        /// Optional whole-trip remaining distance, e.g. `42 km left`.
        var remainingText: String?

        /// Ride completion fraction 0…1 for the progress bar. Clamped by the app.
        var progress: Double

        /// True while MKDirections is recalculating — lets the widget show a
        /// subtle "recalculating" treatment even though the glyph already swaps.
        var isRerouting: Bool
    }

    /// Immutable for the life of the activity — the ride's destination name
    /// (shown as the activity's title). nil for a free-ride / unnamed target.
    var destinationName: String?
}
