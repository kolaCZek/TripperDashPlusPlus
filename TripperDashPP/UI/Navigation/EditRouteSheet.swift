//
//  EditRouteSheet.swift
//  TripperDashPP
//
//  feat/edit-route-mid-ride — change the stops of a RUNNING navigation
//  (remove, reorder, add, change the destination) without ending the ride.
//
//  The sheet edits a throwaway draft: the live position (pinned row 0) +
//  the stops still ahead. Apply builds a fresh plan from it, asks Apple
//  only for the legs the edit touched plus the one from here, and hands it
//  to `ActiveNavigator.replacePlan` — the stream, ride stats and the dash
//  projection carry on. Cancel (or a routing failure) leaves the running
//  route untouched. Phone-side only: nothing new goes over the wire.
//

import CoreLocation
import SwiftUI

struct EditRouteSheet: View {
    @Environment(AppStatus.self) private var status
    @Environment(\.dismiss) private var dismiss

    /// Never installed itself — Apply copies its stops into a new plan.
    @State private var draft: PlannedRoute?
    /// The running plan + leg the draft was cut from. A leg advance (or a
    /// dash "remove waypoint") while editing makes the draft stale — it may
    /// still hold the stop just reached — so the list is reloaded from the
    /// live plan (unsaved edits dropped). A reroute doesn't: the stops are
    /// the same and routing starts from here anyway.
    @State private var basePlan: PlannedRoute?
    @State private var baseLegIndex = 0
    @State private var baseStopIds: [UUID] = []
    @State private var showSearch = false
    @State private var applyingLegs: Set<Int> = []
    @State private var applying = false
    @State private var errorText: String?
    @State private var noticeText: String?
    /// Set on dismissal so a late Apply result never installs a route the
    /// rider walked away from.
    @State private var closed = false

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    WaypointListView(plan: draft,
                                     onRecompute: { _ in },   // routed on Apply, from the live fix
                                     onAddStop: { showSearch = true },
                                     recomputingLegs: applyingLegs,
                                     pinsOrigin: true)
                        .disabled(applying)
                } else {
                    ContentUnavailableView("No route to edit",
                                           systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.regularMaterial)
                } else if let noticeText {
                    Label(noticeText, systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.regularMaterial)
                }
            }
            .navigationTitle("Edit route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if applying {
                        ProgressView()
                    } else {
                        Button("Apply") { apply() }
                            .disabled(!canApply)
                    }
                }
            }
        }
        .onAppear(perform: loadDraft)
        .onDisappear { closed = true }
        // Arrival or the ride ending while the sheet is up: drop the edit.
        .onChange(of: status.activeNavigator.hasArrived) { _, arrived in
            if arrived { dismiss() }
        }
        .onChange(of: status.activeNavigator.isNavigating) { _, navigating in
            if !navigating { dismiss() }
        }
        // A stop reached (or skipped from the dash) while editing: reload.
        .onChange(of: status.activeNavigator.currentLegIndex) { _, _ in reloadIfStale() }
        .onChange(of: status.activeNavigator.plan.map { ObjectIdentifier($0) }) { _, _ in reloadIfStale() }
        .sheet(isPresented: $showSearch) {
            DestinationSearchSheet(onPick: { dest in
                _ = draft?.insertBeforeDestination(Waypoint.from(destination: dest))
            })
            .environment(status)
            .environment(status.navigationStore)
        }
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        status.locationService.lastFix?.coordinate ?? status.activeNavigator.currentCoordinate
    }

    /// Something changed and a stop is left. The model already refuses to
    /// delete the last stop (a plan needs ≥ 2 waypoints), so "remove every
    /// stop" can't be expressed — ending the ride is the Stop button.
    private var canApply: Bool {
        guard let draft else { return false }
        let stopIds = draft.waypoints.dropFirst().map(\.id)
        return !stopIds.isEmpty && stopIds != baseStopIds
    }

    private var isStale: Bool {
        let nav = status.activeNavigator
        return nav.plan !== basePlan || nav.currentLegIndex != baseLegIndex
    }

    private func loadDraft() {
        guard draft == nil else { return }
        let nav = status.activeNavigator
        guard let plan = nav.plan, let coord = currentCoordinate else { return }
        let stops = PlannedRoute.remainingStops(of: plan, fromLegIndex: nav.currentLegIndex)
        guard let wps = PlannedRoute.replacementWaypoints(currentLocation: coord, stops: stops) else { return }
        let d = PlannedRoute(waypoints: wps)
        Self.carryComputedLegs(from: plan, into: d)
        basePlan = plan
        baseLegIndex = nav.currentLegIndex
        baseStopIds = stops.map(\.id)
        draft = d
    }

    /// The route moved on under the open sheet: re-cut the draft from the
    /// live plan. The rider's unsaved edits are dropped — simpler and safer
    /// than merging them onto a list that lost (or skipped) a stop. While
    /// Apply is routing, the post-await check below does this instead.
    private func reloadIfStale() {
        guard !applying, !closed, draft != nil, isStale else { return }
        reloadDraft()
    }

    private func reloadDraft() {
        draft = nil
        errorText = nil
        loadDraft()
        noticeText = Self.reloadedNotice
    }

    private func apply() {
        guard let draft, let coord = currentCoordinate,
              let wps = PlannedRoute.replacementWaypoints(currentLocation: coord, stops: draft.waypoints)
        else { return }
        guard !isStale else {
            reloadDraft()
            return
        }
        let nav = status.activeNavigator
        // A fresh live origin, so leg 0 is always routed from where the
        // rider is NOW; untouched legs keep their routes.
        let newPlan = PlannedRoute(waypoints: wps)
        Self.carryComputedLegs(from: draft, into: newPlan)
        let dirty = Set(newPlan.legs.indices.filter { !newPlan.legs[$0].isComputed })
        errorText = nil
        noticeText = nil
        applying = true
        applyingLegs = dirty
        Task { @MainActor in
            defer {
                applying = false
                applyingLegs = []
            }
            do {
                try await status.routingService.recompute(
                    newPlan,
                    dirtyLegIndices: dirty,
                    preferences: status.navigationStore.routePreferences,
                    // Same cap as a reroute: a dead cellular link shows an
                    // error instead of spinning with the old route running.
                    timeout: ActiveNavigator.routeRequestTimeout,
                    isStillLive: { !closed && nav.isNavigating }
                )
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                errorText = reason + " Your current route is unchanged."
                return
            }
            guard !closed, newPlan.isComputed else { return }
            guard !isStale else {
                reloadDraft()
                return
            }
            if await nav.replacePlan(newPlan) {
                closed = true   // our own swap must not trigger a reload
                dismiss()
            } else {
                errorText = "Couldn't switch routes right now (rerouting?). Your current route is unchanged — try Apply again."
            }
        }
    }

    private static let reloadedNotice = "The route moved on — the list was refreshed."

    /// Reuse the routes (and the rider's picked alternative) of legs whose
    /// two stops are unchanged, so Apply asks Apple only for what changed.
    private static func carryComputedLegs(from source: PlannedRoute, into target: PlannedRoute) {
        for (i, leg) in target.legs.enumerated() {
            guard let old = source.legs.first(where: {
                $0.fromWaypointId == leg.fromWaypointId && $0.toWaypointId == leg.toWaypointId
            }), old.isComputed else { continue }
            target.setOptions(old.options, forLegIndex: i)
            target.setSelectedOption(legIndex: i, optionIndex: old.selectedOptionIndex)
        }
    }
}
