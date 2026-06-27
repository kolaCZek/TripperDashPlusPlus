//
//  SavedRoutesListView.swift
//  TripperDashPP
//
//  feat/saved-routes-gpx — the "Saved routes" library, opened from the
//  button next to Settings on the main screen.
//
//  Shows every imported route (name, start → end, distance in the
//  rider's unit), supports swipe-to-delete, and offers "Import GPX"
//  which drives the system document picker. Tapping a route pushes
//  `SavedRouteDetailView` (rename / delete / start navigation).
//
//  Persistence + import live in SavedRoutesStore / GPXImporter; this
//  view is pure presentation + the .fileImporter glue.
//

import SwiftUI
import UniformTypeIdentifiers

struct SavedRoutesListView: View {
    @Environment(AppStatus.self) private var status
    @Environment(SavedRoutesStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var importError: String?
    @State private var showImportError = false
    /// Set after a successful import so we can flash a confirmation.
    @State private var lastImportedName: String?

    private var metric: Bool { status.dashNavSettings.units == .metric }

    var body: some View {
        NavigationStack {
            Group {
                if store.routes.isEmpty {
                    emptyState
                } else {
                    routeList
                }
            }
            .navigationTitle("Saved routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import GPX", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: Self.gpxContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert("Import failed", isPresented: $showImportError, presenting: importError) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
        }
    }

    // MARK: - Content

    private var routeList: some View {
        List {
            if let name = lastImportedName {
                Section {
                    Label("Imported “\(name)”", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }
            Section {
                ForEach(store.sortedByNewest) { route in
                    NavigationLink {
                        SavedRouteDetailView(routeId: route.id)
                            .environment(status)
                            .environment(store)
                    } label: {
                        SavedRouteRow(route: route, metric: metric)
                    }
                }
                .onDelete(perform: deleteRows)
            } footer: {
                Text("Import a .gpx file to add a route. Tap a route to rename, delete, or start navigation.")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No saved routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        } description: {
            Text("Import a GPX file to save a route you can navigate later.")
        } actions: {
            Button {
                showImporter = true
            } label: {
                Label("Import GPX", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Import handling

    /// Accept both the registered GPX UTI (if the OS knows it) and a
    /// loose xml/data fallback, since GPX is frequently typed as plain
    /// XML or octet-stream by other apps / cloud providers.
    static let gpxContentTypes: [UTType] = {
        var types: [UTType] = []
        if let gpx = UTType(filenameExtension: "gpx") { types.append(gpx) }
        types.append(.xml)
        types.append(.data)  // last-resort: let the rider pick anything
        return types
    }()

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let route = try GPXImporter.importRoute(from: url)
                store.add(route)
                lastImportedName = route.name
            } catch {
                importError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                showImportError = true
            }
        case .failure(let error):
            importError = error.localizedDescription
            showImportError = true
        }
    }

    private func deleteRows(_ offsets: IndexSet) {
        // `offsets` index into the SORTED array shown on screen.
        let shown = store.sortedByNewest
        for i in offsets {
            guard shown.indices.contains(i) else { continue }
            store.remove(id: shown[i].id)
        }
    }
}

// MARK: - Row

private struct SavedRouteRow: View {
    let route: SavedRoute
    let metric: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: route.kind == .waypoints
                  ? "mappin.and.ellipse"
                  : "point.topleft.down.to.point.bottomright.curvepath")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(route.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(route.startName).lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption2)
                    Text(route.endName).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(route.distanceDisplay(metric: metric))
                    .font(.subheadline.monospacedDigit())
                Text("\(route.points.count) pts")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
