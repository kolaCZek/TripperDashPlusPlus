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
        _ssid = State(initialValue: editing?.ssid ?? Self.ssidPrefix)
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

    /// Every Tripper AP SSID starts with this, so the add form starts with it.
    nonisolated static let ssidPrefix = "RE_"

    /// Typing aid for the SSID field: keeps the RE_ prefix, upper-cases, and
    /// puts the second underscore of RE_XXXX_XXXXXX where it belongs, so
    /// typing "0w12345678" after the prefix reads "RE_0W12_345678".
    /// It only shapes, it never cleans: dashes, dots and spaces are left in,
    /// so a home Wi-Fi name or the dash IP still fails the format check
    /// (the 8/2026 field report) instead of being coerced into one.
    /// - The prefix can't be deleted; backspace on it puts it back.
    /// - Text that doesn't start with RE (select-all + paste) is left as
    ///   typed, upper-cased, so the format error shows it.
    /// - The second underscore goes in only after 4 letters/digits and once
    ///   a character follows, so backspace removes it with that character.
    /// - A full SSID pasted after the prefix ("RE_RE_0W12_…") drops the
    ///   doubled prefix; a code that merely starts with RE (RE_RE12_…) is
    ///   kept, since only a body longer than an SSID's 11 is trimmed.
    // ponytail: rewriting the text moves the cursor to the end, so a
    // mid-string edit jumps; a UITextField delegate fixes that if it bites.
    nonisolated static func formatSSIDInput(_ raw: String) -> String {
        let upper = raw.uppercased()
        if ssidPrefix.hasPrefix(upper) { return ssidPrefix }
        var body: Substring
        if upper.hasPrefix(ssidPrefix) {
            body = upper.dropFirst(3)
        } else if upper.hasPrefix("RE") {
            body = upper.dropFirst(2)
        } else {
            return upper
        }
        while body.count > 11, body.hasPrefix(ssidPrefix) { body = body.dropFirst(3) }
        let isCode = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber) }
        if body.count > 4, body.prefix(4).allSatisfy(isCode), body.dropFirst(4).first != "_" {
            return ssidPrefix + String(body.prefix(4)) + "_" + String(body.dropFirst(4))
        }
        return ssidPrefix + String(body)
    }

    /// Editing never re-validates the SSID: it's read-only, and a legacy
    /// bike saved before the format check must still be renamable.
    private var canAdd: Bool {
        editing != nil || Self.isValidTripperSSID(normalizedSSID)
    }

    /// Show a corrective hint only once the rider has typed something that
    /// isn't (yet) a valid SSID — not while the field holds just the prefix.
    private var showFormatError: Bool {
        normalizedSSID != Self.ssidPrefix && !canAdd
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
