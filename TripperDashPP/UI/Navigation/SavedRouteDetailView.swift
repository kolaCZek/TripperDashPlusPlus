//
//  SavedRouteDetailView.swift
//  TripperDashPP
//
//  feat/saved-routes-gpx — actions for a single saved route: preview its
//  shape on a map, rename, edit its points (reorder / delete), delete the
//  route, and start navigation.
//
//  Start flow (rider-confirmed design):
//    1. Analyse the route's points against the live GPS fix
//       (`RouteStartPlanner.analyze`).
//    2. If the nearest point isn't the first AND starting from first
//       would be a meaningful detour backwards, ask the rider:
//       "From the first point" / "From the nearest point".
//    3. Hand the chosen point list to
//       `AppStatus.beginPlanningFromSavedRoute(...)`, which builds a
//       `PlannedRoute` (origin = live location) and kicks off leg
//       computation — exactly the same plan object the manual planner
//       produces, so the existing connect-first "Start navigation" CTA,
//       auto-start, reroute, arrival, and dash-glyph pipeline all apply
//       unchanged.
//    4. Dismiss back to the map picker, which now shows the planning UI
//       for the staged route.
//
//  Editing: points are mutated through `SavedRoutesStore.updatePoints`,
//  which recomputes the stored distance and refuses to drop below 2
//  points. Reorder is offered only for `.waypoints` routes — reordering a
//  `.track` would scramble its recorded shape — while delete is allowed
//  for both (prune a stray via). The preview map reflects edits live.
//

import CoreLocation
import SwiftUI

struct SavedRouteDetailView: View {
    @Environment(AppStatus.self) private var status
    @Environment(SavedRoutesStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let routeId: UUID

    @State private var draftName = ""
    @State private var showDeleteConfirm = false
    @State private var showStartModeDialog = false
    @State private var pendingDecision: RouteStartDecision?
    @State private var nameCommitted = false
    @State private var editMode: EditMode = .inactive

    /// Current value from the store (so rename/delete/edit reflect live).
    private var route: SavedRoute? { store.route(id: routeId) }
    private var metric: Bool { status.dashNavSettings.units == .metric }

    var body: some View {
        Group {
            if let route {
                content(route)
            } else {
                // Route was deleted out from under us — pop.
                Color.clear.onAppear { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func content(_ route: SavedRoute) -> some View {
        Form {
            Section {
                SavedRoutePreviewMap(points: route.points)
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
            }

            Section("Name") {
                TextField("Route name", text: $draftName)
                    .onSubmit { commitName() }
                    .submitLabel(.done)
            }

            Section("Details") {
                LabeledContent("Start", value: route.startName)
                LabeledContent("End", value: route.endName)
                LabeledContent("Distance", value: route.distanceDisplay(metric: metric))
                LabeledContent("Type", value: route.kind == .waypoints ? "Waypoints" : "Track")
                if let file = route.sourceFilename {
                    LabeledContent("Source", value: file)
                }
            }

            pointsSection(route)

            Section {
                Button {
                    beginStart(route)
                } label: {
                    Label("Start navigation", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .disabled(editMode == .active)
            } footer: {
                Text("Builds a route from these points (origin = your current location) and opens it ready to connect & ride.")
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete route", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .environment(\.editMode, $editMode)
        .onAppear {
            if !nameCommitted { draftName = route.name }
        }
        .onDisappear { commitName() }
        .confirmationDialog("Delete this route?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.remove(id: routeId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(route.name)” will be removed from your saved routes. This can't be undone.")
        }
        .confirmationDialog("Start from where?",
                            isPresented: $showStartModeDialog,
                            titleVisibility: .visible) {
            Button("From the first point") { launch(route, mode: .fromFirst) }
            Button("From the nearest point") { launch(route, mode: .fromNearest) }
            Button("Cancel", role: .cancel) { pendingDecision = nil }
        } message: {
            if let d = pendingDecision {
                Text(startPromptMessage(d))
            }
        }
    }

    // MARK: - Points editor

    @ViewBuilder
    private func pointsSection(_ route: SavedRoute) -> some View {
        // Reorder only makes sense for waypoint routes; a recorded track's
        // order IS its shape. nil disables the drag handles entirely.
        // Explicitly typed so the ternary infers Optional, not a concrete
        // closure type (which wouldn't unify with nil).
        let moveAction: ((IndexSet, Int) -> Void)? =
            route.kind == .waypoints
            ? { from, to in movePoints(route, from: from, to: to) }
            : nil

        Section {
            ForEach(Array(route.points.enumerated()), id: \.element.id) { idx, point in
                pointRow(route: route, index: idx, point: point)
            }
            .onDelete { offsets in deletePoints(route, at: offsets) }
            .onMove(perform: moveAction)
        } header: {
            HStack {
                Text("Points (\(route.points.count))")
                Spacer()
                if editMode == .active && route.points.count <= 2 {
                    Text("min 2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if editMode == .active {
                Text(route.kind == .waypoints
                     ? "Swipe to delete a stop, or drag to reorder. A route keeps at least 2 points."
                     : "Swipe to delete a point. Recorded tracks can't be reordered (it would scramble the shape).")
            }
        }
    }

    @ViewBuilder
    private func pointRow(route: SavedRoute, index: Int, point: RoutePoint) -> some View {
        let isFirst = index == 0
        let isLast = index == route.points.count - 1
        HStack(spacing: 10) {
            Image(systemName: isFirst ? "location.fill"
                  : isLast ? "flag.checkered" : "circle.fill")
                .font(isFirst || isLast ? .footnote : .system(size: 7))
                .foregroundStyle(isFirst ? .green : isLast ? .red : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(pointLabel(point, index: index, total: route.points.count))
                    .font(.subheadline)
                    .lineLimit(1)
                Text(String(format: "%.5f, %.5f", point.latitude, point.longitude))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pointLabel(_ p: RoutePoint, index: Int, total: Int) -> String {
        if let n = p.name, !n.isEmpty { return n }
        if index == 0 { return "Start" }
        if index == total - 1 { return "End" }
        return "Via \(index)"
    }

    private func deletePoints(_ route: SavedRoute, at offsets: IndexSet) {
        var pts = route.points
        // Honour the 2-point floor: never delete down past it.
        let removable = pts.count - 2
        guard removable > 0 else { return }
        let trimmed = Array(offsets.sorted().prefix(removable))
        for i in trimmed.sorted(by: >) where pts.indices.contains(i) {
            pts.remove(at: i)
        }
        store.updatePoints(id: route.id, points: pts)
    }

    private func movePoints(_ route: SavedRoute, from source: IndexSet, to destination: Int) {
        var pts = route.points
        pts.move(fromOffsets: source, toOffset: destination)
        store.updatePoints(id: route.id, points: pts)
    }

    // MARK: - Name editing

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let route, !trimmed.isEmpty, trimmed != route.name else { return }
        store.rename(id: routeId, to: trimmed)
        nameCommitted = true
    }

    // MARK: - Start flow

    /// Analyse the route against the live fix and either prompt for the
    /// start mode or launch straight from the first point.
    private func beginStart(_ route: SavedRoute) {
        commitName()  // don't lose an in-flight rename when we navigate away
        let rider = status.locationService.lastFix?.coordinate
        let decision = RouteStartPlanner.analyze(points: route.points, riderLocation: rider)
        if decision.shouldPrompt {
            pendingDecision = decision
            showStartModeDialog = true
        } else {
            launch(route, mode: .fromFirst)
        }
    }

    private func launch(_ route: SavedRoute, mode: RouteStartMode) {
        let nearestIndex = pendingDecision?.nearestIndex ?? 0
        pendingDecision = nil
        status.beginPlanningFromSavedRoute(route, mode: mode, nearestIndex: nearestIndex)
        // Dismiss the whole saved-routes sheet stack so the picker's
        // planning UI (staged plan) is visible underneath.
        dismiss()
        status.requestDismissSavedRoutes = true
    }

    private func startPromptMessage(_ d: RouteStartDecision) -> String {
        let first = formatDistance(d.distanceToFirst)
        let nearest = formatDistance(d.distanceToNearest)
        return "The route's first point is \(first) away; the nearest point on the route is \(nearest) away. Start from the first point to ride the whole route, or from the nearest point to skip the part you've already passed."
    }

    private func formatDistance(_ meters: Double) -> String {
        if metric {
            return meters < 1000
                ? String(format: "%.0f m", meters)
                : String(format: "%.1f km", meters / 1000)
        } else {
            let miles = meters / 1609.344
            return miles < 0.1
                ? String(format: "%.0f ft", meters * 3.280839895)
                : String(format: "%.1f mi", miles)
        }
    }
}
