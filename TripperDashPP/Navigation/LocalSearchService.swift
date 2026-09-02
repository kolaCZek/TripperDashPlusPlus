//
//  LocalSearchService.swift
//  TripperDashPP
//
//  Phase 7b — wrapper around MKLocalSearchCompleter for live
//  autocomplete + MKLocalSearch for resolving a completion to a real
//  coordinate. Owns its region bias (100 km box around the current
//  GPS, Czech Republic fallback).
//

import CoreLocation
import Foundation
import MapKit
import os
import SwiftUI

@MainActor
@Observable
final class LocalSearchService: NSObject {

    /// Current autocomplete results. Driven by MKLocalSearchCompleter
    /// delegate callbacks; UI observes this via @Observable.
    private(set) var completions: [MKLocalSearchCompletion] = []
    /// Any error from the most recent completer update.
    private(set) var lastError: String?

    /// Free-form text the user has typed. Setting this triggers the
    /// underlying MKLocalSearchCompleter.
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            applyQuery()
        }
    }

    /// Centre of the search region (typically current GPS). UI sets
    /// this on appear and on each location update. Setting it
    /// re-applies the current query so suggestions reflect the new
    /// area.
    var biasCenter: CLLocationCoordinate2D? {
        didSet { applyRegion() }
    }

    private let completer = MKLocalSearchCompleter()
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "LocalSearch")

    /// Czech Republic centre — fallback when we don't yet have a fix.
    private static let czechRepublicCenter = CLLocationCoordinate2D(latitude: 49.8, longitude: 15.5)

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        applyRegion()
    }

    // MARK: - Internals

    private func applyQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Same non-animated path as the delegate callbacks — clearing
            // the field is the single biggest row-count change the List
            // ever sees (N → 0), so it must not animate either.
            applyCompletions([])
            completer.cancel()
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    private func applyRegion() {
        let center = biasCenter ?? Self.czechRepublicCenter
        // Tighter box when we have GPS (200 km square, 100 km radius
        // equivalent), wider when we're guessing the Czech Republic centroid.
        let span: CLLocationDistance = (biasCenter == nil) ? 600_000 : 200_000
        completer.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: span,
            longitudinalMeters: span
        )
        // Re-fire the in-flight query so suggestions reflect the new
        // bias.
        if !query.isEmpty { applyQuery() }
    }

    /// Geocode a free-text place name (e.g. a shared "Share to
    /// TripperDash++" label from Google/Apple Maps that carried no
    /// coordinates) into a concrete `Destination`. Natural-language
    /// MKLocalSearch; biased toward `near` when given so an ambiguous name
    /// resolves to the nearby match (e.g. "Zvoleněves" near Prague rather
    /// than "Zvolen" in Slovakia). Returns nil on no results / failure.
    func geocode(_ text: String,
                 near: CLLocationCoordinate2D? = nil) async -> Destination? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let near {
            request.region = MKCoordinateRegion(
                center: near,
                latitudinalMeters: 200_000,
                longitudinalMeters: 200_000)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else { return nil }
            return Destination.from(mapItem: item)
        } catch {
            log.debug("geocode failed for \(trimmed, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Resolve

    /// Turn an autocomplete row into a real MKMapItem (with coords).
    /// Throws on network failure or zero results.
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> Destination {
        let request = MKLocalSearch.Request(completion: completion)
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw LocalSearchError.noResults
        }
        return Destination.from(mapItem: item)
    }

    /// Reverse-geocode a tapped coordinate into an address line (best
    /// effort — returns nil silently on failure).
    func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks.first?.formattedOneLine
        } catch {
            log.debug("reverse-geocode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    enum LocalSearchError: LocalizedError {
        case noResults
        var errorDescription: String? {
            switch self {
            case .noResults: return "No results for that search."
            }
        }
    }
}

// MARK: - MKLocalSearchCompleterDelegate

extension LocalSearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.applyCompletions(results)
            self.lastError = nil
        }
    }
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let nsError = error as NSError
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        // MKErrorDomain code 5 = directionsNotFound / loadingThrottled / serverFailure;
        // MKLocalSearchCompleter routinely throws it on empty or single-character
        // queries (Apple's server rejects them). Don't surface to the UI or warn —
        // just clear results so the dropdown closes cleanly.
        let isTransient = nsError.domain == MKErrorDomain && nsError.code == 5
        Task { @MainActor in
            self.applyCompletions([])
            if isTransient {
                self.lastError = nil
            } else {
                self.lastError = msg
                self.log.warning("completer failed: \(msg, privacy: .public)")
            }
        }
    }
}

// MARK: - Completion publishing

private extension LocalSearchService {
    /// Publish a new completer snapshot to the UI.
    ///
    /// Crash this guards against (TestFlight 1.0.2, iPhone 13 Pro Max,
    /// iOS 26.6.1, 76 s after launch on cellular — i.e. someone poking at
    /// the search field): `NSInternalInconsistencyException`
    /// "Invalid Number Of Items In Section" aborting inside
    /// `UICollectionView _endItemAnimationsWithInvalidationContext:`, under
    /// SwiftUI's `UpdateCoalescingCollectionView.performBatchUpdates`. The
    /// whole stack is SwiftUI/UIKit — no app frame beyond `main` — which is
    /// the signature of a List whose backing collection view was told one
    /// item count and handed another.
    ///
    /// `MKLocalSearchCompleter` calls its delegate on every keystroke AND
    /// asynchronously as network results land, and the delegate hop is
    /// `Task { @MainActor in … }` — scheduled at an arbitrary point, with no
    /// coordination with SwiftUI's update cycle. If that write lands while
    /// the List is mid-animation, the counts disagree and UIKit aborts.
    ///
    /// Two mitigations here, neither changing what the user sees:
    ///   1. Skip the write entirely when the visible content is unchanged.
    ///      The completer re-emits identical result sets often (repeat
    ///      keystrokes, throttled retries); every one of those was a free
    ///      chance to collide for no UI benefit.
    ///   2. Apply the change with animations disabled, so the List swaps
    ///      rows outright instead of running a batch-update animation that
    ///      can be invalidated by the next delegate callback mid-flight.
    ///
    /// NOT claimed to be proven: the crash report names no view, so this is
    /// the most probable candidate hardened on reasoning, not a confirmed
    /// root cause. It cannot regress behaviour — worst case the real cause
    /// is elsewhere and this is simply a no-op made cheaper.
    func applyCompletions(_ new: [MKLocalSearchCompletion]) {
        // Compare on what's actually rendered (title + subtitle);
        // MKLocalSearchCompletion has no stable identity of its own and
        // reference equality would defeat the check.
        let unchanged = new.count == completions.count
            && zip(new, completions).allSatisfy {
                $0.title == $1.title && $0.subtitle == $1.subtitle
            }
        guard !unchanged else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { completions = new }
    }
}

// MARK: - Helpers

private extension CLPlacemark {
    /// One-line address, defensively built from whatever CLGeocoder
    /// gave us. Czech address order: street + number, postal code,
    /// city.
    var formattedOneLine: String {
        var parts: [String] = []
        if let street = thoroughfare {
            if let num = subThoroughfare {
                parts.append("\(street) \(num)")
            } else {
                parts.append(street)
            }
        }
        if let pc = postalCode, let city = locality {
            parts.append("\(pc) \(city)")
        } else if let city = locality {
            parts.append(city)
        }
        if parts.isEmpty, let name { parts.append(name) }
        return parts.joined(separator: ", ")
    }
}
