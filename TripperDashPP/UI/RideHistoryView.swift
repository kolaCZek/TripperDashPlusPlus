//
//  RideHistoryView.swift
//  TripperDashPP
//
//  "Ride history" sheet (picker toolbar, idle state only): every ride of
//  the last `RideHistoryStore.retentionDays` days, newest first. Tap a
//  ride for its map + totals, save it to Saved routes, or export it as
//  GPX — the same actions the post-arrival trip panel offers, for rides
//  that weren't saved on the spot. Swipe to delete.
//

import SwiftUI

struct RideHistoryView: View {
    @Environment(AppStatus.self) private var status
    @Environment(\.dismiss) private var dismiss

    private var history: RideHistoryStore { status.rideHistory }
    /// Once per presentation — the root's appear also fires on every pop
    /// back from a detail view.
    @State private var loaded = false
    private var imperial: Bool { status.dashNavSettings.units == .imperial }
    private var useCommaDecimal: Bool { status.dashNavSettings.decimalSeparator == .comma }

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if history.rides.isEmpty {
                    ContentUnavailableView(
                        "No rides yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Every ride is kept here for \(RideHistoryStore.retentionDays) days.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(history.rides, id: \.startedAt) { ride in
                                NavigationLink {
                                    RideHistoryDetailView(ride: ride)
                                } label: {
                                    row(ride)
                                }
                            }
                            .onDelete { offsets in
                                let doomed = offsets.map { history.rides[$0] }
                                doomed.forEach { history.delete($0) }
                            }
                        } footer: {
                            Text("Rides are kept for \(RideHistoryStore.retentionDays) days. Save one to your routes to keep it.")
                        }
                    }
                }
            }
            .navigationTitle("Ride history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !loaded else { return }
                await history.load()
                loaded = true
            }
        }
    }

    private func row(_ ride: RideStats) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ride.startedAt ?? .distantPast,
                     format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .font(.body.weight(.medium))
                Text("\(RideStatsFormatting.duration(ride.movingSeconds)) moving · avg \(RideStatsFormatting.speed(ride.averageSpeedMps, imperial: imperial))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(RideStatsFormatting.distance(ride.distanceMeters, imperial: imperial, useCommaDecimal: useCommaDecimal))
                .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 4)
    }
}

private struct RideHistoryDetailView: View {
    @Environment(AppStatus.self) private var status

    let ride: RideStats
    /// Built once, when the detail is shown — NOT in init: the list's
    /// NavigationLink builds every visible row's destination on each list
    /// render, and mapping thousands of track points there is wasted.
    /// Fresh point ids on every body pass would also re-snapshot the
    /// preview map. nil until built, and for a ride with no track.
    @State private var route: SavedRoute?
    @State private var exportURL: URL?

    /// Already in Saved routes (from here, a reopen, or the trip panel's
    /// "Save ride" — same default name). A renamed copy isn't matched.
    private var isSaved: Bool {
        guard let route else { return false }
        return status.savedRoutesStore.routes.contains { $0.kind == .track && $0.name == route.name }
    }

    private var imperial: Bool { status.dashNavSettings.units == .imperial }
    private var useCommaDecimal: Bool { status.dashNavSettings.decimalSeparator == .comma }

    var body: some View {
        Form {
            if let route {
                Section {
                    SavedRoutePreviewMap(points: route.points)
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section("Ride") {
                LabeledContent("Distance", value: RideStatsFormatting.distance(ride.distanceMeters, imperial: imperial, useCommaDecimal: useCommaDecimal))
                LabeledContent("Moving", value: RideStatsFormatting.duration(ride.movingSeconds))
                LabeledContent("Elapsed", value: RideStatsFormatting.duration(ride.elapsedSeconds))
                LabeledContent("Avg", value: RideStatsFormatting.speed(ride.averageSpeedMps, imperial: imperial))
                LabeledContent("Max", value: RideStatsFormatting.speed(ride.maxSpeedMps, imperial: imperial))
                LabeledContent("Ascent", value: "≈ " + RideStatsFormatting.elevation(ride.elevationGainMeters, imperial: imperial))
            }

            if let route {
                Section {
                    Button {
                        guard !isSaved else { return }
                        status.savedRoutesStore.add(route)
                    } label: {
                        Label(isSaved ? "Saved to routes" : "Save to routes",
                              systemImage: isSaved ? "checkmark.circle.fill" : "bookmark")
                    }
                    .disabled(isSaved)

                    if let url = exportURL {
                        ShareLink(item: url) {
                            Label("Export as GPX", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            exportURL = SavedRouteDetailView.writeGPX(route)
                        } label: {
                            Label("Export as GPX", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .navigationTitle(Text(ride.startedAt ?? .distantPast, format: .dateTime.day().month(.abbreviated).hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if route == nil { route = RideStatsService.savedRoute(from: ride) }
        }
    }
}
