//
//  SavedBikesStoreTests.swift
//  TripperDashPPTests
//
//  The garage store: add/dedup, remove-reselects, select, persistence across
//  reload, display-name fallback, and tolerant decode of legacy (name-less)
//  records.
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
        let b = s.add(name: "Guerrilla", ssid: "RE_1234_ABCDE")
        #expect(b != nil)
        #expect(s.bikes.map(\.ssid) == ["RE_1234_ABCDE"])
        #expect(s.bikes.map(\.name) == ["Guerrilla"])
        #expect(s.selectedID == b?.id) // first bike is active
    }

    @Test func displayNameFallsBackToSSID() {
        let s = freshStore()
        let named = s.add(name: "Guerrilla", ssid: "RE_1111_AAAAA")!
        let unnamed = s.add(name: "   ", ssid: "RE_2222_BBBBB")!
        #expect(named.displayName == "Guerrilla")
        #expect(unnamed.displayName == "RE_2222_BBBBB") // empty name → SSID
    }

    @Test func dedupesCaseInsensitivelyAndUpdatesName() {
        let s = freshStore()
        _ = s.add(name: "Guerrilla", ssid: "RE_1234_ABCDE")
        let second = s.add(name: "Himalayan", ssid: "RE_9999_ZZZZZ")
        // Re-adding an existing SSID (different case) must not duplicate,
        // just re-select it and refresh the name.
        let again = s.add(name: "GG 450", ssid: "re_1234_abcde")
        #expect(s.bikes.count == 2)
        #expect(again?.ssid == "RE_1234_ABCDE")
        #expect(again?.name == "GG 450") // name refreshed on re-add
        #expect(s.selectedID == again?.id)
        #expect(second?.ssid == "RE_9999_ZZZZZ")
    }

    @Test func ignoresEmptySSID() {
        let s = freshStore()
        #expect(s.add(name: "Ghost", ssid: "   ") == nil)
        #expect(s.bikes.isEmpty)
    }

    @Test func removeReselectsToFirstRemaining() {
        let s = freshStore()
        let a = s.add(name: "A", ssid: "RE_A")!
        let b = s.add(name: "B", ssid: "RE_B")!
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
        let a = s.add(name: "A", ssid: "RE_A")!
        s.select(id: UUID()) // unknown → ignored
        #expect(s.selectedID == a.id)
    }

    @Test func persistsAcrossReload() {
        let suite = UserDefaults(suiteName: "test.bikes.persist.\(UUID().uuidString)")!
        let s1 = SavedBikesStore(defaults: suite)
        _ = s1.add(name: "Guerrilla", ssid: "RE_1234_ABCDE")
        let b = s1.add(name: "Himalayan", ssid: "RE_9999_ZZZZZ")!
        s1.select(id: b.id)

        let s2 = SavedBikesStore(defaults: suite)
        #expect(s2.bikes.map(\.ssid) == ["RE_1234_ABCDE", "RE_9999_ZZZZZ"])
        #expect(s2.bikes.map(\.name) == ["Guerrilla", "Himalayan"])
        #expect(s2.selectedID == b.id) // selection survives reload
    }

    @Test func danglingSelectionFallsBackToFirst() {
        // A reload whose stored selectedID no longer matches any bike must
        // recover by selecting the first bike, not leave a dangling id.
        let suite = UserDefaults(suiteName: "test.bikes.dangling.\(UUID().uuidString)")!
        let payload = SavedBikesPayload(
            bikes: [SavedBike(name: "A", ssid: "RE_A"), SavedBike(name: "B", ssid: "RE_B")],
            selectedID: UUID())
        suite.set(try! JSONEncoder().encode(payload), forKey: "SavedBikes.v1")

        let s = SavedBikesStore(defaults: suite)
        #expect(s.selectedID == s.bikes.first?.id)
    }

    @Test func decodesLegacyRecordWithoutName() {
        // Records written before `name` existed must still load, with the
        // display name falling back to the SSID.
        let suite = UserDefaults(suiteName: "test.bikes.legacy.\(UUID().uuidString)")!
        let legacyJSON = """
        {"schemaVersion":1,"bikes":[{"id":"\(UUID().uuidString)","ssid":"RE_OLD_STYLE","addedAt":0}],"selectedID":null}
        """
        suite.set(Data(legacyJSON.utf8), forKey: "SavedBikes.v1")

        let s = SavedBikesStore(defaults: suite)
        #expect(s.bikes.count == 1)
        #expect(s.bikes.first?.name == "")
        #expect(s.bikes.first?.displayName == "RE_OLD_STYLE")
    }
}
