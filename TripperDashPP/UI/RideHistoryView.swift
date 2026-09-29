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
    private var imperial: Bool { status.dashNavSettings.units == .imperial }
    private var useCommaDecimal: Bool { status.dashNavSettings.decimalSeparator == .comma }

    var body: some View {
        NavigationStack {
            Group {
                if history.rides.isEmpty {
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
            .onAppear { history.load() }
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
    /// Built once (fresh point ids on every body pass would re-snapshot
    /// the preview map). nil for a ride with no recorded track.
    @State private var route: SavedRoute?
    @State private var savedRouteId: UUID?
    @State private var exportURL: URL?

    init(ride: RideStats) {
        self.ride = ride
        _route = State(initialValue: RideStatsService.savedRoute(from: ride))
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
                        guard savedRouteId == nil else { return }
                        status.savedRoutesStore.add(route)
                        savedRouteId = route.id
                    } label: {
                        Label(savedRouteId == nil ? "Save to routes" : "Saved to routes",
                              systemImage: savedRouteId == nil ? "bookmark" : "checkmark.circle.fill")
                    }
                    .disabled(savedRouteId != nil)

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
    }
}
