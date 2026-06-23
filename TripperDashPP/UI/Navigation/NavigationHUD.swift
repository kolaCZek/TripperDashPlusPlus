//
//  NavigationHUD.swift
//  TripperDashPP
//
//  Phase 7f — full-screen HUD shown during active navigation. Replaces
//  the live MKMapView (we're navigating → mutually exclusive with
//  picker live map → no GPU pool race).
//
//  Shows:
//    - Next maneuver card (icon + instruction + distance)
//    - ETA strip (arrival time, time remaining, distance remaining)
//    - Rerouting indicator when active
//    - Stop button (red CTA)
//

import MapKit
import SwiftUI

struct NavigationHUD: View {

    @Environment(ActiveNavigator.self) private var nav

    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            maneuverCard
            if nav.plan != nil, let plan = nav.plan, plan.legs.count > 1 {
                stopProgressPill(plan: plan)
            }
            etaCard
            Spacer()
            stopButton
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Subviews

    /// Multi-stop progress: "Stop 2 of 3 · next Slaný". Only shown when
    /// the active session is plan-navigating more than one leg.
    private func stopProgressPill(plan: PlannedRoute) -> some View {
        let total = plan.legs.count
        let current = min(nav.currentLegIndex + 1, total)
        let nextWaypointName: String = {
            let leg = plan.legs.indices.contains(nav.currentLegIndex) ? plan.legs[nav.currentLegIndex] : nil
            if let leg, let wp = plan.waypoint(id: leg.toWaypointId) { return wp.name }
            return "—"
        }()
        return HStack(spacing: 8) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .foregroundStyle(.blue)
            Text("Stop \(current) of \(total)")
                .font(.subheadline.weight(.semibold))
            Text("· next \(nextWaypointName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var maneuverCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(.blue.opacity(0.15)).frame(width: 60, height: 60)
                Image(systemName: maneuverSymbol(for: nav.nextStep))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(distanceToNext)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(nav.nextStep?.instructions ?? "Continue")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            if nav.isOffRoute {
                Label(nav.isRerouting ? "Rerouting…" : "Off route", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
                    .padding(6)
            }
        }
    }

    private var etaCard: some View {
        HStack(spacing: 0) {
            etaSlot(title: "ETA", value: arrivalTime, icon: "flag.checkered")
            Divider().frame(height: 32)
            etaSlot(title: "Remaining", value: timeRemaining, icon: "clock")
            Divider().frame(height: 32)
            etaSlot(title: "Distance", value: distanceRemaining, icon: "ruler")
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private func etaSlot(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            onStop()
        } label: {
            Label("Stop navigation", systemImage: "stop.circle.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .font(.headline)
    }

    // MARK: - Display helpers

    private var distanceToNext: String {
        let m = nav.distanceToNextStep
        if m < 100 { return String(format: "%.0f m", m) }
        if m < 1000 { return String(format: "%.0f m", (m / 10).rounded() * 10) }
        return String(format: "%.1f km", m / 1000)
    }

    private var distanceRemaining: String {
        let m = nav.remainingDistance
        if m < 1000 { return String(format: "%.0f m", m) }
        return String(format: "%.1f km", m / 1000)
    }

    private var timeRemaining: String {
        let total = Int(nav.etaSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }

    private var arrivalTime: String {
        let arr = Date().addingTimeInterval(nav.etaSeconds)
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: arr)
    }

    /// SF Symbol for the upcoming maneuver. Delegates to the SAME hybrid
    /// classifier (`ManeuverKind.classify`) that drives the dash bubble —
    /// geometry for direction, text for family — so the HUD icon always
    /// agrees with what the dash shows. (Previously this had its own
    /// substring keyword match that, like the dash classifier's old bug,
    /// could read a right turn onto a "left"-named road as a left arrow.)
    private func maneuverSymbol(for step: MKRoute.Step?) -> String {
        guard let step else { return "arrow.up" }
        return ManeuverKind.classify(step, previousStep: nav.stepBeforeNext).sfSymbol
    }
}
