//
//  RideStatsPanel.swift
//  TripperDashPP
//
//  On-phone ride summary card. Reads the observable RideStatsService and
//  renders the ride totals through RideStatsFormatting, honouring the
//  rider's metric/imperial unit choice. Phone-side only — none of this is
//  sent to the dash.
//
//  Shown back on the picker AFTER a ride (gated on `stats.startedAt` in
//  MapPickerView), holding the frozen totals until the session ends (the
//  bike link goes fully down → RideStatsService.reset()) or a new route
//  resumes folding. There is no enable toggle, but the rider can dismiss
//  this instance via the close button — it covers a lot of the map on
//  smaller phones, so MapPickerView tracks the dismissal as transient
//  `@State` and clears it the moment the next leg starts folding
//  (`RideStatsService.state == .running`), so the summary is back for
//  the next arrival instead of staying hidden for the rest of the ride.
//

import SwiftUI

struct RideStatsPanel: View {
    @Environment(AppStatus.self) private var status

    /// Dismiss this panel instance. MapPickerView owns the actual
    /// hidden/shown `@State` — this view just reports the tap.
    let onClose: () -> Void

    /// The exported GPX temp-file URL, built on appear (and on retry) so
    /// `ShareLink` has a ready `item`. Nil until built / after a failed
    /// export.
    @State private var gpxURL: URL?

    private var stats: RideStats { status.rideStats.stats }
    private var imperial: Bool { status.dashNavSettings.units == .imperial }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Trip", systemImage: "gauge.with.needle")
                    .font(.headline)
                Spacer()
                if status.rideStats.state == .paused {
                    Text("PAUSED")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide trip summary")
            }

            // Hero: distance ridden.
            Text(RideStatsFormatting.distance(stats.distanceMeters, imperial: imperial))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            // 2×2 grid of the supporting figures.
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    stat("Moving", RideStatsFormatting.duration(stats.movingSeconds))
                    stat("Elapsed", RideStatsFormatting.duration(stats.elapsedSeconds))
                }
                GridRow {
                    stat("Avg", RideStatsFormatting.speed(stats.averageSpeedMps, imperial: imperial))
                    stat("Max", RideStatsFormatting.speed(stats.maxSpeedMps, imperial: imperial))
                }
                GridRow {
                    stat("Ascent", "≈ " + RideStatsFormatting.elevation(stats.elevationGainMeters, imperial: imperial))
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }

            // Save the recorded ride to a GPX file. Only shown when the
            // trip computer captured a track (`hasRecordedTrack`) — an
            // empty ride has nothing to export. The GPX is written to a
            // temp file on demand and handed to the system share sheet, so
            // the rider can drop it into Files, Strava, Kurviger, etc.
            if status.rideStats.hasRecordedTrack {
                if let url = gpxURL {
                    ShareLink(item: url) {
                        Label("Save ride as GPX", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Save this ride as a GPX file")
                } else {
                    // Export produced no file (write error / empty) — offer
                    // a retry rather than silently hiding the option.
                    Button {
                        gpxURL = status.rideStats.exportGPXToTemporaryFile()
                    } label: {
                        Label("Save ride as GPX", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            // Build the GPX file once when the panel appears (post-ride),
            // so ShareLink has a ready item. Rebuilt lazily on retry.
            if status.rideStats.hasRecordedTrack, gpxURL == nil {
                gpxURL = status.rideStats.exportGPXToTemporaryFile()
            }
        }
    }

    /// A small labelled figure: caption on top, value below.
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
    }
}
