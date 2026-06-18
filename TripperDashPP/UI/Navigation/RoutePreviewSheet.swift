//
//  RoutePreviewSheet.swift
//  TripperDashPP
//
//  Phase 7e — full-screen sheet that shows up to 3 alternative routes
//  to the chosen destination. User picks one and hits "Start
//  navigation", which calls `onStart(route)`. Caller is responsible
//  for transitioning to the navigation phase.
//

import MapKit
import SwiftUI

struct RoutePreviewSheet: View {
    @Environment(AppStatus.self) private var status
    @Environment(NavigationStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let destination: Destination
    let onStart: (MKRoute, Destination) -> Void

    @State private var routes: [RouteOption] = []
    @State private var selected: RouteOption?
    @State private var loading: Bool = false
    @State private var loadError: String?

    private let router = RoutingService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    Text(destination.name).font(.headline)
                    if let addr = destination.addressLine {
                        Text(addr).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if loading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Calculating routes…")
                        }
                    }
                }
                if let err = loadError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if !routes.isEmpty {
                    Section("Choose route") {
                        ForEach(routes) { opt in
                            routeRow(opt)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = opt }
                        }
                    }
                }
                Section {
                    Button {
                        if let sel = selected {
                            onStart(sel.route, destination)
                            dismiss()
                        }
                    } label: {
                        Label("Start navigation", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selected == nil)
                }
            }
            .navigationTitle("Route preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RoutePreferencesView()
                            .environment(store)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .task { await calculate() }
        }
    }

    private func routeRow(_ opt: RouteOption) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: opt == selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(opt == selected ? Color.accentColor : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(opt.label).font(.headline)
                    if !opt.summary.isEmpty {
                        Text(opt.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Label(opt.travelTimeDisplay, systemImage: "clock")
                    Label(opt.distanceDisplay, systemImage: "ruler")
                    Label(opt.arrivalDisplay, systemImage: "flag.checkered")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if !opt.advisoryNotices.isEmpty {
                    Text(opt.advisoryNotices.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func calculate() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let origin = status.locationService.lastFix?.coordinate
            let opts = try await router.calculate(
                from: origin,
                to: destination,
                preferences: store.routePreferences
            )
            self.routes = opts
            self.selected = opts.first
        } catch {
            self.loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Preferences sub-view

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
                Text("Apple's MKDirections returns the best matches Apple Maps would for a car. Czech Republic toll preference applies to D-roads where stamped vignettes are required.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }
}
