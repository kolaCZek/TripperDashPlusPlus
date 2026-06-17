//
//  MapPickerView.swift
//  TripperDashPP
//
//  Phase 5 — Apple Maps preview with the current GPS centered. Phase 6
//  (real one — destinations + routing, not the keep-alive Phase 6 we
//  already shipped) will add a search bar and route line on top.
//
//  Note: this view used to use SwiftUI's `Map(position:)` (which wraps
//  MKMapView) but that crashed on view transitions — SwiftUI dealloc'd
//  the underlying MKMapView while its Metal command buffer was still
//  in flight, triggering MTLDebugDevice assertion + app freeze.
//
//  Replaced with `MapPreviewView`, which renders MKMapSnapshotter into
//  a UIImage at 1 Hz. No live MKMapView, no Metal lifecycle to manage.
//

import CoreLocation
import MapKit
import SwiftUI

struct MapPickerView: View {
    @Environment(AppStatus.self) private var status
    /// LocationService slot we hold while the picker is on-screen. We
    /// MUST release it in .onDisappear, otherwise each push/pop of
    /// MapPicker leaks a consumer and the service stays at .mapping
    /// accuracy forever (battery + log spam).
    @State private var locationToken: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Status banner — wired up in Phase 3.
            StatusBanner(state: status.connectionState, ssid: status.bikeSsid)

            // Phase 5: Apple Maps preview rendered via MKMapSnapshotter
            // at 1 Hz. Same renderer that the dash sees, but at the
            // phone's native size — handy as a sanity check.
            ZStack {
                MapPreviewView(
                    coordinate: status.locationService.lastFix?.coordinate,
                    heading: nil  // always north-up in the picker
                )
                .onAppear {
                    if locationToken == nil {
                        locationToken = status.locationService.start(mode: .mapping)
                    }
                }
                .onDisappear {
                    if let token = locationToken {
                        status.locationService.stop(token: token)
                        locationToken = nil
                    }
                }

                if case .error = status.bikeLink.state, let err = status.lastError {
                    VStack {
                        Spacer()
                        Text(err)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial)
                            .clipShape(.rect(cornerRadius: 8))
                            .padding(.bottom, 12)
                    }
                }
            }

            // Phase 3 — Connect / Disconnect button. Phase 6 (the navigation
            // one — not the wakelock Phase 6 we already shipped) will
            // replace this with a search bar + "Start navigation" action.
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
