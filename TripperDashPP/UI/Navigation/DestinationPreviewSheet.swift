//
//  DestinationPreviewCard.swift
//  TripperDashPP
//
//  Phase 7c — bottom sheet that appears after a destination is
//  selected (tap-to-drop pin, search pick, favorite tap). Shows the
//  destination name + address + "Add to favorites" + "Calculate
//  routes" primary action.
//

import SwiftUI
import CoreLocation

struct DestinationPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NavigationStore.self) private var store

    let destination: Destination
    let onCalculateRoutes: (Destination) -> Void

    @State private var showFavoriteEditor: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.red)
                            .font(.title)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(destination.name).font(.headline)
                            if let addr = destination.addressLine {
                                Text(addr).font(.footnote).foregroundStyle(.secondary)
                            }
                            Text(String(format: "%.5f, %.5f", destination.coordinate.latitude, destination.coordinate.longitude))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button {
                        showFavoriteEditor = true
                    } label: {
                        Label("Add to favorites", systemImage: "star.circle")
                    }
                }
                Section {
                    Button {
                        onCalculateRoutes(destination)
                        dismiss()
                    } label: {
                        Label("Calculate routes", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    }
                    .tint(.accentColor)
                }
            }
            .navigationTitle("Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showFavoriteEditor) {
                FavoriteEditorSheet(existing: nil, seed: destination)
                    .environment(store)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
