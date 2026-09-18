// hnsw_graph_maintenance.rs
//
// Seam for DreamingDaemon's HNSW graph maintenance duties: the two
// cadence-bound operations that keep the approximate float-lane NN index
// aligned with the current vector corpus across THETA and BETA cycles.
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
//     after the swap; no separate clear or lazy rebuild is needed through
//     this seam. (D-7 + F-3, VEC-SHADOWSWAP-01 BRR.)
//
//   THETA (24 h) — after the daily basis retrain the embedding space has
//     shifted. All active HNSW graphs are rebuilt from the current float
//     records so the graph topology matches the new vector geometry. A
//     fresh rebuild also removes tombstone accumulation from the
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
// Mirrors the `ThetaBasisRetrainHook` injection pattern: the trait is pure
// (no SynapseKit import in the daemon itself), the production adapter holds
// a VectorStore reference and delegates to its public HNSW maintenance
// surface. `DreamingDaemon`'s `_with_hnsw` method variants accept an
// `Option<&mut M>` so passing `None` safely disables all HNSW duties for
// tests that do not wire a VectorStore.
//
// ── Failure handling ─────────────────────────────────────────────────────
// Maintenance failures are non-fatal: a stale or missing HNSW graph
// degrades nearest-query performance (falls back to exact scan) but does
// not break correctness. Methods return `bool` — `false` signals a
// captured failure so the caller can log and continue, matching the Swift
// non-fatal behaviour.

// ── Trait ─────────────────────────────────────────────────────────────────

/// Seam for `DreamingDaemon`'s HNSW graph maintenance duties.
///
/// Injected into `DreamingDaemon`'s `_with_hnsw` method variants. The daemon
/// calls the two methods at the appropriate REM cadences (THETA, BETA) to keep
/// the approximate float-lane nearest-neighbour graph aligned with the current
/// vector corpus. The ALPHA cadence maintains the graph through
/// `VectorStore.publishShadowGeneration` (shadow swap), which does not go
/// through this seam. Tests supply `InMemoryHNSWGraphMaintenance`.
///
/// All methods are synchronous: the Rust daemon has no async runtime.
///
/// Returns `true` on success, `false` on a captured failure. The daemon
/// continues on failure (non-fatal, performance-degrading only) and emits
/// an Intellectus counter for operator visibility.
///
/// Mirrors Swift `HNSWGraphMaintenance` protocol (NeuronKit). The float-index
/// duties (`rebuild_float_index`, `compact_float_index_tombstones`) exist only
/// via the whole-record float lane:
/// whole-record float rows, so the seam carries the generation reclaim alone
/// there (ruling 2026-09-07).
/// `clearFloatIndex` was removed from both ports in D-7 (VEC-SHADOWSWAP-01):
/// the ALPHA clear duty is now handled atomically inside
/// `publishShadowGeneration`. Zero production callers remain on this seam.
pub trait HNSWGraphMaintenance {
    /// Rebuild all active HNSW graphs from current float records (THETA duty).
    ///
    /// Called after the daily basis retrain fires. Fetches current float32 rows
    /// from the `vectors` table and re-inserts them into fresh HNSWIndex
    /// instances, so graph topology matches the new embedding geometry.
    ///
    /// `now_epoch_secs` is the caller-injected cycle timestamp.
    fn rebuild_float_index(&mut self, now_epoch_secs: f64) -> bool;

    /// Compact HNSW tombstones across all active graph partitions (BETA duty).
    ///
    /// Called weekly. Each active HNSWIndex rebuilds from its live nodes,
    /// discarding tombstoned entries and dead edges accumulated since the last
    /// compaction.
    ///
    /// `now_epoch_secs` is the caller-injected cycle timestamp.
    fn compact_float_index_tombstones(&mut self, now_epoch_secs: f64) -> bool;

    /// Delete vector rows whose generation is neither the serving generation
    /// nor an active 'building' shadow, for all models (BETA duty).
    ///
    /// Called weekly alongside `compact_float_index_tombstones`. Idempotent
    /// and resumable: killing mid-reclaim and re-running finishes without error
    /// and changes no query result. Returns `true` on success, `false` on a
    /// captured failure (non-fatal — correctness is unaffected; the rows stay
    /// reclaimable by the next BETA cycle).
    ///
    /// NO default implementation — an unwired conformer is invisible to the test
    /// suite. Both production and test conformers must implement this explicitly
    /// (F-2 reviewer ruling; mirrors the Swift `HNSWGraphMaintenance` protocol).
    ///
    /// `now_epoch_secs` is the caller-injected cycle timestamp (unused by most
    /// implementations today but kept for future telemetry).
    fn reclaim_superseded_generations(&mut self, now_epoch_secs: f64) -> bool;
}

// ── In-memory test double ──────────────────────────────────────────────────

/// In-memory `HNSWGraphMaintenance` for tests. Records calls without touching a
/// live VectorStore. Mirrors Swift's `FakeHNSWMaintenance` test double pattern.
///
/// `clear_calls` is absent: `clearFloatIndex` was removed from the protocol in
/// D-7 (VEC-SHADOWSWAP-01). The no-clear guarantee for ALPHA is compile-time.
#[derive(Debug, Default)]
pub struct InMemoryHNSWGraphMaintenance {
    /// Timestamps of successful `rebuild_float_index` calls, in call order.
    pub rebuild_calls: Vec<f64>,
    /// Timestamps of successful `compact_float_index_tombstones` calls, in call order.
    pub compact_calls: Vec<f64>,
    /// Timestamps of successful `reclaim_superseded_generations` calls, in call order.
    pub reclaim_calls: Vec<f64>,
    /// When true, all methods return `false` (simulates captured failures).
    pub fail_all: bool,
}

impl InMemoryHNSWGraphMaintenance {
    /// Construct a maintenance fake with no failures.
    pub fn new() -> Self {
        Self::default()
    }

    /// Construct a maintenance fake whose every call fails.
    pub fn failing() -> Self {
        Self { fail_all: true, ..Default::default() }
    }
}

impl HNSWGraphMaintenance for InMemoryHNSWGraphMaintenance {
    fn rebuild_float_index(&mut self, now_epoch_secs: f64) -> bool {
        if self.fail_all {
            return false;
        }
        self.rebuild_calls.push(now_epoch_secs);
        true
    }

    fn compact_float_index_tombstones(&mut self, now_epoch_secs: f64) -> bool {
        if self.fail_all {
            return false;
        }
        self.compact_calls.push(now_epoch_secs);
        true
    }

    fn reclaim_superseded_generations(&mut self, now_epoch_secs: f64) -> bool {
        if self.fail_all {
            return false;
        }
        self.reclaim_calls.push(now_epoch_secs);
        true
    }
}

// ── Blanket impl for boxed trait objects ──────────────────────────────────────

/// Allow `Box<dyn HNSWGraphMaintenance + Send>` to satisfy the `M:
/// HNSWGraphMaintenance` bound in `DreamingDaemon`'s generic `_with_hnsw`
/// methods. Production callers that store a `Box<dyn HNSWGraphMaintenance +
/// Send>` (e.g. `AutonomicGovernor`'s host-injected maintenance handle) can
/// then pass `Option<&mut Box<dyn HNSWGraphMaintenance + Send>>` without
/// introducing a wrapper type or changing the generic signatures.
impl HNSWGraphMaintenance for Box<dyn HNSWGraphMaintenance + Send> {
    fn rebuild_float_index(&mut self, now_epoch_secs: f64) -> bool {
        (**self).rebuild_float_index(now_epoch_secs)
    }

    fn compact_float_index_tombstones(&mut self, now_epoch_secs: f64) -> bool {
        (**self).compact_float_index_tombstones(now_epoch_secs)
    }

    fn reclaim_superseded_generations(&mut self, now_epoch_secs: f64) -> bool {
        (**self).reclaim_superseded_generations(now_epoch_secs)
    }
}
