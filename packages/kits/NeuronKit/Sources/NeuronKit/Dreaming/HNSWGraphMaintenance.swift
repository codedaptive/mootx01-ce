// HNSWGraphMaintenance.swift
//
// Seam for DreamingDaemon's HNSW graph maintenance duties: the three
// cadence-bound operations that keep the approximate float-lane NN index
// in shape across ALPHA, THETA, and BETA cycles.
//
// ── Design rationale ─────────────────────────────────────────────────────
// HNSWIndex (VectorKit) is an approximate nearest-neighbour index for the
// float lane (Lane D). It activates at/above a configurable threshold
// (default 5 000 vectors per modelID partition). Three dreaming cadences
// have maintenance duties over this graph:
//
//   ALPHA (30 s) — extreme vocabulary drift triggers a corpus reindex.
//     The new embedding geometry makes the old graph topology incorrect;
//     all HNSW graphs are cleared so the next qualifying query rebuilds
//     from the fresh vectors. A lazy rebuild is cheaper than a synchronous
//     full rebuild inside a 30-second cycle.
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
//     and no wasted memory from stale node slots.
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

    /// Clear all HNSW graphs for the estate (ALPHA extreme-drift duty).
    ///
    /// Called when vocabulary drift crosses the auto-reindex threshold and a
    /// full corpus reindex fires. The next `findNearestFloat` call at/above
    /// the threshold lazily rebuilds the graph from the fresh vectors.
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
}
