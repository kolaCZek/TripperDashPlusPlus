//
//  MotionInterpolator.swift
//  TripperDashPP
//
//  Smooths the rider marker's motion between GPS fixes.
//
//  THE PROBLEM
//  CoreLocation delivers fixes at ~1 Hz (best accuracy, no distance filter),
//  but the dash render loop runs at a fixed 6 fps. Feeding the raw fix straight
//  to the renderer means the marker sits still for ~6 frames, then jumps to the
//  next fix — visible "hopping" the rider called out.
//
//  THE APPROACH (dead reckoning + soft correction)
//  Keep a *display* position separate from the last GPS position:
//
//   1. EXTRAPOLATE every render tick: advance the display coordinate along the
//      current velocity vector. Crucially the speed is NOT held constant — we
//      estimate acceleration from the last two fixes and step with
//      v(t) = v0 + a·t (clamped ≥ 0). Constant-speed dead reckoning overshoots
//      under braking (marker runs ahead of the rider) and lags under sustained
//      acceleration (marker trails); carrying acceleration keeps the marker on
//      the rider through both.
//   2. SOFT-CORRECT on each new fix: don't snap. Measure the gap between where
//      we'd extrapolated to and the real fix, then dissolve that error over a
//      short window (exponential lerp) while adopting the fix's fresh speed,
//      course, and a re-estimated acceleration. Real position catches the map
//      up smoothly instead of teleporting.
//
//  GUARDS
//   • Stationary (speed below `minMovingSpeedMPS`) → freeze, no drift, so a
//     parked bike's marker doesn't wander on GPS jitter.
//   • Stale fixes (no update for `maxExtrapolationS`) → stop extrapolating and
//     hold, so a tunnel / signal loss can't fling the marker off into nowhere.
//   • Unknown speed/course (-1 from CoreLocation) → treated as stationary.
//
//  This type is pure geometry (no CoreLocation callbacks, no actor state) so it
//  unit-tests deterministically: feed it fixes + tick timestamps, assert the
//  emitted coordinate.
//

import CoreLocation
import Foundation

/// Deterministic dead-reckoning smoother. Not thread-safe by itself; callers
/// (MapViewSource) drive it entirely on the main actor.
struct MotionInterpolator {

    // MARK: - Tunables

    /// Below this speed the rider is treated as stopped: the display position
    /// freezes on the last fix and does not drift. ~1.8 km/h.
    var minMovingSpeedMPS: CLLocationSpeed = 0.5

    /// Hard cap on how long we'll keep extrapolating forward without a fresh
    /// fix. Past this the marker holds its last extrapolated spot rather than
    /// sailing off on a stale velocity (tunnel, urban canyon, signal loss).
    var maxExtrapolationS: TimeInterval = 3.0

    /// Time constant for dissolving the correction error when a new fix lands.
    /// Smaller = snappier correction (closer to a hard snap); larger = smoother
    /// but laggier. 0.5 s converges ~95% in ~1.5 s at 6 fps.
    var correctionTimeConstantS: TimeInterval = 0.5

    /// Clamp on the acceleration estimated between two fixes (m/s²). Bounds the
    /// damage a noisy GPS speed pair can do: a spurious speed spike can't fling
    /// the marker. ~4 m/s² brackets hard braking / brisk acceleration on a bike
    /// without letting jitter dominate.
    var maxAccelMPS2: Double = 4.0

    // MARK: - State

    /// The coordinate we are currently displaying (extrapolated + corrected).
    private(set) var displayCoordinate: CLLocationCoordinate2D?

    /// The last *real* GPS fix we received.
    private var lastFix: Fix?

    /// Velocity we're currently dead-reckoning along, derived from the last
    /// fix's speed + course. Zeroed when stationary / unknown.
    private var speedMPS: CLLocationSpeed = 0
    private var courseDeg: CLLocationDirection = -1

    /// Acceleration estimate (m/s²) along the direction of travel, from the
    /// delta between the last two fixes' speeds. Positive = speeding up,
    /// negative = braking. Applied as v(t) = v0 + a·t during extrapolation so
    /// the marker tracks the rider through accel/decel instead of over/under-
    /// shooting on a stale constant speed.
    private var accelMPS2: Double = 0

    /// Wall-clock time the display position was last advanced.
    private var lastTickTime: Date?

    // MARK: - Route following

    /// The active route polyline (as coordinates) we snap motion onto, or nil
    /// when free-navigating without a route. When set and the rider is close to
    /// it, extrapolation walks ALONG the polyline by arc length instead of in a
    /// straight velocity-vector line — so the marker follows the road through
    /// curves instead of cutting the chord and snapping back.
    private var routeCoords: [CLLocationCoordinate2D]?

    /// Cumulative arc-length (m) at each route vertex; `routeCumM[i]` is the
    /// distance from the route start to `routeCoords[i]`. Precomputed on
    /// `setRoute` so per-tick walking is cheap.
    private var routeCumM: [Double] = []

    /// How far (m) the display marker is along the route, when route-following.
    private var routeProgressM: Double = 0

    /// Max perpendicular distance (m) from the route within which we consider
    /// the rider "on route" and follow the polyline. Beyond it (detour, GPS off
    /// in a tunnel, off-route) we fall back to free velocity-vector extrapolation.
    var onRouteThresholdM: CLLocationDistance = 30

    /// To LEAVE route-following the rider must be beyond `offRouteThresholdM`
    /// (wider than `onRouteThresholdM` — hysteresis so the decision doesn't
    /// chatter at the boundary) for `offRouteConfirmFixes` consecutive fixes.
    /// This stops a single wide GPS sample from unlatching route-follow, while
    /// still releasing promptly when the rider genuinely turns off the route
    /// (wrong turn, detour) instead of magnetising the marker onto the old line.
    var offRouteThresholdM: CLLocationDistance = 50
    var offRouteConfirmFixes: Int = 3

    /// Whether we're currently following the route polyline. Latches on when a
    /// fix lands within `onRouteThresholdM`; latches off after
    /// `offRouteConfirmFixes` fixes beyond `offRouteThresholdM`.
    private(set) var isFollowingRoute = false

    /// Count of consecutive fixes seen beyond `offRouteThresholdM`.
    private var offRouteStreak = 0

    /// Install (or clear, with nil) the route the marker should follow. Pass the
    /// same ordered coordinate list the renderer draws. Resets progress; the
    /// next fix re-projects onto it.
    mutating func setRoute(_ coords: [CLLocationCoordinate2D]?) {
        guard let coords, coords.count >= 2 else {
            routeCoords = nil
            routeCumM = []
            return
        }
        routeCoords = coords
        var cum: [Double] = [0]
        cum.reserveCapacity(coords.count)
        for i in 1..<coords.count {
            cum.append(cum[i - 1] + Self.haversine(coords[i - 1], coords[i]))
        }
        routeCumM = cum
    }

    // MARK: - Ingest

    /// Feed a fresh GPS fix. Does not itself move the display position — the
    /// next `tick(now:)` blends toward it. Returns immediately.
    mutating func ingest(fix: Fix) {
        // Seed on first fix: nothing to blend from, so display == fix.
        if displayCoordinate == nil {
            displayCoordinate = fix.coordinate
            lastTickTime = fix.timestamp
        }

        let moving = fix.speed >= minMovingSpeedMPS && fix.course >= 0

        // Estimate acceleration from the speed delta between the previous fix
        // and this one. Only meaningful when both carry a valid speed and are
        // separated in time; otherwise decay to zero (constant-speed fallback).
        if let prev = lastFix,
           prev.speed >= 0, fix.speed >= 0 {
            let dtFix = fix.timestamp.timeIntervalSince(prev.timestamp)
            if dtFix > 0.05 {
                let a = (fix.speed - prev.speed) / dtFix
                accelMPS2 = min(maxAccelMPS2, max(-maxAccelMPS2, a))
            }
        } else {
            accelMPS2 = 0
        }
        if !moving { accelMPS2 = 0 }

        lastFix = fix
        speedMPS = moving ? fix.speed : 0
        courseDeg = moving ? fix.course : -1

        updateRouteFollowing(for: fix)
    }

    /// Decide whether we're on the route and, when we are, re-anchor arc-length
    /// progress to the fix's projection. Hysteresis (on vs off thresholds) plus
    /// a confirm streak keep the latch from chattering on GPS noise, yet release
    /// promptly when the rider genuinely leaves the route.
    private mutating func updateRouteFollowing(for fix: Fix) {
        guard let route = routeCoords, route.count >= 2 else {
            isFollowingRoute = false
            offRouteStreak = 0
            return
        }
        let proj = Self.project(fix.coordinate, onto: route, cumM: routeCumM)

        if isFollowingRoute {
            // Latch OFF only after sustained, clearly-off samples.
            if proj.perpM > offRouteThresholdM {
                offRouteStreak += 1
                if offRouteStreak >= offRouteConfirmFixes {
                    isFollowingRoute = false
                    offRouteStreak = 0
                }
            } else {
                offRouteStreak = 0
                // Re-anchor progress to the real fix so drift can't accumulate;
                // never walk backward (monotone forward progress on the route).
                routeProgressM = max(routeProgressM, proj.arcM)
            }
        } else {
            // Latch ON as soon as a fix lands close to the route.
            if proj.perpM <= onRouteThresholdM {
                isFollowingRoute = true
                offRouteStreak = 0
                routeProgressM = proj.arcM
            }
        }
    }

    // MARK: - Tick

    /// Advance and return the display coordinate for a render tick at `now`.
    /// Combines extrapolation along the velocity vector with an exponential
    /// pull toward the true last fix so accumulated dead-reckoning error is
    /// continuously bled off. Returns nil only before the very first fix.
    mutating func tick(now: Date) -> CLLocationCoordinate2D? {
        guard let fix = lastFix, var display = displayCoordinate else {
            return displayCoordinate
        }
        let prevTick = lastTickTime ?? now
        let dt = max(0, now.timeIntervalSince(prevTick))
        lastTickTime = now

        let fixAge = now.timeIntervalSince(fix.timestamp)
        let extrapolating = speedMPS > 0 && fixAge <= maxExtrapolationS

        // ROUTE-FOLLOWING PATH: walk along the polyline by arc length so the
        // marker tracks the road through curves instead of cutting the chord.
        // Only while genuinely on-route (see updateRouteFollowing hysteresis);
        // a real detour drops us to the free velocity path below.
        if isFollowingRoute, let route = routeCoords, !routeCumM.isEmpty {
            if extrapolating, dt > 0 {
                let vMid = Self.speedAt(fixAge - dt / 2, v0: speedMPS, accel: accelMPS2)
                routeProgressM += max(0, vMid * dt)
            }
            let onLine = Self.point(atArcLength: routeProgressM, along: route, cumM: routeCumM)
            // Ease onto the polyline point (bleeds any residual offset without
            // a visible snap).
            if dt > 0 {
                let alpha = 1 - exp(-dt / max(0.0001, correctionTimeConstantS))
                display = Self.lerp(display, onLine.coordinate, alpha)
            } else {
                display = onLine.coordinate
            }
            // Course comes from the polyline tangent while route-following.
            if onLine.courseDeg >= 0 { courseDeg = onLine.courseDeg }
            displayCoordinate = display
            return display
        }

        // FREE PATH (no route, or off-route): straight velocity-vector dead
        // reckoning with soft correction toward the live fix.
        // 1. Extrapolate: step the display coordinate forward. Distance over
        //    this tick is the integral of v(t) = v0 + a·t across [tickStart,
        //    tickStart+dt], where tickStart is measured from the fix. Using the
        //    speed at the tick's midpoint keeps braking/accelerating honest
        //    (constant-speed stepping would over/undershoot).
        if extrapolating, dt > 0 {
            let vMid = Self.speedAt(fixAge - dt / 2, v0: speedMPS, accel: accelMPS2)
            if vMid > 0 {
                display = Self.offset(display,
                                      distanceMeters: vMid * dt,
                                      courseDeg: courseDeg)
            }
        }

        // 2. Soft-correct toward the truth: where the rider actually is now,
        //    i.e. the fix advanced forward by its own age under the same
        //    v(t) = v0 + a·t model (chase the live position, not a stale sample).
        let truth: CLLocationCoordinate2D
        if extrapolating {
            let dist = Self.distance(overSeconds: fixAge, v0: speedMPS, accel: accelMPS2)
            truth = Self.offset(fix.coordinate,
                                distanceMeters: dist,
                                courseDeg: courseDeg)
        } else {
            truth = fix.coordinate
        }

        // Exponential blend: alpha = 1 - e^(-dt / tau). Frame-rate independent.
        if dt > 0 {
            let alpha = 1 - exp(-dt / max(0.0001, correctionTimeConstantS))
            display = Self.lerp(display, truth, alpha)
        } else if !extrapolating {
            display = truth
        }

        displayCoordinate = display
        return display
    }

    /// Reset all state (e.g. link restart / navigation stopped).
    mutating func reset() {
        displayCoordinate = nil
        lastFix = nil
        speedMPS = 0
        courseDeg = -1
        lastTickTime = nil
    }

    // MARK: - Kinematics helpers (pure, static)

    /// Speed (m/s) at time `t` seconds after the fix under v(t) = v0 + a·t,
    /// clamped to ≥ 0 so a decelerating extrapolation coasts to a stop rather
    /// than reversing.
    static func speedAt(_ t: TimeInterval, v0: Double, accel: Double) -> Double {
        max(0, v0 + accel * t)
    }

    /// Distance (m) travelled over `[0, seconds]` under v(t) = v0 + a·t. When
    /// the body decelerates to a stop within the window, integrate only up to
    /// the stop time (no negative-speed contribution).
    static func distance(overSeconds seconds: TimeInterval, v0: Double, accel: Double) -> Double {
        guard seconds > 0 else { return 0 }
        if accel < 0 {
            // Time to reach v = 0.
            let tStop = v0 / -accel
            let t = min(seconds, tStop)
            return v0 * t + 0.5 * accel * t * t
        }
        return v0 * seconds + 0.5 * accel * seconds * seconds
    }

    // MARK: - Geometry helpers (pure, static)

    /// Offset a coordinate by `distanceMeters` along a compass `courseDeg`
    /// (0 = north, 90 = east). Equirectangular approximation — fine for the
    /// sub-30 m steps between 6 fps ticks at road speeds.
    static func offset(_ c: CLLocationCoordinate2D,
                       distanceMeters d: CLLocationDistance,
                       courseDeg: CLLocationDirection) -> CLLocationCoordinate2D {
        guard d != 0, courseDeg >= 0 else { return c }
        let rad = courseDeg * .pi / 180
        let dNorth = d * cos(rad)   // metres north
        let dEast = d * sin(rad)    // metres east
        let dLat = dNorth / 111_111.0
        let cosLat = cos(c.latitude * .pi / 180)
        let dLon = dEast / (111_111.0 * max(0.000001, cosLat))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat,
                                      longitude: c.longitude + dLon)
    }

    /// Linear interpolate between two coordinates. `t` in [0, 1].
    static func lerp(_ a: CLLocationCoordinate2D,
                     _ b: CLLocationCoordinate2D,
                     _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Great-circle distance (m) between two coordinates.
    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let R = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let la1 = a.latitude * .pi / 180
        let la2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(min(1, sqrt(h)))
    }

    // MARK: - Route geometry (pure, static)

    /// Project `p` onto a polyline: returns the perpendicular distance (m) to
    /// the nearest segment and the arc length (m from route start) of that
    /// nearest point. Uses a local equirectangular metre frame per segment —
    /// accurate over the short segments of a decimated route polyline.
    static func project(_ p: CLLocationCoordinate2D,
                        onto route: [CLLocationCoordinate2D],
                        cumM: [Double]) -> (perpM: Double, arcM: Double) {
        guard route.count >= 2, cumM.count == route.count else {
            return (.greatestFiniteMagnitude, 0)
        }
        let mPerDegLat = 111_111.0
        var bestPerp = Double.greatestFiniteMagnitude
        var bestArc = 0.0
        for i in 0..<(route.count - 1) {
            let a = route[i], b = route[i + 1]
            let cosLat = cos(a.latitude * .pi / 180)
            // Local metre coordinates relative to segment start `a`.
            let ax = 0.0, ay = 0.0
            let bx = (b.longitude - a.longitude) * mPerDegLat * cosLat
            let by = (b.latitude - a.latitude) * mPerDegLat
            let px = (p.longitude - a.longitude) * mPerDegLat * cosLat
            let py = (p.latitude - a.latitude) * mPerDegLat
            let abx = bx - ax, aby = by - ay
            let segLen2 = abx * abx + aby * aby
            var t = 0.0
            if segLen2 > 0 { t = ((px - ax) * abx + (py - ay) * aby) / segLen2 }
            t = min(1, max(0, t))
            let projx = ax + t * abx, projy = ay + t * aby
            let dx = px - projx, dy = py - projy
            let perp = sqrt(dx * dx + dy * dy)
            if perp < bestPerp {
                bestPerp = perp
                let segLen = cumM[i + 1] - cumM[i]
                bestArc = cumM[i] + t * segLen
            }
        }
        return (bestPerp, bestArc)
    }

    /// The coordinate at `arcLength` metres along the polyline, plus the
    /// tangent course (compass degrees) of the segment it falls on. Clamped to
    /// the route ends.
    static func point(atArcLength arcLength: Double,
                      along route: [CLLocationCoordinate2D],
                      cumM: [Double]) -> (coordinate: CLLocationCoordinate2D, courseDeg: CLLocationDirection) {
        guard route.count >= 2, cumM.count == route.count else {
            return (route.first ?? CLLocationCoordinate2D(), -1)
        }
        let total = cumM[cumM.count - 1]
        let s = min(max(0, arcLength), total)
        // Find the segment containing `s` (linear scan; routes are modest).
        var i = 0
        while i < route.count - 2 && cumM[i + 1] < s { i += 1 }
        let a = route[i], b = route[i + 1]
        let segLen = max(0.000001, cumM[i + 1] - cumM[i])
        let t = min(1, max(0, (s - cumM[i]) / segLen))
        let coord = lerp(a, b, t)
        let course = bearing(from: a, to: b)
        return (coord, course)
    }

    /// Initial great-circle bearing (compass degrees, 0 = north) from `a` to `b`.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        let brng = atan2(y, x) * 180 / .pi
        return (brng + 360).truncatingRemainder(dividingBy: 360)
    }
}
