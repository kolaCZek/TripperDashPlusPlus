//
//  TripperDashPPApp.swift
//  TripperDashPP
//
//  App entry point. Sets up the root scene and shared app state.
//

import SwiftUI

@main
struct TripperDashPPApp: App {

    init() {
        // Diagnostic: confirm the Mapbox access token actually made it
        // into the bundled Info.plist. Empty / missing → black map +
        // HTTP 401. Should print "MBXAccessToken: pk.eyJ..." in console.
        let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String ?? "<missing>"
        let masked = token.count > 12 ? "\(token.prefix(8))…\(token.suffix(4))" : token
        print("[TripperDashPP] MBXAccessToken: \(masked) (len=\(token.count))")
    }

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
