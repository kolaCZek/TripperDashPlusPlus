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
//    2. Live position feed for the Phase 5 Mapbox snapshotter — the
//       map source subscribes to `lastLocation` / `lastHeading` and
//       re-centres the camera on every update.
//    3. Future Phase 7 turn-by-turn nav — the route engine will also
//       consume `lastLocation` updates to advance maneuver state.
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
struct Fix: Sendable, Equatable {
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
struct Heading: Sendable, Equatable {
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

    /// Fix subscribers (map source, nav engine, telemetry).
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
            log.info("Escalating to Always authorization")
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            startUpdates()
        case .denied, .restricted:
            log.error("Location authorization denied — wakelock + map source will not work")
        @unknown default:
            log.warning("Unknown CLAuthorizationStatus")
        }
    }

    private func startUpdates() {
        // `allowsBackgroundLocationUpdates` MUST be set AFTER auth is
        // Always; setting it before throws at runtime.
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
            case .authorizedAlways:
                if !self.isRunning && !self.consumers.isEmpty { self.startUpdates() }
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
