//
//  SpeedCameraAnnouncer.swift
//  TripperDashPP
//
//  feat/speed-camera-voice-alert — decides WHEN to speak a proximity
//  warning for an approaching speed camera.
//
//  Pure decision logic, isolated from both the synthesizer
//  (`VoiceNavigator`) and the phrase templates (`VoicePhrase`) so it is
//  unit-testable on Linux with no AVFoundation / CoreLocation actor
//  dependencies, exactly like `VoicePromptScheduler`. The caller feeds it
//  the rider's plain lat/lon/heading and a list of cameras each tick; it
//  answers with the camera to announce, or nil.
//
//  ── The problem it solves ─────────────────────────────────────────────
//
//  `SpeedCameraService` fetches cameras and `MapViewSource` draws them, but
//  nothing ever SPOKE the callout — `VoicePhrase.speedCamera(_)` existed
//  yet was only reachable from a unit test. During a ride the rider passed
//  a camera in silence. This announcer closes that gap: it fires the
//  spoken warning ONCE per camera when the rider enters the warning radius
//  AND the camera is genuinely ahead (not one already passed, sitting
//  behind the rider), then never repeats it for that camera.
//
//  ── Firing rules ─────────────────────────────────────────────────────
//
//   1. Proximity — the camera must be within `warnRadiusMeters` (default
//      400 m). Beyond that it is silent.
//   2. Ahead, not behind — the bearing from the rider to the camera must
//      be within `aheadHalfAngleDegrees` of the rider's heading. A camera
//      the rider has already passed sits behind them (bearing ~180° off
//      heading) and must NOT chime. When the heading is unknown (course
//      < 0, e.g. stationary), we skip the ahead-check and fall back to
//      pure proximity so a cold start near a camera still warns.
//   3. Once per camera — each camera id fires at most once. Tracked in a
//      fired-id set, cleared on `reset()` (nav stop / reroute) so a new
//      ride (or a re-ride of the same road) warns afresh.
//
//  All thresholds are plain constants; if they ever need to be
//  user-tunable they move to `DashNavSettings`, same discipline as
//  `VoicePromptScheduler`.
//

import Foundation

/// Pure, value-type announcer. One instance per active-nav session; the
/// caller feeds it the rider fix + cameras each tick and it returns the
/// camera to announce or nil.
///
/// Geometry is done in plain Double lat/lon so the whole type is testable
/// off-device — no `CLLocationCoordinate2D`, no CoreLocation. The caller
/// (`ActiveNavLoop`) adapts its `Fix` / `SpeedCamera` values into these
/// primitives.
struct SpeedCameraAnnouncer {

    /// A camera reduced to the primitives this decider needs. The caller
    /// maps `SpeedCamera` → this so the announcer stays CoreLocation-free.
    struct Target: Equatable {
        let id: Int64
        let latitude: Double
        let longitude: Double
    }

    /// Warn when a camera is at most this far ahead. 400 m gives a rider at
    /// 90 km/h (25 m/s) ~16 s of notice — enough to check the speedo, short
    /// enough that the callout is about THIS camera, not one two junctions
    /// away.
    static let warnRadiusMeters: Double = 400

    /// Half-angle (degrees) of the "ahead" cone around the rider's heading.
    /// 75° each side (150° total) treats anything roughly in front as
    /// ahead while rejecting a camera squarely behind (bearing ~180° off).
    /// Generous because GPS heading is noisy at low speed and cameras just
    /// off a curve should still warn.
    static let aheadHalfAngleDegrees: Double = 75

    /// Cameras already announced this session. A camera fires once; re-riding
    /// the same road only re-warns after a `reset()`.
    private var firedIDs: Set<Int64> = []

    init() {}

    /// Feed one tick. Returns the camera to announce, or nil.
    ///
    /// - Parameters:
    ///   - riderLat/riderLon: current GPS fix.
    ///   - headingDegrees: rider course over ground in degrees (0 = north,
    ///     clockwise). Pass a negative value when unknown (CoreLocation
    ///     reports -1 for a stationary fix); the ahead-check is then skipped
    ///     and proximity alone decides.
    ///   - cameras: the cameras currently loaded for the route.
    ///
    /// When several cameras qualify on the same tick, the NEAREST is chosen
    /// so the most imminent hazard is spoken first; the others will fire on
    /// subsequent ticks as they become the nearest un-fired one.
    mutating func onTick(riderLat: Double,
                         riderLon: Double,
                         headingDegrees: Double,
                         cameras: [Target]) -> Target? {
        guard riderLat.isFinite, riderLon.isFinite else { return nil }

        let headingKnown = headingDegrees.isFinite && headingDegrees >= 0

        var best: Target?
        var bestDistance = Double.infinity

        for cam in cameras {
            if firedIDs.contains(cam.id) { continue }
            let d = Self.haversineMeters(lat1: riderLat, lon1: riderLon,
                                         lat2: cam.latitude, lon2: cam.longitude)
            guard d.isFinite, d <= Self.warnRadiusMeters else { continue }

            if headingKnown {
                let bearing = Self.bearingDegrees(lat1: riderLat, lon1: riderLon,
                                                  lat2: cam.latitude, lon2: cam.longitude)
                let delta = Self.angularDifference(headingDegrees, bearing)
                if delta > Self.aheadHalfAngleDegrees { continue }
            }

            if d < bestDistance {
                bestDistance = d
                best = cam
            }
        }

        if let best {
            firedIDs.insert(best.id)
        }
        return best
    }

    /// Forget all announced cameras (e.g. nav stopped or rerouted). Next
    /// tick starts fresh so the same road can warn again.
    mutating func reset() {
        firedIDs.removeAll(keepingCapacity: true)
    }

    // MARK: - Geometry (pure, testable)

    /// Great-circle distance in metres between two lat/lon points.
    static func haversineMeters(lat1: Double, lon1: Double,
                                lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }

    /// Initial bearing (degrees, 0 = north, clockwise) from point 1 to
    /// point 2 — the compass direction the rider must face to reach the
    /// camera.
    static func bearingDegrees(lat1: Double, lon1: Double,
                               lat2: Double, lon2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let y = sin(dLon) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smallest absolute difference between two compass bearings, in
    /// [0, 180]. Handles the 350°↔10° wrap.
    static func angularDifference(_ a: Double, _ b: Double) -> Double {
        var diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff
    }
}
