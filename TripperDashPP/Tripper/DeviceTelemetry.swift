//
//  DeviceTelemetry.swift
//  TripperDashPP
//
//  Live phone-status provider for the 1 Hz K1G status frames (`0044`
//  heartbeat + `0030` metadata). Mirrors what the stock Royal Enfield
//  app's `REForeGroundService` 1 Hz `TimerTask` (`d.run()`) reports to
//  the big Tripper TFT:
//
//    | TLV       | meaning            | OEM source                         |
//    |-----------|--------------------|------------------------------------|
//    | `06 04`   | battery capacity   | `BatteryManager.getIntProperty(4)` |
//    | `06 0F`   | charging flag      | `ACTION_BATTERY_CHANGED` status    |
//    | `06 03`   | GPS fix on/off     | `LocationManager.isProviderEnabled`|
//    | `06 01`   | mobile signal pres.| `getAllCellInfo()...getLevel() > 0` |
//    | `06 08`   | cell signal 0-255  | `p9k.p0()` (analog bars)            |
//
//  Decoded 2026-06-27 from `com.royalenfield.reprime`
//  (`REForeGroundService.d.run()`, lines 211-232) and byte-verified
//  against the real-phone capture better-dash inlines as
//  `tripper_app_like_nav.py:INITIAL_BURST_HEX[9]`:
//
//    0044 …  06 08 0001 FF   06 03 0001 55   06 04 0001 A2
//            06 0F 0001 AA   06 01 0001 01   …
//
//  i.e. cell-strength 0xFF, GPS on, battery 0xA2-100 = 62 %, not
//  charging, signal present.
//
//  ── iOS reality check (PREDICTION FROM API, not a HW fact) ──
//  * battery %  : `UIDevice.batteryLevel` → exact, fully live.
//  * charging   : `UIDevice.batteryState` → exact, fully live.
//  * GPS fix    : `LocationService` authorization + a real fix → live.
//  * signal     : iOS gives NO public API for the bar COUNT (the
//                 private `_signalStrengthBars` route is an App Store
//                 reject). BUT the stock app's `06 01` TLV is itself
//                 only a binary present/absent flag (payload `01`/`00`,
//                 derived from `getLevel() > 0`), and THAT we can
//                 reproduce faithfully via `NWPathMonitor(.cellular)`.
//                 So `06 01` is byte-faithful to the OEM. The analog
//                 `06 08` strength (0-255) we cannot truly measure, so
//                 we drive it as a binary proxy off the same presence
//                 (`0xA0` when a cellular path exists, `0x00` when not)
//                 rather than ship a fabricated bar count. The dash
//                 thus sees a consistent "have signal / no signal",
//                 matching what the OEM actually puts on `06 01`.
//

import Foundation
import Network
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif

/// Sendable snapshot consumed by `HeartbeatLoop` once per tick. Plain
/// value type so it can cross the actor hop from `DeviceTelemetry`
/// (main actor) into the heartbeat `Task` cleanly.
struct PhoneTelemetry: Sendable, Equatable {
    var cellSignal0to255: Int
    var batteryPct0to100: Int
    var gpsOn: Bool
    var charging: Bool
    var signalPresent: Bool

    /// The pre-telemetry placeholder values the heartbeat shipped before
    /// this feature existed (and still ships when the user turns device
    /// telemetry OFF, or before monitoring has produced a first reading).
    /// Chosen to look like "a sane phone client" to the dash so the link
    /// never drops just because we withheld real data — the OEM dash
    /// keys its keep-alive on the frame ARRIVING, not on its contents.
    static let placeholder = PhoneTelemetry(
        cellSignal0to255: 160,
        batteryPct0to100: 80,
        gpsOn: true,
        charging: false,
        signalPresent: true
    )
}

@MainActor
@Observable
final class DeviceTelemetry {

    // MARK: - Live observable state

    /// 0-100, clamped. Seeded with the placeholder so a UI binding has a
    /// sane value before the first battery notification lands.
    private(set) var batteryPct: Int = 80
    private(set) var isCharging: Bool = false
    /// Whether a cellular data path currently exists. This is the iOS
    /// equivalent of the OEM's `getLevel() > 0` presence check.
    private(set) var hasCellSignal: Bool = true

    // MARK: - Internals

    /// GPS-fix truth comes from the one shared `LocationService` (same
    /// instance that owns the wakelock + map fixes) so we don't spin up a
    /// second `CLLocationManager` or race its authorization pill.
    private weak var location: LocationService?

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "DeviceTelemetry")
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .cellular)
    private let pathQueue = DispatchQueue(label: "eu.kolaczek.tripperdashpp.telemetry.path")
    private var started = false
    #if canImport(UIKit)
    private var notifTokens: [NSObjectProtocol] = []
    #endif

    init(location: LocationService? = nil) {
        self.location = location
    }

    // MARK: - Lifecycle

    /// Begin monitoring battery + cellular reachability. Idempotent.
    func start() {
        guard !started else { return }
        started = true

        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBattery()
        let nc = NotificationCenter.default
        notifTokens.append(nc.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBattery() }
        })
        notifTokens.append(nc.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBattery() }
        })
        #endif

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let present = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.hasCellSignal != present {
                    self.hasCellSignal = present
                    self.log.debug("Cellular path \(present ? "up" : "down")")
                }
            }
        }
        pathMonitor.start(queue: pathQueue)
        log.info("DeviceTelemetry started (battery monitoring + cellular path)")
    }

    /// Stop monitoring and release OS resources. Idempotent.
    func stop() {
        guard started else { return }
        started = false
        pathMonitor.cancel()
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        for t in notifTokens { nc.removeObserver(t) }
        notifTokens.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = false
        #endif
        log.info("DeviceTelemetry stopped")
    }

    // MARK: - Snapshot for the heartbeat

    /// Build the per-tick telemetry the heartbeat encodes. Always reports
    /// the phone's real status — the stock app reports unconditionally and
    /// so do we (there's no user opt-out).
    func snapshot() -> PhoneTelemetry {
        return PhoneTelemetry(
            cellSignal0to255: hasCellSignal ? 0xA0 : 0x00,
            batteryPct0to100: batteryPct,
            gpsOn: currentGpsOn,
            charging: isCharging,
            signalPresent: hasCellSignal
        )
    }

    // MARK: - Sampling

    #if canImport(UIKit)
    private func refreshBattery() {
        let level = UIDevice.current.batteryLevel  // 0.0…1.0, or -1 if unknown
        if level >= 0 {
            batteryPct = max(0, min(100, Int((level * 100).rounded())))
        }
        // else: monitoring not ready / simulator — keep last good / seed.
        switch UIDevice.current.batteryState {
        case .charging, .full:
            isCharging = true
        case .unplugged, .unknown:
            isCharging = false
        @unknown default:
            isCharging = false
        }
    }
    #endif

    /// GPS "on" matches the OEM `06 03` semantics: location services are
    /// authorized for us AND we currently hold a real fix. A bare
    /// authorization with no fix yet (cold start, indoors) reports off,
    /// which is what the dash expects — the OEM derives this from
    /// `isProviderEnabled("gps")` + an actual location.
    private var currentGpsOn: Bool {
        guard let location else { return false }
        #if canImport(CoreLocation)
        let authed = location.authorizationStatus == .authorizedWhenInUse
            || location.authorizationStatus == .authorizedAlways
        return authed && location.lastFix != nil
        #else
        return location.lastFix != nil
        #endif
    }
}
