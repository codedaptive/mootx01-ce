// HNSWGraphMaintenance.swift
//
// Seam for DreamingDaemon's HNSW graph maintenance duties: the four
// cadence-bound operations that keep the approximate float-lane NN index
// in shape across ALPHA, THETA, and BETA cycles.
//
// ── Design rationale ─────────────────────────────────────────────────────
// HNSWIndex (VectorKit) is an approximate nearest-neighbour index for the
// float lane (Lane D). It activates at/above a configurable threshold
// (default 5 000 vectors per modelID partition). Three dreaming cadences
// have maintenance duties over this graph:
//
//   ALPHA (30 s) — extreme vocabulary drift triggers a corpus shadow swap
//     (via CorpusGrowthProbe.reindex). The shadow swap calls
//     VectorStore.publishShadowGeneration, which atomically flips the
//     serving generation and rebuilds the HNSW graph from the new serving
//     rows inside the same operation. The graph is coherent immediately
//     after the swap completes — no separate clear or lazy rebuild is
//     needed. Failure is non-fatal; the daemon continues.
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
// pure (no VectorKit type in any signature, and no VectorKit import in
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
/// Injected into `DreamingDaemon`. The daemon calls the three methods at the
/// appropriate REM cadences (ALPHA, THETA, BETA) to keep the approximate
/// float-lane nearest-neighbour graph aligned with the current vector corpus.
/// `EstateHNSWGraphMaintenance` is the production adapter; tests use in-memory
/// fakes.
///
/// - Note: A nil `hnswMaintenance` in `DreamingDaemon.init` silently disables
///   all HNSW maintenance duties (correct for estates with no float lane and
///   for tests that do not require approximate NN).
public protocol HNSWGraphMaintenance: Sendable {

    /// Clear all HNSW graphs for the estate.
    ///
    /// Previously called by the ALPHA cadence after a corpus reindex. The
    /// ALPHA duty now fires a shadow swap (CorpusGrowthProbe.reindex →
    /// VectorStore.publishShadowGeneration), which rebuilds the HNSW graph
    /// coherently inside the swap operation. This method is no longer called
    /// by the ALPHA path; it remains on the protocol for explicit eviction
    /// use-cases where a caller needs to force a lazy rebuild on the next
    /// qualifying query.
    ///
    /// - Parameter now: Deterministic timestamp from the caller (never
    ///   `Date()` inside the engine).
    func clearFloatIndex(now: Date) async throws

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
