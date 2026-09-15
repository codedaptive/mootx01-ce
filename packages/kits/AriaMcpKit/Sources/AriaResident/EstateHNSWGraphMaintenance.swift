// EstateHNSWGraphMaintenance.swift
//
// Production adapter for NeuronKit's `HNSWGraphMaintenance` seam.
//
// ── Why this lives in AriaResident and not in NeuronKit ──────────────────
// The seam protocol is declared in NeuronKit
// (Dreaming/HNSWGraphMaintenance.swift) and is pure: every method takes a
// `Date` and returns nothing, so the protocol carries no SynapseKit type.
// That purity is the whole point of the seam. DreamingDaemon states it
// directly: "DreamingDaemon never touches VectorStore directly (B-1
// compliance: NeuronKit reaches SynapseKit through a seam, not directly)".
//
// The ADAPTER is the half that must hold a real `VectorStore`, so it
// belongs on the app side of the boundary. The seam file's own header
// already said so: "Construction: the app layer creates an instance with
// the estate's VectorStore and injects it into
// DreamingDaemon.init(hnswMaintenance:)."
//
// It was nonetheless declared inside NeuronKit, which forced
// `import SynapseKit` into that package and put a live storage handle on
// the wrong side of B-1. NeuronKit's three acknowledged B-1 exceptions
// (EngramLib, SubstrateML, LocusKit) are all typed-value or read-only
// with no storage handle; this one held a handle and called three write
// methods, so it was not like them.
//
// Relocating the struct removes NeuronKit's only `import SynapseKit` and
// leaves the architecture as designed. The protocol did not move. The
// daemon did not change. Nothing about the seam idiom changed.
//
// Found by MISSION_MD_01 (TASK-MXE-2026-0339), which correctly refused to
// declare SynapseKit on NeuronKit and escalated rather than legitimizing
// the breach.

import Foundation
import NeuronKit
import SynapseKit

/// Production `HNSWGraphMaintenance` that delegates to a `VectorStore`'s
/// public HNSW maintenance surface.
///
/// Holds a direct reference to the `VectorStore` that owns the float lane
/// for the estate. `DreamingDaemon` never touches `VectorStore` directly;
/// this adapter is the seam between them, and it lives at the app layer
/// because it is the half that holds storage.
///
/// Construction: `ResidentDaemon` creates an instance with the estate's
/// `VectorStore` and injects it into `DreamingDaemon.init(hnswMaintenance:)`.
public struct EstateHNSWGraphMaintenance: HNSWGraphMaintenance {

    private let vectorStore: VectorStore

    /// Construct a maintenance adapter for the given estate's vector store.
    ///
    /// - Parameter vectorStore: The `VectorStore` whose HNSW graphs this
    ///   adapter maintains. Must be the same instance used by the estate's
    ///   recall pipeline.
    public init(vectorStore: VectorStore) {
        self.vectorStore = vectorStore
    }

    // NOTE: clearFloatIndex was removed from the seam by VEC-SHADOWSWAP-01.
    // ALPHA no longer clears the graph through this adapter; it goes through
    // VectorStore.publishShadowGeneration, which flips the serving generation
    // and rebuilds the graph inside one atomic operation.

    /// Delegates to `VectorStore.rebuildAllHNSWIndices()`.
    public func rebuildFloatIndex(now: Date) async throws {
        try await vectorStore.rebuildAllHNSWIndices()
    }

    /// Delegates to `VectorStore.compactAllHNSWTombstones()`.
    public func compactFloatIndexTombstones(now: Date) async throws {
        try await vectorStore.compactAllHNSWTombstones()
    }

    /// Delegates to `VectorStore.reclaimSupersededGenerations()`.
    ///
    /// Added by VEC-SHADOWSWAP-01: a publish leaves the superseded
    /// generation's rows pending-reclaim, and BETA reclaims them. The
    /// underlying call returns a per-modelID count; the seam is void, so the
    /// count is dropped here. Reclamation is idempotent and resumable, so a
    /// partial pass is safe to repeat on the next BETA cycle.
    ///
    /// The protocol provides no default implementation on purpose: an
    /// unwired conformer must be a compile error, because a silent no-op
    /// would make "reclamation never wired" indistinguishable from
    /// "reclamation works". (Reviewer ruling F-2, VEC-SHADOWSWAP-01 BRR.)
    public func reclaimSupersededGenerations(now: Date) async throws {
        _ = try await vectorStore.reclaimSupersededGenerations()
    }
}
