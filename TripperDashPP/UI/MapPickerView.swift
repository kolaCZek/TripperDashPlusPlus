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

                    if case .error = status.bikeLink.state, let err = status.lastError {
                        Text(err)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .padding(.horizontal, 24)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            // Phase 3 — Connect / Disconnect button. Phase 6 will replace
            // this with a search bar + "Start navigation" action.
            connectButton
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        switch status.bikeLink.state {
        case .idle, .error:
            Button {
                status.bikeLink.connect()
            } label: {
                Label("Connect to dash", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.15))
            }
            .buttonStyle(.plain)
        case .connecting, .handshaking:
            HStack {
                ProgressView()
                Text("Connecting…")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.orange.opacity(0.15))
        case .connected:
            VStack(spacing: 8) {
                NavigationLink {
                    StreamingView()
                } label: {
                    Label("Open streaming view", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green.opacity(0.15))
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    status.bikeLink.disconnect()
                } label: {
                    Text("Disconnect")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
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
