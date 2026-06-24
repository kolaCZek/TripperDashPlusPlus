//
//  TripperDashPPApp.swift
//  TripperDashPP
//
//  App entry point. Sets up the root scene and shared app state.
//

import SwiftUI

@main
struct TripperDashPPApp: App {

    /// Single source of truth for global app state (connection status,
    /// streaming counters, selected destination). Injected as
    /// `@Environment(AppStatus.self)` into every screen via
    /// `.environment(_:)` on the root scene.
    @State private var status = AppStatus()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(status)
                .task {
                    // Once-per-launch eviction sweep — removes stale
                    // map tiles and brings the cache under its size
                    // cap. Runs on the actor so it can't race with
                    // live reads/writes from the prerender loop.
                    await TileDiskCache.shared.evictIfNeeded()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // App came to the foreground — if we're sitting on a known
            // dash Wi-Fi and idle, SSID-aware auto-connect kicks the link
            // off without the rider touching anything. No-op on a free
            // account (SSID unreadable) or when suppressed after a manual
            // disconnect.
            if phase == .active {
                status.evaluateWiFiAutoConnect()
            }
        }
    }
}
