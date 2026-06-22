//
//  RoutingService.swift
//  TripperDashPP
//
//  Phase 7e — wrapper around MKDirections for one-shot route
//  calculation between the current location (or a user-chosen origin)
//  and a destination. Returns up to 3 alternatives.
//
//  Stateless — UI calls calculate(...) on demand and stores the
//  resulting RouteOption array itself.
//

import CoreLocation
import Foundation
import MapKit
import os

@MainActor
final class RoutingService {

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "Routing")

    /// Calculate up to 3 alternative routes from origin → destination.
    /// `origin == nil` uses .forCurrentLocation() (CoreLocation must
    /// already be authorised + a fix should be available).
    ///
    /// Retained as the single-leg convenience used by reroute and the
    /// legacy single-destination flow. Internally a one-leg call.
    func calculate(from origin: CLLocationCoordinate2D?,
                   to destination: Destination,
                   preferences: RoutePreferences) async throws -> [RouteOption] {
        let fromWp = origin.map { Waypoint(name: "Origin", coordinate: $0) }
        let toWp = Waypoint.from(destination: destination)
        return try await calculateLeg(from: fromWp, to: toWp, preferences: preferences)
    }

    /// Compute ≤3 alternatives for a single leg `from → to`. A nil
    /// `from`, or a `from` flagged `isCurrentLocation`, resolves to
    /// `.forCurrentLocation()` (used for the origin leg).
    func calculateLeg(from: Waypoint?,
                      to: Waypoint,
                      preferences: RoutePreferences) async throws -> [RouteOption] {
        let req = MKDirections.Request()
        if let from, !from.isCurrentLocation {
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        } else {
            req.source = .forCurrentLocation()
        }
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        req.transportType = .automobile
        req.requestsAlternateRoutes = true
        req.highwayPreference = preferences.avoidHighways ? .avoid : .any
        req.tollPreference = preferences.avoidTolls ? .avoid : .any

        log.info("Calculating leg to \(to.name, privacy: .public) (avoid highways=\(preferences.avoidHighways), tolls=\(preferences.avoidTolls))")
        let response = try await MKDirections(request: req).calculate()

        // MKDirections treats `.avoid` as a SOFT preference — it will
        // still hand back highway/toll routes when it thinks they're
        // best. We promised the rider a HARD filter, so drop any route
        // that violates an active constraint, using MKRoute's own
        // `hasHighways` / `hasTolls` flags (authoritative, not the
        // localized instruction text).
        let allRoutes = response.routes
        let filtered = allRoutes.filter { route in
            if preferences.avoidHighways && route.hasHighways { return false }
            if preferences.avoidTolls && route.hasTolls { return false }
            return true
        }

        // Fallback: if the constraint eliminates EVERYTHING (e.g. the
        // only way out of where the rider is genuinely uses a highway),
        // don't strand them with zero routes — keep the single best
        // original so navigation still works. The UI surfaces that the
        // filter couldn't be honoured (see RouteOption.violatesFilter).
        let chosen: [MKRoute]
        if filtered.isEmpty && !allRoutes.isEmpty {
            log.warning("All \(allRoutes.count) route(s) to \(to.name, privacy: .public) violate the active filter — keeping best original as fallback")
            chosen = [allRoutes[0]]
        } else {
            chosen = filtered
        }

        let routes = Array(chosen.prefix(3))
        log.info("Got \(allRoutes.count) leg route(s), \(routes.count) after filter (avoid highways=\(preferences.avoidHighways), tolls=\(preferences.avoidTolls))")
        return routes.enumerated().map { (idx, route) in
            RouteOption(index: idx,
                        route: route,
                        violatesHighwayFilter: preferences.avoidHighways && route.hasHighways,
                        violatesTollFilter: preferences.avoidTolls && route.hasTolls)
        }
    }

    /// Recompute only the legs flagged in `dirtyLegIndices`, mutating
    /// `plan` in place. Runs sequentially on the main actor — for the
    /// common case (a mutation dirties 1–2 legs) that's as fast as
    /// concurrent, and it sidesteps Swift 6 strict-concurrency issues
    /// with `MKRoute` (non-Sendable) crossing task boundaries. MapKit
    /// throttles concurrent `MKDirections` calls anyway, so little is
    /// lost. Selected-option indices on untouched legs are preserved by
    /// `PlannedRoute.setOptions`.
    ///
    /// Legs that DO compute are written back even if a sibling fails,
    /// so a partial network blip doesn't wipe a half-good plan; the
    /// failure is reported after all legs are attempted.
    func recompute(_ plan: PlannedRoute,
                   dirtyLegIndices: Set<Int>,
                   preferences: RoutePreferences) async throws {
        let dirty = dirtyLegIndices.filter { plan.legs.indices.contains($0) }.sorted()
        guard !dirty.isEmpty else { return }

        var failed: [Int] = []
        for i in dirty {
            let leg = plan.legs[i]
            guard let fromWp = plan.waypoint(id: leg.fromWaypointId),
                  let toWp = plan.waypoint(id: leg.toWaypointId) else {
                failed.append(i)
                continue
            }
            do {
                let opts = try await calculateLeg(from: fromWp, to: toWp, preferences: preferences)
                if opts.isEmpty {
                    failed.append(i)
                } else {
                    plan.setOptions(opts, forLegIndex: i)
                }
            } catch {
                log.error("Leg \(i) recompute failed: \(error.localizedDescription, privacy: .public)")
                failed.append(i)
            }
        }

        if !failed.isEmpty {
            throw RoutingError.legComputationFailed(legIndices: failed.sorted())
        }
    }
}

/// Errors surfaced by multi-leg recomputation.
enum RoutingError: LocalizedError {
    case legComputationFailed(legIndices: [Int])

    var errorDescription: String? {
        switch self {
        case .legComputationFailed(let idx):
            let list = idx.map { "\($0 + 1)" }.joined(separator: ", ")
            return "Couldn't calculate route segment(s) \(list). Check your connection and try again."
        }
    }
}

/// UI-facing wrapper around `MKRoute`. Adds a stable index for the
/// "Route 1/2/3" labelling and pre-computes display strings so the UI
/// layer doesn't have to redo NumberFormatter ceremony per render.
struct RouteOption: Identifiable, Equatable {
    let id: UUID = UUID()
    let index: Int
    let route: MKRoute

    /// True when this route still uses a highway despite an active
    /// "avoid highways" filter — only ever true on the fallback route
    /// kept when EVERY alternative violated the filter (so the rider
    /// isn't stranded). The UI badges it so the compromise is visible.
    var violatesHighwayFilter: Bool = false
    /// Same, for the "avoid tolls" filter.
    var violatesTollFilter: Bool = false

    /// True if this option breaks any active filter (fallback route).
    var violatesFilter: Bool { violatesHighwayFilter || violatesTollFilter }

    var label: String { "Route \(index + 1)" }

    var distanceMeters: CLLocationDistance { route.distance }
    var travelTime: TimeInterval { route.expectedTravelTime }
    var advisoryNotices: [String] { route.advisoryNotices }

    /// "62 km" / "850 m"
    var distanceDisplay: String {
        let m = distanceMeters
        if m < 1000 { return String(format: "%.0f m", m) }
        if m < 10_000 { return String(format: "%.1f km", m / 1000) }
        return String(format: "%.0f km", m / 1000)
    }

    /// "1 h 12 min" / "32 min"
    var travelTimeDisplay: String {
        let total = Int(travelTime)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }

    /// ETA as a localised time string, e.g. "15:42"
    var arrivalDisplay: String {
        let arrival = Date().addingTimeInterval(travelTime)
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: arrival)
    }

    /// "via D7" — best-effort summary built from the first highway-ish
    /// step name. MKRoute doesn't have a real `summary` property.
    var summary: String {
        // First step often says "Proceed to <road>" or "Take <road>" —
        // not always parseable. As a heuristic, look at the longest
        // step's instructions and pull out the first capitalised
        // road-like token.
        let longest = route.steps.max(by: { $0.distance < $1.distance })
        let txt = longest?.instructions ?? ""
        if let match = txt.range(of: #"\b[DRER]\d+\b|\b[IDR]/\d+\b|\b\d{1,3}\b"#, options: .regularExpression) {
            return "via \(txt[match])"
        }
        return ""
    }

    static func == (l: RouteOption, r: RouteOption) -> Bool { l.id == r.id }
}
