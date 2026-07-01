//
//  StreamingView.swift
//  TripperDashPP
//
//  Settings surface. The actual stream lifecycle is driven from
//  MapPickerView: starting navigation also starts the RTP pipeline
//  (MapViewSource → H264Encoder → RtpPacketizer), and ending navigation
//  tears it down. This view is read-mostly — pick units, watch live
//  stream counters, read the build.
//

import CoreLocation
import SwiftUI

struct StreamingView: View {
    @Environment(AppStatus.self) private var status

    /// Allow editing the SSID/IP only when we're not actively connected
    /// or mid-handshake. Idle and error states are both safe entry
    /// points for retrying with different credentials.
    private var isEditableState: Bool {
        switch status.bikeLink.state {
        case .idle, .error: return true
        case .connecting, .handshaking, .reconnecting, .connected: return false
        }
    }

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("State", value: status.connectionState.rawValue)
                if isEditableState {
                    TextField("Bike Wi-Fi (SSID)", text: Binding(
                        get: { status.bikeLink.ssid },
                        set: { status.bikeLink.ssid = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField("Dash IP", text: Binding(
                        get: { status.bikeLink.bikeHost },
                        set: { status.bikeLink.bikeHost = $0 }
                    ))
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                } else {
                    LabeledContent("Wi-Fi", value: status.bikeSsid ?? "—")
                    LabeledContent("Dash host", value: status.bikeLink.bikeHost)
                }
                if let err = status.lastError {
                    LabeledContent("Error") {
                        Text(err).foregroundStyle(.red)
                    }
                }
            }

            Section("Dash display") {
                Picker("Units", selection: Binding(
                    get: { status.dashNavSettings.units },
                    set: { status.dashNavSettings.units = $0 }
                )) {
                    ForEach(DashNavSettings.UnitSystem.allCases) { u in
                        Text(u.label).tag(u)
                    }
                }
                Picker("Decimal separator", selection: Binding(
                    get: { status.dashNavSettings.decimalSeparator },
                    set: { status.dashNavSettings.decimalSeparator = $0 }
                )) {
                    ForEach(DashNavSettings.DecimalSeparator.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                Picker("Clock", selection: Binding(
                    get: { status.dashNavSettings.clockFormat },
                    set: { status.dashNavSettings.clockFormat = $0 }
                )) {
                    ForEach(DashNavSettings.ClockFormat.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                Picker("Bubble bottom row", selection: Binding(
                    get: { status.dashNavSettings.bottomLine },
                    set: { status.dashNavSettings.bottomLine = $0 }
                )) {
                    ForEach(DashNavSettings.BottomLineMode.allCases) { b in
                        Text(b.label).tag(b)
                    }
                }
            }

            Section("Notifications") {
                Toggle(isOn: Binding(
                    get: { status.dashNavSettings.callStateEnabled },
                    set: { status.dashNavSettings.callStateEnabled = $0 }
                )) {
                    Text("Incoming call")
                }

                Toggle(isOn: Binding(
                    get: { status.dashNavSettings.messageNotifyEnabled },
                    set: { status.dashNavSettings.messageNotifyEnabled = $0 }
                )) {
                    Text("Incoming message")
                }

                Toggle(isOn: Binding(
                    get: { status.dashNavSettings.weatherAlertsEnabled },
                    set: { status.dashNavSettings.weatherAlertsEnabled = $0 }
                )) {
                    Text("Weather alerts")
                }

                Toggle(isOn: Binding(
                    get: { status.dashNavSettings.speedCamerasEnabled },
                    set: { status.dashNavSettings.speedCamerasEnabled = $0 }
                )) {
                    Text("Speed cameras")
                }

                Picker("Speed limit", selection: Binding(
                    get: { status.dashNavSettings.speedLimitDisplay },
                    set: { status.dashNavSettings.speedLimitDisplay = $0 }
                )) {
                    ForEach(DashNavSettings.SpeedLimitDisplay.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if status.dashNavSettings.speedLimitDisplay == .overOnly {
                    Stepper(
                        "Speeding tolerance: +\(status.dashNavSettings.speedLimitOverToleranceDisplay) \(status.dashNavSettings.speedLimitToleranceUnit)",
                        value: Binding(
                            get: { status.dashNavSettings.speedLimitOverToleranceDisplay },
                            set: { status.dashNavSettings.speedLimitOverToleranceDisplay = $0 }
                        ),
                        in: 0...20
                    )
                }
                Text("Shows the posted limit as a road sign in the bottom-right corner. From OpenStreetMap data — coverage varies and untagged roads show nothing, so treat a missing sign as unknown, not zero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Route preferences live ONLY in the planning panel's
            // sliders button now (feat/route-waypoints). Removed from
            // here so there's a single source of truth the user edits.

            Section("Map") {
                Picker("Appearance", selection: Binding(
                    get: { status.mapStyleSettings.mode },
                    set: { status.setMapStyleMode($0) }
                )) {
                    ForEach(MapStyleSettings.Mode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                if status.mapStyleSettings.mode == .auto {
                    LabeledContent("Currently",
                                   value: status.effectiveMapStyle == .dark ? "Dark" : "Light")
                }
                Text("Auto follows local sunrise and sunset from your GPS position. Light and dark map tiles are cached separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            MapCacheSection()

            Section("Build") {
                LabeledContent("Version", value: "\(status.buildVersion) (\(status.buildCommitSHA))")
            }
            // NOTE: the parenthesised value is the short git commit SHA the
            // build came from (stamped by tools/stamp-git-sha.sh), not the
            // CFBundleVersion build number.
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings cell that shows the total on-disk cache footprint (map tiles
/// + speed-limit + speed-camera data) and offers a single "Clear cache"
/// button that wipes all three. Kept as its own `View` (not inlined) so
/// the `@State` for the stats stays scoped — the parent Form re-renders
/// constantly when other settings change and we don't want every
/// keystroke to trigger another disk walk.
private struct MapCacheSection: View {
    @State private var stats: (count: Int, bytes: Int) = (0, 0)
    @State private var isClearing = false

    var body: some View {
        Section("Cache") {
            // One row for the whole on-disk footprint: OSM tiles plus the
            // RideAlerts JSON caches (speed limits + cameras). They all
            // live under Caches/ and are all safe to drop — the app just
            // re-fetches on the next ride.
            LabeledContent("Cached data") {
                statsView(stats)
            }
            Button(role: .destructive) {
                Task {
                    isClearing = true
                    // Clear all three caches. Map tiles are the bulk;
                    // clearing the speed-limit cache is also what fixes a
                    // stale pre-shadow-guard entry still showing a phantom
                    // limit (e.g. a 90 on a 50 street).
                    await TileDiskCache.shared.clearAll()
                    await SpeedLimitService.shared.clearDiskCache()
                    await SpeedCameraService.shared.clearDiskCache()
                    await refresh()
                    isClearing = false
                }
            } label: {
                Label("Clear cache", systemImage: "trash")
            }
            .disabled(isClearing || stats.bytes == 0)
        }
        .task {
            // First appearance: load real numbers. Cheap walk (~few
            // hundred files at most), no need for a background queue.
            await refresh()
        }
    }

    @ViewBuilder
    private func statsView(_ s: (count: Int, bytes: Int)) -> some View {
        if isClearing {
            ProgressView()
        } else {
            Text(formatStats(s))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func refresh() async {
        // Sum all three on-disk caches so the row reflects the true
        // footprint and the button enables whenever ANY cache has data
        // (not just map tiles).
        let tiles = await TileDiskCache.shared.statsAll()
        let limits = await SpeedLimitService.shared.diskCacheStats()
        let cameras = await SpeedCameraService.shared.diskCacheStats()
        stats = (count: tiles.count + limits.count + cameras.count,
                 bytes: tiles.bytes + limits.bytes + cameras.bytes)
    }

    private func formatStats(_ s: (count: Int, bytes: Int)) -> String {
        if s.count == 0 { return "Empty" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB]
        fmt.countStyle = .file
        let files = s.count == 1 ? "1 file" : "\(s.count) files"
        return "\(files) • \(fmt.string(fromByteCount: Int64(s.bytes)))"
    }
}

#Preview {
    NavigationStack { StreamingView() }
        .environment(AppStatus())
}
