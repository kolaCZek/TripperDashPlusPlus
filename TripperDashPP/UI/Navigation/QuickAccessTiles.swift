//
//  QuickAccessTiles.swift
//  TripperDashPP
//
//  Phase 7d — 2×2 grid of Quick Access tiles + "Others" disclosure
//  with the remaining favorites. Each populated tile triggers
//  destination preview/route preview directly; an empty tile prompts
//  "+ Add" → favorite editor (seeded from current destination if
//  set, otherwise hint).
//

import SwiftUI

struct QuickAccessTiles: View {
    @Environment(NavigationStore.self) private var store

    /// Called when user taps a populated tile / favorite row.
    let onPick: (Favorite) -> Void

    /// Called when user taps an empty tile or the "+ Add" row.
    /// Caller is expected to present FavoriteEditorSheet.
    let onAddEmptyTile: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quick access").font(.subheadline.weight(.semibold))
                Spacer()
            }
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 10) {
                ForEach(0..<4, id: \.self) { slot in
                    tile(for: slot)
                }
            }

            if !store.otherFavorites.isEmpty {
                DisclosureGroup("Others") {
                    ForEach(store.otherFavorites) { fav in
                        Button { onPick(fav) } label: {
                            HStack {
                                Image(systemName: fav.resolvedIconSymbol).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fav.name).foregroundStyle(.primary)
                                    if let addr = fav.addressLine {
                                        Text(addr).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func tile(for slot: Int) -> some View {
        if let fav = store.favoriteAtSlot(slot) {
            Button { onPick(fav) } label: {
                VStack(spacing: 6) {
                    Image(systemName: fav.resolvedIconSymbol)
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text(fav.name).font(.footnote.weight(.medium)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        } else {
            Button { onAddEmptyTile(slot) } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle.dashed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Add").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
