//
//  RideLiveActivity.swift
//  TripperDashWidgets
//
//  WidgetKit rendering of the ride Live Activity — the Lock Screen card and the
//  Dynamic Island presentations. This file lives in the widget extension target
//  and renders ONLY the pre-formatted strings from
//  `RideActivityAttributes.ContentState`; it links neither MapKit nor the app's
//  navigation stack.
//
//  Phase 1: iPhone only. Apple Watch is deferred (needs a watchOS companion).
//

import ActivityKit
import SwiftUI
import WidgetKit

struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            // ── Lock Screen / banner ────────────────────────────────────────
            LockScreenView(
                state: context.state,
                destination: context.attributes.destinationName
            )
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            // ── Dynamic Island ──────────────────────────────────────────────
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ManeuverGlyph(symbol: context.state.maneuverSymbol,
                                  rerouting: context.state.isRerouting)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(context.state.distanceText)
                            .font(.system(.headline, design: .rounded).weight(.heavy))
                        if let eta = context.state.etaText {
                            Text(eta)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        if let mv = context.state.maneuverText {
                            Text(mv)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ProgressView(value: context.state.progress)
                            .tint(.green)
                        if let dest = context.attributes.destinationName {
                            Text(dest)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } compactLeading: {
                ManeuverGlyph(symbol: context.state.maneuverSymbol,
                              rerouting: context.state.isRerouting)
            } compactTrailing: {
                Text(context.state.distanceText)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
            } minimal: {
                ManeuverGlyph(symbol: context.state.maneuverSymbol,
                              rerouting: context.state.isRerouting)
            }
            .widgetURL(URL(string: "tripperdash://ride"))
            .keylineTint(.green)
        }
    }
}

// MARK: - Lock Screen card

private struct LockScreenView: View {
    let state: RideActivityAttributes.ContentState
    let destination: String?

    var body: some View {
        HStack(spacing: 14) {
            // Big maneuver glyph
            ManeuverGlyph(symbol: state.maneuverSymbol, rerouting: state.isRerouting)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46)

            VStack(alignment: .leading, spacing: 3) {
                // Distance to next maneuver — the headline number.
                Text(state.distanceText)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                if let mv = state.maneuverText {
                    Text(mv)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }

                ProgressView(value: state.progress)
                    .tint(.green)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)

            // ETA + remaining, right-aligned.
            VStack(alignment: .trailing, spacing: 3) {
                if let eta = state.etaText {
                    Text(eta)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                if let rem = state.remainingText {
                    Text(rem)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let dest = destination {
                    Text(dest)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Shared glyph

/// The maneuver arrow. While rerouting we spin the recalculating symbol so the
/// rider sees the route is being recomputed even at a glance.
private struct ManeuverGlyph: View {
    let symbol: String
    let rerouting: Bool

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(rerouting ? AnyShapeStyle(.yellow) : AnyShapeStyle(.white))
    }
}
