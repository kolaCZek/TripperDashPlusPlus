//
//  RootView.swift
//  TripperDashPP
//
//  Top-level navigation container: hosts MapPickerView in a
//  NavigationStack.
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
