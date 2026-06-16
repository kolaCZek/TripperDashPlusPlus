//
//  MapPickerView.swift
//  TripperDashPP
//
//  Phase 1 stub — shows app status and a placeholder for the destination
//  picker. Phase 5 swaps the gray rectangle for a real Mapbox MapView
//  and Phase 6 adds search + route preview.
//

import SwiftUI

struct MapPickerView: View {
    @Environment(AppStatus.self) private var status

    var body: some View {
        VStack(spacing: 0) {
            // Status banner — wired up in Phase 3.
            StatusBanner(state: status.connectionState, ssid: status.bikeSsid)

            // Where the Mapbox MapView will live (Phase 5).
            ZStack {
                Color(.secondarySystemBackground)
                VStack(spacing: 12) {
                    Image(systemName: "map")
                        .font(.system(size: 56))
                        .foregroundStyle(.tertiary)
                    Text("Map placeholder")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Mapbox MapView lands in Phase 5")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Phase 6 will replace this with a search bar + "Start navigation"
            // action that hands a Destination to BikeLink.
            NavigationLink {
                StreamingView()
            } label: {
                Label("Open streaming view (dev)", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.15))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StatusBanner: View {
    let state: BikeConnectionState
    let ssid: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.subheadline.weight(.medium))
            Spacer()
            if let ssid {
                Text(ssid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var color: Color {
        switch state {
        case .disconnected:  .gray
        case .wifiJoining:   .yellow
        case .handshaking:   .orange
        case .connected:     .blue
        case .streaming:     .green
        case .error:         .red
        }
    }

    private var label: String {
        switch state {
        case .disconnected: "Not connected"
        case .wifiJoining:  "Join the Tripper Wi-Fi…"
        case .handshaking:  "Handshaking with dash…"
        case .connected:    "Connected — idle"
        case .streaming:    "Streaming"
        case .error:        "Error — see diagnostics"
        }
    }
}

#Preview {
    NavigationStack { MapPickerView() }
        .environment(AppStatus())
}
