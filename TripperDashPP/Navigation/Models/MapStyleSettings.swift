//
//  MapStyleSettings.swift
//  TripperDashPP
//
//  Persisted user preference for the map appearance: Light, Dark, or
//  Auto (follow local sunrise/sunset). This is the USER-FACING knob —
//  distinct from `MapStyle` (the resolved palette the renderer actually
//  paints). `MapStyleResolver` turns this mode + the live GPS fix + the
//  clock into a concrete `MapStyle`.
//
//  Storage mirrors `DashNavSettings`: a small Codable blob in
//  UserDefaults under a versioned key, observable so the settings UI and
//  the render pipeline react immediately when the rider changes it.
//

import Foundation
import Observation

@Observable
final class MapStyleSettings {

    /// What the rider picked in Settings → Map → Appearance.
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case light
        case dark
        case auto

        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: return "Light"
            case .dark:  return "Dark"
            case .auto:  return "Auto (sunrise/sunset)"
            }
        }
    }

    /// Default Auto — the whole point of the feature is hands-off
    /// day/night switching; riders who want a fixed palette pick it
    /// explicitly.
    var mode: Mode = .auto {
        didSet { persist() }
    }

    // MARK: - Persistence

    private static let storeKey = "mapStyleSettings.v1"

    private struct Persisted: Codable {
        var mode: Mode
    }

    init() {
        load()
    }

    private func load() {
        guard let raw = UserDefaults.standard.data(forKey: Self.storeKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: raw)
        else { return }
        self.mode = p.mode
    }

    private func persist() {
        if let raw = try? JSONEncoder().encode(Persisted(mode: mode)) {
            UserDefaults.standard.set(raw, forKey: Self.storeKey)
        }
    }
}
