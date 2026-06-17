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
    func calculate(from origin: CLLocationCoordinate2D?,
                   to destination: Destination,
                   preferences: RoutePreferences) async throws -> [RouteOption] {
        let req = MKDirections.Request()
        if let origin {
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        } else {
            req.source = .forCurrentLocation()
        }
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        req.transportType = .automobile
        req.requestsAlternateRoutes = true
        req.highwayPreference = preferences.avoidHighways ? .avoid : .any
        req.tollPreference = preferences.avoidTolls ? .avoid : .any

        log.info("Calculating routes to \(destination.name, privacy: .public) (avoid highways=\(preferences.avoidHighways), tolls=\(preferences.avoidTolls))")
        let response = try await MKDirections(request: req).calculate()
        let routes = Array(response.routes.prefix(3))
        log.info("Got \(routes.count) route(s)")
        return routes.enumerated().map { (idx, route) in
            RouteOption(index: idx, route: route)
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
