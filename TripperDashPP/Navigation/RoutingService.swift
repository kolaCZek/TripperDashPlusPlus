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
    /// Retained as the single-leg convenience used by AppStatus's navigator
    /// hooks (off-route reroute, periodic ETA refresh, live-traffic check).
    /// Internally a one-leg call. `alternates` / `timeout` as in
    /// `calculateLeg`.
    func calculate(from origin: CLLocationCoordinate2D?,
                   to destination: Destination,
                   preferences: RoutePreferences,
                   alternates: Bool = true,
                   timeout: TimeInterval? = nil) async throws -> [RouteOption] {
        let fromWp = origin.map { Waypoint(name: "Origin", coordinate: $0) }
        let toWp = Waypoint.from(destination: destination)
        return try await calculateLeg(from: fromWp, to: toWp, preferences: preferences,
                                      alternates: alternates, timeout: timeout)
    }

    /// Compute ≤3 alternatives for a single leg `from → to`. A nil
    /// `from`, or a `from` flagged `isCurrentLocation`, resolves to
    /// `.forCurrentLocation()` (used for the origin leg).
    ///
    /// `alternates: false` asks Apple for the best route only (for callers
    /// that only read `.first`). `timeout` caps the wait for MKDirections,
    /// which has none of its own: past it the request is cancelled and
    /// `RoutingError.timedOut` is thrown.
    func calculateLeg(from: Waypoint?,
                      to: Waypoint,
                      preferences: RoutePreferences,
                      alternates: Bool = true,
                      timeout: TimeInterval? = nil) async throws -> [RouteOption] {
        let req = MKDirections.Request()
        if let from, !from.isCurrentLocation {
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        } else {
            req.source = .forCurrentLocation()
        }
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        req.transportType = .automobile
        req.requestsAlternateRoutes = alternates
        req.highwayPreference = preferences.avoidHighways ? .avoid : .any
        req.tollPreference = preferences.avoidTolls ? .avoid : .any

        log.info("Calculating leg to \(to.name, privacy: .public) (avoid highways=\(preferences.avoidHighways), tolls=\(preferences.avoidTolls))")
        let directions = MKDirections(request: req)
        let response: MKDirections.Response
        if let timeout {
            response = try await Self.calculate(directions, timeout: timeout)
        } else {
            response = try await directions.calculate()
        }

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

    /// `directions.calculate()` raced against `timeout`: whichever lands
    /// first resumes the caller; on timeout the request is cancelled. Not a
    /// task-group race — the async `calculate()` ignores task cancellation,
    /// so a group would still wait for MapKit's reply.
    /// ponytail: a late MapKit reply after the timeout is simply dropped.
    ///
    /// MapKit runs the completion handler on the main thread (documented
    /// for `calculate(completionHandler:)`), so it handles the reply in
    /// place instead of hopping through a Task — no extra main-actor hop,
    /// and the non-Sendable response never crosses isolation. Off main it
    /// falls back to the old Task hop instead of trapping. The reply
    /// cancels the timer (`finish`), so no sleeping Task outlives a request.
    private static func calculate(_ directions: MKDirections,
                                  timeout: TimeInterval) async throws -> MKDirections.Response {
        let race = DirectionsRace()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            race.waiter = cont
            race.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled, race.waiter != nil else { return }
                race.timedOut = true
                directions.cancel()
                race.finish()
            }
            directions.calculate { response, error in
                guard Thread.isMainThread else {
                    // Not expected (documented main); hop rather than
                    // trap mid-ride if a future iOS ever changes it.
                    Task { @MainActor in race.deliver(response, error) }
                    return
                }
                MainActor.assumeIsolated { race.deliver(response, error) }
            }
        }
        if race.timedOut { throw RoutingError.timedOut(seconds: timeout) }
        if let response = race.response { return response }
        if let error = race.error { throw error }
        throw RoutingError.timedOut(seconds: timeout)
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
    ///
    /// `isStillLive` is consulted after every network round trip. Each
    /// `calculateLeg` suspends for ~1 s, and `plan.setOptions` on resume
    /// mutates an `@Observable` object the planning UI is bound to. If the
    /// rider cancelled planning during that window the plan is detached but
    /// its SwiftUI observers are mid-teardown, and the late write aborts
    /// with "Invalid Number Of Items In Section" (TestFlight, 1.0.3).
    /// Bailing out here stops the writes at the source rather than only at
    /// the caller. `nil` means "always live", so existing callers and tests
    /// keep the old behaviour.
    ///
    /// `timeout` caps each leg's request as in `calculateLeg` (a timed-out
    /// leg counts as failed). nil — the planner — waits as long as MapKit.
    func recompute(_ plan: PlannedRoute,
                   dirtyLegIndices: Set<Int>,
                   preferences: RoutePreferences,
                   timeout: TimeInterval? = nil,
                   isStillLive: (@MainActor () -> Bool)? = nil) async throws {
        let dirty = dirtyLegIndices.filter { plan.legs.indices.contains($0) }.sorted()
        guard !dirty.isEmpty else { return }
        func stillLive() -> Bool { isStillLive?() ?? true }

        var failed: [Int] = []
        for i in dirty {
            guard stillLive() else { return }
            let leg = plan.legs[i]
            guard let fromWp = plan.waypoint(id: leg.fromWaypointId),
                  let toWp = plan.waypoint(id: leg.toWaypointId) else {
                failed.append(i)
                continue
            }
            do {
                let opts = try await calculateLeg(from: fromWp, to: toWp, preferences: preferences,
                                                  timeout: timeout)
                // Re-check AFTER the await — this is the window the crash
                // lands in. Returning without throwing is deliberate: the
                // work was abandoned, not failed, so no error is surfaced
                // into a UI that no longer exists.
                guard stillLive() else { return }
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

        guard stillLive() else { return }
        if !failed.isEmpty {
            throw RoutingError.legComputationFailed(legIndices: failed.sorted())
        }
    }
}

/// Result slot for `RoutingService.calculate(_:timeout:)`: the first of
/// MapKit's reply or the timeout resumes `waiter`; the other is a no-op.
private final class DirectionsRace {
    var response: MKDirections.Response?
    var error: Error?
    var timedOut = false
    var waiter: CheckedContinuation<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    func deliver(_ response: MKDirections.Response?, _ error: Error?) {
        self.response = response
        self.error = error
        finish()
    }

    func finish() {
        waiter?.resume()
        waiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}

/// Errors surfaced by multi-leg recomputation and bounded route requests.
enum RoutingError: LocalizedError {
    case legComputationFailed(legIndices: [Int])
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .legComputationFailed(let idx):
            let list = idx.map { "\($0 + 1)" }.joined(separator: ", ")
            return "Couldn't calculate route segment(s) \(list). Check your connection and try again."
        case .timedOut(let seconds):
            return "No route from Apple within \(Int(seconds)) s. Check your connection and try again."
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
