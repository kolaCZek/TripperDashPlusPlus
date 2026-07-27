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

    /// Tracks the post-ride "Save ride" action: nil = not yet saved,
    /// non-nil = the id of the SavedRoute we created (so the button flips
    /// to a "Saved ✓" confirmation and won't double-save the same ride).
    @State private var savedRouteId: UUID?

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

            // Save the recorded ride into the Saved routes library. Only
            // shown when the trip computer captured a track
            // (`hasRecordedTrack`) — an empty ride has nothing to save.
            // Saving builds a `.track` SavedRoute (same shape as a GPX
            // import), so the ride then lives in Saved routes where it can
            // be navigated again or exported to a GPX file. Once saved the
            // button flips to a confirmation and disables, so a ride can't
            // be double-added.
            if status.rideStats.hasRecordedTrack {
                Button {
                    guard savedRouteId == nil,
                          let route = status.rideStats.makeSavedRoute() else { return }
                    status.savedRoutesStore.add(route)
                    savedRouteId = route.id
                } label: {
                    Label(savedRouteId == nil ? "Save ride" : "Saved to routes",
                          systemImage: savedRouteId == nil ? "bookmark" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background((savedRouteId == nil ? Color.accentColor : Color.green).opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(savedRouteId != nil)
                .accessibilityLabel(savedRouteId == nil
                                    ? "Save this ride to your routes"
                                    : "Ride saved to your routes")
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
