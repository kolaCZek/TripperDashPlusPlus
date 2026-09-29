//
//  RideHistoryStoreTests.swift
//  TripperDashPPTests
//
//  feat/ride-history — the 30-day ride log. One file per ride keyed by
//  start time (a multi-leg session overwrites, never duplicates), expired
//  rides pruned by filename, and the RideStatsService wiring (a restored
//  summary is never re-recorded). The reset-before-zero ordering for a
//  live ride is pinned by the Python drift guard. Each test uses its own
//  temp directory.
//

import Testing
import Foundation
import CoreLocation
@testable import TripperDashPP

@MainActor
struct RideHistoryStoreTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ridehist-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func fix(_ lon: Double, _ t: TimeInterval) -> Fix {
        Fix(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 50, longitude: lon),
            altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 90, speed: 10, timestamp: Date(timeIntervalSince1970: t)))
    }

    /// A ride starting at `start` (epoch seconds) with `n` fixes 1 s apart.
    private func ride(start: TimeInterval, fixes n: Int = 2) -> RideStats {
        (0..<n).reduce(RideStats()) { s, i in s.folding(fix(14 + Double(i) * 0.0002, start + Double(i))) }
    }

    @Test func recordThenReloadRoundTrips() {
        let dir = tempDir()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RideHistoryStore(directory: dir, now: now)
        store.record(ride(start: 999_000), now: now)

        let fresh = RideHistoryStore(directory: dir, now: now)
        fresh.load(now: now)
        #expect(fresh.rides.count == 1)
        #expect(fresh.rides[0].startedAt == Date(timeIntervalSince1970: 999_000))
        #expect(fresh.rides[0].trackPoints.count == 2)
    }

    @Test func sameSessionOverwritesInsteadOfDuplicating() {
        let dir = tempDir()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RideHistoryStore(directory: dir, now: now)
        store.record(ride(start: 999_000, fixes: 2), now: now)
        store.record(ride(start: 999_000, fixes: 5), now: now)   // next leg, same session
        #expect(store.rides.count == 1)

        let fresh = RideHistoryStore(directory: dir, now: now)
        fresh.load(now: now)
        #expect(fresh.rides.count == 1)
        #expect(fresh.rides[0].trackPoints.count == 5)
    }

    @Test func newestFirstAndExpiredRidesPruned() {
        let dir = tempDir()
        let day: TimeInterval = 86_400
        let t0: TimeInterval = 10_000_000
        let store = RideHistoryStore(directory: dir, now: Date(timeIntervalSince1970: t0))
        store.record(ride(start: t0 - 31 * day), now: Date(timeIntervalSince1970: t0 - 31 * day))
        store.record(ride(start: t0 - 2 * day), now: Date(timeIntervalSince1970: t0))
        store.record(ride(start: t0 - 1 * day), now: Date(timeIntervalSince1970: t0))

        let fresh = RideHistoryStore(directory: dir, now: Date(timeIntervalSince1970: t0))
        fresh.load(now: Date(timeIntervalSince1970: t0))
        #expect(fresh.rides.map(\.startedAt) == [
            Date(timeIntervalSince1970: t0 - 1 * day),
            Date(timeIntervalSince1970: t0 - 2 * day),
        ])
    }

    @Test func deleteRemovesTheFile() {
        let dir = tempDir()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RideHistoryStore(directory: dir, now: now)
        let r = ride(start: 999_000)
        store.record(r, now: now)
        store.delete(r)
        let fresh = RideHistoryStore(directory: dir, now: now)
        fresh.load(now: now)
        #expect(fresh.rides.isEmpty)
    }

    @Test func rideWithoutAFixIsNotRecorded() {
        let store = RideHistoryStore(directory: tempDir())
        store.record(RideStats())
        #expect(store.rides.isEmpty)
    }

    /// A service whose persisted last ride started an hour ago.
    private func serviceWithLastRide(history: RideHistoryStore) -> (RideStatsService, RideStats) {
        let suite = UserDefaults(suiteName: "test.ridehist.\(UUID().uuidString)")!
        let last = ride(start: Date.now.timeIntervalSince1970 - 3600)
        suite.set(try! JSONEncoder().encode(last), forKey: "RideStats.lastRide.v1")
        return (RideStatsService(location: LocationService(), defaults: suite, history: history), last)
    }

    @Test func resetDoesNotResurrectADeletedRestoredRide() {
        // The last-ride summary restored on launch was recorded in its own
        // session. If the rider deleted it from the history, the link-down
        // reset() must not write it back.
        let dir = tempDir()
        let history = RideHistoryStore(directory: dir)
        let (svc, last) = serviceWithLastRide(history: history)
        history.record(last)
        history.delete(last)

        svc.reset()
        #expect(svc.stats.startedAt == nil)
        let fresh = RideHistoryStore(directory: dir)
        fresh.load()
        #expect(fresh.rides.isEmpty)
    }

    @Test func historyRideConvertsToSavedTrackRoute() {
        let route = RideStatsService.savedRoute(from: ride(start: 999_000, fixes: 3))
        #expect(route?.kind == .track)
        #expect(route?.points.count == 3)
        #expect(RideStatsService.savedRoute(from: RideStats()) == nil)
    }
}
