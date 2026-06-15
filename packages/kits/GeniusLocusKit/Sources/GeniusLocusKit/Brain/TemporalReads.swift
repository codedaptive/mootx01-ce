// TemporalReads.swift
//
// Estate-surface forwarding for the two LocusKit temporal reads
// (dormant-surfaces mission, Part 2).
//
// GeniusLocusKit exposes fingerprintsCaptured and fingerprintBitSeries
// to callers (NeuronKit) who must reach the substrate only through the
// GLK estate surface (NeuronKit B-1). The underlying reads live on
// LocusKit.DrawerStore; this file bridges them through the estate
// surface using the same DrawerStore lazy-cache pattern established
// by DreamingWrites.swift.
//
// Access pattern: GLK cannot reach `Estate.store` (internal to
// LocusKit). Instead it builds a DrawerStore lazily from
// `storages[handle]` and caches it in `fingerprintStores[handle]`
// so the schema-open cost is paid at most once per estate lifetime.

import Foundation
import LocusKit
import SubstrateTypes

public extension GeniusLocusKit {

    /// Returns the `Fingerprint256` of every non-tombstoned drawer captured
    /// within `window` for the given estate.
    ///
    /// Forwards to `DrawerStore.fingerprintsCaptured(in:)` on the estate's
    /// backing store. The returned array is in HLC-ascending order within
    /// the window and excludes any withdrawn (tombstoned) drawers.
    ///
    /// - Parameters:
    ///   - handle: Open estate handle.
    ///   - window: Closed date range; drawers captured outside this range
    ///     are excluded.
    /// - Returns: Fingerprints in HLC-ascending order within the window.
    /// - Throws: `.estateNotOpen` if the handle is not in the registry;
    ///   underlying storage errors on SQLite failure.
    func glkFingerprintsCaptured(
        in handle: EstateHandle,
        window: ClosedRange<Date>
    ) async throws -> [Fingerprint256] {
        let store = try await ensureFingerprintStore(for: handle)
        return try await store.fingerprintsCaptured(in: window)
    }

    /// Returns a time-bucketed bit series for one bit position of the
    /// composite fingerprint for the given estate.
    ///
    /// Forwards to `DrawerStore.fingerprintBitSeries(bit:bucketSeconds:
    /// bucketCount:endingAt:)`. Each element of the result is `true` if
    /// any non-tombstoned drawer captured in that bucket had the given bit
    /// set in its fingerprint, and `false` otherwise.
    ///
    /// - Parameters:
    ///   - handle: Open estate handle.
    ///   - bit: Bit position in `[0, 255]`.
    ///   - bucketSeconds: Width of each time bucket in seconds (≥ 1).
    ///   - bucketCount: Number of buckets to return (≥ 1).
    ///   - endingAt: The closed right edge of the last bucket; buckets
    ///     extend backwards in time from this date.
    /// - Returns: Array of `bucketCount` Bool values, index 0 = oldest.
    /// - Throws: `.estateNotOpen`, `.invalidContent` on invalid parameters,
    ///   or underlying storage errors.
    func glkFingerprintBitSeries(
        in handle: EstateHandle,
        bit: Int,
        bucketSeconds: Int,
        bucketCount: Int,
        endingAt: Date
    ) async throws -> [Bool] {
        let store = try await ensureFingerprintStore(for: handle)
        return try await store.fingerprintBitSeries(
            bit: bit,
            bucketSeconds: bucketSeconds,
            bucketCount: bucketCount,
            endingAt: endingAt
        )
    }

    /// Returns every room-level container fingerprint (room non-empty) with
    /// its bitwise-OR aggregate over the container's active drawers, for the
    /// given estate.
    ///
    /// Forwards to `Estate.roomLevelFingerprints()`, which reads the OR
    /// aggregates the recall pruner maintains (`ContainerFingerprintStore`,
    /// spec § 11.5) straight from the `container_fingerprints` table — no
    /// drawer scan. The maintenance daemon's fingerprint-drift signal reads
    /// these as the live per-scope fingerprint and compares them against the
    /// prior snapshot's aggregates (B-1 — NeuronKit reaches the substrate only
    /// through this GLK surface).
    ///
    /// - Parameter handle: Open estate handle.
    /// - Returns: One entry per room-level container, in `wing`-ascending order.
    /// - Throws: `.estateNotOpen` if the handle is not in the registry;
    ///   underlying storage errors on SQLite failure.
    func roomLevelFingerprints(
        in handle: EstateHandle
    ) async throws -> [(wing: String, room: String, fingerprint: ContainerFingerprint)] {
        let estate = try estate(for: handle)
        return try await estate.roomLevelFingerprints()
    }
}

// MARK: - Private helpers

private extension GeniusLocusKit {

    /// Returns the cached fingerprint `DrawerStore` for `handle`, creating
    /// it on first access.
    ///
    /// Mirrors `ensureDiaryStore(for:)` in `DreamingWrites.swift`: the store
    /// is built from `storages[handle]` rather than `Estate.store` (which is
    /// `internal` to LocusKit). The fingerprint store is read-only from GLK's
    /// perspective — it is never used for writes.
    func ensureFingerprintStore(for handle: EstateHandle) async throws -> DrawerStore {
        if let store = fingerprintStores[handle] { return store }
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        let store = try await DrawerStore(storage: storage)
        fingerprintStores[handle] = store
        return store
    }
}
