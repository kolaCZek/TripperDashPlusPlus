//
//  RideStatsPersistenceTests.swift
//  TripperDashPPTests
//
//  Cross-launch persistence of the last ride summary. Verifies the
//  arrival→sleep→kill recovery path: a finished ride is written to disk at
//  teardown and rehydrated on the next launch (so the picker shows the last
//  ride's summary instead of a blank screen), while a genuinely new ride
//  still starts from zero rather than folding onto last session's totals.
//

import Testing
import Foundation
import CoreLocation
@testable import TripperDashPP

@MainActor
struct RideStatsPersistenceTests {

    /// The UserDefaults key the service persists under (kept in sync with
    /// `RideStatsService.storageKey`).
    private static let storageKey = "RideStats.lastRide.v1"

    /// A private-suite UserDefaults so tests never touch `.standard`.
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.ridestats.persist.\(UUID().uuidString)")!
    }

    /// A finished-looking ride: two accepted fixes → non-nil `startedAt`
    /// and non-zero distance.
    private func sampleRide() -> RideStats {
        var s = RideStats()
        s = s.folding(Fix(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0.000),
            altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 0, speed: 10, timestamp: Date(timeIntervalSince1970: 0))))
        s = s.folding(Fix(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0.010),
            altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 0, speed: 10, timestamp: Date(timeIntervalSince1970: 30))))
        return s
    }

    /// Seed a suite with a persisted ride the way the service would.
    private func seed(_ ride: RideStats, into suite: UserDefaults) {
        suite.set(try! JSONEncoder().encode(ride), forKey: Self.storageKey)
    }

    @Test func restoresLastRideFromDiskOnLaunch() {
        let suite = freshSuite()
        let ride = sampleRide()
        seed(ride, into: suite)

        // A fresh service on the same suite rehydrates the summary so the
        // post-arrival panel (gated on `startedAt != nil`) shows immediately.
        let svc = RideStatsService(location: LocationService(), defaults: suite)
        #expect(svc.stats.startedAt != nil)
        #expect(abs(svc.stats.distanceMeters - ride.distanceMeters) < 1e-6)
        #expect(svc.state == .idle) // restored ride is reference-only, not running
    }

    @Test func newRideZeroesRestoredTotals() {
        let suite = freshSuite()
        seed(sampleRide(), into: suite)

        let svc = RideStatsService(location: LocationService(), defaults: suite)
        #expect(svc.stats.distanceMeters > 0) // restored

        // Starting a genuinely new ride must NOT fold onto last session's
        // totals — the restored summary is zeroed on begin().
        svc.begin()
        #expect(svc.stats.distanceMeters == 0)
        #expect(svc.stats.startedAt == nil)
    }

    @Test func resetClearsPersistedCopy() {
        let suite = freshSuite()
        seed(sampleRide(), into: suite)

        let svc = RideStatsService(location: LocationService(), defaults: suite)
        svc.reset()
        #expect(svc.stats.startedAt == nil)
        #expect(suite.data(forKey: Self.storageKey) == nil)

        // A subsequent launch sees nothing to restore.
        let svc2 = RideStatsService(location: LocationService(), defaults: suite)
        #expect(svc2.stats.startedAt == nil)
    }

    @Test func emptyRideIsNotPersisted() {
        // end() before any fix must not write a blank record.
        let suite = freshSuite()
        let svc = RideStatsService(location: LocationService(), defaults: suite)
        svc.end()
        #expect(suite.data(forKey: Self.storageKey) == nil)
    }
}
