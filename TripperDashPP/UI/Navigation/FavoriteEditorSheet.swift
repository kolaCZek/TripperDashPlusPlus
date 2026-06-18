//
//  FavoriteEditorSheet.swift
//  TripperDashPP
//
//  Phase 7d — create or edit a favorite. Two creation paths:
//    - "Add favorite" with no destination → user has to search/tap a
//      location first (in this version: show "use a destination from
//      search/pin first" hint; simpler than embedding a second search).
//    - "Add to favorites" from an already-resolved Destination → form
//      is pre-filled, user just gives it a name + icon.
//

import SwiftUI
import CoreLocation

struct FavoriteEditorSheet: View {
    @Environment(NavigationStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Existing favorite to edit, or nil to create from `seed`.
    let existing: Favorite?
    /// Destination payload when adding a new favorite. nil if editing.
    let seed: Destination?

    @State private var name: String = ""
    @State private var icon: String = ""
    @State private var pinToQuickAccess: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Home / Work / Mountain hut…", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Icon") {
                    TextField("SF Symbol name (optional)", text: $icon)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Leave blank to auto-pick from the name (e.g. \"Home\" → house, \"Work\" → briefcase, fuel/coffee/etc. are detected).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let dest = seed ?? existing.map({
                    Destination(id: $0.id, name: $0.name, addressLine: $0.addressLine, coordinate: $0.coordinate)
                }) {
                    Section("Location") {
                        Text(dest.addressLine ?? "—").font(.footnote)
                        Text(String(format: "%.5f, %.5f", dest.coordinate.latitude, dest.coordinate.longitude))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if existing == nil {
                    Section {
                        Toggle("Pin to Quick Access", isOn: $pinToQuickAccess)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New favorite" : "Edit favorite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    icon = existing.iconSymbol ?? ""
                } else if let seed {
                    name = seed.name
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedIcon = icon.trimmingCharacters(in: .whitespaces)
        let resolvedIcon = trimmedIcon.isEmpty ? nil : trimmedIcon
        if let existing {
            var updated = existing
            updated.name = trimmedName
            updated.iconSymbol = resolvedIcon
            store.updateFavorite(updated)
        } else if let seed {
            let fav = Favorite(name: trimmedName,
                               iconSymbol: resolvedIcon,
                               coordinate: seed.coordinate,
                               addressLine: seed.addressLine)
            store.addFavorite(fav, pinToQuickAccess: pinToQuickAccess)
        }
        dismiss()
    }
}
