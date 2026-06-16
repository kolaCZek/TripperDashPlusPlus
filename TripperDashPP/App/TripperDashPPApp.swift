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
    /// `@Environment` into every view that needs it.
    @State private var status = AppStatus()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(status)
        }
    }
}
