//
//  PermissionsView.swift
//  TripperDashPP
//
//  A self-contained sheet listing every OS permission the app needs, each
//  with a live green-check status and a "Set" button that requests it (or
//  routes to iOS Settings when the permission can only be changed there).
//
//  Presented from Settings → About → "Check permissions".
//
//  Permissions covered (matches TripperDashPP-Info.plist usage strings):
//    • Location (When In Use → Always) — CLLocationManager. The app needs
//      Always so the map/wakelock keeps running with the screen off.
//    • Apple Music — MPMediaLibrary. Dash joystick skips tracks via
//      MPMusicPlayerController.systemMusicPlayer.
//    • Local Network — talking to the dash AP at 192.168.1.1. iOS exposes
//      NO API to read this permission's state, so it's shown as
//      informational; "Set" opens Settings where the toggle lives.
//

import SwiftUI
import CoreLocation
import MediaPlayer

struct PermissionsView: View {
    @Environment(AppStatus.self) private var status
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Apple Music authorization, re-read on appear / foreground.
    @State private var musicStatus: MPMediaLibraryAuthorizationStatus = MPMediaLibrary.authorizationStatus()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(
                        title: "Location",
                        detail: locationDetail,
                        granted: locationGranted,
                        actionable: locationActionable,
                        action: requestLocation
                    )
                    row(
                        title: "Apple Music",
                        detail: musicDetail,
                        granted: musicStatus == .authorized,
                        actionable: musicStatus != .authorized,
                        action: requestMusic
                    )
                    row(
                        title: "Local Network",
                        detail: "Needed to reach the Tripper dash at 192.168.1.1 over Wi-Fi. iOS can't report this one — check the toggle in Settings.",
                        granted: nil,
                        actionable: true,
                        action: openSettings
                    )
                } footer: {
                    Text("A green check means the permission is granted. “Set” asks the system for it; if it was denied earlier, iOS only lets you change it in Settings.")
                }
            }
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { musicStatus = MPMediaLibrary.authorizationStatus() }
        }
    }

    // MARK: - Row builder

    @ViewBuilder
    private func row(
        title: String,
        detail: String,
        granted: Bool?,
        actionable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusIcon(granted)
                Text(title).font(.body.weight(.medium))
                Spacer()
                if actionable {
                    Button("Set", action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ granted: Bool?) -> some View {
        switch granted {
        case .some(true):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .some(false):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .none:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }

    // MARK: - Location

    private var locationGranted: Bool {
        status.locationService.authorizationStatus == .authorizedAlways
    }

    /// Actionable (show "Set") until Always is granted. When denied/restricted
    /// the button routes to Settings; otherwise it escalates in-app.
    private var locationActionable: Bool {
        status.locationService.authorizationStatus != .authorizedAlways
    }

    private var locationDetail: String {
        switch status.locationService.authorizationStatus {
        case .authorizedAlways:
            return "Always — the map keeps streaming to the dash with the screen off."
        case .authorizedWhenInUse:
            return "While Using — tap Set to upgrade to Always so it keeps working in your pocket."
        case .denied, .restricted:
            return "Denied. Open Settings to allow location (Always)."
        case .notDetermined:
            return "Not set yet. Tap Set to allow location."
        @unknown default:
            return "Unknown state."
        }
    }

    private func requestLocation() {
        switch status.locationService.authorizationStatus {
        case .denied, .restricted:
            openSettings()
        default:
            status.locationService.requestAuthorization()
        }
    }

    // MARK: - Apple Music

    private var musicDetail: String {
        switch musicStatus {
        case .authorized:
            return "Granted — dash joystick can skip tracks."
        case .denied, .restricted:
            return "Denied. Open Settings to allow Media & Apple Music."
        case .notDetermined:
            return "Not set yet. Tap Set to allow music control."
        @unknown default:
            return "Unknown state."
        }
    }

    private func requestMusic() {
        switch musicStatus {
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { newStatus in
                Task { @MainActor in musicStatus = newStatus }
            }
        default:
            openSettings()
        }
    }

    // MARK: - Settings deep link

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
