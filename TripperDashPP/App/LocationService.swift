//
//  LocationService.swift
//  TripperDashPP
//
//  Single source of truth for everything CoreLocation in the app.
//  Replaces the Phase 6 stand-alone `BackgroundLocationKeeper` so the
//  same CLLocationManager serves three concerns simultaneously:
//
//    1. Background wakelock — `allowsBackgroundLocationUpdates = true`
//       on an active subscription keeps the app from being suspended
//       while the screen is locked (this is the only reason Phase 6
//       worked at all).
//    2. Live position feed for the map frame source — `MapViewSource`
//       subscribes via `subscribeFixes` / `subscribeHeading` and re-centres the
//       composited tile on every update.
//    3. Turn-by-turn nav — the active-nav route engine consumes
//       `lastFix` updates to advance maneuver state.
//
//  Owning a single CLLocationManager (instead of one per consumer)
//  matters because:
//    - iOS only renders ONE blue background-location indicator pill;
//      two managers race for it and confuse the user.
//    - Authorization is per-app, not per-manager; multiple managers
//      duplicate prompts in edge cases.
//    - The GPS chip warm-up cost is per-process; sharing is free.
//
//  Required Info.plist keys (already present):
//    - UIBackgroundModes contains "location"
//    - NSLocationWhenInUseUsageDescription
//    - NSLocationAlwaysAndWhenInUseUsageDescription
//

import CoreLocation
import Foundation
import Observation
import os.log

/// Snapshot the map source / nav engine consume. Plain value type so
/// we can hand it to background queues without actor hops.
nonisolated struct Fix: Sendable, Equatable {
    let coordinate: CLLocationCoordinate2D
    let altitude: CLLocationDistance
    let horizontalAccuracy: CLLocationAccuracy
    let speed: CLLocationSpeed         // m/s, -1 if unknown
    let course: CLLocationDirection    // degrees, -1 if unknown
    let timestamp: Date

    init(_ loc: CLLocation) {
        coordinate = loc.coordinate
        altitude = loc.altitude
        horizontalAccuracy = loc.horizontalAccuracy
        speed = loc.speed
        course = loc.course
        timestamp = loc.timestamp
    }

    /// Memberwise init. Was used by the since-removed motion interpolator to
    /// synthesize a display `Fix` at an extrapolated coordinate while carrying
    /// the real GPS-derived speed/course forward; no callers remain.
    init(coordinate: CLLocationCoordinate2D,
         altitude: CLLocationDistance,
         horizontalAccuracy: CLLocationAccuracy,
         speed: CLLocationSpeed,
         course: CLLocationDirection,
         timestamp: Date) {
        self.coordinate = coordinate
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }

    // CLLocationCoordinate2D is a C struct and doesn't conform to
    // Equatable, so we have to write the comparison out by hand.
    static func == (lhs: Fix, rhs: Fix) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.altitude == rhs.altitude &&
        lhs.horizontalAccuracy == rhs.horizontalAccuracy &&
        lhs.speed == rhs.speed &&
        lhs.course == rhs.course &&
        lhs.timestamp == rhs.timestamp
    }
}

/// Heading (true / magnetic north). Phase 5 uses this for the camera
/// bearing so the map rotates with the bike.
nonisolated struct Heading: Sendable, Equatable {
    let trueHeading: CLLocationDirection      // degrees, -1 if invalid
    let magneticHeading: CLLocationDirection  // degrees
    let accuracy: CLLocationDirectionAccuracy // degrees, negative if invalid
    let timestamp: Date

    init(_ h: CLHeading) {
        trueHeading = h.trueHeading
        magneticHeading = h.magneticHeading
        accuracy = h.headingAccuracy
        timestamp = h.timestamp
    }
}

/// Subscribers register a closure that fires on every fresh fix or
/// heading. Returned token cancels the subscription on deinit.
final class LocationSubscription {
    let id: UUID
    private let onCancel: (UUID) -> Void

    init(id: UUID, onCancel: @escaping (UUID) -> Void) {
        self.id = id
        self.onCancel = onCancel
    }

    deinit { onCancel(id) }
}

/// What the consumer wants: just a wakelock, or actual usable fixes.
/// Multiple consumers can call `start(mode:)` and the service picks the
/// highest required accuracy.
enum LocationMode: Int, Comparable {
    case wakelock = 0      // 100 m accuracy, 50 m distance filter — battery-friendly
    case mapping = 1       // best accuracy, no distance filter — for live map / nav

    static func < (lhs: LocationMode, rhs: LocationMode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

@MainActor
@Observable
final class LocationService: NSObject {

    // MARK: - Public observable state

    private(set) var lastFix: Fix?
    private(set) var lastHeading: Heading?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var isRunning = false
    private(set) var currentMode: LocationMode = .wakelock

    // MARK: - Internals

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "LocationService")
    private let manager = CLLocationManager()

    /// Active consumers and the mode each one requires. The service
    /// runs at the highest requested mode and stops only when all
    /// consumers have released.
    private var consumers: [UUID: LocationMode] = [:]

    /// Fix subscribers (map source, ride stats).
    private var fixSubscribers: [UUID: (Fix) -> Void] = [:]
    private var headingSubscribers: [UUID: (Heading) -> Void] = [:]

    override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        // Required since iOS 11: shows the blue status-bar pill while
        // the app uses location in the background. Intentional — it
        // makes the wakelock visible and consent-driven.
        manager.showsBackgroundLocationIndicator = true
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - Public API

    /// Request location authorization from a UI affordance (the permissions
    /// sheet's "Set" button). Escalates one step: undetermined → whenInUse,
    /// whenInUse → always. A no-op once already Always or denied (in the
    /// denied case the user must go to iOS Settings — the sheet links there).
    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Acquire a slot. Returns an opaque token; release it via `stop(token:)`
    /// or just let it deinit. The service auto-picks the highest mode
    /// across all active slots.
    @discardableResult
    func start(mode: LocationMode) -> UUID {
        let token = UUID()
        consumers[token] = mode
        log.info("Consumer \(token.uuidString.prefix(8)) added (mode=\(mode.rawValue), total=\(self.consumers.count))")
        reconcile()
        return token
    }

    func stop(token: UUID) {
        guard consumers.removeValue(forKey: token) != nil else { return }
        log.info("Consumer \(token.uuidString.prefix(8)) removed (remaining=\(self.consumers.count))")
        reconcile()
    }

    /// Subscribe to fresh fixes. Returned subscription cancels on deinit.
    func subscribeFixes(_ handler: @escaping (Fix) -> Void) -> LocationSubscription {
        let id = UUID()
        fixSubscribers[id] = handler
        // Replay last known fix synchronously so the consumer doesn't
        // have to wait for the next GPS tick to draw something.
        if let lastFix { handler(lastFix) }
        return LocationSubscription(id: id) { [weak self] id in
            Task { @MainActor [weak self] in
                self?.fixSubscribers.removeValue(forKey: id)
            }
        }
    }

    func subscribeHeading(_ handler: @escaping (Heading) -> Void) -> LocationSubscription {
        let id = UUID()
        headingSubscribers[id] = handler
        if let lastHeading { handler(lastHeading) }
        return LocationSubscription(id: id) { [weak self] id in
            Task { @MainActor [weak self] in
                self?.headingSubscribers.removeValue(forKey: id)
            }
        }
    }

    // MARK: - Internal state machine

    /// Re-evaluate desired mode and update the underlying manager.
    /// Idempotent: safe to call from any state transition.
    private func reconcile() {
        let desired = consumers.values.max() ?? .wakelock
        let wantRunning = !consumers.isEmpty

        if wantRunning {
            applyMode(desired)
            beginIfNeeded()
        } else {
            stopUpdates()
        }
        currentMode = desired
    }

    private func applyMode(_ mode: LocationMode) {
        switch mode {
        case .wakelock:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
        case .mapping:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = kCLDistanceFilterNone
        }
    }

    private func beginIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            log.info("Requesting whenInUse authorization (will escalate to always)")
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Ask for the Always upgrade, but START ANYWAY. iOS prompts for
            // that upgrade only once; a rider who answers "Keep While Using"
            // is pinned to this status for good. Returning here left
            // `startUpdates()` unreachable, so no fix ever reached
            // MapViewSource and the dash drew a permanently blank map —
            // while routing kept working, because MKDirections
            // `.forCurrentLocation()` uses MapKit's own location, not ours.
            // While Using covers the locked-screen ride too, because
            // updates start in the foreground (see `startUpdates`).
            log.info("Escalating to Always authorization (starting on While Using meanwhile)")
            manager.requestAlwaysAuthorization()
            startUpdates()
        case .authorizedAlways:
            startUpdates()
        case .denied, .restricted:
            log.error("Location authorization denied — wakelock + map source will not work")
        @unknown default:
            log.warning("Unknown CLAuthorizationStatus")
        }
    }

    private func startUpdates() {
        // True on While Using too. Updates are always started from a
        // foreground user action (connect / start ride), and a While Using
        // app that started them in the foreground with this flag set keeps
        // receiving them in the background, with the blue indicator pill
        // (WWDC19 "What's New in Core Location"; Apple's
        // "Choosing the Location Services Authorization to Request").
        // The only documented fatal error is setting it without `location`
        // in UIBackgroundModes, which Info.plist has. An earlier comment
        // here claimed it throws on While Using; nothing backed that, and
        // gating on Always made the dash drop 2-3 min after the phone
        // locked for every While Using rider. Always is still what lets
        // iOS relaunch us in the background; While Using is enough to ride.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 2 // degrees
            manager.startUpdatingHeading()
        }
        if !isRunning {
            log.info("LocationService started (mode=\(self.currentMode.rawValue))")
        }
        isRunning = true
    }

    private func stopUpdates() {
        guard isRunning else { return }
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
        log.info("LocationService stopped (no consumers)")
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            self.log.info("Authorization changed → \(status.rawValue)")
            switch status {
            case .authorizedWhenInUse:
                self.manager.requestAlwaysAuthorization()
                if !self.consumers.isEmpty { self.startUpdates() }
            case .authorizedAlways:
                // Unconditional (when wanted): `startUpdates` is idempotent.
                // No `!isRunning` guard: a status change while running must
                // still re-apply the manager config, and skipping it here
                // is the kind of silent gap #133 was about.
                if !self.consumers.isEmpty { self.startUpdates() }
            case .denied, .restricted:
                self.isRunning = false
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.log.warning("CLLocationManager error: \(error.localizedDescription)")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let fix = Fix(latest)
        Task { @MainActor in
            self.lastFix = fix
            for handler in self.fixSubscribers.values { handler(fix) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = Heading(newHeading)
        Task { @MainActor in
            self.lastHeading = h
            for handler in self.headingSubscribers.values { handler(h) }
        }
    }
}
