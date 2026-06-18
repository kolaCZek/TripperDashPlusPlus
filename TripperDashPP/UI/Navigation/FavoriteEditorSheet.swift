//
//  FavoriteEditorSheet.swift
//  TripperDashPP
//
//  Phase 7d — create or edit a custom favorite (Others list).
//
//  IMPORTANT (Phase 7g): this sheet is NO LONGER used to set the
//  pinned Home/Work slots. Those use a fixed name + icon and are
//  filled by `DestinationSearchSheet → store.setQuickAccess(slot,…)`
//  directly from the empty-tile tap. This editor only ever creates or
//  edits user-named entries that live in the "Others" list.
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Mountain hut, café, parking…", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Icon") {
                    TextField("SF Symbol name (optional)", text: $icon)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Leave blank to auto-pick from the name (fuel/coffee/garage/etc. are detected).")
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
                if existing != nil {
                    Section {
                        Button(role: .destructive) {
                            if let existing { store.removeFavorite(id: existing.id) }
                            dismiss()
                        } label: {
                            Label("Delete favorite", systemImage: "trash")
                        }
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
            store.addFavorite(fav)
        }
        dismiss()
    }
}
