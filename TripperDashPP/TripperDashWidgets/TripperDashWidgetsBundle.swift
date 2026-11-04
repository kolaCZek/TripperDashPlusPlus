//
//  TripperDashWidgetsBundle.swift
//  TripperDashWidgets
//
//  Entry point for the widget extension: the ride Live Activity and the
//  Quick Ride home-screen widget.
//

import SwiftUI
import WidgetKit

@main
struct TripperDashWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivity()
        QuickRideWidget()
    }
}

/// Home-screen widget: four buttons that open the app on
/// `tripperdash://ride?to=…` (`AppStatus.runWidgetAction`). Static: it
/// shows no app data, so it needs no App Group or timeline refresh.
struct QuickRideWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickRide", provider: QuickRideProvider()) { _ in
            QuickRideView()
        }
        .configurationDisplayName("Quick Ride")
        .description("Ride home or to work, start a free ride, or go to the nearest fuel station.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

nonisolated struct QuickRideEntry: TimelineEntry {
    let date: Date
}

nonisolated struct QuickRideProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickRideEntry { QuickRideEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (QuickRideEntry) -> Void) {
        completion(QuickRideEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickRideEntry>) -> Void) {
        completion(Timeline(entries: [QuickRideEntry(date: .now)], policy: .never))
    }
}

struct QuickRideView: View {
    @Environment(\.widgetFamily) private var family

    private struct Action: Identifiable {
        let id: String, title: String, symbol: String
    }
    private static let actions = [
        Action(id: "home", title: "Home", symbol: "house.fill"),
        Action(id: "work", title: "Work", symbol: "briefcase.fill"),
        Action(id: "free", title: "Free Ride", symbol: "map.fill"),
        Action(id: "fuel", title: "Fuel", symbol: "fuelpump.fill"),
    ]

    var body: some View {
        let small = family == .systemSmall
        let rows = small ? [Array(Self.actions.prefix(2)), Array(Self.actions.suffix(2))] : [Self.actions]
        VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r]) { a in
                        Link(destination: URL(string: "tripperdash://ride?to=\(a.id)")!) {
                            VStack(spacing: 6) {
                                Image(systemName: a.symbol).font(small ? .title3 : .title2)
                                Text(a.title).font(.caption2.weight(.semibold)).lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .accessibilityLabel(a.title)
                    }
                }
            }
        }
        .containerBackground(.background, for: .widget)
    }
}
