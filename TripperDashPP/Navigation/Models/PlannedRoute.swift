//
//  PlannedRoute.swift
//  TripperDashPP
//
//  feat/route-waypoints — the multi-stop route model.
//
//  Holds an ordered list of `Waypoint`s and, derived from them, an
//  ordered list of `RouteLeg`s. Each leg owns up to 3 `MKRoute`
//  alternatives (one `MKDirections` call) plus the index of the one
//  currently selected. "Pick the route between two points" == "set a
//  leg's selectedOptionIndex" — which is exactly what an in-map tap on
//  an alternative polyline mutates.
//
//  Why a reference type: the planning UI (map + waypoint list) and the
//  recompute driver all mutate the SAME live object and observe each
//  other's changes. @Observable + @MainActor gives us that without a
//  binding tangle. All mutation happens on the main actor — legs hold
//  `MKRoute`, which is main-thread-affined.
//
//  Leg invariant once computed: legs.count == waypoints.count - 1, and
//  legs[i] runs waypoints[i] -> waypoints[i+1].
//

import CoreLocation
import Foundation
import MapKit
import Observation

/// The numbers `PlannedRoute` needs from an alternative to compute its
/// roll-up totals. `RouteOption` conforms; the seam keeps the totals
/// (and their unit tests) independent of the non-constructible
/// `MKRoute`.
protocol LegMetrics {
    var distanceMeters: CLLocationDistance { get }
    var travelTime: TimeInterval { get }
}

extension RouteOption: LegMetrics {}

/// One leg of a multi-stop route: the alternatives between two
/// adjacent waypoints, plus which one is selected.
struct RouteLeg: Identifiable {
    let id: UUID
    let fromWaypointId: UUID
    let toWaypointId: UUID
    /// ≤3 alternatives from a single MKDirections call. Empty while the
    /// leg is awaiting (re)computation.
    var options: [RouteOption]
    /// Index into `options`. Clamped on every mutation so it can never
    /// dangle past the array.
    var selectedOptionIndex: Int

    init(id: UUID = UUID(),
         fromWaypointId: UUID,
         toWaypointId: UUID,
         options: [RouteOption] = [],
         selectedOptionIndex: Int = 0) {
        self.id = id
        self.fromWaypointId = fromWaypointId
        self.toWaypointId = toWaypointId
        self.options = options
        self.selectedOptionIndex = selectedOptionIndex
    }

    /// Currently-selected alternative, or nil if the leg hasn't been
    /// computed yet.
    var selected: RouteOption? {
        guard options.indices.contains(selectedOptionIndex) else { return nil }
        return options[selectedOptionIndex]
    }

    var isComputed: Bool { !options.isEmpty }
}

@MainActor
@Observable
final class PlannedRoute {

    // MARK: - State

    private(set) var waypoints: [Waypoint]
    private(set) var legs: [RouteLeg]

    // MARK: - Init

    /// Build from an ordered list of waypoints. Legs start empty —
    /// the caller runs `RoutingService.recompute(_:dirtyLegIndices:)`
    /// with `allLegIndices` to fill them.
    init(waypoints: [Waypoint]) {
        precondition(waypoints.count >= 2, "A PlannedRoute needs at least origin + destination")
        self.waypoints = waypoints
        self.legs = Self.makeEmptyLegs(for: waypoints)
    }

    /// Convenience: the classic single-destination case (origin +
    /// destination) so the existing search/preview flow is just n=2.
    convenience init(origin: Waypoint, destination: Waypoint) {
        self.init(waypoints: [origin, destination])
    }

    private static func makeEmptyLegs(for wps: [Waypoint]) -> [RouteLeg] {
        guard wps.count >= 2 else { return [] }
        return (0..<(wps.count - 1)).map { i in
            RouteLeg(fromWaypointId: wps[i].id, toWaypointId: wps[i + 1].id)
        }
    }

    // MARK: - Derived totals (roll-ups over selected options)

    /// Total distance across every selected leg option, meters. 0 until
    /// all legs are computed.
    var totalDistanceMeters: CLLocationDistance {
        legs.reduce(0) { $0 + ($1.selected?.distanceMeters ?? 0) }
    }

    /// Total travel time across every selected leg option, seconds.
    var totalTravelTime: TimeInterval {
        legs.reduce(0) { $0 + ($1.selected?.travelTime ?? 0) }
    }

    /// True once every leg has at least one option selected — i.e. the
    /// route is fully computed and navigable.
    var isComputed: Bool {
        legs.count == waypoints.count - 1
            && !legs.isEmpty
            && legs.allSatisfy { $0.selected != nil }
    }

    /// All leg indices — pass to `recompute` for a full (re)build.
    var allLegIndices: Set<Int> { Set(legs.indices) }

    /// "1 h 12 min" across all stops.
    var totalTravelTimeDisplay: String {
        let total = Int(totalTravelTime)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }

    /// "62 km" / "850 m" across all stops.
    var totalDistanceDisplay: String {
        let m = totalDistanceMeters
        if m < 1000 { return String(format: "%.0f m", m) }
        if m < 10_000 { return String(format: "%.1f km", m / 1000) }
        return String(format: "%.0f km", m / 1000)
    }

    // MARK: - Selection (no recompute)

    /// Select alternative `optionIndex` for `legIndex`. Out-of-range
    /// indices are ignored. This is what an in-map tap on a gray
    /// alternative calls.
    func setSelectedOption(legIndex: Int, optionIndex: Int) {
        guard legs.indices.contains(legIndex) else { return }
        guard legs[legIndex].options.indices.contains(optionIndex) else { return }
        legs[legIndex].selectedOptionIndex = optionIndex
    }

    // MARK: - Mutation (returns the leg indices needing recompute)

    /// Insert a waypoint at `index` (clamped to [1, count-1] so the
    /// origin stays first and a new stop lands before the final
    /// destination by default when index == count-1 is requested via
    /// `insertBeforeDestination`). Returns the leg indices that must be
    /// recomputed.
    @discardableResult
    func addWaypoint(_ wp: Waypoint, at index: Int) -> Set<Int> {
        let clamped = max(1, min(index, waypoints.count))
        waypoints.insert(wp, at: clamped)
        rebuildLegPlaceholders(preservingAround: clamped)
        // Inserting at `clamped` splits the old leg (clamped-1) into two
        // legs (clamped-1) and (clamped). Both need computing.
        return legIndicesTouchingWaypoint(clamped)
    }

    /// Append a stop as the new final destination. Returns dirty legs.
    @discardableResult
    func appendWaypoint(_ wp: Waypoint) -> Set<Int> {
        waypoints.append(wp)
        rebuildLegPlaceholders(preservingAround: waypoints.count - 1)
        // The newly-added last leg is the only dirty one.
        return [legs.count - 1]
    }

    /// Insert a stop just before the final destination (the default
    /// "add a via stop" behaviour). Returns dirty legs.
    @discardableResult
    func insertBeforeDestination(_ wp: Waypoint) -> Set<Int> {
        addWaypoint(wp, at: waypoints.count - 1)
    }

    /// Remove a waypoint by id. Refuses to drop below 2 waypoints, and
    /// (when removing the current-location origin) keeps a sane origin.
    /// Returns the leg indices that must be recomputed (the merged leg
    /// across the gap).
    @discardableResult
    func removeWaypoint(id: UUID) -> Set<Int> {
        guard waypoints.count > 2,
              let idx = waypoints.firstIndex(where: { $0.id == id })
        else { return [] }
        waypoints.remove(at: idx)
        rebuildLegPlaceholders(preservingAround: nil)
        // Removing waypoint idx merges legs (idx-1) and (idx) into a
        // single new leg at index (idx-1). Endpoints that survived keep
        // their options (restored in rebuildLegPlaceholders); the merged
        // leg is dirty.
        let merged = max(0, min(idx - 1, legs.count - 1))
        return legs.isEmpty ? [] : [merged]
    }

    /// Move a waypoint (drag-to-reorder in the list). Returns the leg
    /// indices adjacent to BOTH the old and new positions — those are
    /// the segments whose endpoints changed.
    @discardableResult
    func moveWaypoint(from source: Int, to destination: Int) -> Set<Int> {
        guard waypoints.indices.contains(source) else { return [] }
        let dest = max(0, min(destination, waypoints.count - 1))
        guard source != dest else { return [] }
        let wp = waypoints.remove(at: source)
        waypoints.insert(wp, at: dest)
        rebuildLegPlaceholders(preservingAround: nil)
        // Conservative: any leg whose endpoint pair changed. Recompute
        // legs touching the union of old + new neighbourhoods.
        var dirty = legIndicesTouchingWaypoint(source)
        dirty.formUnion(legIndicesTouchingWaypoint(dest))
        // Clamp to valid range.
        return Set(dirty.filter { legs.indices.contains($0) })
    }

    // MARK: - Leg placeholder rebuild

    /// Rebuild `legs` to match the current `waypoints`, preserving the
    /// computed `options`/`selectedOptionIndex` of any leg whose
    /// (fromWaypointId, toWaypointId) pair still exists. Legs whose
    /// endpoints changed come back empty (dirty), so a subsequent
    /// `recompute` only does the minimal MKDirections work.
    ///
    /// `preservingAround` is advisory; the (from,to) id match below is
    /// what actually decides preservation, so reorders/inserts/removes
    /// all reuse untouched legs correctly.
    private func rebuildLegPlaceholders(preservingAround: Int?) {
        // Index existing legs by their endpoint-id pair.
        var byPair: [Pair: RouteLeg] = [:]
        for leg in legs {
            byPair[Pair(leg.fromWaypointId, leg.toWaypointId)] = leg
        }
        var rebuilt: [RouteLeg] = []
        rebuilt.reserveCapacity(max(0, waypoints.count - 1))
        for i in 0..<max(0, waypoints.count - 1) {
            let fromId = waypoints[i].id
            let toId = waypoints[i + 1].id
            if let existing = byPair[Pair(fromId, toId)] {
                // Endpoint pair unchanged — keep its computed options.
                rebuilt.append(existing)
            } else {
                rebuilt.append(RouteLeg(fromWaypointId: fromId, toWaypointId: toId))
            }
        }
        legs = rebuilt
    }

    /// Leg indices that have `waypoints[wpIndex]` as an endpoint.
    private func legIndicesTouchingWaypoint(_ wpIndex: Int) -> Set<Int> {
        var s = Set<Int>()
        // Leg (wpIndex-1) ends at this waypoint; leg (wpIndex) starts at it.
        if legs.indices.contains(wpIndex - 1) { s.insert(wpIndex - 1) }
        if legs.indices.contains(wpIndex) { s.insert(wpIndex) }
        return s
    }

    // MARK: - Writing back computed options

    /// Assign freshly-computed options to a leg (called by
    /// RoutingService after an MKDirections request). Resets the
    /// selection to the first (fastest) alternative unless a valid
    /// prior selection index still fits.
    func setOptions(_ options: [RouteOption], forLegIndex legIndex: Int) {
        guard legs.indices.contains(legIndex) else { return }
        let prior = legs[legIndex].selectedOptionIndex
        legs[legIndex].options = options
        legs[legIndex].selectedOptionIndex = options.indices.contains(prior) ? prior : 0
    }

    /// Waypoint lookup by id (used when seeding the navigator's
    /// per-leg destination).
    func waypoint(id: UUID) -> Waypoint? {
        waypoints.first { $0.id == id }
    }

    /// Update a waypoint's display name / address (e.g. after an async
    /// reverse-geocode of a long-pressed pin). Coordinate and id are
    /// unchanged, so no leg needs recomputing.
    func renameWaypoint(id: UUID, name: String, addressLine: String?) {
        guard let idx = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[idx].name = name
        waypoints[idx].addressLine = addressLine
    }

    // MARK: - Pair key

    private struct Pair: Hashable {
        let a: UUID
        let b: UUID
        init(_ a: UUID, _ b: UUID) { self.a = a; self.b = b }
    }
}
