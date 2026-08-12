//
//  SavedBikesStoreTests.swift
//  TripperDashPPTests
//
//  The garage store: add/dedup, remove-reselects, select, persistence across
//  reload, and one-time legacy-SSID migration.
//

import Testing
import Foundation
@testable import TripperDashPP

@MainActor
struct SavedBikesStoreTests {

    private func freshStore() -> SavedBikesStore {
        let suite = UserDefaults(suiteName: "test.bikes.\(UUID().uuidString)")!
        return SavedBikesStore(defaults: suite)
    }

    @Test func addsBikeAndSelectsFirst() {
        let s = freshStore()
        let b = s.add(ssid: "RE_1234_ABCDE")
        #expect(b != nil)
        #expect(s.bikes.map(\.ssid) == ["RE_1234_ABCDE"])
        #expect(s.selectedID == b?.id) // first bike is active
    }

    @Test func dedupesCaseInsensitivelyAndSelects() {
        let s = freshStore()
        _ = s.add(ssid: "RE_1234_ABCDE")
        let second = s.add(ssid: "RE_9999_ZZZZZ")
        // Re-adding an existing SSID (different case) must not duplicate,
        // just re-select it.
        let again = s.add(ssid: "re_1234_abcde")
        #expect(s.bikes.count == 2)
        #expect(again?.ssid == "RE_1234_ABCDE")
        #expect(s.selectedID == again?.id)
        #expect(second?.ssid == "RE_9999_ZZZZZ")
    }

    @Test func ignoresEmptySSID() {
        let s = freshStore()
        #expect(s.add(ssid: "   ") == nil)
        #expect(s.bikes.isEmpty)
    }

    @Test func removeReselectsToFirstRemaining() {
        let s = freshStore()
        let a = s.add(ssid: "RE_A")!
        let b = s.add(ssid: "RE_B")!
        s.select(id: b.id)
        #expect(s.selectedID == b.id)
        s.remove(id: b.id)
        // Active bike removed → selection falls back to the first remaining.
        #expect(s.selectedID == a.id)
        s.remove(id: a.id)
        #expect(s.bikes.isEmpty)
        #expect(s.selectedID == nil)
    }

    @Test func selectOnlyAcceptsKnownID() {
        let s = freshStore()
        let a = s.add(ssid: "RE_A")!
        s.select(id: UUID()) // unknown → ignored
        #expect(s.selectedID == a.id)
    }

    @Test func persistsAcrossReload() {
        let suite = UserDefaults(suiteName: "test.bikes.persist.\(UUID().uuidString)")!
        let s1 = SavedBikesStore(defaults: suite)
        _ = s1.add(ssid: "RE_1234_ABCDE")
        let b = s1.add(ssid: "RE_9999_ZZZZZ")!
        s1.select(id: b.id)

        let s2 = SavedBikesStore(defaults: suite)
        #expect(s2.bikes.map(\.ssid) == ["RE_1234_ABCDE", "RE_9999_ZZZZZ"])
        #expect(s2.selectedID == b.id) // selection survives reload
    }

    @Test func danglingSelectionFallsBackToFirst() {
        // A reload whose stored selectedID no longer matches any bike must
        // recover by selecting the first bike, not leave a dangling id.
        let suite = UserDefaults(suiteName: "test.bikes.dangling.\(UUID().uuidString)")!
        let payload = SavedBikesPayload(
            bikes: [SavedBike(ssid: "RE_A"), SavedBike(ssid: "RE_B")],
            selectedID: UUID())
        suite.set(try! JSONEncoder().encode(payload), forKey: "SavedBikes.v1")

        let s = SavedBikesStore(defaults: suite)
        #expect(s.selectedID == s.bikes.first?.id)
    }
}
