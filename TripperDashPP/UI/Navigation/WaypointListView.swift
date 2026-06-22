//
//  WaypointListView.swift
//  TripperDashPP
//
//  feat/route-waypoints — the stop list for a multi-stop plan.
//
//  Drag-to-reorder, swipe-to-delete, and an "Add stop" affordance,
//  bound to the live @Observable PlannedRoute. Every mutation returns
//  the minimal set of dirty leg indices; this view forwards them to
//  `onRecompute` so only the affected legs hit MKDirections.
//
//  Pairs with PlanningMapView (shares the same PlannedRoute instance),
//  so reordering here redraws the map and vice-versa with no manual
//  sync.
//

import SwiftUI

struct WaypointListView: View {
    /// The live plan. Mutated in place; @Observable propagates to the
    /// map + totals.
    @Bindable var plan: PlannedRoute

    /// Fired with the dirty leg indices after any structural mutation.
    /// The owner runs RoutingService.recompute for exactly these legs.
    let onRecompute: (Set<Int>) -> Void

    /// Fired when the user taps "Add stop" — owner presents the search
    /// sheet and, on pick, inserts the waypoint + triggers recompute.
    let onAddStop: () -> Void

    /// Leg indices currently being recomputed — shows a spinner on the
    /// affected rows. Owner updates this around the async recompute.
    var recomputingLegs: Set<Int> = []

    var body: some View {
        List {
            Section {
                ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, wp in
                    waypointRow(index: index, waypoint: wp)
                }
                .onMove(perform: moveRows)
                .onDelete(perform: deleteRows)
            } header: {
                HStack {
                    Text("Stops")
                    Spacer()
                    if plan.isComputed {
                        Text("\(plan.totalDistanceDisplay) · \(plan.totalTravelTimeDisplay)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }

            Section {
                Button {
                    onAddStop()
                } label: {
                    Label("Add stop", systemImage: "plus.circle.fill")
                }
            }
        }
        .environment(\.editMode, .constant(.active))  // always reorder-enabled
        .listStyle(.insetGrouped)
    }

    // MARK: - Row

    @ViewBuilder
    private func waypointRow(index: Int, waypoint wp: Waypoint) -> some View {
        HStack(spacing: 12) {
            stopBadge(index: index)
            VStack(alignment: .leading, spacing: 2) {
                Text(wp.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let addr = wp.addressLine, !addr.isEmpty {
                    Text(addr)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Leg summary for the segment LEAVING this stop (not the
                // final destination, which has no outgoing leg).
                if index < plan.legs.count {
                    legSummary(forLegIndex: index)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// Badge: ▶ origin, numbered intermediate stops, ⚑ destination.
    @ViewBuilder
    private func stopBadge(index: Int) -> some View {
        let isOrigin = index == 0
        let isDestination = index == plan.waypoints.count - 1
        ZStack {
            Circle()
                .fill(badgeColor(isOrigin: isOrigin, isDestination: isDestination).opacity(0.15))
                .frame(width: 28, height: 28)
            if isOrigin {
                Image(systemName: "location.fill").font(.caption2)
                    .foregroundStyle(badgeColor(isOrigin: true, isDestination: false))
            } else if isDestination {
                Image(systemName: "flag.checkered").font(.caption2)
                    .foregroundStyle(badgeColor(isOrigin: false, isDestination: true))
            } else {
                Text("\(index)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(badgeColor(isOrigin: false, isDestination: false))
            }
        }
    }

    private func badgeColor(isOrigin: Bool, isDestination: Bool) -> Color {
        if isOrigin { return .green }
        if isDestination { return .red }
        return .blue
    }

    @ViewBuilder
    private func legSummary(forLegIndex i: Int) -> some View {
        if recomputingLegs.contains(i) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Recalculating…").font(.caption2).foregroundStyle(.secondary)
            }
        } else if let opt = plan.legs[i].selected {
            HStack(spacing: 8) {
                if !opt.summary.isEmpty {
                    Text(opt.summary)
                }
                Text(opt.travelTimeDisplay)
                Text("·")
                Text(opt.distanceDisplay)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Text("No route yet")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Mutations

    private func moveRows(from source: IndexSet, to destination: Int) {
        guard let src = source.first else { return }
        // SwiftUI's onMove destination is the post-removal insertion
        // slot; PlannedRoute.moveWaypoint expects the same semantics as
        // Array.move, so translate.
        let dest = destination > src ? destination - 1 : destination
        let dirty = plan.moveWaypoint(from: src, to: dest)
        if !dirty.isEmpty { onRecompute(dirty) }
    }

    private func deleteRows(at offsets: IndexSet) {
        // Collect ids first (indices shift as we remove).
        let ids = offsets.compactMap { plan.waypoints.indices.contains($0) ? plan.waypoints[$0].id : nil }
        var dirty = Set<Int>()
        for id in ids {
            dirty.formUnion(plan.removeWaypoint(id: id))
        }
        if !dirty.isEmpty { onRecompute(dirty) }
    }
}
