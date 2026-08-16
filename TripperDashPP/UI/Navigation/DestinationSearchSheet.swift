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

    /// Optional text to seed the search field with on first appear — used
    /// by "Share to TripperDash++" when a shared link couldn't be geocoded
    /// but yielded a place/road label to look up manually.
    var initialQuery: String? = nil

    @State private var search = LocalSearchService()
    @State private var resolving: Bool = false
    @State private var resolveError: String?
    @State private var didSeed = false

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
                    let recents = status.recentDestinationsStore.items
                    if recents.isEmpty {
                        Section("Tip") {
                            Text("Start typing an address, city, or place name. Results are biased toward your current location.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            ForEach(recents) { r in
                                Button {
                                    onPick(r.destination)
                                    status.recentDestinationsStore.record(r.destination)
                                    dismiss()
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(r.name).foregroundStyle(.primary)
                                            if let line = r.addressLine, !line.isEmpty {
                                                Text(line).font(.footnote).foregroundStyle(.secondary)
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        status.recentDestinationsStore.remove(id: r.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("Recent")
                                Spacer()
                                Button("Clear") {
                                    status.recentDestinationsStore.clear()
                                }
                                .font(.footnote)
                                .textCase(nil)
                            }
                        }
                    }
                } else if search.completions.isEmpty && !resolving {
                    Section {
                        Text("No results yet…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // Identify rows by array offset, not `\.self`. The completer
                // (MKLocalSearchCompleter) rewrites the whole array on every
                // keystroke and can emit content-duplicate rows; keying on the
                // element made SwiftUI's diff see a different item count than
                // it actually inserted into its backing UICollectionView,
                // crashing with "Invalid Number Of Items In Section". Offsets
                // are always unique for the current snapshot.
                ForEach(Array(search.completions.enumerated()), id: \.offset) { _, c in
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
                    // .plain stops the List/Form from tinting the whole row
                    // label with the accent colour — otherwise the result
                    // titles render blue (accent) and are hard to read.
                    // Setting .foregroundStyle(.primary) on the Text alone
                    // does NOT override the button tint inside a List.
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(resolving)
                }
            }
            .searchable(text: $search.query, prompt: "Where to?")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
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
                // "Share to TripperDash++" fallback: pre-fill the query with
                // the label recovered from an un-geocodable shared link so
                // the rider just picks from the results. Once only.
                if !didSeed, let seed = initialQuery,
                   !seed.trimmingCharacters(in: .whitespaces).isEmpty {
                    search.query = seed
                    didSeed = true
                }
            }
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        resolveError = nil
        defer { resolving = false }
        do {
            let dest = try await search.resolve(completion)
            status.recentDestinationsStore.record(dest)
            onPick(dest)
            dismiss()
        } catch {
            resolveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
