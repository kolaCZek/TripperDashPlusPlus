//
//  DestinationPreviewCard.swift
//  TripperDashPP
//
//  Compact, non-modal preview of a selected destination (June 2026
//  redesign). Replaces the old `DestinationPreviewSheet` modal.
//
//  Why an inline overlay instead of a `.sheet`:
//   - A modal sheet (even at `.medium`) covers ~half the map and, more
//     importantly, BLOCKS the map underneath — the rider couldn't tap a
//     nearby point to retarget without first dismissing the card.
//   - This card floats at the bottom over a still-live map. Tapping
//     another point on the map just re-seeds the card with the new
//     coordinate (handled by the parent's `onTap`), so "pick something,
//     then nudge to a neighbour" is one fluid gesture.
//
//  Layout: a single rounded card pinned to the bottom safe area. Title
//  + address on top, a tight action row (Add to favorites — only when
//  not already saved — and Calculate routes) below. Deliberately short
//  so the map dominates.
//

import CoreLocation
import SwiftUI

struct DestinationPreviewCard: View {
    @Environment(NavigationStore.self) private var store

    let destination: Destination
    /// Begin route planning to this destination.
    let onCalculateRoutes: (Destination) -> Void
    /// Open the favorite editor seeded with this destination.
    let onAddToFavorites: (Destination) -> Void
    /// Dismiss the card (clears the selection in the parent).
    let onClose: () -> Void

    private var alreadyFavorited: Bool { store.isFavorited(destination) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: icon + name/address + close.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: alreadyFavorited
                      ? (store.matchingFavorite(for: destination)?.resolvedIconSymbol ?? "star.fill")
                      : "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(alreadyFavorited ? Color.accentColor : .red)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let addr = destination.addressLine, !addr.isEmpty {
                        Text(addr)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(String(format: "%.5f, %.5f",
                                    destination.coordinate.latitude,
                                    destination.coordinate.longitude))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            // Action row.
            HStack(spacing: 10) {
                if alreadyFavorited {
                    Label("Saved", systemImage: "star.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Button {
                        onAddToFavorites(destination)
                    } label: {
                        Label("Add to favorites", systemImage: "star")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    onCalculateRoutes(destination)
                } label: {
                    Label("Routes", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.horizontal, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
