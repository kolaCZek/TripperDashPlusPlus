//
//  StreamingView.swift
//  TripperDashPP
//
//  Phase 1 stub — telemetry surface for the encoder/streamer that lands
//  in Phase 4. Today it just shows zeroed metrics so we can verify the
//  navigation push and @Environment plumbing work end to end.
//

import SwiftUI

struct StreamingView: View {
    @Environment(AppStatus.self) private var status

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("State", value: status.connectionState.rawValue)
                LabeledContent("Wi-Fi", value: status.bikeSsid ?? "—")
                if let err = status.lastError {
                    LabeledContent("Error") {
                        Text(err).foregroundStyle(.red)
                    }
                }
            }
            Section("Stream") {
                LabeledContent("Encoded fps", value: String(format: "%.1f", status.metrics.encodedFps))
                LabeledContent("Bitrate (kbps)", value: String(format: "%.0f", status.metrics.kbpsOut))
                LabeledContent("Packets sent", value: "\(status.metrics.packetsSent)")
                LabeledContent("Packets dropped", value: "\(status.metrics.packetsDropped)")
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
