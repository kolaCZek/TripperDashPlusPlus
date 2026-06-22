//
//  Waypoint.swift
//  TripperDashPP
//
//  feat/route-waypoints — a single stop in a multi-stop planned route.
//
//  A `PlannedRoute` is an ordered list of these. Waypoint 0 is the
//  origin (usually the live GPS fix), the last is the final
//  destination, and anything in between is a "via" stop the rider
//  wants the route to pass through.
//
//  MapKit has no waypoint API (`MKDirections.Request` only exposes
//  `source` + `destination`), so a multi-stop route is computed as
//  N-1 single-leg requests, waypoint i -> i+1. This type is the stop
//  identity those legs are derived from.
//

import CoreLocation
import Foundation
import MapKit

/// One stop in a planned route. Value type, identity by `id` so the
/// SwiftUI list can reorder/delete stably even when two stops share a
/// coordinate.
struct Waypoint: Identifiable, Hashable, Sendable {
    let id: UUID

    /// Short display name. Street/venue name, "Current location" for
    /// the live-GPS origin, or "Pin <lat>, <lon>" for a raw map tap.
    var name: String

    /// Full one-line address if known. nil until reverse-geocoded.
    var addressLine: String?

    /// Last-known coordinate. For an `isCurrentLocation` origin this is
    /// only a snapshot used for map-fit / display; routing uses the
    /// live fix via `.forCurrentLocation()` instead.
    var coordinate: CLLocationCoordinate2D

    /// When true this waypoint tracks the live GPS fix rather than a
    /// fixed coordinate. Only meaningful for the origin (index 0).
    /// `RoutingService.calculateLeg` maps a nil `from` waypoint — or
    /// one with this flag set — to `MKDirections.Request.source =
    /// .forCurrentLocation()`.
    var isCurrentLocation: Bool

    init(id: UUID = UUID(),
         name: String,
         addressLine: String? = nil,
         coordinate: CLLocationCoordinate2D,
         isCurrentLocation: Bool = false) {
        self.id = id
        self.name = name
        self.addressLine = addressLine
        self.coordinate = coordinate
        self.isCurrentLocation = isCurrentLocation
    }

    // MARK: - Hashable (identity-based, mirrors Destination)

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (l: Waypoint, r: Waypoint) -> Bool { l.id == r.id }

    // MARK: - Convenience constructors

    /// The live-GPS origin. `coordinate` is a snapshot of the last
    /// known fix (for map-fit); routing resolves the real position at
    /// request time.
    static func currentLocation(_ coord: CLLocationCoordinate2D) -> Waypoint {
        Waypoint(name: "Current location",
                 addressLine: nil,
                 coordinate: coord,
                 isCurrentLocation: true)
    }

    /// Bridge from the existing `Destination` model — search results,
    /// favorites, and tap-pins all become waypoints this way.
    static func from(destination: Destination) -> Waypoint {
        Waypoint(name: destination.name,
                 addressLine: destination.addressLine,
                 coordinate: destination.coordinate,
                 isCurrentLocation: false)
    }

    /// Reverse bridge — the final waypoint is the navigation
    /// destination handed to `ActiveNavigator`.
    var asDestination: Destination {
        Destination(id: id,
                    name: name,
                    addressLine: addressLine,
                    coordinate: coordinate)
    }
}
