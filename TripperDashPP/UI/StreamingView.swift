//
//  StreamingView.swift
//  TripperDashPP
//
//  Phase 4 — control surface for the RTP video pipeline. Start/stop a
//  TestPatternSource → H264Encoder → RtpPacketizer chain pointed at the
//  connected dash, and watch the live counters (fps, kbps, packets,
//  IDRs, drops) update once a second.
//

import CoreLocation
import SwiftUI
import UIKit

struct StreamingView: View {
    @Environment(AppStatus.self) private var status

    /// Toggles the share sheet for the most recent scan CSV log.
    @State private var scanShareURL: URL?

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

            Section("Source") {
                Picker("Frame source", selection: Binding(
                    get: { status.sourceKind },
                    set: { status.sourceKind = $0 }
                )) {
                    // Hide the maneuver-scan kind — it's selected
                    // implicitly via the toggle below, not from the
                    // picker (avoids the "I picked scan but forgot to
                    // arm it" footgun).
                    ForEach(AppStatus.SourceKind.allCases.filter { $0 != .maneuverScan }) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(status.isStreaming || status.dashNavSettings.maneuverScanEnabled)

                switch status.sourceKind {
                case .liveMap:
                    Text("Renders a Mapbox map centred on your current GPS at 12 fps. Requires location permission and a valid `pk.*` token in Secrets.xcconfig.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let fix = status.locationService.lastFix {
                        LabeledContent("GPS", value: String(format: "%.5f, %.5f  (±%.0f m)", fix.coordinate.latitude, fix.coordinate.longitude, fix.horizontalAccuracy))
                            .font(.caption.monospaced())
                    } else {
                        Text("GPS: acquiring…").font(.caption).foregroundStyle(.secondary)
                    }
                case .mapView:
                    Text("Live MKMapView mounted in the HUD (visible thumb). Renders @ 6 fps via layer.render(in:). Keeps MapKit alive in BG without the MKMapSnapshotter throttle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let fix = status.locationService.lastFix {
                        LabeledContent("GPS", value: String(format: "%.5f, %.5f  (±%.0f m)", fix.coordinate.latitude, fix.coordinate.longitude, fix.horizontalAccuracy))
                            .font(.caption.monospaced())
                    }
                case .testPattern:
                    Text("Synthetic 526×300 test pattern (clock, frame counter, colour bars). Useful for validating the encoder/RTP path without touching Mapbox.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .maneuverScan:
                    // Never visible (filtered out above), but the
                    // switch must be exhaustive.
                    EmptyView()
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

            Section {
                Toggle("Suppress ETA TLV", isOn: Binding(
                    get: { status.dashNavSettings.suppressEtaTlv },
                    set: { status.dashNavSettings.suppressEtaTlv = $0 }
                ))
                Toggle("Send 1 Hz heartbeat", isOn: Binding(
                    get: { status.dashNavSettings.sendHeartbeat0044 },
                    set: { status.dashNavSettings.sendHeartbeat0044 = $0 }
                ))
                Toggle("Send initial-burst packet 9", isOn: Binding(
                    get: { status.dashNavSettings.sendInitialBurstPacket9 },
                    set: { status.dashNavSettings.sendInitialBurstPacket9 = $0 }
                ))
                Toggle("Verbose packet logging", isOn: Binding(
                    get: { status.dashNavSettings.verbosePacketLogging },
                    set: { status.dashNavSettings.verbosePacketLogging = $0 }
                ))
            } header: {
                Text("Diagnostics (Bug 3 / Bug 4)")
            } footer: {
                Text("A/B-test toggles for the dash clock-shift bug. Defaults match shipping behaviour; flip individual switches off, reconnect to the bike, watch whether the dash clock still jumps. Verbose logging surfaces every ETA tick and outbound packet to Console.app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Maneuver scanner
            //
            // Empirical sweep that pushes every byte through the primary
            // maneuver TLV (`05 02 00 01 XX`) one at a time while the
            // RTP stream burns the same byte large into the H.264 frame.
            // The rider points a camera at the dash + iPhone, then walks
            // through the captured video offline to map bytes → glyphs.
            // Resulting CSV is shared from this section.
            Section {
                Toggle("Enable maneuver scanner", isOn: Binding(
                    get: { status.dashNavSettings.maneuverScanEnabled },
                    set: { status.dashNavSettings.maneuverScanEnabled = $0 }
                ))
                .disabled(status.isStreaming)

                if status.dashNavSettings.maneuverScanEnabled {
                    HStack {
                        Text("Start byte")
                        Spacer()
                        Text(String(format: "0x%02X", status.dashNavSettings.scanStartByte))
                            .font(.body.monospaced())
                    }
                    Stepper(value: Binding(
                        get: { Int(status.dashNavSettings.scanStartByte) },
                        set: { status.dashNavSettings.scanStartByte = UInt8(clamping: $0) }
                    ), in: 0...255) {
                        Text("Start byte stepper").hidden()
                    }
                    .labelsHidden()

                    HStack {
                        Text("End byte")
                        Spacer()
                        Text(String(format: "0x%02X", status.dashNavSettings.scanEndByte))
                            .font(.body.monospaced())
                    }
                    Stepper(value: Binding(
                        get: { Int(status.dashNavSettings.scanEndByte) },
                        set: { status.dashNavSettings.scanEndByte = UInt8(clamping: $0) }
                    ), in: 0...255) {
                        Text("End byte stepper").hidden()
                    }
                    .labelsHidden()

                    HStack {
                        Text("Hold per byte")
                        Spacer()
                        Text("\(status.dashNavSettings.scanHoldMs) ms")
                            .font(.body.monospaced())
                    }
                    Stepper(value: Binding(
                        get: { status.dashNavSettings.scanHoldMs },
                        set: { status.dashNavSettings.scanHoldMs = $0 }
                    ), in: 1000...30000, step: 500) {
                        Text("Hold stepper").hidden()
                    }
                    .labelsHidden()

                    HStack {
                        Text("Pause between")
                        Spacer()
                        Text("\(status.dashNavSettings.scanPauseMs) ms")
                            .font(.body.monospaced())
                    }
                    Stepper(value: Binding(
                        get: { status.dashNavSettings.scanPauseMs },
                        set: { status.dashNavSettings.scanPauseMs = $0 }
                    ), in: 0...5000, step: 250) {
                        Text("Pause stepper").hidden()
                    }
                    .labelsHidden()

                    // Live banner with current byte + progress when
                    // the scan is actually running.
                    if let loop = status.maneuverScannerLoop, loop.isRunning {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Sending")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "0x%02X  (dec %d)",
                                            loop.currentByte, loop.currentByte))
                                    .font(.headline.monospaced())
                                    .foregroundStyle(.orange)
                            }
                            ProgressView(value: loop.progress)
                        }
                    }

                    // CSV share — appears as soon as the scanner has
                    // written its header (first byte sent).
                    if let url = status.maneuverScannerLoop?.csvLogURL {
                        Button {
                            scanShareURL = url
                        } label: {
                            Label("Share scan CSV", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } header: {
                Text("Maneuver scanner")
            } footer: {
                Text("Empirical sweep through every primary-maneuver byte (TLV 05 02 00 01 XX). The RTP frame shows the same hex burned-in large; pair the camera-captured dash glyph with the CSV log to map byte → maneuver. Each byte holds for `Hold`, then a black `Pause` frame, then advances. Stand still on the bike — dash will display whatever glyph it knows for the byte.")
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

            Section {
                Text("Picture-in-Picture hosts a 90×54 thumbnail above the navigation view (top-right) — it keeps the MapKit / GPU pipeline alive while the screen is locked.\n\nWhy: iOS suspends regular apps on lock. PiP convinces the system we're a video player, so `MKMapSnapshotter` keeps running and the stream to the dash doesn't stall. Same trick as Waze and GMaps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Background runtime (PiP)")
            } footer: {
                Text("The PiP thumbnail is only visible during active navigation in MapPickerView. This screen just explains it; the preview view was moved there so it keeps the PiP controller alive even when this settings screen is closed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

            Section("Control") {
                if status.isStreaming {
                    Button(role: .destructive) {
                        status.stopStreaming()
                    } label: {
                        Label(
                            status.dashNavSettings.maneuverScanEnabled
                                ? "Stop maneuver scan"
                                : "Stop streaming",
                            systemImage: "stop.circle.fill"
                        )
                    }
                } else {
                    Button {
                        status.startStreaming()
                    } label: {
                        if status.dashNavSettings.maneuverScanEnabled {
                            Label("Start maneuver scan → dash", systemImage: "scope")
                        } else {
                            Label("Start \(status.sourceKind.rawValue.lowercased()) → dash", systemImage: "play.circle.fill")
                        }
                    }
                    .disabled(status.bikeLink.dashHost == nil)
                }
                if status.bikeLink.dashHost == nil {
                    Text("Connect to the dash first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .navigationTitle("Streaming")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(
            get: { scanShareURL != nil },
            set: { newValue in if !newValue { scanShareURL = nil } }
        )) {
            if let url = scanShareURL {
                ActivityShareSheet(items: [url])
            }
        }
    }
}

/// UIKit `UIActivityViewController` wrapped for SwiftUI. `ShareLink`
/// works fine for URL/Text/Image, but the scan CSV is a real on-disk
/// file the user needs to airdrop / mail off the device — this gives
/// the user the standard "Save to Files" / "Mail" / "AirDrop" sheet
/// without any extra preview rendering.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack { StreamingView() }
        .environment(AppStatus())
}
