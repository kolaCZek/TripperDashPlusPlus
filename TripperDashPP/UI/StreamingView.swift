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

/// Settings cell that shows the on-disk map tile cache size and offers a
/// clear button. Kept as its own `View` (not inlined) so the `@State` for
/// the stats stays scoped — the parent Form re-renders constantly when
/// other settings change and we don't want every keystroke to trigger
/// another disk walk.
private struct MapCacheSection: View {
    @State private var stats: (count: Int, bytes: Int) = (0, 0)
    @State private var isClearing = false

    var body: some View {
        Section("Map cache") {
            // One shared OSM tile cache for both palettes: light and dark
            // render from the SAME raster tiles (dark is a composite-time
            // recolour), so there's a single on-disk namespace and a
            // single row — no per-palette split anymore.
            LabeledContent("Map tiles") {
                statsView(stats)
            }
            Button(role: .destructive) {
                Task {
                    isClearing = true
                    await TileDiskCache.shared.clearAll()
                    await refresh()
                    isClearing = false
                }
            } label: {
                Label("Clear map cache", systemImage: "trash")
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
        // Single shared namespace → aggregate stats is the whole cache.
        stats = await TileDiskCache.shared.statsAll()
    }

    private func formatStats(_ s: (count: Int, bytes: Int)) -> String {
        if s.count == 0 { return "Empty" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB]
        fmt.countStyle = .file
        return "\(s.count) tiles • \(fmt.string(fromByteCount: Int64(s.bytes)))"
    }
}

#Preview {
    NavigationStack { StreamingView() }
        .environment(AppStatus())
}
