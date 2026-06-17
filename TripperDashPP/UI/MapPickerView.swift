//
//  MapPickerView.swift
//  TripperDashPP
//
//  Phase 7a (current) — top-level destination/navigation view.
//
//  Architecture: the picker has two mutually exclusive UI phases that
//  match the underlying streaming state:
//
//    • .picking  — live MKMapView, "Navigate" CTA, no stream running.
//    • .navigating — placeholder nav HUD (ETA / dist / turns come in
//                    7b), "Stop navigation" CTA, stream pumping to dash.
//
//  Why mutually exclusive? Apple Maps SDK has an internal shared GPU
//  resource pool. Running a live `MKMapView` and `MKMapSnapshotter` at
//  the same time triggers MTLDebugDevice assertions on view transitions
//  ("Metal object destroyed while still required by command buffer").
//  We tried to coordinate them with parking ring buffers (MapViewPark +
//  SnapshotterPark) — works in isolation, still races when both pools
//  are live. So instead: only ONE map subsystem is alive at any time.
//
//  Transitions go through a brief `.transitioning` phase (~500 ms
//  spinner) that yanks the old subsystem out of the view tree before
//  starting the new one — gives Apple Maps' shared pool time to drain.
//
//  Diagnostics (test pattern, raw metrics, source picker, manual
//  start/stop) live behind the toolbar gear icon — pre-flight tool,
//  not the primary path.
//

import CoreLocation
import MapKit
import SwiftUI

struct MapPickerView: View {
    @Environment(AppStatus.self) private var status

    /// LocationService slot we hold while the picker (with live map) is
    /// on-screen. MUST be released in .onDisappear of the picking view,
    /// otherwise each push/pop leaks a consumer and the service stays
    /// at .mapping accuracy forever.
    @State private var locationToken: UUID?

    /// True during the ~500 ms window between view phases — neither
    /// MKMapView nor MapSnapshotSource are active. Prevents the GPU
    /// pool race described in the header.
    @State private var transitioning = false

    /// Sheet flag for the diagnostics screen (was StreamingView when
    /// it lived in the navigation stack).
    @State private var showDiagnostics = false

    private enum DisplayMode { case picking, navigating, transitioning }
    private var mode: DisplayMode {
        if transitioning { return .transitioning }
        return status.isStreaming ? .navigating : .picking
    }

    var body: some View {
        VStack(spacing: 0) {
            StatusBanner(state: status.connectionState, ssid: status.bikeSsid)

            ZStack {
                switch mode {
                case .picking:      pickingBody
                case .navigating:   navigatingBody
                case .transitioning: transitioningBody
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlButton
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showDiagnostics = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Diagnostics")
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack { StreamingView() }
                .environment(status)
        }
    }

    // MARK: - Phase bodies

    /// Live interactive map. Used to pick a destination (7b) or just
    /// orient yourself before navigating. Only present in .picking mode.
    @ViewBuilder
    private var pickingBody: some View {
        InteractiveMapView(
            coordinate: status.locationService.lastFix?.coordinate,
            followsUser: true
        )
        .ignoresSafeArea(edges: .horizontal)
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
    }

    /// Stream is up, dash is mirroring the map. Phone shows a status
    /// HUD instead of a live map (7b will add ETA, distance to next
    /// turn, current street name). No MKMapView here = no GPU pool
    /// fight with MapSnapshotSource.
    @ViewBuilder
    private var navigatingBody: some View {
        VStack(spacing: 24) {
            Image(systemName: "location.north.line.fill")
                .font(.system(size: 88))
                .foregroundStyle(.green)
                .symbolEffect(.pulse, options: .repeating)

            Text("Navigating")
                .font(.largeTitle.weight(.semibold))

            VStack(spacing: 6) {
                LabeledContent("Encoded fps", value: String(format: "%.1f", status.metrics.encodedFps))
                LabeledContent("Bitrate",     value: String(format: "%.0f kbps", status.metrics.kbpsOut))
                if let fix = status.locationService.lastFix {
                    LabeledContent("GPS", value: String(format: "%.5f, %.5f", fix.coordinate.latitude, fix.coordinate.longitude))
                }
                LabeledContent("Background", value: status.backgroundKeepAliveActive ? "active" : "—")
            }
            .font(.caption.monospaced())
            .padding()
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
            .clipShape(.rect(cornerRadius: 12))
            .padding(.horizontal)

            Text("ETA, distance and turn-by-turn — Phase 7b.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(.top, 40)
    }

    /// Brief blank state between phases. Lets the previous map
    /// subsystem (MKMapView or MapSnapshotter) finish its GPU work
    /// before we touch Apple Maps again.
    @ViewBuilder
    private var transitioningBody: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(status.isStreaming ? "Starting navigation…" : "Stopping navigation…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Control button

    @ViewBuilder
    private var controlButton: some View {
        switch (mode, status.bikeLink.state) {
        case (.transitioning, _):
            HStack {
                ProgressView()
                Text("Switching…")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.gray.opacity(0.15))

        case (.navigating, _):
            Button(role: .destructive) {
                stopNavigation()
            } label: {
                Label("Stop navigation", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.15))
            }
            .buttonStyle(.plain)

        case (.picking, .idle), (.picking, .error):
            Button {
                status.bikeLink.connect()
            } label: {
                Label("Connect to dash", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.15))
            }
            .buttonStyle(.plain)

        case (.picking, .connecting), (.picking, .handshaking):
            HStack {
                ProgressView()
                Text("Connecting…")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.orange.opacity(0.15))

        case (.picking, .connected):
            VStack(spacing: 8) {
                Button {
                    startNavigation()
                } label: {
                    Label("Navigate", systemImage: "location.north.line.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green.opacity(0.15))
                }
                .buttonStyle(.plain)
                .disabled(status.bikeLink.dashHost == nil)

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

    // MARK: - Transition handlers

    /// Flip into .transitioning so SwiftUI yanks `pickingBody` (and its
    /// MKMapView) out of the view tree. Wait long enough for
    /// MapViewPark to drain its hardened-teardown sequence and for
    /// Apple Maps' shared GPU pool to settle. Then start the streamer,
    /// which spins up MapSnapshotSource. The phase flips to .navigating
    /// automatically once status.isStreaming becomes true.
    private func startNavigation() {
        guard status.bikeLink.dashHost != nil, !status.isStreaming else { return }
        transitioning = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            status.startStreaming()
            // status.isStreaming flipped to true synchronously; the
            // computed `mode` will return .navigating after we drop
            // the transitioning flag.
            transitioning = false
        }
    }

    /// Mirror of startNavigation. Stop the streamer immediately
    /// (synchronously cancels MapSnapshotSource's timer; any in-flight
    /// snapshotter is held by SnapshotterPark until its GPU work
    /// drains), show the spinner for 500 ms, then let SwiftUI mount
    /// the picker's MKMapView. By that point Apple Maps' shared GPU
    /// pool is quiet.
    private func stopNavigation() {
        status.stopStreaming()
        transitioning = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            transitioning = false
        }
    }
}

// MARK: - Status banner

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
