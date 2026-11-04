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
/// `tripperdash://quick?to=…` (`AppStatus.runWidgetAction`). Static: it
/// shows no app data, so it needs no App Group or timeline refresh.
/// Medium only: a small widget is one tap target (`Link` needs medium+).
struct QuickRideWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickRide", provider: QuickRideProvider()) { _ in
            QuickRideView()
        }
        .configurationDisplayName("Quick Ride")
        .description("Ride home or to work, start a free ride, or go to the nearest fuel station.")
        .supportedFamilies([.systemMedium])
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
    private struct Action: Identifiable {
        let id: String, title: String, symbol: String, label: String
    }
    private static let actions = [
        Action(id: "home", title: "Home", symbol: "house.fill", label: "Navigate home"),
        Action(id: "work", title: "Work", symbol: "briefcase.fill", label: "Navigate to work"),
        Action(id: "free", title: "Free Ride", symbol: "map.fill", label: "Start a free ride"),
        Action(id: "fuel", title: "Fuel", symbol: "fuelpump.fill", label: "Navigate to the nearest fuel station"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.actions) { a in
                Link(destination: URL(string: "tripperdash://quick?to=\(a.id)")!) {
                    VStack(spacing: 6) {
                        Image(systemName: a.symbol).font(.title2).widgetAccentable()
                        Text(a.title).font(.caption2.weight(.semibold)).lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityLabel(a.label)
            }
        }
        .containerBackground(.background, for: .widget)
    }
}
