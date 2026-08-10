//
//  SharedDeepLink.swift
//  TripperDashPP
//
//  Codec for the `tripperdash://plan` deep link the share extension posts
//  to the main app after it has resolved a shared payload. The extension
//  runs in its own process and can't touch AppStatus directly, so it packs
//  the resolved waypoints (or a search hint) into a URL the OS hands to the
//  app's `onOpenURL`. Small payloads ride in the URL query directly; this
//  keeps the extension → app handoff dependency-free (no App Group write
//  needed for the common 1–a-few-stop case).
//
//  URL shapes:
//    tripperdash://plan?wp=LAT,LON,Name&wp=LAT,LON&wp=,,NameOnly…
//    tripperdash://search?q=Some%20Place
//
//  Each `wp` is "lat,lon,name" — lat/lon may be empty (name-only stop);
//  name is percent-encoded and may be empty. Order is preserved.
//

import CoreLocation
import Foundation

enum SharedDeepLink {

    static let scheme = "tripperdash"

    /// Build a deep link from a resolution (used by the share extension).
    static func encode(_ resolution: ShareResolution) -> URL? {
        var comps = URLComponents()
        comps.scheme = scheme

        switch resolution {
        case .empty:
            return nil

        case .searchHint(let hint):
            comps.host = "search"
            comps.queryItems = [URLQueryItem(name: "q", value: hint)]
            return comps.url

        case .waypoints(let wps):
            comps.host = "plan"
            comps.queryItems = wps.map { wp in
                let lat = wp.coordinate.map { String($0.latitude) } ?? ""
                let lon = wp.coordinate.map { String($0.longitude) } ?? ""
                let name = wp.name ?? ""
                // Commas separate the fields; the name is the last field so
                // any commas inside it are harmless (we split with a cap).
                return URLQueryItem(name: "wp", value: "\(lat),\(lon),\(name)")
            }
            return comps.url
        }
    }

    /// Decode a `tripperdash://` deep link back into a resolution
    /// (used by the main app on `onOpenURL`).
    static func decode(_ url: URL) -> ShareResolution {
        guard url.scheme?.lowercased() == scheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .empty }

        let host = (url.host ?? "").lowercased()
        let items = comps.queryItems ?? []

        if host == "search" {
            if let q = items.first(where: { $0.name == "q" })?.value,
               !q.trimmingCharacters(in: .whitespaces).isEmpty {
                return .searchHint(q)
            }
            return .empty
        }

        // host == "plan" (or anything else with wp items)
        var out: [ResolvedWaypoint] = []
        for item in items where item.name == "wp" {
            guard let raw = item.value else { continue }
            let fields = raw.split(separator: ",", maxSplits: 2,
                                   omittingEmptySubsequences: false).map(String.init)
            var coord: CLLocationCoordinate2D?
            if fields.count >= 2,
               let lat = Double(fields[0]), let lon = Double(fields[1]),
               let c = SharedDestinationResolver.validCoord(lat: lat, lon: lon) {
                coord = c
            }
            let name = fields.count >= 3
                ? fields[2].trimmingCharacters(in: .whitespaces)
                : ""
            if coord == nil && name.isEmpty { continue }
            out.append(ResolvedWaypoint(coordinate: coord,
                                        name: name.isEmpty ? nil : name))
        }
        return out.isEmpty ? .empty : .waypoints(out)
    }
}
