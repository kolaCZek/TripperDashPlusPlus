//
//  AddBikeSheet.swift
//  TripperDashPP
//
//  Short "add a bike" form presented from the Bikes section: the rider names
//  the bike (e.g. "Guerrilla") and enters its Tripper AP Wi-Fi SSID
//  (RE_XXXX_XXXXX). The dash IP is not asked for — it's always 192.168.1.1.
//

import SwiftUI

/// A small modal form for adding a bike to the garage. Calls `onAdd(name,
/// ssid)` and dismisses when the rider taps Add; Add is disabled until the
/// SSID is non-empty (the name is optional and falls back to the SSID).
struct AddBikeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onAdd: (_ name: String, _ ssid: String) -> Void

    @State private var name: String = ""
    @State private var ssid: String = ""

    private var canAdd: Bool {
        !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Bike name (e.g. Guerrilla)", text: $name)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown in the bike list and on the main screen. Optional — defaults to the Wi-Fi name.")
                }

                Section {
                    TextField("RE_XXXX_XXXXX", text: $ssid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Wi-Fi network (SSID)")
                } footer: {
                    Text("Your Tripper's Wi-Fi network. The dash IP is always 192.168.1.1.")
                }
            }
            .navigationTitle("Add bike")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(name, ssid)
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }
}
