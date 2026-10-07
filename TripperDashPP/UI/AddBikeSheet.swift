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

/// A small modal form for adding a bike to the garage, or editing a saved
/// one's name. Calls `onSave(name, ssid)` and dismisses when the rider taps
/// Add / Save. Adding requires an SSID in the Tripper AP format
/// (RE_XXXX_XXXXXX); editing shows the SSID read-only, since a different
/// network is a different bike (remove it and add it again).
struct AddBikeSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// nil = add a new bike; set = edit this bike's name.
    let editing: SavedBike?
    let onSave: (_ name: String, _ ssid: String) -> Void

    @State private var name: String
    @State private var ssid: String

    init(editing: SavedBike? = nil, onSave: @escaping (_ name: String, _ ssid: String) -> Void) {
        self.editing = editing
        self.onSave = onSave
        _name = State(initialValue: editing?.name ?? "")
        _ssid = State(initialValue: editing?.ssid ?? "")
    }

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

    /// Typing aid for the SSID field: upper-cases and puts the underscores
    /// of RE_XXXX_XXXXXX where they belong, so "re0w12345678" reads
    /// "RE_0W12_345678". A separator appears only once a character follows
    /// it, so backspace removes it with the character before. Input that
    /// doesn't start with RE is only upper-cased, so the format error still
    /// shows a home Wi-Fi name or the dash IP as typed. Extra characters
    /// are kept, not cut, so a too-long SSID still fails the check.
    // ponytail: rewriting the text moves the cursor to the end, so a
    // mid-string edit jumps; a UITextField delegate fixes that if it bites.
    nonisolated static func formatSSIDInput(_ raw: String) -> String {
        let upper = raw.uppercased()
        let chars = upper.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard chars.hasPrefix("RE") else { return upper }
        var out = "RE"
        for (i, c) in chars.dropFirst(2).enumerated() {
            if i == 0 || i == 4 { out.append("_") }
            out.append(c)
        }
        return out
    }

    private var trimmedSSID: String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Editing never re-validates the SSID: it's read-only, and a legacy
    /// bike saved before the format check must still be renamable.
    private var canAdd: Bool {
        editing != nil || Self.isValidTripperSSID(normalizedSSID)
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
                    if editing != nil {
                        Text(ssid)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("RE_XXXX_XXXXXX", text: $ssid)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onChange(of: ssid) { _, new in
                                let formatted = Self.formatSSIDInput(new)
                                if formatted != new { ssid = formatted }
                            }
                    }
                } header: {
                    Text("Wi-Fi network (SSID)")
                } footer: {
                    if editing != nil {
                        Text("The Wi-Fi network can't be changed. For a different network, remove this bike and add it again.")
                    } else if showFormatError {
                        Text("That doesn't look like a Tripper network name. It should read like RE_0W12_345678 — you'll find it on the dash's phone-pairing screen.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Your Tripper's Wi-Fi network name, e.g. RE_0W12_345678. Find it on the dash's phone-pairing screen.")
                    }
                }
            }
            .navigationTitle(editing == nil ? "Add bike" : "Edit bike")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        onSave(name, editing?.ssid ?? normalizedSSID)
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }
}
