//
//  KnownNetworksSettingsView.swift
//  TripperDashPP
//
//  Settings UI for the saved dash Wi-Fi list. Replaces the old free-form
//  "SSID" + "Dash IP" text fields with a managed list:
//
//    • one row per saved network, SSID shown verbatim
//    • a green dot on the row whose SSID is the one we're connected to now
//    • swipe-to-delete to forget a network
//    • a per-row "Connect" button (join that network + start the dash link)
//    • an "Add" button opening a dialog to enter a new RE_… SSID
//
//  ── Free vs paid behaviour ──────────────────────────────────────────
//  The green "currently connected" dot and the per-row Connect's Wi-Fi
//  join both need the paid NetworkExtension entitlements. On a free
//  account `currentSSID()` returns nil (no dots) and `join()` fails with
//  a friendly error surfaced on the link. The list, Add, delete, and the
//  plain dash connect all work regardless — see docs/WIFI_MANAGEMENT.md.
//

import SwiftUI

struct KnownNetworksSettingsView: View {
    @Environment(AppStatus.self) private var status

    /// SSID we're currently associated to, re-read when the view appears
    /// and after a join. `nil` on a free account (entitlement absent) or
    /// when off Wi-Fi → no green dot, which is the intended degradation.
    @State private var connectedSSID: String?
    @State private var showingAdd = false
    @State private var newSSID = ""
    @State private var newPassphrase = KnownNetwork.factoryPassphrase

    /// Editing is only safe while the link is idle/errored — mirrors the
    /// old SSID-field gating so we don't mutate the target mid-handshake.
    private var isEditableState: Bool { status.linkIsIdle }

    var body: some View {
        Section {
            if status.knownNetworks.isEmpty {
                Text("No saved dash networks yet. Tap Add and enter the Wi-Fi name printed on / shown by your dash (looks like RE_xxxxxx).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(status.knownNetworks.networks) { network in
                    row(for: network)
                }
                .onDelete { offsets in
                    deleteNetworks(at: offsets)
                }
            }

            Button {
                newSSID = ""
                newPassphrase = KnownNetwork.factoryPassphrase
                showingAdd = true
            } label: {
                Label("Add network", systemImage: "plus.circle.fill")
            }
            .disabled(!isEditableState)
        } header: {
            Text("Dash Wi-Fi networks")
        } footer: {
            footerText
        }
        .task { await refreshConnectedSSID() }
        .alert("Add dash network", isPresented: $showingAdd) {
            TextField("SSID (e.g. RE_1A2B3C)", text: $newSSID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Wi-Fi password", text: $newPassphrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { addNetwork() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The password is pre-filled with the Royal Enfield factory default. Change it only if you changed your dash's Wi-Fi password.")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for network: KnownNetwork) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(network.ssid)
                    .font(.body)
                if connectedSSID == network.ssid {
                    Text("Connected")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            // Per-row Connect — joins THIS network then starts the link.
            // Hidden while the link is busy so we don't offer a connect
            // mid-handshake; the main control button owns that state.
            if isEditableState {
                Button {
                    Task { await connectTo(network) }
                } label: {
                    Text("Connect")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

            // Green "currently connected" dot.
            Circle()
                .fill(connectedSSID == network.ssid ? Color.green : Color.clear)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: connectedSSID == network.ssid ? 0 : 1)
                )
                .accessibilityLabel(connectedSSID == network.ssid ? "Connected" : "Not connected")
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var footerText: some View {
        if status.wifiManager.didReadSSIDAtLeastOnce {
            Text("The green dot marks the network you're connected to. Swipe a row to delete it.")
        } else {
            // Either we just haven't read yet, or (free account) we can't.
            Text("Tip: join the dash Wi-Fi, then tap Connect. Swipe a row to delete it.")
        }
    }

    // MARK: - Actions

    private func addNetwork() {
        let trimmed = newSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pass = newPassphrase.isEmpty ? KnownNetwork.factoryPassphrase : newPassphrase
        status.knownNetworks.add(ssid: trimmed, passphrase: pass)
    }

    private func deleteNetworks(at offsets: IndexSet) {
        // Forget the iOS hotspot config too so we don't keep auto-rejoining
        // a network the rider just removed from the app.
        for idx in offsets {
            let net = status.knownNetworks.networks[idx]
            if let ssid = net.normalizedSSID {
                status.wifiManager.forget(ssid: ssid)
            }
        }
        status.knownNetworks.remove(atOffsets: offsets)
    }

    private func connectTo(_ network: KnownNetwork) async {
        await status.joinAndConnect(network)
        await refreshConnectedSSID()
    }

    private func refreshConnectedSSID() async {
        connectedSSID = await status.wifiManager.currentSSID()
    }
}
