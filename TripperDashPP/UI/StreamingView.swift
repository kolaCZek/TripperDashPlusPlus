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

struct StreamingView: View {
    @Environment(AppStatus.self) private var status

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("State", value: status.connectionState.rawValue)
                LabeledContent("Wi-Fi", value: status.bikeSsid ?? "—")
                LabeledContent("Dash host", value: status.bikeLink.dashHost ?? "—")
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
                    ForEach(AppStatus.SourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(status.isStreaming)

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
                case .testPattern:
                    Text("Synthetic 526×300 test pattern (clock, frame counter, colour bars). Useful for validating the encoder/RTP path without touching Mapbox.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            Section("Control") {
                if status.isStreaming {
                    Button(role: .destructive) {
                        status.stopStreaming()
                    } label: {
                        Label("Stop streaming", systemImage: "stop.circle.fill")
                    }
                } else {
                    Button {
                        status.startStreaming()
                    } label: {
                        Label("Start \(status.sourceKind.rawValue.lowercased()) → dash", systemImage: "play.circle.fill")
                    }
                    .disabled(status.bikeLink.dashHost == nil)
                }
                if status.bikeLink.dashHost == nil {
                    Text("Connect to the dash first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Build") {
                LabeledContent("Version", value: "\(status.buildVersion) (\(status.buildNumber))")
            }
        }
        .navigationTitle("Streaming")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { StreamingView() }
        .environment(AppStatus())
}
