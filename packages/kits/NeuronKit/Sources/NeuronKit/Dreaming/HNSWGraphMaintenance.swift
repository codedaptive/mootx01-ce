// HNSWGraphMaintenance.swift
//
// Seam for DreamingDaemon's HNSW graph maintenance duties: the three
// cadence-bound operations that keep the approximate float-lane NN index
// in shape across THETA and BETA cycles.
//
// ── Design rationale ─────────────────────────────────────────────────────
// HNSWIndex (SynapseKit) is an approximate nearest-neighbour index for the
// float lane (Lane D). It activates at/above a configurable threshold
// (default 5 000 vectors per modelID partition). Two dreaming cadences
// have maintenance duties over this graph (THETA and BETA); ALPHA manages
// the graph through the shadow-swap publish path, not through this seam:
//
//   ALPHA (30 s) — extreme vocabulary drift triggers a corpus shadow swap
//     (via CorpusGrowthProbe.reindex). The shadow swap calls
//     VectorStore.publishShadowGeneration, which atomically flips the
//     serving generation and rebuilds the HNSW graph from the new serving
//     rows inside the same operation. The graph is coherent immediately
//     after the swap completes. No duty on this seam for ALPHA.
//
//   THETA (24 h) — after the daily basis retrain the embedding space has
//     shifted. All active HNSW graphs are rebuilt from the current float
//     records so the graph topology matches the new vector geometry. A
//     fresh rebuild also removes any tombstone accumulation from the
//     incremental insert path.
//
//   BETA (7 d) — tombstones accumulate when items are updated or deleted.
//     BETA compaction rebuilds the live-node graph, discarding tombstoned
//     entries and dead edges. A compacted graph has better cache locality
//     and no wasted memory from stale node slots. BETA also reclaims
//     superseded-generation vector rows left 'pending-reclaim' after a
//     shadow swap publish. Reclamation is idempotent and resumable.
//
//   OMEGA (14 d) — retires dreamed tunnels. No HNSW duty.
//
// ── Seam idiom ───────────────────────────────────────────────────────────
// Mirrors the `ThetaBasisRetrainHook` injection pattern: the protocol is
// pure (no SynapseKit type in any signature, and no SynapseKit import in
// this package at all). The production adapter,
// `EstateHNSWGraphMaintenance`, holds a `VectorStore` reference and
// delegates to its public HNSW maintenance surface. It lives in
// AriaMcpKit/Sources/AriaResident because it is the half that holds
// storage, and NeuronKit may not (B-1). The daemon stores it
// as `private let hnswMaintenance: (any HNSWGraphMaintenance)?` so nil
// safely disables all HNSW duties in tests that do not wire a VectorStore.
//
// ── Failure handling ─────────────────────────────────────────────────────
// Maintenance failures are non-fatal: a stale or missing HNSW graph
// degrades nearest-query performance (falls back to exact scan) but does
// not break correctness. DreamingDaemon catches errors and emits an
// Intellectus metric for operator visibility.

import Foundation

// MARK: - Protocol

/// Seam for DreamingDaemon's HNSW graph maintenance duties.
///
/// Injected into `DreamingDaemon`. The daemon calls the two methods at the
/// appropriate REM cadences (THETA, BETA) to keep the approximate float-lane
/// nearest-neighbour graph aligned with the current vector corpus. The ALPHA
/// cadence maintains the graph through `VectorStore.publishShadowGeneration`
/// (shadow swap), which does not go through this seam.
/// `EstateHNSWGraphMaintenance` is the production adapter; tests use in-memory
/// fakes.
///
/// - Note: A nil `hnswMaintenance` in `DreamingDaemon.init` silently disables
///   every duty on this seam (correct for tests that wire no vector store).
///   The float-index duties (`rebuildFloatIndex`, `compactFloatIndexTombstones`)
///   exist only when the whole-record float lane is active. The default product writes no
///   whole-record float rows, so the seam carries the generation reclaim
///   alone there (ruling 2026-09-07).
public protocol HNSWGraphMaintenance: Sendable {

    /// Rebuild all active HNSW graphs from current float records (THETA duty).
    ///
    /// Called after the daily basis retrain fires. Fetches current float32 rows
    /// from the `vectors` table and re-inserts them into fresh HNSWIndex
    /// instances, so graph topology matches the new embedding geometry.
    ///
    /// - Parameter now: Deterministic timestamp from the caller.
    func rebuildFloatIndex(now: Date) async throws

    /// Compact HNSW tombstones across all active graph partitions (BETA duty).
    ///
    /// Called weekly. Each active HNSWIndex rebuilds from its live nodes,
    /// discarding tombstoned entries and dead edges accumulated since the last
    /// compaction.
    ///
    /// - Parameter now: Deterministic timestamp from the caller.
    func compactFloatIndexTombstones(now: Date) async throws

    /// Reclaim superseded-generation vector rows from the estate (BETA duty).
    ///
    /// Called alongside `compactFloatIndexTombstones` in every BETA cycle.
    /// Deletes `vectors` and `hnsw_graph` rows whose generation is neither
    /// the model's current serving generation nor an active shadow build,
    /// then clears the 'pending-reclaim' registry state. The operation is
    /// idempotent and resumable: a kill mid-run and a second call finish
    /// without error and produce no incorrect query results (the serving
    /// generation is committed before reclamation begins).
    ///
    /// No default implementation is provided intentionally. An unwired
    /// conformer must be a compile error — a silent no-op would make the
    /// difference between "reclamation works" and "reclamation never wired"
    /// invisible to tests. (Reviewer ruling F-2, VEC-SHADOWSWAP-01 BRR.)
    ///
    /// - Parameter now: Deterministic timestamp from the caller.
    func reclaimSupersededGenerations(now: Date) async throws
}
