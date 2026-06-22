//
//  RoutePreferencesView.swift
//  TripperDashPP
//
//  feat/route-waypoints — extracted from RoutePreviewSheet when the
//  under-map alternatives menu was retired in favour of in-map
//  picking. The preferences (avoid highways / tolls) are still reached
//  from the planning toolbar's sliders button.
//

import SwiftUI

struct RoutePreferencesView: View {
    @Environment(NavigationStore.self) private var store

    var body: some View {
        Form {
            Section("Route preferences") {
                Toggle("Avoid highways", isOn: Binding(
                    get: { store.settings.avoidHighways },
                    set: { store.setAvoidHighways($0) }
                ))
                Toggle("Avoid tolls", isOn: Binding(
                    get: { store.settings.avoidTolls },
                    set: { store.setAvoidTolls($0) }
                ))
                Text("Apple's MKDirections returns the best matches Apple Maps would for a car. Czech Republic toll preference applies to D-roads where stamped vignettes are required. Changing a preference recalculates every leg of the planned route.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }
}
