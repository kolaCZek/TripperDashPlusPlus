//
//  TripperDashPPApp.swift
//  TripperDashPP
//
//  App entry point. Sets up the root scene and shared app state.
//

import SwiftUI
import UIKit

@main
struct TripperDashPPApp: App {

    /// Single source of truth for global app state (connection status,
    /// streaming counters, selected destination). Injected as
    /// `@Environment(AppStatus.self)` into every screen via
    /// `.environment(_:)` on the root scene.
    @State private var status = AppStatus()
    init() {
        // Diagnostic: mark every process launch. Paired with the
        // `scenePhase` transitions logged in MapPickerView, this is what
        // lets a future connection-diagnostics.log distinguish "the app
        // process was killed and cold-relaunched" (a `[lifecycle] launch`
        // line with NO preceding `.active` scenePhase since the last
        // `.background`) from a plain Wi-Fi drop. See MapPickerView's
        // scenePhase comment for the field evidence that motivated this
        // (8/2026: locked-phone ride disconnect with the staged route
        // gone afterward and nothing in the connection log explaining
        // why).
        ConnDiag.log("lifecycle", "launch (process start)")
        // Diagnostic: iOS fires this on a live (not-yet-killed) process
        // under memory pressure BEFORE jetsam actually terminates it, so a
        // line here right before the log goes silent is the strongest
        // available evidence of a resource-pressure kill (vs. a plain
        // network drop) — the app doesn't get to log anything as jetsam
        // itself acts, so this early-warning notification is the closest
        // signal we can capture. NotificationCenter observer with no
        // owner captured is fine: it needs to live for the whole process
        // lifetime, same as `ConnDiag.store`.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            ConnDiag.log("lifecycle", "⚠️ didReceiveMemoryWarning — jetsam kill may follow")
        }
        // Diagnostic: MetricKit reports crash diagnostics AND exit-reason
        // counters (foreground/background, incl. jetsam memory/CPU limits)
        // on a later launch, opportunistically. This is the only source
        // that can actually confirm/rule out a jetsam kill vs. a plain
        // network drop — see CrashDiagnostics.swift for detail.
        CrashDiagnosticsSubscriber.shared.start()
    }
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
