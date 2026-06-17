//
//  Destination.swift
//  TripperDashPP
//
//  Phase 7 — unified destination model. A destination may come from
//  any of: search result, tap-on-map pin, favorite. Once resolved
//  (i.e. we know the coordinate), it has the same shape regardless of
//  origin. RoutingService and ActiveNavigator only see this type,
//  never an MKLocalSearchCompletion or MKMapItem.
//

import CoreLocation
import Foundation
import MapKit

/// Resolved destination — has coordinate plus enough display metadata
/// to render a card/pin/HUD title.
struct Destination: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Short display name. For an address: street name. For a POI:
    /// venue name. For a tap-pin: "Pin" + truncated coords.
    var name: String
    /// Full one-line address, if known. nil for raw map taps until we
    /// reverse-geocode.
    var addressLine: String?
    var coordinate: CLLocationCoordinate2D

    init(id: UUID = UUID(),
         name: String,
         addressLine: String? = nil,
         coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.name = name
        self.addressLine = addressLine
        self.coordinate = coordinate
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (l: Destination, r: Destination) -> Bool { l.id == r.id }

    // MARK: - Convenience constructors

    /// From an MKMapItem returned by MKLocalSearch.
    static func from(mapItem: MKMapItem) -> Destination {
        let coord = mapItem.placemark.coordinate
        let name = mapItem.name ?? Destination.fallbackName(for: coord)
        let address = mapItem.placemark.title  // formatted full address
        return Destination(name: name, addressLine: address, coordinate: coord)
    }

    /// From a raw tap on the map. We hold the pin synchronously; the
    /// reverse-geocode can update `addressLine` later if it succeeds.
    static func fromTap(_ coord: CLLocationCoordinate2D) -> Destination {
        Destination(name: Destination.fallbackName(for: coord),
                    addressLine: nil,
                    coordinate: coord)
    }

    private static func fallbackName(for coord: CLLocationCoordinate2D) -> String {
        String(format: "Pin %.4f, %.4f", coord.latitude, coord.longitude)
    }
}

// CLLocationCoordinate2D isn't Hashable out of the box. Encode the
// pair of doubles for hashing/equality.
extension CLLocationCoordinate2D: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(latitude)
        hasher.combine(longitude)
    }
    public static func == (l: CLLocationCoordinate2D, r: CLLocationCoordinate2D) -> Bool {
        l.latitude == r.latitude && l.longitude == r.longitude
    }
}
