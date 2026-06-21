//
//  SnapshotterPark.swift
//  TripperDashPP
//
//  Extracted from the now-deleted MapSnapshotSource on the catalog-complete
//  refactor (commit db89d51). MapPreviewView still relies on it to drain
//  MKMapSnapshotter Metal command buffers without freezing the app, so the
//  helper survives even though its original owner doesn't.
//

import MapKit

/// Non-isolated holder that retains MKMapSnapshotter instances after
/// their completion fires, so the underlying Metal command buffer has
/// time to drain on the GPU. Required from nonisolated callbacks (the
/// snapshotter's completion handler), so this is a `@unchecked Sendable`
/// reference type with its own lock — not a `@MainActor` actor.
///
/// Strategy: bounded LIFO ring. New entries push out old ones; by the
/// time an entry has been pushed out by `capacity` newer entries the
/// GPU work is long-since complete.
final class SnapshotterPark: @unchecked Sendable {
    static let shared = SnapshotterPark(capacity: 100)

    private let capacity: Int
    private let lock = NSLock()
    private var ring: [MKMapSnapshotter] = []

    init(capacity: Int) {
        self.capacity = capacity
        self.ring.reserveCapacity(capacity + 1)
    }

    func park(_ snapshotter: MKMapSnapshotter) {
        lock.lock()
        defer { lock.unlock() }
        ring.append(snapshotter)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
    }
}
