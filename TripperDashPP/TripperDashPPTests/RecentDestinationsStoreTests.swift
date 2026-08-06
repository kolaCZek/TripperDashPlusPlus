//
//  RecentDestinationsStoreTests.swift
//  TripperDashPPTests
//
//  feat/search-history — de-dup, ordering, cap and clear behaviour for the
//  recent-search list. Uses an isolated UserDefaults suite so tests don't
//  touch the app's real store.
//

import Testing
import Foundation
import CoreLocation
@testable import TripperDashPP

@MainActor
struct RecentDestinationsStoreTests {

    private func freshStore() -> RecentDestinationsStore {
        let suite = UserDefaults(suiteName: "test.recents.\(UUID().uuidString)")!
        return RecentDestinationsStore(defaults: suite)
    }

    private func dest(_ name: String, _ lat: Double, _ lon: Double) -> Destination {
        Destination(name: name, addressLine: nil,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    @Test func recordInsertsMostRecentFirst() {
        let s = freshStore()
        s.record(dest("A", 50.0, 14.0))
        s.record(dest("B", 51.0, 15.0))
        #expect(s.items.map(\.name) == ["B", "A"])
    }

    @Test func rePickingSamePlaceMovesItToTopWithoutDuplicating() {
        let s = freshStore()
        s.record(dest("A", 50.0, 14.0))
        s.record(dest("B", 51.0, 15.0))
        s.record(dest("A", 50.0, 14.0))
        #expect(s.items.map(\.name) == ["A", "B"])
        #expect(s.items.count == 2)
    }

    @Test func samePlaceToleratesTinyCoordinateJitter() {
        let s = freshStore()
        s.record(dest("Cafe", 50.123456, 14.123456))
        // ~5 m jitter on the same POI — must be treated as the same place.
        s.record(dest("Cafe", 50.123459, 14.123458))
        #expect(s.items.count == 1)
    }

    @Test func differentNameSameCoordIsDistinct() {
        let s = freshStore()
        s.record(dest("Cafe", 50.0, 14.0))
        s.record(dest("Bar", 50.0, 14.0))
        #expect(s.items.count == 2)
    }

    @Test func listIsCappedAtTwelve() {
        let s = freshStore()
        for i in 0..<20 { s.record(dest("P\(i)", 50.0 + Double(i), 14.0)) }
        #expect(s.items.count == 12)
        // Newest kept, oldest dropped.
        #expect(s.items.first?.name == "P19")
        #expect(!s.items.contains { $0.name == "P0" })
    }

    @Test func removeAndClear() {
        let s = freshStore()
        s.record(dest("A", 50.0, 14.0))
        s.record(dest("B", 51.0, 15.0))
        let bID = s.items.first { $0.name == "B" }!.id
        s.remove(id: bID)
        #expect(s.items.map(\.name) == ["A"])
        s.clear()
        #expect(s.items.isEmpty)
    }

    @Test func persistsAcrossReload() {
        let suite = UserDefaults(suiteName: "test.recents.persist.\(UUID().uuidString)")!
        let s1 = RecentDestinationsStore(defaults: suite)
        s1.record(dest("A", 50.0, 14.0))
        // A fresh store on the same suite should see the persisted entry.
        let s2 = RecentDestinationsStore(defaults: suite)
        #expect(s2.items.map(\.name) == ["A"])
    }

    @Test func roundTripDestinationRebuildsCoordinate() {
        let s = freshStore()
        s.record(dest("Zvoleněves", 50.2131, 14.1876))
        let d = s.items.first!.destination
        #expect(abs(d.coordinate.latitude - 50.2131) < 1e-9)
        #expect(abs(d.coordinate.longitude - 14.1876) < 1e-9)
    }
}
