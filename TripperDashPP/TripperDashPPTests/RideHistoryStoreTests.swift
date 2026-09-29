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

    /// A ride starting at `start` (epoch seconds) with `n` fixes 10 s apart.
    private func ride(start: TimeInterval, fixes n: Int = 2) -> RideStats {
        // ~143 m per 10 s step: over the 100 m history minimum from 2 fixes.
        (0..<n).reduce(RideStats()) { s, i in s.folding(fix(14 + Double(i) * 0.002, start + Double(i) * 10)) }
    }

    @Test func recordThenReloadRoundTrips() async {
        let dir = tempDir()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RideHistoryStore(directory: dir, now: now)
        store.record(ride(start: 999_000), now: now)

        let fresh = RideHistoryStore(directory: dir, now: now)
        await fresh.load(now: now)
        #expect(fresh.rides.count == 1)
        #expect(fresh.rides[0].startedAt == Date(timeIntervalSince1970: 999_000))
        #expect(fresh.rides[0].trackPoints.count == 2)
    }

    @Test func sameSessionOverwritesInsteadOfDuplicating() async {
        let dir = tempDir()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RideHistoryStore(directory: dir, now: now)
        store.record(ride(start: 999_000, fixes: 2), now: now)
        store.record(ride(start: 999_000, fixes: 5), now: now)   // next leg, same session
        #expect(store.rides.count == 1)

        let fresh = RideHistoryStore(directory: dir, now: now)
        await fresh.load(now: now)
        #expect(fresh.rides.count == 1)
        #expect(fresh.rides[0].trackPoints.count == 5)
    }

    @Test func newestFirstAndExpiredRidesPruned() async {
        let dir = tempDir()
        let day: TimeInterval = 86_400
        let t0: TimeInterval = 10_000_000
        let store = RideHistoryStore(directory: dir, now: Date(timeIntervalSince1970: t0))
        store.record(ride(start: t0 - 31 * day), now: Date(timeIntervalSince1970: t0 - 31 * day))
        store.record(ride(start: t0 - 2 * day), now: Date(timeIntervalSince1970: t0))
        store.record(ride(start: t0 - 1 * day), now: Date(timeIntervalSince1970: t0))

        let fresh = RideHistoryStore(directory: dir, now: Date(timeIntervalSince1970: t0))
        await fresh.load(now: Date(timeIntervalSince1970: t0))
        #expect(fresh.rides.map(\.startedAt) == [
            Date(timeIntervalSince1970: t0 - 1 * day),
            Date(timeIntervalSince1970: t0 - 2 * day),
        ])
    }

    @Test func deleteRemovesTheFile() async {
        let dir = tempDir()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RideHistoryStore(directory: dir, now: now)
        let r = ride(start: 999_000)
        store.record(r, now: now)
        store.delete(r)
        let fresh = RideHistoryStore(directory: dir, now: now)
        await fresh.load(now: now)
        #expect(fresh.rides.isEmpty)
    }

    @Test func rideWithoutAFixIsNotRecorded() {
        let store = RideHistoryStore(directory: tempDir())
        store.record(RideStats())
        #expect(store.rides.isEmpty)
    }

    @Test func sessionUnder100mIsNotRecorded() {
        // Connect + disconnect at home: one fix, or a few metres of jitter.
        let store = RideHistoryStore(directory: tempDir())
        let short = (0..<3).reduce(RideStats()) { s, i in
            s.folding(fix(14 + Double(i) * 0.0002, 999_000 + Double(i)))   // ~14 m steps
        }
        #expect(short.distanceMeters < RideHistoryStore.minimumDistanceMeters)
        store.record(short)
        store.record(ride(start: 999_100, fixes: 1))
        #expect(store.rides.isEmpty)
    }

    @Test func deletedRideIsNotWrittenBackByTheNextTeardown() async {
        // Review of #152: the live service still holds the deleted ride
        // (same startedAt); bike off → reset() → record must not restore it.
        let dir = tempDir()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RideHistoryStore(directory: dir, now: now)
        let r = ride(start: 999_000)
        store.record(r, now: now)
        store.delete(r)
        store.record(r, now: now)                                 // bike off: same ride
        #expect(store.rides.isEmpty)
        let fresh = RideHistoryStore(directory: dir, now: now)
        await fresh.load(now: now)
        #expect(fresh.rides.isEmpty)
    }

    @Test func deletedRideComesBackOnceTheSessionRidesOn() async {
        // Review 2 of #152: the tombstone must not swallow the rest of the
        // session (delete a test loop, then ride 80 km without disconnecting).
        let dir = tempDir()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RideHistoryStore(directory: dir, now: now)
        let r = ride(start: 999_000)
        store.record(r, now: now)
        store.delete(r)
        store.record(ride(start: 999_000, fixes: 4), now: now)   // next leg, same session
        #expect(store.rides.count == 1)
        let fresh = RideHistoryStore(directory: dir, now: now)
        await fresh.load(now: now)
        #expect(fresh.rides.map(\.trackPoints.count) == [4])
    }

    @Test func aStationaryFixDoesNotBringADeletedRideBack() async {
        // Review 3 of #152: a restart replays the last fix — one more track
        // point, no distance. The delete must stick.
        let dir = tempDir()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RideHistoryStore(directory: dir, now: now)
        let r = ride(start: 999_000, fixes: 3)
        store.record(r, now: now)
        store.delete(r)
        let last = r.trackPoints.last!
        let stationary = r.folding(Fix(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
            altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 90, speed: 0, timestamp: last.timestamp.addingTimeInterval(3))))
        #expect(stationary.trackPoints.count == r.trackPoints.count + 1)
        store.record(stationary, now: now)
        #expect(store.rides.isEmpty)
        let fresh = RideHistoryStore(directory: dir, now: now)
        await fresh.load(now: now)
        #expect(fresh.rides.isEmpty)
    }

    /// A service whose persisted last ride started an hour ago.
    private func serviceWithLastRide(history: RideHistoryStore) -> (RideStatsService, RideStats) {
        let suite = UserDefaults(suiteName: "test.ridehist.\(UUID().uuidString)")!
        let last = ride(start: Date.now.timeIntervalSince1970 - 3600)
        suite.set(try! JSONEncoder().encode(last), forKey: "RideStats.lastRide.v1")
        return (RideStatsService(location: LocationService(), defaults: suite, history: history), last)
    }

    @Test func resetDoesNotResurrectADeletedRestoredRide() async {
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
        await fresh.load()
        #expect(fresh.rides.isEmpty)
    }

    @Test func acknowledgedRestoredSummaryIsStillZeroedByTheNextRide() {
        // Review of #152 (High): closing yesterday's restored panel used to
        // clear `restoredFromDisk`, so today's begin() folded onto
        // yesterday's stats — one merged ride under yesterday's startedAt.
        let (svc, _) = serviceWithLastRide(history: RideHistoryStore(directory: tempDir()))
        #expect(svc.stats.startedAt != nil)
        svc.acknowledgeSummary()
        svc.begin()
        #expect(svc.stats.startedAt == nil)
        #expect(svc.stats.distanceMeters == 0)
    }

    @Test func endBeforeANewBeginDoesNotRewriteTheRestoredRide() async {
        // Link drop during stream warm-up: stopStreaming() → end() runs
        // while `stats` is still the restored summary (no begin() yet).
        let dir = tempDir()
        let history = RideHistoryStore(directory: dir)
        let (svc, _) = serviceWithLastRide(history: history)
        svc.end()
        let fresh = RideHistoryStore(directory: dir)
        await fresh.load()
        #expect(fresh.rides.isEmpty)
    }

    @Test func historyRideConvertsToSavedTrackRoute() {
        let route = RideStatsService.savedRoute(from: ride(start: 999_000, fixes: 3))
        #expect(route?.kind == .track)
        #expect(route?.points.count == 3)
        #expect(RideStatsService.savedRoute(from: RideStats()) == nil)
    }
}
