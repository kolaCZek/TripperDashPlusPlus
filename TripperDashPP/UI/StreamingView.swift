//
//  StreamingView.swift
//  TripperDashPP
//
//  Phase 4 — control surface for the RTP video pipeline. Start/stop a
//  TestPatternSource → H264Encoder → RtpPacketizer chain pointed at the
//  connected dash, and watch the live counters (fps, kbps, packets,
//  IDRs, drops) update once a second.
//

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

            Section("Stream") {
                LabeledContent("Encoded fps",     value: String(format: "%.1f", status.metrics.encodedFps))
                LabeledContent("Bitrate (kbps)",  value: String(format: "%.0f", status.metrics.kbpsOut))
                LabeledContent("NALs emitted",    value: "\(status.metrics.nalsEmitted)")
                LabeledContent("IDR frames",      value: "\(status.metrics.idrCount)")
                LabeledContent("Packets sent",    value: "\(status.metrics.packetsSent)")
                LabeledContent("Packets dropped", value: "\(status.metrics.packetsDropped)")
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
                        Label("Start test pattern → dash", systemImage: "play.circle.fill")
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
