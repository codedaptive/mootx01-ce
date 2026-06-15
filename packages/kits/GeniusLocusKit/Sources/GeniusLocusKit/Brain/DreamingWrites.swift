import Foundation
import LocusKit

/// Dreaming daemon write surface — the two estate-handle-scoped writes the
/// dreaming daemon's sink seam performs (NEURONKIT_SPEC § 3.1 steps 6–7).
///
/// These methods follow the same handle-resolution pattern as
/// `VerbSurface.swift`'s `propose` and the read extension in
/// `DreamingReads.swift`. `NeuronKit`'s `EstateDreamingSink` calls
/// them through the public GeniusLocusKit verb surface (B-1-compliant).
///
/// The `addDiaryEntry(in:_:)` method builds a `DrawerStore` lazily from the
/// estate's retained storage and caches it per handle, mirroring the
/// `GrantStore` pattern from GRT-01. The Estate's own `DrawerStore` (internal
/// to LocusKit) handles all nine-verb operations; this cached store is a
/// separate facade on the same PersistenceKit `Storage` used exclusively for
/// diary writes. Both facades share the underlying actor-isolated storage,
/// so writes are serialised at the `Storage` layer.
public extension GeniusLocusKit {

    /// Write a diary entry to the estate addressed by `handle`.
    ///
    /// Used by `EstateDreamingSink` to record the dreaming daemon's per-cycle
    /// summary (NEURONKIT_SPEC § 3.1 step 7). Builds a `DrawerStore` lazily
    /// from the estate's retained `Storage` on first use and caches it per
    /// handle so repeated calls do not re-open schema.
    ///
    /// - Parameters:
    ///   - handle: the estate to write to. Must be open in this kit.
    ///   - entry: the diary entry to store.
    /// - Throws:
    ///   - `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    ///   - Any `LocusKitError` raised by `DrawerStore.addDiaryEntry`.
    func addDiaryEntry(in handle: EstateHandle, _ entry: DiaryEntry) async throws {
        let store = try await ensureDiaryStore(for: handle)
        // Dreaming-daemon diary entries carry no embedding (the daemon emits
        // only text). The storage layer requires a non-empty embeddingModelID;
        // substitute "no-embedding" when the caller left the field empty so
        // autonomous diary writes are not blocked by the model-tagging constraint.
        let stored: DiaryEntry
        if entry.embeddingModelID.isEmpty {
            stored = DiaryEntry(
                id: entry.id,
                agentName: entry.agentName,
                entry: entry.entry,
                topic: entry.topic,
                wing: entry.wing,
                room: entry.room,
                filedAt: entry.filedAt,
                embeddingModelID: "no-embedding",
                tombstonedAt: entry.tombstonedAt,
                removedByBatch: entry.removedByBatch,
                operationalBitmap: entry.operationalBitmap,
                // Pass through explicit reward fields so dreaming-daemon diary
                // entries carry any reward signal the caller attached.
                reward: entry.reward,
                rewardProvenance: entry.rewardProvenance
            )
        } else {
            stored = entry
        }
        try await store.addDiaryEntry(stored)
    }

    /// Read diary entries for `agentName` from the estate addressed by `handle`.
    ///
    /// Companion to `addDiaryEntry(in:_:)` for verification in tests and for
    /// monitoring surfaces that need to inspect the dreaming daemon's diary.
    /// Returns the most-recent `lastN` entries (newest first) written by
    /// `agentName`.
    ///
    /// - Parameters:
    ///   - handle: the estate to read from. Must be open in this kit.
    ///   - agentName: the agent whose diary entries to fetch.
    ///   - lastN: maximum number of entries to return (default 10).
    /// - Throws:
    ///   - `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    ///   - Any `LocusKitError` raised by `DrawerStore.readDiary`.
    func readDiaryEntries(
        in handle: EstateHandle,
        agentName: String,
        lastN: Int = 10
    ) async throws -> [DiaryEntry] {
        let store = try await ensureDiaryStore(for: handle)
        return try await store.readDiary(agentName: agentName, lastN: lastN)
    }

    // MARK: - Internal helpers

    /// Return the cached `DrawerStore` for `handle`, building one from the
    /// retained `Storage` on first use. Mirrors `ensureGrantSurface` in the
    /// grant surface plumbing (VerbSurface.swift): the storage is retained
    /// in `storages[handle]` since `open`; the store is built lazily and
    /// cached in `diaryStores[handle]`.
    private func ensureDiaryStore(for handle: EstateHandle) async throws -> DrawerStore {
        if let store = diaryStores[handle] { return store }
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        let store = try await DrawerStore(storage: storage)
        diaryStores[handle] = store
        return store
    }
}
