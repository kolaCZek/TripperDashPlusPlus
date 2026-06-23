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
//  Phase 7h (June 2026) — the icon is no longer typed as a raw SF
//  Symbol string. It is a tappable glyph that sits *before* the name
//  field on a single row, mirroring how the entry will look in the
//  Others list. Tapping it opens a menu to pick from a curated symbol
//  catalogue (or "Automatic", which re-enables name-based detection).
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
    /// Explicit SF Symbol chosen by the user. Empty == "Automatic"
    /// (derive from the name, exactly like the list rows do).
    @State private var icon: String = ""

    /// The glyph actually shown on the row: the explicit pick when set,
    /// otherwise the live name-based guess so the preview tracks typing.
    private var displayedIcon: String {
        let trimmed = icon.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return Favorite.autoIconSymbol(forName: name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        iconMenu
                        TextField("Mountain hut, café, parking…", text: $name)
                            .textInputAutocapitalization(.words)
                    }
                } header: {
                    Text("Name & icon")
                } footer: {
                    Text(icon.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Tap the icon to choose one. Left on Automatic, it is picked from the name (fuel/coffee/garage/etc. are detected)."
                         : "Tap the icon to change it, or choose Automatic to pick from the name.")
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

    /// Tappable icon that opens the symbol catalogue. Shown before the
    /// name field so the row reads like an Others-list entry.
    private var iconMenu: some View {
        Menu {
            Button {
                icon = ""   // back to name-based automatic
            } label: {
                Label("Automatic", systemImage: Favorite.autoIconSymbol(forName: name))
            }
            Divider()
            ForEach(FavoriteIconCatalog.options) { option in
                Button {
                    icon = option.symbol
                } label: {
                    Label(option.label, systemImage: option.symbol)
                }
            }
        } label: {
            Image(systemName: displayedIcon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary, Color(.systemBackground))
                        .offset(x: 3, y: 3)
                }
        }
        .accessibilityLabel("Choose icon")
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

/// Curated SF Symbols offered in the favorite icon picker. Kept in sync
/// with the heuristics in `Favorite.autoIconSymbol(forName:)` and padded
/// with common moto-trip POIs (hut, viewpoint, camp, ferry, parking…).
enum FavoriteIconCatalog {
    struct Option: Identifiable {
        let symbol: String
        let label: String
        var id: String { symbol }
    }

    static let options: [Option] = [
        .init(symbol: "house.fill", label: "Home"),
        .init(symbol: "briefcase.fill", label: "Work"),
        .init(symbol: "fuelpump.fill", label: "Fuel"),
        .init(symbol: "cup.and.saucer.fill", label: "Coffee"),
        .init(symbol: "fork.knife", label: "Food"),
        .init(symbol: "wrench.and.screwdriver.fill", label: "Garage / service"),
        .init(symbol: "bed.double.fill", label: "Lodging / hut"),
        .init(symbol: "tent.fill", label: "Camp"),
        .init(symbol: "mountain.2.fill", label: "Viewpoint"),
        .init(symbol: "binoculars.fill", label: "Scenic spot"),
        .init(symbol: "camera.fill", label: "Photo"),
        .init(symbol: "cart.fill", label: "Shop"),
        .init(symbol: "cross.case.fill", label: "Pharmacy / medical"),
        .init(symbol: "parkingsign", label: "Parking"),
        .init(symbol: "ferry.fill", label: "Ferry"),
        .init(symbol: "airplane", label: "Airport"),
        .init(symbol: "graduationcap.fill", label: "School"),
        .init(symbol: "building.2.fill", label: "City / town"),
        .init(symbol: "star.fill", label: "Star"),
        .init(symbol: "mappin.circle.fill", label: "Generic pin"),
    ]
}
