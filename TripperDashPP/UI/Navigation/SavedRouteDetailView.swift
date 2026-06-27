//
//  SavedRouteDetailView.swift
//  TripperDashPP
//
//  feat/saved-routes-gpx — actions for a single saved route: rename,
//  delete, and start navigation.
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

    /// Current value from the store (so rename/delete reflect live).
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
            Section("Name") {
                TextField("Route name", text: $draftName)
                    .onSubmit { commitName() }
                    .submitLabel(.done)
            }

            Section("Details") {
                LabeledContent("Start", value: route.startName)
                LabeledContent("End", value: route.endName)
                LabeledContent("Distance", value: route.distanceDisplay(metric: metric))
                LabeledContent("Points", value: "\(route.points.count)")
                LabeledContent("Type", value: route.kind == .waypoints ? "Waypoints" : "Track")
                if let file = route.sourceFilename {
                    LabeledContent("Source", value: file)
                }
            }

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
