//
//  RideStats.swift
//  TripperDashPP
//
//  GPS-only ride trip computer — the pure accumulator half.
//
//  Folds each accepted CoreLocation `Fix` into running ride totals:
//  distance ridden, moving time, max speed, average (moving) speed, and
//  elevation gain. No sensor beyond GPS, no I/O, no actor — a `Sendable`
//  value type so it crosses actor hops cleanly and is fully unit-tested
//  in `RideStatsTests` (native `TripperDashPPTests` target).
//
//  Accumulation rules (each has a matching test; tunables are pinned by
//  `tunablesAreTheReviewedValues`):
//
//    1. Distance   — great-circle sum between consecutive accepted fixes.
//    2. Fix gating — reject accuracy < 0 or > 50 m, non-monotonic time,
//                    sub-3 m jitter steps (0 distance), and teleport
//                    glitches (implied speed > 90 m/s → skip distance,
//                    still advance the clock).
//    3. Moving time — sum of dt while max(gpsSpeed, d/dt) ≥ 0.7 m/s, each
//                    dt capped at 10 s (a longer gap = signal loss).
//    4. Max speed  — max Doppler GPS speed (ignores -1 unknown).
//    5. Avg speed  — distance / movingSeconds (moving average).
//    6. Elevation  — positive altitude deltas with a 2 m hysteresis so
//                    GPS altitude noise doesn't inflate the climb. GPS
//                    altitude is coarse → the UI labels this "approx."
//    7. Elapsed    — lastFixAt − startedAt (wall clock), for a total.
//
//  Distance under-reads a bike odometer (chord not arc, sub-3 m jitter
//  dropped) — acceptable for a ride summary, not a certified odometer.
//

import CoreLocation
import Foundation

/// Pure, `Sendable` ride accumulator. Fold each accepted `Fix` in with
/// `folding(_:)`; every derived stat is a stored/computed property. No
/// actor, no I/O — unit-tested in `RideStatsTests`.
struct RideStats: Sendable, Equatable, Codable {

    /// One recorded point of the live ride track — the raw material a
    /// GPX `<trkpt>` is serialised from (`GPXExporter`). Captured for
    /// every GATE-PASSING fix (accuracy + monotonic-time), i.e. the same
    /// fixes the totals fold, so the exported trace matches the on-screen
    /// distance. Jitter-floor / teleport fixes are still recorded — a GPX
    /// track is the raw path, not the distance-gated subset — but bad-
    /// accuracy / out-of-order fixes never enter either the totals or the
    /// track. Plain `Codable` value so `RideStats` stays `Sendable`.
    struct TrackPoint: Sendable, Equatable, Codable {
        let latitude: Double
        let longitude: Double
        let altitude: Double          // metres, GPS ellipsoidal (coarse)
        let timestamp: Date
        let speedMps: Double          // Doppler GPS speed, -1 if unknown
    }

    // Running totals
    private(set) var distanceMeters: Double = 0
    private(set) var movingSeconds: Double = 0
    private(set) var maxSpeedMps: Double = 0
    private(set) var elevationGainMeters: Double = 0
    private(set) var acceptedFixCount: Int = 0
    private(set) var startedAt: Date?
    private(set) var lastFixAt: Date?

    /// Ordered recorded track — one entry per gate-passing fix. Feeds the
    /// GPX export (`GPXExporter.gpx(from:)`). In-memory only, like the
    /// rest of `RideStats`: an app kill or `reset()` drops it.
    private(set) var trackPoints: [TrackPoint] = []

    // Bookkeeping for the next fold (not part of the public readout)
    private var lastLat: Double?
    private var lastLon: Double?
    private var lastAlt: Double?
    private var ascentBuffer: Double = 0   // cumulative rise since last counted

    // Tunables (also asserted by a drift-guard test)
    static let accuracyGateMeters = 50.0
    static let jitterFloorMeters = 3.0
    static let teleportSpeedMps = 90.0
    static let movingThresholdMps = 0.7
    static let maxStepSeconds = 10.0
    static let ascentHysteresisMeters = 2.0

    /// Wall-clock ride duration (independent of moving time). 0 until a
    /// second accepted fix gives us a span.
    var elapsedSeconds: Double {
        guard let start = startedAt, let last = lastFixAt else { return 0 }
        return max(0, last.timeIntervalSince(start))
    }

    var averageSpeedMps: Double {
        movingSeconds > 0 ? distanceMeters / movingSeconds : 0
    }

    /// Return a new accumulator with `fix` folded in. Rejected fixes
    /// return a copy that may still advance time/last-seen bookkeeping.
    func folding(_ fix: Fix) -> RideStats {
        var s = self

        // Accuracy gate.
        guard fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= Self.accuracyGateMeters else { return s }

        // Monotonic time gate.
        if let last = s.lastFixAt, fix.timestamp <= last { return s }

        // Max speed (Doppler GPS speed, ignore unknown).
        if fix.speed >= 0 { s.maxSpeedMps = max(s.maxSpeedMps, fix.speed) }

        // Seed on the first accepted fix (no previous point → no deltas
        // yet). Explicit seed block instead of a defer so the control
        // flow reads straight through.
        guard let plat = s.lastLat, let plon = s.lastLon,
              let plastT = s.lastFixAt else {
            s.lastLat = fix.coordinate.latitude
            s.lastLon = fix.coordinate.longitude
            s.lastAlt = fix.altitude
            s.lastFixAt = fix.timestamp
            s.acceptedFixCount += 1
            s.startedAt = fix.timestamp
            s.recordTrackPoint(fix)
            return s
        }

        let dt = fix.timestamp.timeIntervalSince(plastT)
        guard dt > 0 else { return s }

        let d = Self.haversine(plat, plon,
                               fix.coordinate.latitude, fix.coordinate.longitude)

        // Teleport glitch guard.
        let impliedSpeed = d / dt
        let glitch = impliedSpeed > Self.teleportSpeedMps

        // Distance (jitter floor + glitch guard).
        if !glitch, d >= Self.jitterFloorMeters {
            s.distanceMeters += d
        }

        // Moving time. A teleport glitch's implied speed is bogus, so we
        // drop it and fall back to the (possibly unknown) Doppler speed —
        // a glitch must never fabricate moving time.
        let effectiveSpeed = max(fix.speed, glitch ? 0 : impliedSpeed)
        if effectiveSpeed >= Self.movingThresholdMps {
            s.movingSeconds += min(dt, Self.maxStepSeconds)
        }

        // Elevation gain with hysteresis.
        let rise = fix.altitude - (s.lastAlt ?? fix.altitude)
        if rise > 0 {
            s.ascentBuffer += rise
            if s.ascentBuffer >= Self.ascentHysteresisMeters {
                s.elevationGainMeters += s.ascentBuffer
                s.ascentBuffer = 0
            }
        } else if rise < 0 {
            s.ascentBuffer = 0 // reset on descent; a flat fix holds it
        }

        // Advance bookkeeping.
        s.lastLat = fix.coordinate.latitude
        s.lastLon = fix.coordinate.longitude
        s.lastAlt = fix.altitude
        s.lastFixAt = fix.timestamp
        s.acceptedFixCount += 1
        s.recordTrackPoint(fix)

        return s
    }

    /// Append a gate-passing fix to the recorded track. Called from
    /// `folding(_:)` AFTER the accuracy + monotonic-time gates (and only
    /// for fixes that seed or advance the accumulator), so the track never
    /// contains a bad-accuracy or out-of-order point. Deliberately keeps
    /// jitter-floor / teleport fixes: those are dropped from the DISTANCE
    /// total (chord noise / GPS glitch) but a raw GPX trace still wants the
    /// point — a rider stopped at lights should show as a dense cluster,
    /// not a gap, and one teleport spike is better carried and smoothed by
    /// a downstream tool than silently swallowed.
    private mutating func recordTrackPoint(_ fix: Fix) {
        trackPoints.append(TrackPoint(
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            altitude: fix.altitude,
            timestamp: fix.timestamp,
            speedMps: fix.speed
        ))
    }

    /// Great-circle metres. Private copy so the accumulator has no
    /// dependency on the renderer/actor (mirrors WeatherAlertService).
    private static func haversine(_ lat1: Double, _ lon1: Double,
                                  _ lat2: Double, _ lon2: Double) -> Double {
        let R = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2)
            + cos(lat1 * .pi/180) * cos(lat2 * .pi/180) * sin(dLon/2) * sin(dLon/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
