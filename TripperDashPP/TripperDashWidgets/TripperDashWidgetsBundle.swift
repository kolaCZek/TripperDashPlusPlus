//
//  TripperDashWidgetsBundle.swift
//  TripperDashWidgets
//
//  Entry point for the widget extension. Phase 1 ships a single Live Activity
//  (the ride card); future home-screen widgets can be added to this bundle.
//

import SwiftUI
import WidgetKit

@main
struct TripperDashWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivity()
    }
}
