//
//  BackgroundLocationKeeper.swift
//  TripperDashPP
//
//  Phase 6 — keep the app alive while the iPhone screen is off.
//
//  iOS suspends foreground apps within ~3–10 seconds after the screen
//  locks. When that happens the VTCompressionSession loses GPU access
//  and every subsequent `VTCompressionSessionEncodeFrame` returns
//  `kVTInvalidSessionErr` (-12903). The dash sees the RTP stream go
//  silent and falls back to the loading-dots placeholder within a few
//  hundred milliseconds.
//
//  The standard iOS workaround is to claim a **background execution
//  mode** that the system honours indefinitely. CoreLocation with the
//  `location` UIBackgroundMode + `Always` authorization keeps the app
//  scheduled forever as long as the location manager is actively
//  updating — this is exactly the pattern Strava, Komoot, RWGPS use.
//
//  Pair this with `SilentAudioKeeper` (audio background mode) as a
//  fallback for environments where GPS may briefly drop (tunnels,
//  garages); together they cover virtually every real-world ride.
//
//  Required Info.plist keys (already present in TripperDashPP-Info.plist):
//    - UIBackgroundModes contains "location"
//    - NSLocationWhenInUseUsageDescription
//    - NSLocationAlwaysAndWhenInUseUsageDescription
//

import CoreLocation
import Foundation
import os.log

@MainActor
final class BackgroundLocationKeeper: NSObject {

    private let log = Logger(subsystem: "TripperDashPP", category: "BgLocation")
    private let manager = CLLocationManager()
    private(set) var isRunning = false

    override init() {
        super.init()
        manager.delegate = self
        // We do NOT need precise GPS for the wakelock — any active
        // location subscription keeps the app scheduled. Hundred-metre
        // accuracy minimises battery cost and avoids fighting Mapbox
        // for the GPS chip when navigation is also active.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50    // metres
        manager.pausesLocationUpdatesAutomatically = false
        // Required since iOS 11: shows the blue status-bar pill while
        // the app is using location in the background. The user will
        // see this and that's intentional — it makes the wakelock
        // visible and consent-driven.
        manager.showsBackgroundLocationIndicator = true
    }

    // MARK: - Lifecycle

    /// Start the background-keep-alive. Idempotent.
    func start() {
        guard !isRunning else { return }

        switch manager.authorizationStatus {
        case .notDetermined:
            // First-time launch: ask for While-In-Use, then escalate to
            // Always on the second call (iOS pattern — Always cannot be
            // requested cold).
            log.info("Requesting location authorization (whenInUse → always)")
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            log.info("Escalating to Always authorization")
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            log.error("Location authorization denied — background streaming WILL NOT survive screen lock")
        @unknown default:
            log.warning("Unknown CLAuthorizationStatus: \(self.manager.authorizationStatus.rawValue)")
        }
    }

    /// Stop the background-keep-alive. Idempotent.
    func stop() {
        guard isRunning else { return }
        manager.stopUpdatingLocation()
        // Drop the background-updates flag so iOS can suspend us
        // normally when we go back to the foreground-only lifecycle.
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
        log.info("BackgroundLocationKeeper stopped")
    }

    // MARK: - Private

    private func beginUpdates() {
        // `allowsBackgroundLocationUpdates` MUST be set AFTER
        // authorization is Always; setting it before throws at runtime.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isRunning = true
        log.info("BackgroundLocationKeeper started (allowsBackground=true, indicator=true)")
    }
}

// MARK: - CLLocationManagerDelegate

extension BackgroundLocationKeeper: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.log.info("Authorization changed → \(status.rawValue)")
            switch status {
            case .authorizedWhenInUse:
                // We need Always for true screen-off survival.
                self.manager.requestAlwaysAuthorization()
            case .authorizedAlways:
                if !self.isRunning { self.beginUpdates() }
            case .denied, .restricted:
                self.log.error("Location denied — background mode will not work")
                self.isRunning = false
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (GPS warming up) are fine — the wakelock
        // survives as long as the subscription itself is alive.
        // We only care if the subscription gets torn down.
        Task { @MainActor in
            self.log.warning("CLLocationManager error: \(error.localizedDescription)")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We don't actually use the fixes here — Phase 6 only needs the
        // wakelock. Phase 7+ (real nav) will route these to the renderer
        // for the moving bike avatar.
    }
}
