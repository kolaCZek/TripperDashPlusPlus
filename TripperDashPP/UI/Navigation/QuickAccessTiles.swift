//
//  QuickAccessTiles.swift
//  TripperDashPP
//
//  Phase 7g (June 2026) — exactly TWO hard-coded pinned tiles, Home
//  and Work, in a single horizontal row. Names + icons are fixed; the
//  user only picks the coordinate. Empty tile opens search directly
//  and saves the result into THAT slot — no separate editor sheet,
//  no risk of accidentally creating an unpinned favorite.
//
//  Why two and not four:
//   - Saves a lot of vertical screen real estate; the map is no longer
//     hidden under a 2×2 grid of mostly-empty tiles.
//   - User reported the 4-slot grid blocked their current GPS position
//     and was rarely full anyway.
//   - "Others" still scales — power users can have many named favorites,
//     they just live under the disclosure, not pinned to the top.
//

import SwiftUI

struct QuickAccessTiles: View {
    @Environment(NavigationStore.self) private var store

    /// Called when the user taps a populated tile / favorite row to
    /// start the destination preview flow.
    let onPick: (Favorite) -> Void

    /// Called when the user taps an empty pinned tile. Caller should
    /// present DestinationSearchSheet and, on selection, call
    /// `store.setQuickAccess(slot, from: dest)`.
    let onFillSlot: (QuickAccessSlot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                tile(for: .home)
                tile(for: .work)
            }

            if !store.otherFavorites.isEmpty {
                DisclosureGroup("Others") {
                    // List inside a DisclosureGroup gives us swipe-to-delete
                    // for free. Fixed height keeps the tile area predictable
                    // — long favorite lists scroll internally.
                    List {
                        ForEach(store.otherFavorites) { fav in
                            Button { onPick(fav) } label: {
                                HStack {
                                    Image(systemName: fav.resolvedIconSymbol).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fav.name).foregroundStyle(.primary)
                                        if let addr = fav.addressLine {
                                            Text(addr).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            for idx in offsets {
                                let fav = store.otherFavorites[idx]
                                store.removeFavorite(id: fav.id)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .frame(height: min(CGFloat(store.otherFavorites.count) * 48, 200))
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func tile(for slot: QuickAccessSlot) -> some View {
        if let fav = store.favorite(in: slot) {
            Button { onPick(fav) } label: {
                HStack(spacing: 8) {
                    Image(systemName: slot.iconSymbol)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slot.displayName).font(.footnote.weight(.semibold))
                        if let addr = fav.addressLine {
                            Text(addr).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(String(format: "%.4f, %.4f", fav.latitude, fav.longitude))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    onFillSlot(slot)  // replace
                } label: {
                    Label("Replace…", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) {
                    store.clearQuickAccess(slot)
                } label: {
                    Label("Remove pin", systemImage: "pin.slash")
                }
            }
        } else {
            Button { onFillSlot(slot) } label: {
                HStack(spacing: 8) {
                    Image(systemName: slot.iconSymbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slot.displayName).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Tap to set").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
