//
//  FreeRideHUD.swift
//  TripperDashPP
//
//  feat/free-ride-and-gpx-export — full-screen phone HUD shown during a
//  FREE RIDE (map projecting to the dash with no route, no navigation).
//
//  Deliberately mirrors `NavigationHUD`'s layout so the rider sees the
//  same familiar status page as during navigation, with three changes:
//    1. The maneuver card becomes a "Free ride" card — a motorcycle icon
//       and the label, since there is no upcoming turn to show.
//    2. The ETA strip drops ETA + Remaining (both meaningless without a
//       destination) and shows only Duration + Distance ridden.
//    3. The bottom map frames just the rider's current position (a clean
//       basemap + position puck) — no route line, because there is none.
//
//  Like NavigationHUD this replaces the live MKMapView while streaming
//  (the dash MapViewSource owns Apple's shared Metal pool), so the map
//  here is the CPU-composited RouteProgressMap thumbnail, not a live map.
//
//  Stats come straight from the live RideStatsService accumulator — the
//  same numbers the post-ride "Trip" card shows — so "Save ride as GPX"
//  stays on that Trip card after the ride ends, exactly as it does after
//  navigation. This HUD is purely informational; the "Stop free ride"
//  button lives in MapPickerView's control bar.
//

import CoreLocation
import SwiftUI

struct FreeRideHUD: View {

    /// Live ride accumulator (distance / moving / elapsed).
    let stats: RideStats
    /// Rider unit preference for the distance readout.
    let imperial: Bool
    /// Current GPS fix for the position-only map puck.
    let position: CLLocationCoordinate2D?

    var body: some View {
        VStack(spacing: 16) {
            freeRideCard
            statsCard
            positionMap
            Spacer()
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Subviews

    /// The maneuver-card slot, repurposed: a motorcycle glyph + "Free
    /// ride" instead of a turn arrow + instruction. Same frame/size as
    /// NavigationHUD.maneuverCard so the page reads identically.
    private var freeRideCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(.blue.opacity(0.15)).frame(width: 60, height: 60)
                Image(systemName: "motorcycle")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Free ride")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Map projecting to your dash — no route")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The ETA-strip slot, repurposed: Duration + Distance only (no ETA /
    /// Remaining — there is no destination). Wrapped in the same 1 Hz
    /// TimelineView as NavigationHUD.etaCard so the elapsed clock ticks
    /// smoothly even when GPS fixes thin out at a standstill.
    private var statsCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 0) {
                slot(title: "Duration", value: RideStatsFormatting.duration(stats.elapsedSeconds), icon: "clock")
                Divider().frame(height: 32)
                slot(title: "Distance",
                     value: RideStatsFormatting.distance(stats.distanceMeters, imperial: imperial),
                     icon: "ruler")
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func slot(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Position-only map: reuses RouteProgressMap with empty route lists,
    /// so it frames ~1.2 km around the rider and draws only the position
    /// puck — the "current position on the map (no route)" the rider asked
    /// for. Hidden until we have a fix (avoids an empty grey box).
    @ViewBuilder
    private var positionMap: some View {
        if position != nil {
            RouteProgressMap(traveled: [], ahead: [], position: position)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
        }
    }
}
