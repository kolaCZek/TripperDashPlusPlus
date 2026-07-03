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
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
