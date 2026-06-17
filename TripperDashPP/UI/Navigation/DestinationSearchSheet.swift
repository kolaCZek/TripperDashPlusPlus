//
//  DestinationSearchSheet.swift
//  TripperDashPP
//
//  Phase 7b — full-screen sheet with sticky search field + live
//  autocomplete list. Selecting a row resolves it to a Destination
//  and calls `onPick`.
//

import MapKit
import SwiftUI

struct DestinationSearchSheet: View {
    @Environment(AppStatus.self) private var status
    @Environment(\.dismiss) private var dismiss

    /// Caller hook. Sheet auto-dismisses after invoking this.
    let onPick: (Destination) -> Void

    @State private var search = LocalSearchService()
    @State private var resolving: Bool = false
    @State private var resolveError: String?

    var body: some View {
        NavigationStack {
            List {
                if let err = search.lastError ?? resolveError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if search.query.isEmpty {
                    Section("Tip") {
                        Text("Start typing an address, city, or place name. Results are biased toward your current location.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if search.completions.isEmpty && !resolving {
                    Section {
                        Text("No results yet…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(search.completions, id: \.self) { c in
                    Button {
                        Task { await pick(c) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).foregroundStyle(.primary)
                            if !c.subtitle.isEmpty {
                                Text(c.subtitle).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(resolving)
                }
            }
            .searchable(text: $search.query, prompt: "Where to?")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if resolving {
                    ProgressView("Resolving…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task {
                // Seed the search bias from current GPS, if available.
                search.biasCenter = status.locationService.lastFix?.coordinate
            }
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        resolveError = nil
        defer { resolving = false }
        do {
            let dest = try await search.resolve(completion)
            onPick(dest)
            dismiss()
        } catch {
            resolveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
