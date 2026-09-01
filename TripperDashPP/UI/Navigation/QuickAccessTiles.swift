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

    /// Ceiling for the expanded favorites list, in points — how far it may
    /// grow before it would run past the bottom of the screen. Supplied by
    /// the host, which is the only thing that knows the real layout.
    ///
    /// A CONCRETE height is required here. The obvious-looking
    /// `.frame(maxHeight: .infinity)` does not work: `List` is a scroll
    /// view with no intrinsic height, and the enclosing `VStack` only ever
    /// offers its children their ideal height, so the list collapses to
    /// nothing and the panel renders as an empty sheet of material (which
    /// is exactly what it did when this was first attempted).
    let maxListHeight: CGFloat

    /// Whether the "Others" disclosure is open. Bound rather than implicit
    /// so `pick(_:)` can close it programmatically.
    @State private var othersExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                tile(for: .home)
                tile(for: .work)
            }

            if !store.otherFavorites.isEmpty {
                DisclosureGroup("Others", isExpanded: $othersExpanded) {
                    // List inside a DisclosureGroup gives us swipe-to-delete
                    // for free.
                    //
                    // The cap used to be a hard-coded 200 pt, which made the
                    // expanded panel a cramped strip scrolling internally
                    // while the screen below it sat empty. It now opens to
                    // the full host-measured height (`listHeight`) and lets
                    // the List scroll natively once the rows overflow.
                    List {
                        ForEach(store.otherFavorites) { fav in
                            Button { pick(fav) } label: {
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
                    .frame(height: listHeight)
                }
                .font(.subheadline)
            }
        }
    }

    /// Exact height for the open list: always the full space the screen
    /// allows, so the panel opens to the bottom edge of the display no
    /// matter how many favorites there are. The List scrolls internally
    /// once the rows no longer fit — which is what it does natively.
    ///
    /// This deliberately replaced a content-derived height (sum of
    /// estimated per-row heights). Rows are not uniform — a favorite with a
    /// resolved address draws two lines, one without draws a single line,
    /// and Dynamic Type scales both — so any per-row constant was an
    /// unverifiable guess that could not be measured without a device.
    /// Taking the whole area sidesteps the estimate entirely: the layout no
    /// longer depends on predicting what UIKit will draw.
    private var listHeight: CGFloat {
        max(maxListHeight, Self.minListHeight)
    }

    /// Never shrink the open list below this, even on a very short screen —
    /// an expanded disclosure showing nothing would be worse than one that
    /// scrolls. Also covers the very first layout pass, when the host has
    /// not measured the screen yet and `maxListHeight` is still negative.
    private static let minListHeight: CGFloat = 120

    /// Forward a pick and close the disclosure.
    ///
    /// Selecting a favorite recenters the map and raises the destination
    /// preview card; leaving a full-height "Others" panel open would cover
    /// exactly the detail the tap asked to see. Applies to the pinned
    /// Home/Work tiles too — they stay visible above an expanded list, so
    /// they can be tapped while it is covering the map.
    private func pick(_ fav: Favorite) {
        withAnimation(.easeInOut(duration: 0.2)) { othersExpanded = false }
        onPick(fav)
    }

    @ViewBuilder
    private func tile(for slot: QuickAccessSlot) -> some View {
        if let fav = store.favorite(in: slot) {
            Button { pick(fav) } label: {
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
