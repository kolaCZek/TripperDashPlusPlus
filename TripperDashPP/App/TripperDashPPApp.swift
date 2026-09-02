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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(status)
                .onOpenURL { url in
                    // "Share to TripperDash++": the share extension posts a
                    // tripperdash:// deep link; the OS may also hand us raw
                    // geo:/maps URLs. Both funnel through AppStatus, which
                    // resolves and stages a plan (pre-filling the planner).
                    status.handleIncomingURL(url)
                }
                .task {
                    // Once-per-launch eviction sweep — removes stale
                    // map tiles and brings the cache under its size
                    // cap. Runs on the actor so it can't race with
                    // live reads/writes from the prerender loop.
                    await TileDiskCache.shared.evictIfNeeded()
                }
        }
    }
}
