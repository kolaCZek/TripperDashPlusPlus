//
//  RootView.swift
//  TripperDashPP
//
//  Top-level navigation container. Phase 1 stub — full picker + streaming
//  views land in Phases 5/6.
//

import SwiftUI

struct RootView: View {
    @Environment(AppStatus.self) private var status

    var body: some View {
        NavigationStack {
            MapPickerView()
                .navigationTitle("TripperDash++")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    RootView()
        .environment(AppStatus())
}
