//
//  Favorite.swift
//  TripperDashPP
//
//  Phase 7d — persisted favorite destination. Owns its own UUID so it
//  survives renames/coordinate edits without breaking quick-access
//  slot bindings.
//

import CoreLocation
import Foundation

struct Favorite: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String           // "Home", "Work", or custom
    /// SF Symbol name. Optional — when nil, UI picks one based on
    /// the lowercased name (house → house.fill, work → briefcase.fill,
    /// fuel → fuelpump.fill, etc.) and falls back to mappin.circle.fill.
    var iconSymbol: String?
    var latitude: Double
    var longitude: Double
    var addressLine: String?
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         iconSymbol: String? = nil,
         coordinate: CLLocationCoordinate2D,
         addressLine: String? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.iconSymbol = iconSymbol
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.addressLine = addressLine
        self.createdAt = createdAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Adapter for use anywhere `Destination` is expected.
    var asDestination: Destination {
        // Reuse the favorite's UUID so route caching keyed by id stays
        // stable across UI refreshes.
        Destination(id: id, name: name, addressLine: addressLine, coordinate: coordinate)
    }

    /// Picks a sensible SF Symbol when none is explicitly set. Order
    /// matters — most specific match wins.
    var resolvedIconSymbol: String {
        if let explicit = iconSymbol, !explicit.isEmpty { return explicit }
        let n = name.lowercased()
        if n.contains("home") || n.contains("dom") { return "house.fill" }
        if n.contains("work") || n.contains("prác") || n.contains("kancel") || n.contains("office") {
            return "briefcase.fill"
        }
        if n.contains("fuel") || n.contains("benz") || n.contains("čerp") || n.contains("pump") {
            return "fuelpump.fill"
        }
        if n.contains("coffee") || n.contains("kav") || n.contains("café") || n.contains("cafe") {
            return "cup.and.saucer.fill"
        }
        if n.contains("food") || n.contains("restaur") || n.contains("jíd") {
            return "fork.knife"
        }
        if n.contains("garage") || n.contains("garáž") || n.contains("servis") || n.contains("service") {
            return "wrench.and.screwdriver.fill"
        }
        if n.contains("airport") || n.contains("letiš") { return "airplane" }
        if n.contains("school") || n.contains("škol") { return "graduationcap.fill" }
        return "mappin.circle.fill"
    }
}
