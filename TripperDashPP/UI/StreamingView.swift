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
        case .connecting, .handshaking, .connected: return false
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
                Text("Active-nav bubble can show either ETA or remaining distance — pick which one the dash should render.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stream") {
                LabeledContent("Encoded fps",     value: String(format: "%.1f", status.metrics.encodedFps))
                LabeledContent("Bitrate (kbps)",  value: String(format: "%.0f", status.metrics.kbpsOut))
                LabeledContent("NALs emitted",    value: "\(status.metrics.nalsEmitted)")
                LabeledContent("IDR frames",      value: "\(status.metrics.idrCount)")
                LabeledContent("Packets sent",    value: "\(status.metrics.packetsSent)")
                LabeledContent("Packets dropped", value: "\(status.metrics.packetsDropped)")
            }

            Section("Background") {
                Toggle(isOn: Binding(
                    get: { status.keepAwakeWhileStreaming },
                    set: { status.keepAwakeWhileStreaming = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep streaming when screen locks")
                        Text("Uses GPS + silent audio so iOS doesn't suspend the app. A blue indicator appears in the status bar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if status.isStreaming {
                    LabeledContent("Wakelock") {
                        if status.backgroundKeepAliveActive {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Off — screen-off will break stream", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section("Route preferences") {
                Toggle("Avoid highways", isOn: Binding(
                    get: { status.navigationStore.routePreferences.avoidHighways },
                    set: { status.navigationStore.setAvoidHighways($0) }
                ))
                Toggle("Avoid tolls", isOn: Binding(
                    get: { status.navigationStore.routePreferences.avoidTolls },
                    set: { status.navigationStore.setAvoidTolls($0) }
                ))
                Text("Applied to new route calculations and reroutes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Build") {
                LabeledContent("Version", value: "\(status.buildVersion) (\(status.buildNumber))")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { StreamingView() }
        .environment(AppStatus())
}
