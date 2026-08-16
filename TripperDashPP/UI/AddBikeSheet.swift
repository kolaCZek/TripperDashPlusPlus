//
//  AddBikeSheet.swift
//  TripperDashPP
//
//  Short "add a bike" form presented from the Bikes section: the rider names
//  the bike (e.g. "Guerrilla") and enters its Tripper AP Wi-Fi SSID
//  (RE_XXXX_XXXXXX). The dash IP is a fixed internal constant (192.168.1.1) —
//  the rider never types it, so it is deliberately NOT mentioned on this form
//  (an earlier hint that named the IP led a tester to type it INTO the SSID
//  field, which then failed to join any network — 8/2026 field report).
//

import SwiftUI

/// A small modal form for adding a bike to the garage. Calls `onAdd(name,
/// ssid)` and dismisses when the rider taps Add; Add is disabled until the
/// SSID matches the Tripper AP format (RE_XXXX_XXXXXX).
struct AddBikeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onAdd: (_ name: String, _ ssid: String) -> Void

    @State private var name: String = ""
    @State private var ssid: String = ""

    /// Trimmed, upper-cased SSID as it will be stored/validated.
    private var normalizedSSID: String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// A Tripper AP SSID looks like `RE_XXXX_XXXXXX`: the `RE_` prefix, a
    /// 4-char alphanumeric block, an underscore, then a 6-char alphanumeric
    /// block (e.g. `RE_DEMO_000001`). This guards against the classic mistake
    /// of typing the dash IP (192.168.1.1) or a home Wi-Fi name into the
    /// field — neither of which iOS could ever join as the AP.
    static func isValidTripperSSID(_ s: String) -> Bool {
        s.range(of: #"^RE_[A-Z0-9]{4}_[A-Z0-9]{6}$"#, options: .regularExpression) != nil
    }

    private var trimmedSSID: String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        Self.isValidTripperSSID(normalizedSSID)
    }

    /// Show a corrective hint only once the rider has typed something that
    /// isn't (yet) a valid SSID — don't nag on an empty field.
    private var showFormatError: Bool {
        !trimmedSSID.isEmpty && !canAdd
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
                    TextField("RE_XXXX_XXXXXX", text: $ssid)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Wi-Fi network (SSID)")
                } footer: {
                    if showFormatError {
                        Text("That doesn't look like a Tripper network name. It should read like RE_0W12_345678 — you'll find it on the dash's phone-pairing screen.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Your Tripper's Wi-Fi network name, e.g. RE_0W12_345678. Find it on the dash's phone-pairing screen.")
                    }
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
                        onAdd(name, normalizedSSID)
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }
}
