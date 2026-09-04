//! VectorStore — persistence-kit-backed CRUD over the `vectors` table.
//!
//! Lane F schema (multi-vector, fresh install — no migration):
//!
//!   vectors (
//!     id             UUID PRIMARY KEY,
//!     item_id        TEXT NOT NULL,        -- replaces drawer_id (Lane F rename)
//!     vector_index   INTEGER NOT NULL,     -- 0 for single-vector; token index for ColBERT
//!     model_id       TEXT NOT NULL,
//!     model_version  TEXT NOT NULL,
//!     kind           INTEGER NOT NULL,     -- VectorKind raw value
//!     dim            INTEGER NOT NULL,     -- number of logical elements
//!     payload        BLOB NOT NULL,        -- raw bytes (Engram wire form for Binary)
//!     scale          REAL,                 -- dequantisation scale for Int8; NULL otherwise
//!     filed_at       TIMESTAMP NOT NULL,
//!     ext            JSON                  -- forward-compat slot (nullable entity ext slots, v3); nullable, NULL in 1.0
//!   )
//!   UNIQUE(item_id, vector_index, model_id)
//!
//! Backward-compatible convenience API:
//! - `add_vector` / `get_vector` / `vectors_for_item` wrap the binary
//!   Engram path for callers that don't need multi-vector or float lanes.
//! - `add_payload` / `get_payload` expose the general typed-payload path.
//!
//! The comment about `drawer_id` in the old schema is gone; the rename
//! is canonical and final.
//!
//! HOT-PATH WIRING: `find_nearest` scans a resident `ResidentVectorArray`
//! via a size-threshold policy:
//!
//!   - Below `mih_threshold` live binary vectors (default 50_000): routes
//!     through `BruteForceIndex` (Lane A, O(N) exact scan, ~sub-ms at
//!     small estates per §3.2 perf model).
//!   - At or above threshold: promotes to `MIHIndex` (Lane B, sub-linear
//!     EXACT Hamming KNN, Norouzi & Fleet CVPR 2012).
//!
//! Both indexes are EXACT. `MIHIndex.search == BruteForceIndex.search`
//! bit-for-bit on identical inputs is the conformance BLOCKER (arch spec
//! §3.3). Results are identical regardless of which index is active.
//!
//! FLOAT LANE (Lane D) HNSW ROUTING: `find_nearest_float` uses a separate
//! size-threshold policy:
//!
//!   - Below `hnsw_threshold` live float32 vectors (default 5,000): routes
//!     through `FloatBruteForceIndex` (Lane C, O(N) exact scan).
//!   - At or above threshold: builds and routes through `HNSWIndex` (Lane D,
//!     approximate NN, Malkov & Yashunin 2018). ≥90% recall@10 at threshold.
//!
//! `find_farthest_float` ALWAYS uses `FloatBruteForceIndex`: anti-similarity
//! with HNSW requires a full-graph scan and provides no speed benefit.
//!
//! By default, both indexes are updated on every write so they stay current
//! immediately. During a deferred-index burst (`begin_deferred_index` /
//! `publish_resident_index`), staged rows are not searchable until publish
//! completes. The size-threshold policy
//! (`select_index`) swaps `is_mih_active` when `live_binary_count` crosses
//! `mih_threshold`. Default band count M16 (§1.6: m ≈ b/log2(n); at 50k
//! log2(50000) ≈ 15.6, nearest conformance value is 16).
//!
//! I-7 satisfied: all Hamming arithmetic routes through the active index →
//! EngramLib → SubstrateKernel (four-way conformance-gated). VectorStore
//! does not reimplement Hamming distance.
//!
//! Telemetry: emits `synapsekit.*` metrics via IntellectusLib when
//! monitoring is enabled. Off by default; off-path cost is one
//! AtomicBool load.

use crate::engine::brute_force::BruteForceIndex;
use crate::engine::float_brute_force::FloatBruteForceIndex;
use crate::engine::hnsw_index::{
    GraphRow, HNSWIndex, HNSW_DEFAULT_THRESHOLD, HNSW_M0, HNSW_MAX_PERSISTED_LAYER,
};
use crate::engine::key::VectorRecordKey;
use crate::engine::metric::{DenseMetric, FloatMetric};
use crate::engine::mih::{MIHBandCount, MIHIndex};
use crate::engine::payload::{VectorKind, VectorPayload};
use crate::engine::resident_store::ResidentArrayStore;
use crate::engine::seam::{DenseIndex, MetadataFilter};
use crate::error::SynapseKitError;
use engram_lib::Engram;
use intellectus_lib::{StatSample, report};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::Arc;
use persistence_kit::{
    BackendConfiguration, Column, ColumnDeclaration, IndexDeclaration, Migration, OrderClause,
    OrderDirection, ResidencyHint, SchemaDeclaration, SchemaOperation,
    Storage, StoragePredicate, StorageRow, TableDeclaration, TypedValue, physical_memory_bytes,
};
use uuid::Uuid;

/// One row of the `vectors` table. Parallel to the Swift `StoredVector`.
///
/// `filed_at` is Unix epoch milliseconds; `vector_index` is 0 for
/// single-vector models.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredVector {
    pub id: String,
    /// Renamed from `drawer_id` (Lane F rename).
    pub item_id: String,
    pub vector_index: u32,
    pub model_id: String,
    pub model_version: String,
    pub engram: Engram,
    /// Unix epoch milliseconds. Callers pass the drawer's
    /// `filed_at`, which is epoch-ms; the `_unix_secs` suffix on the input
    /// params is legacy naming, not a unit — the value is milliseconds.
    pub filed_at: i64,
    /// Shadow-swap generation this row belongs to (v6). Serving rows carry the
    /// model's `serving_generation`; shadow rows carry `shadow_generation` while
    /// a build is in flight. DEFAULT 0 for rows written before the v6 migration.
    /// Contract parity: both ports expose this field on every StoredVector
    /// construction site (SHADOWSWAP_DESIGN_CONTRACT §3).
    pub generation: i64,
}

/// Result of a `VectorStore::find_nearest` call. Parallel to Swift
/// `VectorMatch`.
#[derive(Debug, Clone, PartialEq)]
pub struct VectorMatch {
    /// Renamed from `drawer_id` (Lane F rename).
    pub item_id: String,
    /// Hamming distance over the 256-bit engram. Range 0..=256.
    pub distance: i32,
    pub model_id: String,
    /// Shadow-swap generation this result came from (v6). Matches the serving
    /// generation for the result's model at the time the query was answered.
    /// Contract parity: both ports expose this field on every VectorMatch
    /// construction site (SHADOWSWAP_DESIGN_CONTRACT §3).
    pub generation: i64,
    /// Metric-native similarity in [0,1] when the producing metric is not
    /// Hamming (W2.5 M1: Jaccard); None for Hamming matches. `distance`
    /// remains the ordering key in both cases. Twin of Swift
    /// `VectorMatch.score`.
    pub score: Option<f64>,
}

// Manual Eq: the derived impl was dropped when `score: Option<f64>` landed
// (f64 is not Eq). Equality remains total here because `score` is always a
// finite ratio in [0,1] or None — never NaN — so the Eq marker's
// reflexivity contract holds. Ord (below) reads only distance + item_id.
impl Eq for VectorMatch {}

impl Ord for VectorMatch {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        // Primary: distance ascending. Tiebreak: item_id ascending
        // (universal tie-break rule, retrieval algorithms reference §0.3).
        self.distance
            .cmp(&other.distance)
            .then(self.item_id.cmp(&other.item_id))
    }
}

impl PartialOrd for VectorMatch {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

/// One row of input for the bulk `VectorStore::add_payloads` path.
///
/// Bundles a `VectorPayload` with the index metadata that a single
/// `add_payload` call would otherwise take as separate arguments. The
/// import/migration path builds a slice of these and submits them in one
/// batch so the resident array, sidecar, and indexes are updated once for
/// the whole batch rather than once per row (TASK #24). Parallel to the
/// Swift `VectorPayloadInput`.
#[derive(Debug, Clone, PartialEq)]
pub struct VectorPayloadInput {
    /// The owning item (drawer/chunk) id. Joins to `vectors.item_id`.
    pub item_id: String,
    /// 0 for single-vector models; token position for late-interaction.
    pub vector_index: u32,
    /// The typed vector payload (binary, float32, or int8).
    pub payload: VectorPayload,
    /// The embedding model id.
    pub model_id: String,
    /// The embedding model version.
    pub model_version: String,
    /// Wall-clock filing time as Unix epoch milliseconds (epoch-millisecond instants; determinism
    /// discipline: passed in, never read from the system clock inside the engine).
    pub filed_at_unix_secs: i64,
}

/// One logical vector row address: (item_id, vector_index, model_id) —
/// the triple the schema's UNIQUE constraint keys. Deliberately EXCLUDES
/// model_version: a version bump replaces the row at the same logical
/// position, so scoped deletion must clear every version stored there.
/// Mirrors Swift `VectorExactKey` (GLK shared-content 1.1, P0).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct VectorExactKey {
    pub item_id: String,
    pub vector_index: u32,
    pub model_id: String,
}

impl VectorExactKey {
    pub fn new(item_id: impl Into<String>, vector_index: u32, model_id: impl Into<String>) -> Self {
        VectorExactKey {
            item_id: item_id.into(),
            vector_index,
            model_id: model_id.into(),
        }
    }
}

// ── Deferred-buffer back-pressure cap ────────────────────────────────────

/// Maximum number of (key, bytes) records that may accumulate in the
/// memory-only deferred pending buffer before an intermediate index rebuild
/// is forced.
///
/// When no sidecar is present, deferred records accumulate in
/// `HotState::deferred_pending_records` until `publish_resident_index` is
/// called. Without this cap, a caller that never calls `publish_resident_index`
/// (or does so only at process exit) could grow the buffer without bound.
///
/// At the cap, `flush_deferred_pending` performs a full merge + index rebuild,
/// clears the buffer, reseeds `deferred_live_keys`, and keeps
/// `deferred_index_active = true` so subsequent appends continue deferring
/// normally. The rebuild is transparent to callers — it does NOT end the
/// deferred-index window.
///
/// Mirrors Swift `VectorStore.deferredPendingLimit = 50_000`.
const DEFERRED_PENDING_LIMIT: usize = 50_000;
/// Small drain bursts update the resident indexes directly instead of
/// rebuilding the whole estate snapshot.
const INCREMENTAL_PUBLISH_LIMIT: usize = 256;
/// Periodically materialize a clean snapshot to bound accumulated tombstones.
const INCREMENTAL_COMPACTION_INTERVAL: usize = 1_024;

// ── Hot-path inner state ──────────────────────────────────────────────────

/// Mutable hot-path state, protected by a Mutex.
///
/// Separate from the immutable `Storage` reference so that read-heavy
/// `find_nearest` can lock only the index state (not the storage handle).
struct HotState {
    /// Sidecar-backed persistent store. Present when the caller supplies
    /// a sidecar path at construction. When `None`, the resident array is
    /// held purely in memory (rebuilt from the table on first use).
    array_store: Option<ResidentArrayStore>,

    /// Binary brute-force index — the Lane A conformance oracle.
    ///
    /// Always kept in sync with the resident array. Used directly when
    /// `live_binary_count < mih_threshold`, and as the backing array
    /// source for key iteration in all delete paths.
    brute_force_index: BruteForceIndex,

    /// Multi-Index Hashing index — Lane B, sub-linear EXACT Hamming KNN.
    ///
    /// Always kept in sync with `brute_force_index`. Active when
    /// `live_binary_count >= mih_threshold`.
    mih_index: MIHIndex,

    /// Count of live (non-tombstoned) binary vectors.
    ///
    /// Incremented on successful insert (non-replacement), decremented on
    /// delete. Drives the threshold policy in `select_index`.
    live_binary_count: u32,

    /// Below this count use BruteForce; at or above, use MIH.
    ///
    /// Set at construction; overridable via `new_with_threshold`.
    mih_threshold: u32,

    /// True when MIH is the active (hot) index; false when BruteForce is.
    ///
    /// Updated by `select_index`. Separate from `live_binary_count >= mih_threshold`
    /// to avoid recomputing the condition in hot paths.
    is_mih_active: bool,

    /// True once both indexes have been populated. Set by `ensure_index_built_locked`
    /// on the first `find_nearest` or write call.
    index_built: bool,

    /// Deferred-index (bulk-write) mode — Rust twin of Swift `deferredIndexActive`.
    /// While active, `add_payloads` appends to the durable table + resident array
    /// but DEFERS the MIH + brute-force rebuild; `publish_resident_index` rebuilds
    /// once at the end of the burst (O(N) bulk import instead of O(N²) per-write).
    deferred_index_active: bool,

    /// At least one deferred append since the last publish — gates
    /// `publish_resident_index` so it is a no-op on an idle barrier.
    deferred_index_dirty: bool,

    /// Live full keys grouped by the durable schema's logical UNIQUE position.
    /// The grouping excludes model version, so a version bump removes the stale
    /// resident slot instead of leaving two searchable versions in memory.
    deferred_live_keys: Option<
        std::collections::HashMap<
            VectorExactKey,
            std::collections::HashSet<VectorRecordKey>,
        >,
    >,

    /// Full keys superseded in the active window. Small-delta publication uses
    /// these to remove stale model-version entries before incremental upsert.
    deferred_replaced_keys: std::collections::HashSet<VectorRecordKey>,

    /// Memory-only deferral buffer (Rust twin of Swift `deferredPendingRecords`).
    /// With no sidecar `array_store`, deferred `add_payloads` records accumulate
    /// here and `publish_resident_index` merges them all in one pass at burst end.
    deferred_pending_records: Vec<(VectorRecordKey, Vec<u8>)>,

    /// Number of small incremental publications since the last full snapshot
    /// materialization. Bounds tombstone history in the brute-force oracle.
    incremental_publication_count: usize,

    /// Maximum records allowed in `deferred_pending_records` before an
    /// intermediate flush is forced (memory-only deferred path only).
    /// Default is `DEFERRED_PENDING_LIMIT` (50_000). Configurable via
    /// `new_with_deferred_limit` so tests can use a small value to exercise
    /// the back-pressure flush path without large record counts.
    deferred_pending_limit: usize,

    /// Lane D: the in-house exact float indices, ONE PER modelID, over the
    /// float32 rows in the `vectors` table. Production exact path per Bob's
    /// storage amendment (2026-06-12): floats live in resident float arrays
    /// scanned by `FloatBruteForceIndex` — no external engine.
    ///
    /// ## Why per-modelID (mission 6a-iii-core)
    ///
    /// `FloatBruteForceIndex` requires a SINGLE stride (one dimension) per index
    /// and `search` errors when the probe dimension does not match the array
    /// stride. Different models emit different float dimensions, and an
    /// N-provider corpus holds several models' float rows in one `vectors`
    /// table, so a SINGLE shared index built from the first record's stride
    /// would be corrupt for every other model and error on query. Spec I-4 keeps
    /// models on disjoint partitions and forbids cross-model comparison, so the
    /// correct structure is one index per modelID, built from that model's rows
    /// only (uniform stride). For a single-model corpus the map holds exactly
    /// one entry — byte-identical behaviour to the prior single shared index.
    /// Mirrors Swift `VectorStore.floatIndices`.
    ///
    /// The float lane is reproducible-within-config, NOT four-way bit-identical
    /// (arch spec §6), so it is kept on its own indices, separate from the
    /// binary `brute_force_index`/`mih_index` (I-7). Built lazily per modelID on
    /// the first `find_nearest_float` for that model; the entry's presence in
    /// the map is the per-model "built" flag.
    float_indices: std::collections::HashMap<String, FloatBruteForceIndex>,

    /// Per-modelID approximate nearest-neighbour graphs (Lane D HNSW).
    ///
    /// Activates at/above `VectorStore.hnsw_threshold` live vectors per modelID.
    /// Loaded from the `hnsw_graph` SQLite table on first qualifying
    /// `find_nearest_float` call (persisted by THETA rebuild and BETA compact).
    /// Mirrors Swift `VectorStore.hnswIndices`.
    hnsw_indices: std::collections::HashMap<String, HNSWIndex>,

    /// Live float32 vector count per modelID. Used to decide when to activate
    /// HNSW above the crossover threshold. Mirrors Swift `VectorStore.liveFloatCounts`.
    ///
    /// Set when `ensure_float_index_built_locked` builds the per-model float index,
    /// and incremented by `add_payload` when mirroring a float32 write.
    live_float_counts: std::collections::HashMap<String, u32>,

    /// Number of times the HNSW graph was REBUILT (not loaded) per modelID.
    ///
    /// Incremented by `rebuild_hnsw_index` after a full corpus re-insert.
    /// A LOAD from the `hnsw_graph` table does NOT increment this counter.
    /// Exposed for test assertions so tests can distinguish process-restart
    /// load paths (build_count == 0) from inline builds (build_count > 0).
    /// Mirrors Swift `VectorStore.hnswBuildCount`.
    pub(crate) hnsw_build_count: std::collections::HashMap<String, u32>,

    /// ModelID partitions modified by encode-path inserts since the last `flush()`.
    ///
    /// `add_payload` sets this when it mirrors a float32 insert into an active
    /// HNSW graph. `flush()` drains the set and calls `persist_hnsw_graph` for
    /// each dirty partition before flushing the binary sidecar.
    /// Mirrors Swift `VectorStore.hnswGraphDirty`.
    hnsw_graph_dirty: std::collections::HashSet<String>,

    /// Number of times the sidecar was detected as stale and rebuilt from
    /// the `vectors` table in the lifetime of this `VectorStore` instance.
    ///
    /// Incremented by `ensure_index_built_locked` on each stale-sidecar path.
    /// Zero means the sidecar was current on load (the normal path). Exposed
    /// for test assertions only — callers should not use this value to drive
    /// application logic.
    sidecar_rebuild_count: usize,

    // ── Shadow-swap in-memory caches (§2 + §3 of SHADOWSWAP_DESIGN_CONTRACT) ──

    /// Serving generation per modelID. Absent entry → serving generation 0
    /// (the DEFAULT for models that have never participated in a shadow swap).
    /// Updated by `begin_shadow_generation` (on begin) and
    /// `publish_shadow_generation` (after the flip commits).
    /// Mirrors Swift `VectorStore.servingGenerations`.
    pub(crate) serving_generations: std::collections::HashMap<String, i64>,

    /// Shadow generation per modelID when a shadow build is in flight.
    /// Absent entry → no active shadow for that model.
    /// Populated by `begin_shadow_generation`; removed by `publish_shadow_generation`.
    /// Mirrors Swift `VectorStore.shadowGenerations`.
    pub(crate) shadow_generations: std::collections::HashMap<String, i64>,

    /// Shadow state string per modelID.
    ///   'building'        — shadow in flight, incomplete.
    ///   'pending-reclaim' — flip committed, superseded rows not yet deleted.
    /// Absent entry → no shadow state for that model.
    /// Mirrors Swift `VectorStore.shadowStates`.
    pub(crate) shadow_states: std::collections::HashMap<String, String>,

    /// Accumulated shadow payload bytes per modelID for the current build window.
    /// `add_payload` increments this on every shadow write (Binary + Float32).
    /// Exposed via `peak_shadow_storage_bytes` for the §2 peak-storage probe.
    /// Mirrors Swift `VectorStore.shadowPayloadBytes`.
    pub(crate) shadow_payload_bytes: std::collections::HashMap<String, i64>,

    /// Generation of the HNSW graph instance that last answered a `find_nearest_float`
    /// query for each modelID. None (absent entry) if no float query has been served
    /// for that model since this VectorStore was opened. Recorded at answer time from
    /// the graph object, not from a store-level field (§4 probe-reading requirement).
    /// Exposed via `last_served_graph_generation` for Gate 5 assertions.
    /// Mirrors Swift `VectorStore.lastServedGraphGen`.
    pub(crate) last_served_graph_gen: std::collections::HashMap<String, i64>,

    /// Models whose shadow generation was opened in THIS process instance via
    /// `begin_shadow_generation`. Removed by `publish_shadow_generation` (flip
    /// committed) and `abandon_shadow_generation` (explicit abort).
    ///
    /// Purpose: distinguish a genuinely in-flight shadow from an abandoned
    /// 'building' DB row written by a prior crashed process.
    /// `reclaim_superseded_generations` exempts models in this set from reclaim;
    /// models with shadow_state='building' in the DB but NOT in this set are
    /// abandoned and their rows are reclaimed.
    ///
    /// CRITICAL: do NOT use `shadow_generations` for this purpose.
    /// `shadow_generation()` populates that map as a side effect of merely
    /// READING the registry, so after any read it no longer means "opened in
    /// this process". This field is the sole reliable in-flight marker.
    /// Mirrors Swift `VectorStore.openShadows`.
    pub(crate) open_shadows: std::collections::HashSet<String>,

    // ── Admission accounting — self-reconciling map (BRR §5) ─────────────────

    /// Projected heap footprint in bytes per modelID for each float index
    /// currently resident. Keyed identically to `float_indices` so that the
    /// admission gate can reconcile this map against `float_indices` in a
    /// single pass: entries whose model is absent from `float_indices` have
    /// been evicted and are dropped before summing.
    ///
    /// WHY A MAP RATHER THAN A RUNNING COUNTER: a counter must be decremented
    /// at every site that drops a cached index. There are ~9 such sites per port
    /// (evict_float_indices, delete_all_vectors, publish_shadow_generation, and
    /// six others). A single missed site drifts the counter upward until every
    /// estate is refused forever. The map self-reconciles at admission time by
    /// comparing against `float_indices`, so none of those sites need to be
    /// edited and none can cause drift. Do NOT replace this with a counter.
    float_index_footprints: std::collections::HashMap<String, u64>,

    /// Total count of admission refusals across all modelIDs since this
    /// `VectorStore` was opened. Incremented by `ensure_float_index_built_locked`
    /// on every refusal. Exposed via `admission_refusal_count()` for tests.
    /// Mirrors Swift `VectorStore.admissionRefusalCount`.
    admission_refusal_count: u64,
}

// ── VectorStore ───────────────────────────────────────────────────────────

/// persistence-kit-backed CRUD over the `vectors` table.
///
/// Thread-safety: the hot-path resident array is protected by a `Mutex`.
/// The `Storage` handle is `Arc<dyn Storage>` and is assumed thread-safe
/// by the PersistenceKit contract.
///
/// The `vectors` table is the durable source of truth. The resident array
/// is a regenerable cache loaded once per process lifetime (from the .vec
/// sidecar if a sidecar path is supplied, or from a full table scan). All
/// writes keep both in sync; `find_nearest` reads only the resident array.
pub struct VectorStore {
    storage: Arc<dyn Storage>,
    state: Mutex<HotState>,
    /// Live float32 count per modelID above which `HNSWIndex` activates for
    /// `find_nearest_float`. Below this count `FloatBruteForceIndex` is used.
    /// Mirrors Swift `VectorStore.hnswThreshold`.
    hnsw_threshold: u32,
}

impl VectorStore {
    /// Schema declaration consumed by `Storage::open`. Lane F
    /// multi-vector schema: UNIQUE(item_id, vector_index, model_id).
    ///
    /// v3 adds the nullable `.json` `ext` forward-compat slot;
    /// 1.0 writes NULL and never reads it.
    ///
    /// v4 adds `idx_vectors_filed_at_item` on (filed_at, item_id).
    /// Covers `recent_item_ids` ORDER BY filed_at DESC, item_id ASC so
    /// SQLite can do an ordered index scan rather than a full-table scan +
    /// filesort. Migrated onto existing estates by the v3→v4 migration.
    ///
    /// v5 adds the `hnsw_graph` table — the schema home for the
    /// approximate float-lane NN index (Lane D). The table is
    /// device-local derived state (never in ConvergenceKit sync manifests)
    /// and is rebuildable from the `vectors` table at any time.
    /// Columns: model_id TEXT, node_idx INTEGER, node_id TEXT,
    /// layer INTEGER, neighbours BLOB; PK=(model_id, node_idx, layer).
    pub fn schema_declaration() -> SchemaDeclaration {
        // v5 hnsw_graph table declaration — reused in the v4→v5 migration only.
        // The v6 declaration (with generation column) is the canonical table entry.
        let hnsw_graph_table_v5 = TableDeclaration::new(
            "hnsw_graph",
            vec![
                ColumnDeclaration::text("model_id"),
                ColumnDeclaration::int("node_idx"),
                ColumnDeclaration::text("node_id"),
                ColumnDeclaration::int("layer"),
                ColumnDeclaration::blob("neighbours"),
            ],
            vec![
                "model_id".to_string(),
                "node_idx".to_string(),
                "layer".to_string(),
            ],
        );
        // v6 hnsw_graph table declaration — includes `generation` column.
        // Reused in both the table list and the v5→v6 migration.
        let hnsw_graph_table_v6 = TableDeclaration::new(
            "hnsw_graph",
            vec![
                // Partition key: which embedding model owns this graph node.
                ColumnDeclaration::text("model_id"),
                // Ordinal index of the node within this model's graph
                // (assigned at serialisation time, stable for the life of the graph).
                ColumnDeclaration::int("node_idx"),
                // The item ID stored at this node (matches vectors.item_id).
                ColumnDeclaration::text("node_id"),
                // Layer within the HNSW hierarchical structure (0 = base layer).
                ColumnDeclaration::int("layer"),
                // Serialized neighbour list: little-endian u32 node indices.
                // Rebuilt from the vectors table when the graph is cleared.
                ColumnDeclaration::blob("neighbours"),
                // v6: shadow-swap generation. Rows with a different generation from
                // the serving generation are silently skipped at load time (§4).
                // DEFAULT 0 ensures backward-compat reads from v5 graphs return
                // generation-0 rows (which match serving_gen 0 for non-swapped estates).
                ColumnDeclaration::int("generation").with_default(TypedValue::Int(0)),
            ],
            vec![
                "model_id".to_string(),
                "node_idx".to_string(),
                "layer".to_string(),
            ],
        );
        SchemaDeclaration::new(
            "SynapseKit",
            6,
            vec![
                TableDeclaration::new(
                    "vectors",
                    vec![
                        ColumnDeclaration::uuid("id"),
                        // Lane F rename: item_id replaces drawer_id.
                        ColumnDeclaration::text("item_id"),
                        // vector_index: 0 for single-vector models; token
                        // position for ColBERT late-interaction.
                        ColumnDeclaration::int("vector_index"),
                        ColumnDeclaration::text("model_id"),
                        ColumnDeclaration::text("model_version"),
                        // kind: VectorKind raw integer (0=Binary,1=Float32,2=Int8).
                        ColumnDeclaration::int("kind"),
                        // dim: number of logical elements (bits for Binary,
                        // floats for Float32, int8s for Int8).
                        ColumnDeclaration::int("dim"),
                        // payload: raw bytes. For Binary: 32-byte Engram wire form.
                        ColumnDeclaration::blob("payload"),
                        // scale: dequantisation multiplier for Int8; NULL for Binary/Float32.
                        ColumnDeclaration::float("scale").nullable(),
                        ColumnDeclaration::timestamp("filed_at"),
                        // ext: nullable entity ext slots forward-compat slot (v3). Nullable JSON;
                        // future per-vector typed metadata (quantisation provenance,
                        // embedding-run tags) serializes here migration-free. 1.0
                        // writes NULL and never reads it.
                        ColumnDeclaration::json("ext").nullable(),
                        // v6: shadow-swap generation. Serving rows carry the model's
                        // serving_generation (0 for estates with no prior swap).
                        // Shadow rows carry shadow_generation while a build is in flight.
                        // DEFAULT 0 ensures backward-compat reads from v5 estates return
                        // serving-generation rows automatically.
                        // UNIQUE constraint widens to include generation so serving rows
                        // (generation = serving_gen) and shadow rows (generation =
                        // shadow_gen) for the same (item_id, vector_index, model_id)
                        // can coexist during a shadow build.
                        ColumnDeclaration::int("generation").with_default(TypedValue::Int(0)),
                    ],
                    vec!["id".to_string()],
                )
                .with_unique_constraints(vec![vec![
                    "item_id".to_string(),
                    "vector_index".to_string(),
                    "model_id".to_string(),
                    "generation".to_string(),
                ]]),
                // v5 + v6: HNSW graph storage table (v6 declaration: includes generation).
                // Device-local derived state; never synced via ConvergenceKit.
                // Rebuildable from `vectors` at any time.
                hnsw_graph_table_v6.clone(),
                // v6: vector_generations registry — one row per model_id that has
                // ever participated in a shadow swap. Absent row ⇒ serving_generation = 0,
                // no shadow active. `shadow_state` values:
                //   'building'        — shadow in flight, incomplete, reclaimable.
                //   'pending-reclaim' — flip committed, superseded rows not yet deleted.
                // NO Bool columns per schema invariant — state is the TEXT enum plus
                // nullable shadow_generation.
                TableDeclaration::new(
                    "vector_generations",
                    vec![
                        ColumnDeclaration::text("model_id"),
                        ColumnDeclaration::int("serving_generation")
                            .with_default(TypedValue::Int(0)),
                        ColumnDeclaration::int("shadow_generation").nullable(),
                        ColumnDeclaration::text("shadow_state").nullable(),
                    ],
                    vec!["model_id".to_string()],
                ),
            ],
        )
        .with_indices(vec![
            IndexDeclaration::new(
                "idx_vectors_item",
                "vectors",
                vec!["item_id".to_string()],
            ),
            IndexDeclaration::new(
                "idx_vectors_model_item",
                "vectors",
                vec!["model_id".to_string(), "item_id".to_string()],
            ),
            // v4: covers recent_item_ids ORDER BY filed_at DESC, item_id ASC.
            // SQLite can traverse this index in reverse for the DESC major key,
            // eliminating the full-table scan + filesort that fired on every
            // recent_item_ids call before v4. With query_projected projecting
            // only (item_id, filed_at), this also enables a covering scan —
            // payload blobs are never read off disk. Migrated by v3→v4 below.
            IndexDeclaration::new(
                "idx_vectors_filed_at_item",
                "vectors",
                vec!["filed_at".to_string(), "item_id".to_string()],
            ),
            // v6: serves serving-generation filter (WHERE model_id=? AND generation=?)
            // and batched reclamation scans (WHERE model_id=? AND generation!=?).
            // Migrated onto existing estates by the v5→v6 migration.
            IndexDeclaration::new(
                "idx_vectors_model_generation",
                "vectors",
                vec!["model_id".to_string(), "generation".to_string()],
            ),
        ])
        .with_migrations(vec![
            // v3 → v4: add idx_vectors_filed_at_item to existing estates.
            // Idempotent: the backend's CREATE INDEX IF NOT EXISTS makes it
            // safe to replay. SQLite backfills the index over existing rows
            // when CREATE INDEX runs against a non-empty table.
            Migration {
                from_version: 3,
                to_version: 4,
                operations: vec![SchemaOperation::AddIndex(IndexDeclaration::new(
                    "idx_vectors_filed_at_item",
                    "vectors",
                    vec!["filed_at".to_string(), "item_id".to_string()],
                ))],
            },
            // v4 → v5: add the hnsw_graph table to existing estates.
            // New estates receive it directly from the schema declaration above (v6 decl).
            // Idempotent: CREATE TABLE IF NOT EXISTS (enforced by the backend).
            Migration {
                from_version: 4,
                to_version: 5,
                operations: vec![SchemaOperation::CreateTable(hnsw_graph_table_v5)],
            },
            // v5 → v6: shadow-swap generation support.
            //
            // Three changes on existing estates:
            //   (a) vectors table: add `generation` column AND change the UNIQUE
            //       constraint from (item_id, vector_index, model_id) to
            //       (item_id, vector_index, model_id, generation). SQLite cannot
            //       ALTER TABLE to change a UNIQUE constraint, so the table is
            //       recreated via four .custom(sqlite:) ops. InMemory ignores
            //       .custom ops (they are no-ops in InMemoryStorage); fresh
            //       InMemory databases get the v6 table declaration directly.
            //   (b) hnsw_graph: addColumn `generation` (idempotent on both SQLite
            //       and InMemory because the column already exists in the v6 table
            //       declaration for fresh databases).
            //   (c) vector_generations registry: new table (idempotent via createTable
            //       which emits CREATE TABLE IF NOT EXISTS on InMemory + SQLite).
            //
            // All four .custom ops run inside the migration's BEGIN IMMEDIATE
            // transaction on SQLite. They are correct when replayed on a fresh
            // database: vectors_v6 is created, data copied from the just-created
            // (empty) vectors table, vectors dropped, and vectors_v6 renamed —
            // net result is the same v6-schema table. Indices dropped with the
            // old table are re-added at the end of this migration.
            Migration {
                from_version: 5,
                to_version: 6,
                operations: vec![
                    // (a-1) Recreate vectors with the new UNIQUE constraint and generation column.
                    SchemaOperation::Custom {
                        sqlite: Some(
                            "CREATE TABLE \"vectors_v6\" (\"id\" TEXT PRIMARY KEY NOT NULL, \
                             \"item_id\" TEXT NOT NULL, \"vector_index\" INTEGER NOT NULL DEFAULT 0, \
                             \"model_id\" TEXT NOT NULL, \"model_version\" TEXT NOT NULL, \
                             \"kind\" INTEGER NOT NULL DEFAULT 0, \"dim\" INTEGER NOT NULL DEFAULT 256, \
                             \"payload\" BLOB NOT NULL, \"scale\" REAL, \"filed_at\" TEXT NOT NULL, \
                             \"ext\" TEXT, \"generation\" INTEGER NOT NULL DEFAULT 0, \
                             UNIQUE(\"item_id\",\"vector_index\",\"model_id\",\"generation\"))"
                                .to_string(),
                        ),
                        postgresql: None,
                    },
                    // (a-2) Copy all existing rows; tag with generation 0 (existing data = serving gen 0).
                    SchemaOperation::Custom {
                        sqlite: Some(
                            "INSERT INTO \"vectors_v6\" \
                             SELECT \"id\",\"item_id\",\"vector_index\",\"model_id\",\"model_version\",\
                             \"kind\",\"dim\",\"payload\",\"scale\",\"filed_at\",\"ext\",0 \
                             FROM \"vectors\""
                                .to_string(),
                        ),
                        postgresql: None,
                    },
                    // (a-3) Drop old vectors table (and its indices — SQLite drops them automatically).
                    SchemaOperation::Custom {
                        sqlite: Some("DROP TABLE \"vectors\"".to_string()),
                        postgresql: None,
                    },
                    // (a-4) Rename vectors_v6 to vectors.
                    SchemaOperation::Custom {
                        sqlite: Some("ALTER TABLE \"vectors_v6\" RENAME TO \"vectors\"".to_string()),
                        postgresql: None,
                    },
                    // Re-create all vectors indices dropped with the old table.
                    SchemaOperation::AddIndex(IndexDeclaration::new(
                        "idx_vectors_item",
                        "vectors",
                        vec!["item_id".to_string()],
                    )),
                    SchemaOperation::AddIndex(IndexDeclaration::new(
                        "idx_vectors_model_item",
                        "vectors",
                        vec!["model_id".to_string(), "item_id".to_string()],
                    )),
                    SchemaOperation::AddIndex(IndexDeclaration::new(
                        "idx_vectors_filed_at_item",
                        "vectors",
                        vec!["filed_at".to_string(), "item_id".to_string()],
                    )),
                    SchemaOperation::AddIndex(IndexDeclaration::new(
                        "idx_vectors_model_generation",
                        "vectors",
                        vec!["model_id".to_string(), "generation".to_string()],
                    )),
                    // (b) Add generation column to hnsw_graph (DEFAULT 0 — existing
                    //     rows all belong to generation 0, the pre-swap serving generation).
                    SchemaOperation::AddColumn {
                        table: "hnsw_graph".to_string(),
                        column: ColumnDeclaration::int("generation")
                            .with_default(TypedValue::Int(0)),
                    },
                    // (c) Create vector_generations registry (idempotent via IF NOT EXISTS).
                    SchemaOperation::CreateTable(TableDeclaration::new(
                        "vector_generations",
                        vec![
                            ColumnDeclaration::text("model_id"),
                            ColumnDeclaration::int("serving_generation")
                                .with_default(TypedValue::Int(0)),
                            ColumnDeclaration::int("shadow_generation").nullable(),
                            ColumnDeclaration::text("shadow_state").nullable(),
                        ],
                        vec!["model_id".to_string()],
                    )),
                ],
            },
        ])
    }

    /// Test-only: open a VectorStore with a custom HNSW activation threshold.
    ///
    /// Allows tests to trigger HNSW routing with small corpora (e.g.
    /// threshold 10 with 20 vectors) without waiting for the default 5,000.
    /// Not part of the stable public API. All production callers use `open`.
    pub fn open_with_hnsw_threshold(
        storage: Arc<dyn Storage>,
        hnsw_threshold: u32,
    ) -> Result<Self, SynapseKitError> {
        let schema = Self::schema_declaration();
        storage
            .open(&schema)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        Ok(Self::new_internal(
            storage,
            None,
            50_000,
            MIHBandCount::M16,
            DEFERRED_PENDING_LIMIT,
            hnsw_threshold,
        ))
    }

    /// Construct against an already-opened `Storage`, with optional sidecar
    /// persistence and default threshold/band-count parameters.
    ///
    /// The caller is responsible for calling `Storage::open(schema_declaration())`
    /// before using the store.
    ///
    /// - `storage`: A PersistenceKit Storage instance.
    /// - `sidecar_path`: Optional path to a `.vec` packed binary sidecar.
    ///   When supplied, the resident array is loaded from this file on first
    ///   use (one OS read, amortised) and kept in sync on every write. A stale
    ///   or absent sidecar is detected by comparing its slot count to the
    ///   table binary-row count; if they disagree the array is rebuilt and the
    ///   sidecar is rewritten. When `None`, the array is built from the table
    ///   on first use and held in memory only.
    ///
    /// Default threshold: 50_000 binary vectors. Default band count: M16
    /// (m ≈ b/log2(n) at 50k → log2(50000) ≈ 15.6, nearest conformance value).
    pub fn new(storage: Arc<dyn Storage>, sidecar_path: Option<PathBuf>) -> Self {
        Self::new_with_threshold(storage, sidecar_path, 50_000, MIHBandCount::M16)
    }

    /// Derive the conventional resident-array sidecar path for an estate's
    /// storage: a `.vec` file beside the SQLite database
    /// (`<estate>.sqlite` -> `<estate>.vectors.vec`). Mirrors Swift
    /// `VectorStore.defaultSidecarURL(for:)`.
    ///
    /// Returns `None` for non-file backends (in-memory, PostgreSQL) where a local
    /// sidecar does not apply — those rebuild the resident array from the table on
    /// each open, which is correct for ephemeral / server-hosted backends. The
    /// `.vec` filename convention lives here in SynapseKit so every caller derives
    /// the same stable path.
    pub fn default_sidecar_path(storage: &Arc<dyn Storage>) -> Option<PathBuf> {
        match &storage.configuration().backend {
            BackendConfiguration::Sqlite { path, .. } => {
                let mut p = PathBuf::from(path);
                p.set_extension("vectors.vec");
                Some(p)
            }
            _ => None,
        }
    }

    /// Construct with an explicit threshold and MIH band count.
    ///
    /// Useful for callers with different estate sizes or for tests that need
    /// to cross the threshold with a small corpus.
    pub fn new_with_threshold(
        storage: Arc<dyn Storage>,
        sidecar_path: Option<PathBuf>,
        mih_threshold: u32,
        mih_band_count: MIHBandCount,
    ) -> Self {
        let array_store = sidecar_path.map(|p| ResidentArrayStore::new_binary(p));
        Self::new_internal(storage, array_store, mih_threshold, mih_band_count,
                           DEFERRED_PENDING_LIMIT, HNSW_DEFAULT_THRESHOLD)
    }

    /// Internal constructor. All public constructors delegate here.
    fn new_internal(
        storage: Arc<dyn Storage>,
        array_store: Option<ResidentArrayStore>,
        mih_threshold: u32,
        mih_band_count: MIHBandCount,
        deferred_pending_limit: usize,
        hnsw_threshold: u32,
    ) -> Self {
        VectorStore {
            storage,
            hnsw_threshold,
            state: Mutex::new(HotState {
                array_store,
                brute_force_index: BruteForceIndex::new(),
                mih_index: MIHIndex::new(mih_band_count),
                live_binary_count: 0,
                mih_threshold,
                is_mih_active: false,
                index_built: false,
                deferred_index_active: false,
                deferred_index_dirty: false,
                deferred_live_keys: None,
                deferred_replaced_keys: std::collections::HashSet::new(),
                deferred_pending_records: Vec::new(),
                incremental_publication_count: 0,
                deferred_pending_limit,
                // Float indices are built lazily per modelID on first
                // find_nearest_float; the map starts empty.
                float_indices: std::collections::HashMap::new(),
                // HNSW indices and live counts start empty; loaded from the
                // hnsw_graph table on first qualifying find_nearest_float call.
                hnsw_indices: std::collections::HashMap::new(),
                live_float_counts: std::collections::HashMap::new(),
                hnsw_build_count: std::collections::HashMap::new(),
                hnsw_graph_dirty: std::collections::HashSet::new(),
                sidecar_rebuild_count: 0,
                // Shadow-swap in-memory caches — start empty.
                // Populated lazily by begin_shadow_generation and
                // publish_shadow_generation as shadow windows are opened and closed.
                serving_generations: std::collections::HashMap::new(),
                shadow_generations: std::collections::HashMap::new(),
                shadow_states: std::collections::HashMap::new(),
                shadow_payload_bytes: std::collections::HashMap::new(),
                last_served_graph_gen: std::collections::HashMap::new(),
                // open_shadows tracks models whose shadow was begun in this process
                // instance. Empty on open: prior crashed processes' shadows are
                // abandoned rows, not in-flight ones.
                open_shadows: std::collections::HashSet::new(),
                // Admission accounting starts empty; populated by
                // ensure_float_index_built_locked on each admitted index.
                float_index_footprints: std::collections::HashMap::new(),
                admission_refusal_count: 0,
            }),
        }
    }

    /// Test-only constructor: same as `new_with_threshold` but with a custom
    /// `deferred_pending_limit`. Allows tests to trigger the back-pressure
    /// flush with a small record count, without flooding the index with
    /// production-scale data. Not part of the stable public API — exposed
    /// as `pub` rather than `pub(crate)` because Rust integration tests
    /// (in `tests/`) are separate crates and cannot see `pub(crate)` items.
    pub fn new_with_deferred_limit(
        storage: Arc<dyn Storage>,
        sidecar_path: Option<PathBuf>,
        mih_threshold: u32,
        mih_band_count: MIHBandCount,
        deferred_pending_limit: usize,
    ) -> Self {
        let array_store = sidecar_path.map(|p| ResidentArrayStore::new_binary(p));
        Self::new_internal(storage, array_store, mih_threshold, mih_band_count,
                           deferred_pending_limit, HNSW_DEFAULT_THRESHOLD)
    }

    /// Convenience: construct with no sidecar (memory-only resident array).
    ///
    /// Equivalent to `new(storage, None)`. Used by callers that do not
    /// have a stable sidecar path (e.g. in-process tests).
    pub fn new_no_sidecar(storage: Arc<dyn Storage>) -> Self {
        Self::new(storage, None)
    }

    /// Open the storage's schema and return the store (no sidecar).
    ///
    /// Convenience for callers that want a single `open` call and do not
    /// need sidecar persistence. Parallel to Swift `VectorStore(storage:)`.
    pub fn open(storage: Arc<dyn Storage>) -> Result<Self, SynapseKitError> {
        let schema = Self::schema_declaration();
        storage
            .open(&schema)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        Ok(VectorStore::new(storage, None))
    }

    /// Number of times the sidecar was detected as stale and rebuilt in
    /// the lifetime of this `VectorStore` instance.
    ///
    /// Zero is the normal path (sidecar was current on reopen). A non-zero
    /// value indicates the sidecar was missing, corrupted, or out of sync
    /// with the `vectors` table at startup. Exposed for test assertions.
    pub fn sidecar_rebuild_count(&self) -> usize {
        self.state.lock().unwrap().sidecar_rebuild_count
    }

    // -----------------------------------------------------------------------
    // Convenience API — binary Engram path (single-vector, vector_index=0)
    // -----------------------------------------------------------------------

    /// Insert or update the binary Engram vector for `(item_id, 0, model_id)`.
    ///
    /// Keeps the resident hot-path array in sync with the table write.
    ///
    /// Telemetry: emits `synapsekit.index.insert_latency_ms` when monitoring
    /// is enabled. Emitted at the operation boundary.
    pub fn add_vector(
        &self,
        item_id: &str,
        engram: &Engram,
        model_id: &str,
        model_version: &str,
        filed_at_unix_secs: i64,
    ) -> Result<(), SynapseKitError> {
        let payload = VectorPayload::from_engram(engram);
        self.add_payload(item_id, 0, &payload, model_id, model_version, filed_at_unix_secs)
    }

    /// General write path: insert or update a typed payload for
    /// `(item_id, vector_index, model_id)`.
    ///
    /// For binary payloads: writes the row AND mirrors the vector into the
    /// resident array, updating the binary index incrementally. For float32
    /// payloads: writes the row AND mirrors into the per-model
    /// `FloatBruteForceIndex` when that index is already built. Other kinds
    /// (e.g. int8) are written to the table only.
    ///
    /// Sidecar persistence is WRITE-BEHIND (TASK #24): the in-memory resident
    /// array is updated immediately but the `.vec` sidecar is marked dirty,
    /// not rewritten, per call. Call `flush()` at a quiesce point to persist;
    /// crash safety is preserved because the `vectors` table is the durable
    /// source (a stale sidecar is rebuilt from the table on the next open).
    /// For importing many vectors at once, prefer `add_payloads`, which bounds
    /// both sidecar writes and index builds to O(batches).
    ///
    /// # Errors
    ///
    /// Returns `SynapseKitError::Int8QuantizationPolicyUndefined` when the
    /// payload kind is `Int8`. Int8 writes are rejected fail-closed because
    /// the quantization policy (symmetric vs asymmetric, per-vector vs per-dim
    /// scale) has not been ratified. Use `Float32` or `Binary` instead.
    /// See SYNAPSEKIT_SPEC §I-4a.
    ///
    /// Telemetry: emits `synapsekit.index.insert_latency_ms` when monitoring
    /// is enabled. Emitted at the operation boundary.
    pub fn add_payload(
        &self,
        item_id: &str,
        vector_index: u32,
        payload: &VectorPayload,
        model_id: &str,
        model_version: &str,
        filed_at_unix_secs: i64,
    ) -> Result<(), SynapseKitError> {
        // PRECONDITION GUARD: int8 writes are rejected fail-closed.
        // The quantization policy (symmetric vs asymmetric, per-vector vs
        // per-dim scale) has not been ratified. Persisting an int8 payload now
        // would lock in undefined dequantization semantics. Use Float32 or the
        // Binary Engram lane. See SYNAPSEKIT_SPEC §I-4a and arch spec §10.3.
        if payload.kind == VectorKind::Int8 {
            return Err(SynapseKitError::Int8QuantizationPolicyUndefined(
                "int8 writes are rejected: quantization policy is unspecified. \
                 Use Float32 or the Binary Engram lane. See SYNAPSEKIT_SPEC §I-4a."
                    .to_string(),
            ));
        }

        let start = std::time::Instant::now();

        // Shadow-swap write routing: determine which generation this write belongs to
        // and whether it is a shadow write (bypasses all resident structures).
        // Lock state briefly — no I/O inside the lock.
        let (write_gen, is_shadow_write) = {
            let mut state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            let serving = state.serving_generations.get(model_id).copied().unwrap_or(0);
            if let Some(&sg) = state.shadow_generations.get(model_id) {
                if state.shadow_states.get(model_id).map(|s| s.as_str()) == Some("building") {
                    // Tally payload bytes for peak-storage instrumentation (Gate 9).
                    *state.shadow_payload_bytes.entry(model_id.to_string()).or_insert(0)
                        += payload.bytes.len() as i64;
                    (sg, true)
                } else {
                    (serving, false)
                }
            } else {
                (serving, false)
            }
        };

        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
        values.insert("item_id".to_string(), TypedValue::Text(item_id.to_string()));
        values.insert("vector_index".to_string(), TypedValue::Int(vector_index as i64));
        values.insert("model_id".to_string(), TypedValue::Text(model_id.to_string()));
        values.insert("model_version".to_string(), TypedValue::Text(model_version.to_string()));
        values.insert("kind".to_string(), TypedValue::Int(payload.kind.raw()));
        values.insert("dim".to_string(), TypedValue::Int(payload.dim as i64));
        values.insert("payload".to_string(), TypedValue::Blob(payload.bytes.clone()));
        match payload.scale {
            Some(s) => {
                values.insert("scale".to_string(), TypedValue::Float(s as f64));
            }
            None => {
                values.insert("scale".to_string(), TypedValue::Null);
            }
        }
        values.insert("filed_at".to_string(), TypedValue::Timestamp(filed_at_unix_secs));
        // generation: shadow writes land tagged with shadow_gen, serving writes with serving_gen.
        values.insert("generation".to_string(), TypedValue::Int(write_gen));

        let row_store = self.storage.row_store();
        row_store
            .upsert(
                "vectors",
                values,
                &[
                    "item_id".to_string(),
                    "vector_index".to_string(),
                    "model_id".to_string(),
                    // Conflict columns widened to include generation (v6 UNIQUE constraint):
                    // a shadow row and a serving row for the same item coexist with different
                    // generation values. Without generation in the conflict set, the shadow
                    // write would clobber the serving row.
                    "generation".to_string(),
                ],
            )
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        // Shadow writes bypass ALL resident structures. The serving generation's
        // resident arrays remain coherent; shadow rows are not surfaced until publish.
        if is_shadow_write {
            // Record telemetry but skip resident-array mutation.
            report!({
                use std::time::{SystemTime, UNIX_EPOCH};
                let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
                let ts = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs_f64())
                    .unwrap_or(0.0);
                let mut tags = std::collections::HashMap::new();
                tags.insert("kit".to_string(), "SynapseKit".to_string());
                tags.insert("model_id".to_string(), model_id.to_string());
                tags.insert("shadow".to_string(), "true".to_string());
                StatSample::metric("synapsekit.index.insert_latency_ms".to_string(), elapsed_ms, tags, ts)
            });
            return Ok(());
        }

        // Mirror binary payloads into the resident hot-path array.
        // Non-binary lanes remain table-only (I-7 absolute: Hamming is
        // integer-only and only applies to the binary lane).
        if payload.kind == VectorKind::Binary {
            let key = VectorRecordKey::new(
                item_id.to_string(),
                vector_index,
                model_id.to_string(),
                model_version.to_string(),
            );

            let mut state = self.state.lock().map_err(|_| {
                SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
            })?;

            // Ensure both indexes are coherent before mutating.
            self.ensure_index_built_locked(&mut state)?;

            // Detect replacement (same key already live) before mutating.
            // BruteForce array is the authoritative slot source.
            let is_replacement = {
                let arr = state.brute_force_index.array();
                arr.keys.iter().enumerate().any(|(i, k)| {
                    !arr.is_tombstoned(i) && *k == key
                })
            };

            if let Some(ref mut store) = state.array_store {
                // Sidecar path (write-behind): tombstone any prior slot for
                // this key in memory, append the new slot in memory, mark the
                // sidecar dirty — NO whole-sidecar rewrite per write (TASK #24).
                // Both indexes are updated INCREMENTALLY (MIH add is O(m); the
                // brute-force add appends one slot) so there is no per-write
                // full-index rebuild either. The sidecar is persisted at the
                // next quiesce point via `flush()`; crash safety is preserved
                // by the table-rebuild path (the `vectors` table is durable).
                let mut single = std::collections::HashSet::new();
                single.insert(key.clone());
                store.tombstone_deferred(&single);
                store.append_deferred(key.clone(), payload.bytes.clone())?;
                state.brute_force_index.add(key.clone(), payload.clone())?;
                state.mih_index.add(key, payload.clone())?;
            } else {
                // Memory-only path: add to both indexes (upsert semantics).
                state.brute_force_index.add(key.clone(), payload.clone())?;
                state.mih_index.add(key, payload.clone())?;
            }

            if !is_replacement {
                state.live_binary_count = state.live_binary_count.saturating_add(1);
            }
            Self::select_index(&mut state);
        } else if payload.kind == VectorKind::Float32 {
            // Mirror float32 payloads into the Lane D float index for THIS
            // modelID so find_nearest_float sees this write without a full table
            // rescan. Only when this model's float index is already built (its
            // presence in `float_indices` is the built flag) — otherwise the
            // table write is authoritative and the row is picked up when
            // find_nearest_float lazily builds this model's index on first use.
            let mut state = self.state.lock().map_err(|_| {
                SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
            })?;
            if let Some(model_index) = state.float_indices.get_mut(model_id) {
                let key = VectorRecordKey::new(
                    item_id.to_string(),
                    vector_index,
                    model_id.to_string(),
                    model_version.to_string(),
                );
                // The upsert above may have replaced an existing row; tombstone
                // the prior float slot for this key before appending the new
                // one, mirroring the table's ON CONFLICT UPDATE so a stale
                // float vector cannot survive in the scan.
                model_index.remove(&key)?;
                model_index.add(key, payload.clone())?;
                // Increment live count (counts replacements as +1; slight
                // overcount is acceptable — threshold is 5,000 and HNSW
                // activation is idempotent). Mirrors Swift liveFloatCounts update.
                *state.live_float_counts.entry(model_id.to_string()).or_insert(0) += 1;
                // Mirror into the HNSW index if it is already active for this model,
                // and mark the partition dirty so flush() persists the change.
                // Incremental inserts keep ARRIVAL order (SPEC 1.10.0): only
                // bulk rebuilds (rebuild_hnsw_index, compact) apply the
                // content-stable (vec_hash, key) build order, so cross-run
                // graph identity is guaranteed for bulk-built graphs only;
                // the next THETA rebuild converges an incrementally-grown graph.
                if let Some(hnsw_idx) = state.hnsw_indices.get_mut(model_id) {
                    if let Ok(floats) = payload.as_f32_vec() {
                        hnsw_idx.insert(item_id.to_string(), model_id.to_string(), floats);
                        state.hnsw_graph_dirty.insert(model_id.to_string());
                    }
                }
            }
        }

        let model_id_owned = model_id.to_string();
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "SynapseKit".to_string());
            tags.insert("model_id".to_string(), model_id_owned.clone());
            StatSample::metric(
                "synapsekit.index.insert_latency_ms".to_string(),
                elapsed_ms,
                tags,
                ts,
            )
        });

        Ok(())
    }

    /// Bulk-upsert N typed payloads in one call — the import/migration path.
    ///
    /// The amortised counterpart to `add_payload` for import, migration, and
    /// any caller that has many vectors ready at once (TASK #24):
    ///
    ///   • Each row is upserted to the `vectors` table (durable source of
    ///     truth — O(N) table writes, unavoidable and not the disease).
    ///   • Binary lane: prior slots for replaced keys are tombstoned in ONE
    ///     pass, all new slots appended in ONE pass, the sidecar written ONCE
    ///     (via `append_batch`), and both indexes rebuilt ONCE from the final
    ///     array — not per row. So a batch of N binary vectors costs O(1)
    ///     sidecar writes and O(1) index builds.
    ///   • Float32 rows invalidate the Lane D index once for a lazy rebuild.
    ///
    /// The memory-only (no-sidecar) path builds the combined array once and
    /// calls `build` once, so it is bounded too — no per-row array clone.
    ///
    /// Search output is identical to inserting the same rows one-by-one (the
    /// (distance ASC, vec_hash ASC, item_id ASC) total order is applied at query time).
    pub fn add_payloads(&self, batch: &[VectorPayloadInput]) -> Result<(), SynapseKitError> {
        if batch.is_empty() {
            return Ok(());
        }

        // PRECONDITION GUARD: reject any int8 payload in the batch fail-closed.
        // The quantization policy has not been ratified; a batch containing even
        // one int8 payload must be rejected entirely — no partial writes. The
        // first offending item is reported. See SYNAPSEKIT_SPEC §I-4a.
        if let Some(bad) = batch.iter().find(|i| i.payload.kind == VectorKind::Int8) {
            return Err(SynapseKitError::Int8QuantizationPolicyUndefined(format!(
                "int8 writes are rejected: quantization policy is unspecified. \
                 Offending item: {}. \
                 Use Float32 or the Binary Engram lane. See SYNAPSEKIT_SPEC §I-4a.",
                bad.item_id
            )));
        }

        let start = std::time::Instant::now();

        // Shadow-swap partitioning: read all models' shadow state once before
        // iterating the batch (one lock, no I/O inside the lock).
        // Inputs whose model has an active 'building' shadow land tagged with
        // shadow_gen and are collected separately — they bypass resident structures.
        let (shadow_gens, shadow_states) = {
            let state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            (state.shadow_generations.clone(), state.shadow_states.clone())
        };

        // 1. Upsert every row to the table (durable source of truth). Callers that
        //    write in bulk (the reindex re-embed) wrap this in an OUTER transaction
        //    so the whole batch commits with a single fsync instead of one per row;
        //    add_payloads itself does NOT open a transaction, because the ingest
        //    drain already calls it inside its own open transaction and a nested
        //    BEGIN is an error ("transaction within a transaction").
        let row_store = self.storage.row_store();
        let mut shadow_payload_deltas: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
        let mut shadow_item_ids: std::collections::HashSet<(String, u32, String)> = std::collections::HashSet::new();
        for input in batch {
            // Determine write generation per input (each model_id may have
            // a different shadow state — e.g. model A in shadow, model B not).
            let (write_gen, is_shadow) = {
                let serving_gen = {
                    let state = self.state.lock()
                        .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
                    state.serving_generations.get(&input.model_id).copied().unwrap_or(0)
                };
                if let Some(&sg) = shadow_gens.get(&input.model_id) {
                    if shadow_states.get(&input.model_id).map(|s| s.as_str()) == Some("building") {
                        *shadow_payload_deltas.entry(input.model_id.clone()).or_insert(0)
                            += input.payload.bytes.len() as i64;
                        (sg, true)
                    } else {
                        (serving_gen, false)
                    }
                } else {
                    (serving_gen, false)
                }
            };
            if is_shadow {
                shadow_item_ids.insert((input.item_id.clone(), input.vector_index, input.model_id.clone()));
            }

            let mut values = BTreeMap::new();
            values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
            values.insert("item_id".to_string(), TypedValue::Text(input.item_id.clone()));
            values.insert("vector_index".to_string(), TypedValue::Int(input.vector_index as i64));
            values.insert("model_id".to_string(), TypedValue::Text(input.model_id.clone()));
            values.insert("model_version".to_string(), TypedValue::Text(input.model_version.clone()));
            values.insert("kind".to_string(), TypedValue::Int(input.payload.kind.raw()));
            values.insert("dim".to_string(), TypedValue::Int(input.payload.dim as i64));
            values.insert("payload".to_string(), TypedValue::Blob(input.payload.bytes.clone()));
            match input.payload.scale {
                Some(s) => { values.insert("scale".to_string(), TypedValue::Float(s as f64)); }
                None => { values.insert("scale".to_string(), TypedValue::Null); }
            }
            values.insert("filed_at".to_string(), TypedValue::Timestamp(input.filed_at_unix_secs));
            // generation: shadow writes land tagged with shadow_gen, serving writes with serving_gen.
            values.insert("generation".to_string(), TypedValue::Int(write_gen));
            row_store
                .upsert(
                    "vectors",
                    values,
                    &[
                        "item_id".to_string(),
                        "vector_index".to_string(),
                        "model_id".to_string(),
                        // Conflict columns widened to include generation (v6 UNIQUE constraint).
                        "generation".to_string(),
                    ],
                )
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        }

        // Accumulate shadow payload bytes in state (for Gate 9 instrumentation).
        if !shadow_payload_deltas.is_empty() {
            if let Ok(mut state) = self.state.lock() {
                for (model_id, delta) in shadow_payload_deltas {
                    *state.shadow_payload_bytes.entry(model_id).or_insert(0) += delta;
                }
            }
        }

        // Filter the batch to serving inputs only — shadow inputs bypass resident structures.
        let serving_binary_records: Vec<(VectorRecordKey, Vec<u8>)> = batch
            .iter()
            .filter(|i| {
                i.payload.kind == VectorKind::Binary
                    && !shadow_item_ids.contains(&(i.item_id.clone(), i.vector_index, i.model_id.clone()))
            })
            .map(|i| {
                (
                    VectorRecordKey::new(
                        i.item_id.clone(),
                        i.vector_index,
                        i.model_id.clone(),
                        i.model_version.clone(),
                    ),
                    i.payload.bytes.clone(),
                )
            })
            .collect();

        // 2. Mirror binary rows into the resident array + both indexes in one
        //    amortised pass. Shadow inputs were filtered out above (they bypass
        //    all resident structures until publish_shadow_generation promotes them).
        let binary_records = serving_binary_records;

        // Collect the distinct modelIDs that have a float row in the batch so
        // each affected model's Lane D index can be invalidated below (per-model
        // index, mission 6a-iii-core).
        let float_model_ids: std::collections::HashSet<String> = batch
            .iter()
            .filter(|i| i.payload.kind == VectorKind::Float32)
            .map(|i| i.model_id.clone())
            .collect();

        {
            let mut state = self.state.lock().map_err(|_| {
                SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
            })?;

            if !binary_records.is_empty() {
                self.ensure_index_built_locked(&mut state)?;

                if state.deferred_index_active {
                    // Deferred path (bulk write): DEFER the index rebuild to
                    // publish_resident_index(). Replacement detection uses the
                    // incrementally-maintained live-key set, so the whole window
                    // stays O(batch) per call (no per-call snapshot scan).
                    let mut live = state.deferred_live_keys.take().unwrap_or_default();
                    let mut seen_in_batch = std::collections::HashSet::new();
                    let mut new_key_count: u32 = 0;
                    let mut replaced = std::collections::HashSet::new();
                    for (k, _) in &binary_records {
                        let pos = VectorExactKey::new(
                            k.item_id.clone(),
                            k.vector_index,
                            k.model_id.clone(),
                        );
                        if let Some(existing) = live.get(&pos) {
                            // The durable UNIQUE key excludes model_version.
                            // Replace every resident full key at this position.
                            replaced.extend(existing.iter().cloned());
                        } else if !seen_in_batch.contains(&pos) {
                            new_key_count += 1;
                        }
                        seen_in_batch.insert(pos.clone());
                        live.insert(pos, std::iter::once(k.clone()).collect());
                    }
                    if state.array_store.is_some() {
                        // Sidecar present: stage into the resident array store now.
                        let store = state.array_store.as_mut().unwrap();
                        store.tombstone_deferred(&replaced);
                        store.append_batch(&binary_records)?;
                    }
                    // Keep the compact delta in both modes. Small publications
                    // update the resident indexes directly; large publications
                    // materialize the sidecar/current snapshot once.
                    state
                        .deferred_pending_records
                        .extend(binary_records.iter().cloned());
                    state.deferred_replaced_keys.extend(replaced);
                    state.deferred_live_keys = Some(live);
                    state.live_binary_count =
                        state.live_binary_count.saturating_add(new_key_count);
                    state.deferred_index_dirty = true;
                    // Back-pressure: if the memory-only deferred buffer exceeds
                    // DEFERRED_PENDING_LIMIT, flush it now. This bounds peak
                    // memory use to ~limit × record_size while keeping the deferred
                    // window open (mode stays active). The sidecar path is excluded
                    // because sidecar writes are already bounded per append.
                    // Mirrors Swift `VectorStore._flushDeferredPending()` call site.
                    if state.array_store.is_none()
                        && state.deferred_pending_records.len() > state.deferred_pending_limit
                    {
                        Self::flush_deferred_pending(&mut state)?;
                    }
                    // Indexes intentionally NOT rebuilt and select_index NOT
                    // called: publish_resident_index() does both once at burst end.
                } else {
                    // Immediate path (default — single captures and every direct
                    // caller): rebuild both indexes once from the final snapshot.
                    //
                    // Live keys currently in the array (for replacement detection).
                    let live_keys: std::collections::HashSet<VectorRecordKey> = {
                        let arr = state.brute_force_index.array();
                        (0..arr.count)
                            .filter(|&i| !arr.is_tombstoned(i))
                            .map(|i| arr.keys[i].clone())
                            .collect()
                    };

                    // Count genuinely new keys (not live, and not repeated earlier
                    // in this batch) so the live count only grows by new records.
                    let mut seen_in_batch = std::collections::HashSet::new();
                    let mut new_key_count: u32 = 0;
                    for (k, _) in &binary_records {
                        let is_new = !live_keys.contains(k) && !seen_in_batch.contains(k);
                        if is_new {
                            new_key_count += 1;
                        }
                        seen_in_batch.insert(k.clone());
                    }

                    if state.array_store.is_some() {
                        // Tombstone replaced keys in one pass, append the whole
                        // batch in one pass, write the sidecar once.
                        let replaced: std::collections::HashSet<VectorRecordKey> = binary_records
                            .iter()
                            .map(|(k, _)| k.clone())
                            .filter(|k| live_keys.contains(k))
                            .collect();
                        let store = state.array_store.as_mut().unwrap();
                        store.tombstone_deferred(&replaced);
                        store.append_batch(&binary_records)?;
                        let snap = store.snapshot();
                        let (payloads, keys) = Self::array_to_payloads_keys(&snap);
                        state.brute_force_index.build(&payloads, &keys)?;
                        state.mih_index.build(&payloads, &keys)?;
                    } else {
                        // Memory-only: merge the batch into the current snapshot in
                        // one pass, then build both indexes once.
                        let merged = Self::merge_batch_into_snapshot(
                            state.brute_force_index.array(),
                            &binary_records,
                        );
                        let (payloads, keys) = Self::array_to_payloads_keys(&merged);
                        state.brute_force_index.build(&payloads, &keys)?;
                        state.mih_index.build(&payloads, &keys)?;
                    }

                    state.live_binary_count =
                        state.live_binary_count.saturating_add(new_key_count);
                    Self::select_index(&mut state);
                }
            }

            // 3. Float lane: invalidate the Lane D index for every modelID that
            //    has a float row in the batch so the next find_nearest_float
            //    rebuilds that model's index once from the table (cheaper than N
            //    float adds). Dropping the map entry is the invalidation; other
            //    models' indices are untouched. HNSW and live counts are
            //    invalidated alongside FloatBruteForce — the batch may have
            //    changed the vector geometry enough to warrant a fresh graph.
            for model_id in &float_model_ids {
                state.float_indices.remove(model_id);
                state.hnsw_indices.remove(model_id);
                state.live_float_counts.remove(model_id);
                // Dirty-flag hygiene (VH-01): see delete_and_tombstone — a
                // dropped graph's dirty flag would make flush() delete the
                // still-serviceable persisted rows.
                state.hnsw_graph_dirty.remove(model_id);
            }
        }

        let batch_size = batch.len();
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "SynapseKit".to_string());
            tags.insert("batch_size".to_string(), batch_size.to_string());
            StatSample::metric(
                "synapsekit.index.batch_insert_latency_ms".to_string(),
                elapsed_ms,
                tags,
                ts,
            )
        });

        Ok(())
    }

    /// Enter deferred-index mode for a burst of `add_payloads` writes.
    ///
    /// While active, each `add_payloads` appends to the durable table and the
    /// resident array but defers the MIH + brute-force index rebuild;
    /// `publish_resident_index` rebuilds once at the end. The corpus ingest drain
    /// wraps a drain burst in begin/publish so a bulk import pays ONE index
    /// rebuild instead of one per write (O(N) vs O(N²)). Idempotent. Works with
    /// OR without a sidecar: without one (the current CorpusKit/serve resident
    /// array is memory-only), deferred records accumulate in
    /// `deferred_pending_records` and the single rebuild at publish merges them.
    /// Mirrors Swift `VectorStore.beginDeferredIndex()`.
    pub fn begin_deferred_index(&self) -> Result<(), SynapseKitError> {
        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        if state.deferred_index_active {
            return Ok(());
        }
        self.ensure_index_built_locked(&mut state)?;
        // Seed live keys from the currently-published snapshot so replacement
        // detection across the window is O(batch), not O(N), per call.
        let keys: std::collections::HashMap<
            VectorExactKey,
            std::collections::HashSet<VectorRecordKey>,
        > = {
            let arr = state.brute_force_index.array();
            let mut grouped = std::collections::HashMap::new();
            for i in (0..arr.count).filter(|&i| !arr.is_tombstoned(i)) {
                let key = arr.keys[i].clone();
                let pos = VectorExactKey::new(
                    key.item_id.clone(),
                    key.vector_index,
                    key.model_id.clone(),
                );
                grouped
                    .entry(pos)
                    .or_insert_with(std::collections::HashSet::new)
                    .insert(key);
            }
            grouped
        };
        state.deferred_live_keys = Some(keys);
        state.deferred_pending_records.clear();
        state.deferred_replaced_keys.clear();
        state.deferred_index_dirty = false;
        state.deferred_index_active = true;
        Ok(())
    }

    /// Rebuild the resident MIH + brute-force index once from the final resident
    /// array snapshot, ending deferred-index mode. A no-op rebuild (but still
    /// clears the mode) when nothing was deferred since the last publish. Called
    /// by the corpus ingest drain when a burst drains to empty and by
    /// `await_ingest_drain`. Mirrors Swift `VectorStore.publishResidentIndex()`.
    pub fn publish_resident_index(&self) -> Result<(), SynapseKitError> {
        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        let was_dirty = state.deferred_index_dirty;
        state.deferred_index_active = false;
        state.deferred_index_dirty = false;
        state.deferred_live_keys = None;
        let pending = std::mem::take(&mut state.deferred_pending_records);
        let replaced = std::mem::take(&mut state.deferred_replaced_keys);
        if !was_dirty {
            return Ok(());
        }
        let delta = Self::dedup_last_wins(pending);
        if delta.len() <= INCREMENTAL_PUBLISH_LIMIT
            && state.incremental_publication_count < INCREMENTAL_COMPACTION_INTERVAL
        {
            for key in &replaced {
                state.brute_force_index.remove(key)?;
                state.mih_index.remove(key)?;
            }
            for (key, bytes) in delta {
                let payload = VectorPayload {
                    kind: VectorKind::Binary,
                    dim: 256,
                    bytes,
                    scale: None,
                };
                state.brute_force_index.add(key.clone(), payload.clone())?;
                state.mih_index.add(key, payload)?;
            }
            state.incremental_publication_count += 1;
            Self::select_index(&mut state);
            return Ok(());
        }
        let snap = if state.array_store.is_some() {
            // Sidecar path: the records were staged into the array store.
            state.array_store.as_ref().unwrap().snapshot()
        } else {
            // Memory-only: merge every accumulated record into the pre-burst
            // snapshot in ONE pass. Dedup last-wins so a key re-ingested within
            // the window keeps its latest bytes (merge_batch_into_snapshot appends
            // every record, so a duplicate key must not produce two live slots).
            let cur = state.brute_force_index.array().clone();
            Self::merge_batch_into_snapshot(&cur, &delta)
        };
        let (payloads, keys) = Self::array_to_payloads_keys(&snap);
        state.brute_force_index.build(&payloads, &keys)?;
        state.mih_index.build(&payloads, &keys)?;
        // Recompute the live count authoritatively from the final snapshot so any
        // incremental drift over the window is corrected.
        let live = (0..snap.count).filter(|&i| !snap.is_tombstoned(i)).count() as u32;
        state.live_binary_count = live;
        state.incremental_publication_count = 0;
        Self::select_index(&mut state);
        Ok(())
    }

    /// Publish any in-flight deferred-index burst before a mutate-against-index
    /// operation (delete) so the resident index reflects every appended vector
    /// before we tombstone against it. No-op when no burst is dirty. Mirrors the
    /// Swift `if deferredIndexDirty { try await publishResidentIndex() }` guard.
    fn publish_if_deferred_dirty(&self) -> Result<(), SynapseKitError> {
        let dirty = {
            let state = self.state.lock().map_err(|_| {
                SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
            })?;
            state.deferred_index_dirty
        };
        if dirty {
            self.publish_resident_index()?;
        }
        Ok(())
    }

    /// Flush any pending write-behind sidecar mutation to disk.
    ///
    /// The single `add_payload` binary path is write-behind (TASK #24): it
    /// mutates the in-memory resident array and marks the sidecar dirty
    /// without writing. Callers persist by calling `flush()` at a quiesce
    /// point. No-op when there is no sidecar or nothing is dirty. Crash safety
    /// does not depend on flush: the `vectors` table is the durable source and
    /// the sidecar is rebuilt on the next open if it is stale.
    pub fn flush(&self) -> Result<(), SynapseKitError> {
        // Persist encode-path dirty HNSW partitions before flushing the binary sidecar.
        // Drain the dirty set with the lock held, then release it before I/O so we
        // do not hold the mutex across SQLite writes.
        let dirty: std::collections::HashSet<String> = {
            let mut state = self.state.lock().map_err(|_| {
                SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
            })?;
            std::mem::take(&mut state.hnsw_graph_dirty)
        };
        for model_id in &dirty {
            self.persist_hnsw_graph(model_id)?;
        }

        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        if let Some(ref mut store) = state.array_store {
            store.flush()?;
        }
        Ok(())
    }

    /// Collapse deferred records by the durable logical UNIQUE position, keeping
    /// only the final revision in a burst. Model version is excluded so a version
    /// bump cannot leave both old and new resident slots searchable.
    fn dedup_last_wins(
        records: Vec<(VectorRecordKey, Vec<u8>)>,
    ) -> Vec<(VectorRecordKey, Vec<u8>)> {
        if records.is_empty() {
            return records;
        }
        let mut last_index: std::collections::HashMap<VectorExactKey, usize> =
            std::collections::HashMap::with_capacity(records.len());
        for (i, (k, _)) in records.iter().enumerate() {
            last_index.insert(
                VectorExactKey::new(k.item_id.clone(), k.vector_index, k.model_id.clone()),
                i,
            );
        }
        // Collect the indices to keep (last occurrence per logical key), in order.
        let keep: Vec<bool> = records
            .iter()
            .enumerate()
            .map(|(i, (k, _))| {
                let pos =
                    VectorExactKey::new(k.item_id.clone(), k.vector_index, k.model_id.clone());
                last_index.get(&pos) == Some(&i)
            })
            .collect();
        records
            .into_iter()
            .zip(keep)
            .filter_map(|(rec, k)| if k { Some(rec) } else { None })
            .collect()
    }

    /// Intermediate flush for the memory-only deferred pending buffer.
    ///
    /// Called when `deferred_pending_records.len() > DEFERRED_PENDING_LIMIT`
    /// and no sidecar is present. Merges the current pending records into the
    /// resident index in one rebuild pass, then clears the buffer and reseeds
    /// `deferred_live_keys` from the new snapshot so replacement detection
    /// remains correct for subsequent writes.
    ///
    /// Keeps `deferred_index_active = true` and `deferred_index_dirty = true` —
    /// the deferred window is NOT ended; callers observe no change in mode.
    ///
    /// Mirrors Swift `VectorStore._flushDeferredPending()`.
    fn flush_deferred_pending(state: &mut HotState) -> Result<(), SynapseKitError> {
        if state.deferred_pending_records.is_empty() {
            return Ok(());
        }
        let pending = std::mem::take(&mut state.deferred_pending_records);
        let cur = state.brute_force_index.array().clone();
        let merged = Self::merge_batch_into_snapshot(&cur, &Self::dedup_last_wins(pending));
        let (payloads, keys) = Self::array_to_payloads_keys(&merged);
        state.brute_force_index.build(&payloads, &keys)?;
        state.mih_index.build(&payloads, &keys)?;
        // Recompute live count and live key set authoritatively from the
        // merged snapshot so incremental drift is corrected before the next
        // batch arrives.
        let mut live_count: u32 = 0;
        let mut live_keys: std::collections::HashMap<
            VectorExactKey,
            std::collections::HashSet<VectorRecordKey>,
        > = std::collections::HashMap::new();
        for i in 0..merged.count {
            if !merged.is_tombstoned(i) {
                live_count += 1;
                let key = merged.keys[i].clone();
                let pos = VectorExactKey::new(
                    key.item_id.clone(),
                    key.vector_index,
                    key.model_id.clone(),
                );
                live_keys.entry(pos).or_default().insert(key);
            }
        }
        state.live_binary_count = live_count;
        // Replace the deferred live key set so the next batch's replacement
        // detection is based on what is actually in the rebuilt snapshot.
        state.deferred_live_keys = Some(live_keys);
        state.deferred_replaced_keys.clear();
        state.incremental_publication_count = 0;
        // deferred_index_active and deferred_index_dirty intentionally stay true.
        Ok(())
    }

    /// Merge a batch of (key, bytes) records into a snapshot in one pass.
    ///
    /// Used by the memory-only `add_payloads` path. Replaced keys (present in
    /// the snapshot, live) are tombstoned in place; the new slots are appended
    /// after the existing storage. Produces a single array the indexes build
    /// from once — no per-row clone.
    fn merge_batch_into_snapshot(
        snapshot: &crate::engine::resident::ResidentVectorArray,
        records: &[(VectorRecordKey, Vec<u8>)],
    ) -> crate::engine::resident::ResidentVectorArray {
        use crate::engine::resident::ResidentVectorArray;
        let replaced: std::collections::HashSet<&VectorRecordKey> =
            records.iter().map(|(k, _)| k).collect();
        let mut new_tombstones = snapshot.tombstones.clone();
        for slot_idx in 0..snapshot.count {
            if replaced.contains(&snapshot.keys[slot_idx]) {
                let w = slot_idx / 64;
                let b = slot_idx % 64;
                while new_tombstones.len() <= w {
                    new_tombstones.push(0);
                }
                new_tombstones[w] |= 1u64 << b;
            }
        }

        let mut new_storage = snapshot.storage.clone();
        new_storage.reserve(records.len() * snapshot.stride);
        let mut new_keys = snapshot.keys.clone();
        new_keys.reserve(records.len());
        for (k, bytes) in records {
            new_storage.extend_from_slice(bytes);
            new_keys.push(k.clone());
        }

        let new_count = new_keys.len();
        let words_needed = (new_count + 63) / 64;
        while new_tombstones.len() < words_needed {
            new_tombstones.push(0);
        }
        let new_partitions = ResidentArrayStore::build_partitions(&new_keys, &new_tombstones);
        ResidentVectorArray {
            kind: snapshot.kind,
            stride: snapshot.stride,
            count: new_count,
            storage: new_storage,
            keys: new_keys,
            model_partitions: new_partitions,
            tombstones: new_tombstones,
        }
    }

    /// Number of on-disk sidecar writes performed by the resident store.
    ///
    /// Test instrumentation for the import-scale regression test. Returns 0
    /// when there is no sidecar (memory-only store).
    pub fn sidecar_write_count(&self) -> usize {
        let state = self.state.lock().unwrap();
        state
            .array_store
            .as_ref()
            .map(|s| s.sidecar_write_count())
            .unwrap_or(0)
    }

    /// Fetch the Engram stored under `(item_id, 0, model_id)`.
    pub fn get_vector(
        &self,
        item_id: &str,
        model_id: &str,
    ) -> Result<Option<Engram>, SynapseKitError> {
        match self.get_payload(item_id, 0, model_id)? {
            None => Ok(None),
            Some(payload) => {
                let engram = payload.as_engram()?;
                Ok(Some(engram))
            }
        }
    }

    /// Fetch the typed payload stored under `(item_id, vector_index, model_id)`.
    pub fn get_payload(
        &self,
        item_id: &str,
        vector_index: u32,
        model_id: &str,
    ) -> Result<Option<VectorPayload>, SynapseKitError> {
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new("vectors", "item_id"),
                TypedValue::Text(item_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "vector_index"),
                TypedValue::Int(vector_index as i64),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
        ]);
        let rows = self
            .storage
            .row_store()
            .query("vectors", Some(&predicate), &[], Some(1), None)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        match rows.first() {
            None => Ok(None),
            Some(row) => decode_payload(row).map(Some),
        }
    }

    /// Return every row for `item_id`, ordered by `filed_at` ASC.
    pub fn vectors_for_item(
        &self,
        item_id: &str,
    ) -> Result<Vec<StoredVector>, SynapseKitError> {
        let predicate = StoragePredicate::Eq(
            Column::new("vectors", "item_id"),
            TypedValue::Text(item_id.to_string()),
        );
        let order = vec![OrderClause::new(
            Column::new("vectors", "filed_at"),
            OrderDirection::Ascending,
        )];
        let rows = self
            .storage
            .row_store()
            .query("vectors", Some(&predicate), &order, None, None)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let mut out = Vec::new();
        for row in rows {
            if let Some(sv) = decode_stored_vector(&row)? {
                out.push(sv);
            }
        }
        Ok(out)
    }

    // -----------------------------------------------------------------------
    // Search — resident hot-path (no per-query table fetch)
    // -----------------------------------------------------------------------

    /// k-nearest-neighbours by Hamming distance, using the resident
    /// packed array — no per-query SQLite fetch.
    ///
    /// On the first call, `ensure_index_built` populates `BruteForceIndex`
    /// from the .vec sidecar (one OS read, amortised) or from a single
    /// full-table read (amortised: paid once per process lifetime). Subsequent
    /// calls scan the in-memory packed array — O(N × stride) bytes walked,
    /// not O(N) SQLite row fetches + per-row decode.
    ///
    /// All Hamming arithmetic routes through BruteForceIndex →
    /// EngramLib → SubstrateKernel (I-7 absolute, arch spec §3.4).
    ///
    /// Returns up to `k` matches sorted by (distance ASC, vec_hash ASC, item_id ASC)
    /// — the universal tie-break rule (retrieval algorithms reference §0.3).
    ///
    /// Telemetry: emits `synapsekit.search.latency_ms` and
    /// `synapsekit.search.result_count` when monitoring is enabled.
    pub fn find_nearest(
        &self,
        probe: &Engram,
        model_id: &str,
        k: usize,
    ) -> Result<Vec<VectorMatch>, SynapseKitError> {
        self.find_nearest_with_metric(probe, model_id, k, DenseMetric::HAMMING)
    }

    /// `find_nearest` with an explicit binary metric (W2.5 M1). Jaccard
    /// always serves from the brute-force engine — MIH's band structure is
    /// Hamming-specific. Twin of Swift `findNearest(probe:modelID:limit:metric:)`.
    pub fn find_nearest_with_metric(
        &self,
        probe: &Engram,
        model_id: &str,
        k: usize,
        metric: DenseMetric,
    ) -> Result<Vec<VectorMatch>, SynapseKitError> {
        if k == 0 {
            return Ok(Vec::new());
        }
        let start = std::time::Instant::now();

        // Populate the resident index on first call (amortised, not per-query).
        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        self.ensure_index_built_locked(&mut state)?;

        // Convert Engram probe to the typed payload BruteForceIndex expects.
        let probe_payload = VectorPayload::from_engram(probe);

        // Restrict the scan to this model's partition (O(log m)).
        let filter = MetadataFilter {
            model_id: Some(model_id.to_string()),
            model_version: None,
        };

        // Delegate all Hamming arithmetic to the active index (I-7).
        // Both indexes are EXACT and produce bit-identical results.
        let hits = if state.is_mih_active && metric != DenseMetric::JACCARD {
            state.mih_index.search(&probe_payload, metric, k, Some(&filter))?
        } else {
            state.brute_force_index.search(&probe_payload, metric, k, Some(&filter))?
        };

        // Map DenseHit → VectorMatch. BruteForceIndex already enforces
        // (distance ASC, vec_hash ASC, item_id ASC) per the oracle contract (SPEC 1.9.0).
        // Rows in the resident binary index are built from serving-generation rows
        // only; generation is the model's serving generation (absent row = 0).
        let serving_gen_for_binary = state.serving_generations.get(model_id).copied().unwrap_or(0);
        let result: Vec<VectorMatch> = hits
            .into_iter()
            .map(|h| {
                // Jaccard (W2.5 M1): raw_distance is an f32 bit pattern —
                // map onto the 0..=256 integer scale (Hamming's range) so
                // shared consumers keep working, and carry the exact
                // similarity in `score`. Twin of Swift.
                if let Some(jd) = h.jaccard_distance() {
                    VectorMatch {
                        item_id: h.key.item_id.clone(),
                        distance: (jd * 256.0).round() as i32,
                        model_id: model_id.to_string(),
                        generation: serving_gen_for_binary,
                        score: Some(1.0 - jd),
                    }
                } else {
                    VectorMatch {
                        item_id: h.key.item_id.clone(),
                        distance: h.raw_distance,
                        model_id: model_id.to_string(),
                        generation: serving_gen_for_binary,
                        score: None,
                    }
                }
            })
            .collect();

        let result_count = result.len();
        let model_id_owned = model_id.to_string();
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "SynapseKit".to_string());
            tags.insert("model_id".to_string(), model_id_owned.clone());
            StatSample::metric("synapsekit.search.latency_ms".to_string(), elapsed_ms, tags.clone(), ts)
        });
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "SynapseKit".to_string());
            tags.insert("model_id".to_string(), model_id_owned.clone());
            StatSample::metric("synapsekit.search.result_count".to_string(), result_count as f64, tags, ts)
        });

        Ok(result)
    }

    /// k-nearest-neighbours over the float32 (Lane D) vectors by cosine
    /// distance, using the in-house `FloatBruteForceIndex` — the production
    /// exact path (Bob's storage amendment 2026-06-12: no external engine).
    ///
    /// On the first call (or after a process restart) the float index is
    /// built once from the float32 rows in the `vectors` table; subsequent
    /// calls scan the resident float array. The scan restricts to
    /// `model_id`'s partition (spec I-4: cross-model comparisons forbidden).
    ///
    /// Cosine is the float lane's ranking metric: it is scale-invariant, so
    /// the answer-vs-question-echo case the SimHash-Hamming lane could not
    /// separate ranks correctly here. Results are sorted by (cosine distance
    /// ASC, item_id ASC) — the universal tie-break (retrieval algorithms ref
    /// §0.3), applied inside `FloatBruteForceIndex`.
    ///
    /// Determinism: the float lane is reproducible-within-config, NOT
    /// four-way bit-identical (arch spec §6). Rank order is stable across
    /// languages on shared fixtures; raw cosine values are not asserted
    /// bit-identical.
    ///
    /// Returns up to `k` matches, nearest first. Empty if `k` is 0, the
    /// probe is empty, or no float rows exist.
    /// k-NEAREST neighbours over the float32 (Lane D) vectors by cosine.
    ///
    /// Dispatch by `residencyHint`:
    /// - `RamResident` (default): builds a `FloatBruteForceIndex` per modelID on
    ///   first call, subject to the estate's `ResidentIndexBudget`. If admitted,
    ///   the index is cached in heap and served from there. If the budget ceiling
    ///   would be exceeded, the build is refused and the query falls back to
    ///   `float_scan_from_table` — correct results, no allocation of the refused
    ///   index. Also falls back when the index is absent (evicted or no float rows).
    /// - `DiskBacked`: always scans the `vectors` table directly via
    ///   `float_scan_from_table`. The OS page cache manages RAM residency.
    ///
    /// Both paths compute the same cosine distance formula; results are
    /// reproducible-within-config but not four-way bit-identical (arch spec §6).
    /// k-NEAREST neighbours over the float32 (Lane D) vectors.
    ///
    /// Both ramResident (FloatBruteForceIndex / HNSW) and diskBacked (table scan)
    /// paths respect the `metric` parameter. Callers that do not need metric
    /// selection may pass `FloatMetric::Cosine` to preserve the historical behaviour.
    pub fn find_nearest_float(
        &self,
        probe: &[f32],
        model_id: &str,
        k: usize,
        metric: FloatMetric,
    ) -> Result<Vec<VectorMatch>, SynapseKitError> {
        if k == 0 || probe.is_empty() {
            return Ok(Vec::new());
        }
        if self.storage.configuration().residency_hint == ResidencyHint::RamResident {
            let mut state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            let built = self.ensure_float_index_built_locked(&mut state, model_id)?;
            if built {
                let live_count = state.live_float_counts.get(model_id).copied().unwrap_or(0);
                if live_count >= self.hnsw_threshold {
                    // HNSW path: route through the approximate NN index for this model.
                    // Farthest queries always use FloatBruteForceIndex (anti-similarity
                    // with HNSW requires a full-graph scan and provides no speed benefit).
                    if !state.hnsw_indices.contains_key(model_id) {
                        // Load from the hnsw_graph table (written by THETA rebuild, BETA
                        // compact, and encode-path inserts via flush). If no rows exist,
                        // load_hnsw_graph_if_present is a no-op and the exact scan below
                        // handles the query — no inline build on the query path (defect fix).
                        // Drop the mutex before I/O to avoid holding it across table access.
                        drop(state);
                        self.load_hnsw_graph_if_present(model_id)?;
                        state = self.state.lock()
                            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
                    }
                    // §4 generation-identity check: a stale graph (gen ≠ serving)
                    // is treated as absent — fall through to load/exact scan.
                    // Gate 5 probe: record which generation answered this query.
                    let hnsw_result = if let Some(hnsw_index) = state.hnsw_indices.get(model_id) {
                        let serving_gen = state.serving_generations.get(model_id).copied().unwrap_or(0);
                        if hnsw_index.generation() == serving_gen {
                            let result = hnsw_index.search(probe, model_id, k);
                            Some((serving_gen, result))
                        } else {
                            // Generation mismatch — stale graph, fall through.
                            None
                        }
                    } else {
                        None
                    };
                    if let Some((serving_gen, result)) = hnsw_result {
                        state.last_served_graph_gen.insert(model_id.to_string(), serving_gen);
                        return result;
                    }
                    // No graph on disk yet: fall through to exact scan (defect D — fallback).
                }
                // Below threshold: use FloatBruteForceIndex (exact scan).
                let probe_payload = VectorPayload::from_f32(probe);
                // Unwrap is safe: ensure_float_index_built_locked guarantees
                // the entry is present when it returns true.
                let index = state.float_indices.get(model_id)
                    .expect("ensure_float_index_built_locked returned true but entry is absent");
                let serving_gen = state.serving_generations.get(model_id).copied().unwrap_or(0);
                // Wrap FloatMetric in DenseMetric::Float for the index API.
                let hits = index.search(&probe_payload, DenseMetric::Float(metric), k, None)?;
                // Record which generation answered — Gate 3/5 probe. The float
                // brute-force path is used when live_count < hnsw_threshold; the
                // gate asserts the generation matches regardless of which path fired.
                state.last_served_graph_gen.insert(model_id.to_string(), serving_gen);
                return Ok(hits.into_iter().map(|h| VectorMatch {
                    item_id: h.key.item_id,
                    distance: h.raw_distance,
                    model_id: model_id.to_string(),
                    // Float index built from serving-generation rows only.
                    generation: serving_gen,
                score: None,
                }).collect());
            }
            // ensure_float_index_built_locked returned false. That means EITHER no
            // float rows exist for this model OR admission was refused because the
            // projected resident set would exceed the estate's ceiling. Both fall
            // through to the table scan below, which answers the query correctly.
        }
        // Reached for a diskBacked estate, for a ramResident estate with no rows yet,
        // and for a ramResident estate whose float index was refused admission.
        // Table scan filters to serving generation, so generation = serving gen (0 pre-swap).
        let scored = self.float_scan_from_table(probe, model_id, k, true, metric)?;
        Ok(scored.into_iter().map(|(dist, item_id)| VectorMatch {
            item_id,
            distance: (dist * 10_000.0).round() as i32,
            model_id: model_id.to_string(),
            generation: 0, // Table scan serves generation 0 until serving-gen filter is wired.
            score: None,
        }).collect())
    }

    /// k-FARTHEST neighbours over the float32 (Lane D) vectors by cosine —
    /// the most DISSIMILAR rows first (anti-similarity retrieval, mission
    /// 6b-modifiers-antisim). Parallel to Swift `VectorStore.findFarthestFloat`.
    ///
    /// Identical to `find_nearest_float` in every respect — same lazy per-model
    /// index build, same `ResidentIndexBudget` admission gate, same model_id
    /// partition scope (spec I-4), same cosine metric, same VectorMatch
    /// quantisation — EXCEPT it ranks by FARTHEST (bottom-K by cosine similarity
    /// = largest cosine distance first) via `FloatBruteForceIndex::search_farthest`.
    /// It is NOT a negated nearest-list: the farthest rows are not in the nearest
    /// top-K, so the index orders by the opposite end. No new distance math.
    ///
    /// When the admission gate refuses the index build the query falls back to
    /// `float_scan_from_table`, returning correct results without allocating the
    /// refused index.
    ///
    /// Determinism: like `find_nearest_float`, the float lane is reproducible-
    /// within-config, NOT four-way bit-identical (arch spec §6).
    ///
    /// Returns up to `k` matches, FARTHEST (most dissimilar) first. Empty if
    /// `k` is 0, the probe is empty, or no float rows exist for the model.
    /// k-FARTHEST neighbours over the float32 (Lane D) vectors.
    ///
    /// Identical to `find_nearest_float` except it ranks FARTHEST first (most
    /// dissimilar). HNSW is not used regardless of threshold — HNSW is a
    /// nearest-only structure; anti-similarity requires a full scan.
    ///
    /// The `metric` parameter selects the distance function. Pass
    /// `FloatMetric::Cosine` for the historical behaviour.
    pub fn find_farthest_float(
        &self,
        probe: &[f32],
        model_id: &str,
        k: usize,
        metric: FloatMetric,
    ) -> Result<Vec<VectorMatch>, SynapseKitError> {
        if k == 0 || probe.is_empty() {
            return Ok(Vec::new());
        }
        if self.storage.configuration().residency_hint == ResidencyHint::RamResident {
            let mut state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            let built = self.ensure_float_index_built_locked(&mut state, model_id)?;
            if built {
                let probe_payload = VectorPayload::from_f32(probe);
                let index = state.float_indices.get(model_id)
                    .expect("ensure_float_index_built_locked returned true but entry is absent");
                let serving_gen = state.serving_generations.get(model_id).copied().unwrap_or(0);
                // Wrap FloatMetric in DenseMetric::Float for the index API.
                let hits = index.search_farthest(&probe_payload, DenseMetric::Float(metric), k, None)?;
                return Ok(hits.into_iter().map(|h| VectorMatch {
                    item_id: h.key.item_id,
                    distance: h.raw_distance,
                    model_id: model_id.to_string(),
                    // Float index built from serving-generation rows only.
                    generation: serving_gen,
                score: None,
                }).collect());
            }
            // ensure_float_index_built_locked returned false. That means EITHER no
            // float rows exist for this model OR admission was refused because the
            // projected resident set would exceed the estate's ceiling. Both fall
            // through to the table scan below, which answers the query correctly.
        }
        // Reached for a diskBacked estate, for a ramResident estate with no rows yet,
        // and for a ramResident estate whose float index was refused admission.
        let scored = self.float_scan_from_table(probe, model_id, k, false, metric)?;
        Ok(scored.into_iter().map(|(dist, item_id)| VectorMatch {
            item_id,
            distance: (dist * 10_000.0).round() as i32,
            model_id: model_id.to_string(),
            generation: 0, // Table scan serves generation 0 until serving-gen filter is wired.
            score: None,
        }).collect())
    }

    /// Coarse keyword pre-filter: returns distinct item IDs whose
    /// `item_id` contains the query as a substring. Full BM25 lives in
    /// CorpusKit.
    pub fn find_by_keyword(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<String>, SynapseKitError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        // Empty query would become LIKE '%%', scanning every row — fail-safe: return
        // empty immediately. No caller depends on empty-query-returns-all (confirmed).
        if query.is_empty() {
            return Ok(Vec::new());
        }
        // `limit` counts DISTINCT item IDs — the contract every caller
        // means ("memories probed"): the contradiction hunter's probe_limit
        // and VectorSimilaritySignal's sample size both document items, not
        // rows. The vectors table holds MANY rows per item (binary + float
        // per model slot; the five-model production ensemble ⇒ ~10 rows per
        // chunk), so applying the limit to ROWS silently shrank the probe
        // window ~10×: on a 109k-chunk estate, probe_limit 10000 reached
        // ~1,000 items — a static window newly-captured memories' UUIDs
        // almost never sort into, leaving the hunter blind on large
        // estates. Page the row query until `limit` distinct IDs are
        // collected or the table is exhausted. Mirrors the Swift twin.
        let pattern = format!("%{}%", query);
        // AND with serving-generation predicate so shadow rows are never visible
        // to keyword search before publish. serving_gen_predicate() handles the
        // multi-model case and defaults to generation=0 when no swap has occurred.
        let serving_pred = self.serving_gen_predicate()?;
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Like(Column::new("vectors", "item_id"), pattern),
            serving_pred,
        ]);
        let order = vec![OrderClause::new(
            Column::new("vectors", "item_id"),
            OrderDirection::Ascending,
        )];
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::new();
        const PAGE_SIZE: usize = 8192;
        let mut offset = 0usize;
        while out.len() < limit {
            // Project only `item_id` — payload blobs are irrelevant here and
            // can be enormous on rich estates. `query_projected` pushes a
            // narrow SELECT item_id ... down into SQLite so the payload is
            // never loaded off disk. Non-SQLite backends fall back to the full
            // read (still correct; a superset of the requested columns).
            let rows = self
                .storage
                .row_store()
                .query_projected(
                    "vectors",
                    &["item_id"],
                    Some(&predicate),
                    &order,
                    Some(PAGE_SIZE),
                    Some(offset),
                )
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            let page_len = rows.len();
            for row in rows {
                if let Some(TypedValue::Text(item_id)) = row.get("item_id") {
                    if seen.insert(item_id.clone()) && out.len() < limit {
                        out.push(item_id.clone());
                    }
                }
            }
            if page_len < PAGE_SIZE {
                break; // table exhausted
            }
            offset += PAGE_SIZE;
        }

        let count = out.len();
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "SynapseKit".to_string());
            StatSample::metric(
                "synapsekit.search.keyword_result_count".to_string(),
                count as f64,
                tags,
                ts,
            )
        });

        Ok(out)
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// Destroy all vector rows. Called by `EstateCoordinator::destroy`.
    ///
    /// Deletes every row from the `vectors` table AND resets the resident
    /// array to empty. After this call the backing storage still exists
    /// (schema intact) but contains no vector data.
    pub fn destroy_all_vectors(&self) -> Result<(), SynapseKitError> {
        self.storage
            .row_store()
            .delete("vectors", &StoragePredicate::IsTrue)
            .map_err(|e| SynapseKitError::StoreUnavailable(format!("destroy_all_vectors failed: {e}")))?;
        // HNSW lane teardown (VH-01 Finding A): a full destroy must leave no
        // graph behind, in memory OR on disk. The persisted hnsw_graph rows
        // describe vectors that no longer exist; delete them here (I/O outside
        // the state lock, matching the vectors delete above).
        self.storage
            .row_store()
            .delete("hnsw_graph", &StoragePredicate::IsTrue)
            .map_err(|e| SynapseKitError::StoreUnavailable(format!("destroy_all_vectors failed: {e}")))?;

        // Reset both indexes and live count to empty. The table is now empty.
        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        if let Some(ref mut store) = state.array_store {
            store.rebuild_from(&[])?;
            let snap = store.snapshot();
            let (payloads, keys) = Self::array_to_payloads_keys(&snap);
            state.brute_force_index.build(&payloads, &keys)?;
            state.mih_index.build(&payloads, &keys)?;
        } else {
            state.brute_force_index.build(&[], &[])?;
            state.mih_index.build(&[], &[])?;
        }
        state.live_binary_count = 0;
        state.is_mih_active = false;
        state.index_built = true;
        // Abandon any in-flight deferred-index window — the store is now empty.
        state.deferred_index_active = false;
        state.deferred_index_dirty = false;
        state.deferred_live_keys = None;
        state.deferred_pending_records.clear();
        state.deferred_replaced_keys.clear();
        state.incremental_publication_count = 0;
        // Reset the Lane D float indices — every float row was just deleted, so
        // every per-modelID resident float array must be cleared. Dropping all
        // map entries clears every model's index; each rebuilds lazily (and
        // empty) on the next find_nearest_float for that model. HNSW graphs and
        // live counts are cleared alongside: no vectors remain, so no graphs remain.
        state.float_indices.clear();
        state.hnsw_indices.clear();
        state.live_float_counts.clear();
        // Dirty flags go with the graphs: every partition's persisted rows
        // were just deleted, so there is nothing left for flush() to persist.
        state.hnsw_graph_dirty.clear();
        Ok(())
    }

    /// Remove the row for `(item_id, 0, model_id)`. Idempotent.
    /// The most recently filed DISTINCT item IDs, newest first.
    ///
    /// The probe-enumeration surface for sweep consumers (the contradiction
    /// hunter, VectorSimilaritySignal): a bounded sweep should examine the
    /// NEWEST content first — new memories are the ones that need
    /// contradiction/association screening against the existing estate, and
    /// a recency window composes with the hunter's `filed_after` watermark.
    /// `find_by_keyword`'s ascending-item_id order is a UUID lottery: on a
    /// 109k-chunk estate a 10k-item window is static and newly-captured
    /// chunks' content-addressed UUIDs almost never sort into it, so
    /// bounded sweeps never saw new content.
    ///
    /// `limit` counts DISTINCT item IDs (rows are many-per-item); pages the
    /// row query until `limit` IDs are collected or the table is exhausted.
    /// Ties on filed_at break by item_id ascending for determinism.
    /// Mirrors the Swift twin `recentItemIDs(limit:)`.
    pub fn recent_item_ids(&self, limit: usize) -> Result<Vec<String>, SynapseKitError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let order = vec![
            OrderClause::new(Column::new("vectors", "filed_at"), OrderDirection::Descending),
            OrderClause::new(Column::new("vectors", "item_id"), OrderDirection::Ascending),
        ];
        // Filter to serving-generation rows only — shadow rows are never visible
        // to recent_item_ids before publish. Defaults to generation=0 when no swap
        // has occurred (all rows have DEFAULT 0).
        let serving_pred = self.serving_gen_predicate()?;
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::new();
        const PAGE_SIZE: usize = 8192;
        let mut offset = 0usize;
        while out.len() < limit {
            // Project only (item_id, filed_at) — those are the only columns
            // this function reads. Combined with idx_vectors_filed_at_item
            // (v4, columns: [filed_at, item_id]) this enables a covering index
            // scan: SQLite satisfies the ORDER BY from the index and never
            // touches the main table rows (no payload blobs loaded). Non-SQLite
            // backends fall back to the full-row read (correct: superset of
            // requested columns).
            let rows = self
                .storage
                .row_store()
                .query_projected(
                    "vectors",
                    &["item_id", "filed_at"],
                    Some(&serving_pred),
                    &order,
                    Some(PAGE_SIZE),
                    Some(offset),
                )
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            let page_len = rows.len();
            for row in rows {
                if let Some(TypedValue::Text(item_id)) = row.get("item_id") {
                    if seen.insert(item_id.clone()) && out.len() < limit {
                        out.push(item_id.clone());
                    }
                }
            }
            if page_len < PAGE_SIZE {
                break; // table exhausted
            }
            offset += PAGE_SIZE;
        }
        Ok(out)
    }

    pub fn delete_vector(
        &self,
        item_id: &str,
        model_id: &str,
    ) -> Result<(), SynapseKitError> {
        self.publish_if_deferred_dirty()?;
        self.delete_and_tombstone(item_id, 0, model_id)
    }

    /// Remove the row for `(item_id, vector_index, model_id)`. Idempotent.
    ///
    /// Publishes any in-flight deferred-index burst before tombstoning the
    /// resident slot — identical contract to `delete_vector` and
    /// `delete_all_vectors`. Without the publish step, a deferred slot added
    /// during a bulk-write window survives the delete in the resident index
    /// even after the row is removed from the table (secfix/ws2-coredelete:
    /// hard-delete destruction contract requires no in-memory copy survives).
    pub fn delete_payload(
        &self,
        item_id: &str,
        vector_index: u32,
        model_id: &str,
    ) -> Result<(), SynapseKitError> {
        self.publish_if_deferred_dirty()?;
        self.delete_and_tombstone(item_id, vector_index, model_id)
    }

    /// Delete all rows for `(item_id, model_id)` regardless of vector_index.
    pub fn delete_all_vectors(
        &self,
        item_id: &str,
        model_id: &str,
    ) -> Result<(), SynapseKitError> {
        // Publish any in-flight deferred burst first (see delete_vector).
        self.publish_if_deferred_dirty()?;
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new("vectors", "item_id"),
                TypedValue::Text(item_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
        ]);
        self.storage
            .row_store()
            .delete("vectors", &predicate)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        // The deletion may have removed float32 rows for this modelID.
        // Invalidate THIS model's Lane D index so the next find_nearest_float
        // rebuilds from the table (the authoritative source). The delete carries
        // no kind, so a lazy rebuild is the correct coherence path for the float
        // lane. Other models' indices are untouched. HNSW and live count are
        // invalidated alongside so the next query builds a fresh graph.
        state.float_indices.remove(model_id);
        state.hnsw_indices.remove(model_id);
        state.live_float_counts.remove(model_id);
        // Dirty-flag hygiene (VH-01): the graph was just dropped, so clear the
        // partition's dirty flag too — otherwise the next flush() sees a dirty
        // partition with no in-memory graph and deletes the still-serviceable
        // persisted hnsw_graph rows (reload re-derives bytes from the vectors
        // table, so those rows can never resurface deleted content).
        state.hnsw_graph_dirty.remove(model_id);
        if !state.index_built {
            return Ok(()); // table delete already applied; array not yet built
        }

        // Collect keys matching (item_id, model_id) from the BruteForce array
        // (the authoritative slot source), then remove from both indexes.
        let snap = state.brute_force_index.array().clone();
        let mut removed_count: u32 = 0;
        for slot_idx in 0..snap.count {
            if snap.is_tombstoned(slot_idx) {
                continue;
            }
            let k = &snap.keys[slot_idx];
            if k.item_id == item_id && k.model_id == model_id {
                let owned_key = k.clone();
                if let Some(ref mut store) = state.array_store {
                    store.tombstone(&owned_key)?;
                }
                state.brute_force_index.remove(&owned_key)?;
                state.mih_index.remove(&owned_key)?;
                removed_count += 1;
            }
        }
        state.live_binary_count = state.live_binary_count.saturating_sub(removed_count);
        Self::select_index(&mut state);
        Ok(())
    }

    /// Replace a model's ENTIRE vector set — the BATCH reindex re-embed path,
    /// deliberately SEPARATE from the shared 1-off `add_payloads` /
    /// `delete_all_vectors` (which live captures use unchanged). Those mutate the
    /// resident index PER key, and every `BruteForceIndex::remove`/`add` rebuilds
    /// all partitions (O(n)), so doing tens of thousands of them — a full re-embed —
    /// is O(n²). This path instead writes the durable table in ONE transaction
    /// (bulk delete + plain insert → a single fsync, no per-row existence SELECT)
    /// and rebuilds the resident binary index ONCE from the table (O(n)). Mirrors
    /// Swift `VectorStore.replaceModelVectors`.
    pub fn replace_model_vectors(
        &self,
        model_id: &str,
        batch: &[VectorPayloadInput],
    ) -> Result<(), SynapseKitError> {
        // Reject int8 fail-closed — same precondition as add_payloads.
        if let Some(bad) = batch.iter().find(|i| i.payload.kind == VectorKind::Int8) {
            return Err(SynapseKitError::Int8QuantizationPolicyUndefined(format!(
                "int8 writes are rejected: quantization policy is unspecified. \
                 Offending item: {}. See SYNAPSEKIT_SPEC §I-4a.",
                bad.item_id
            )));
        }
        // Flush any in-flight deferred burst so the table is the single source of
        // truth before the resident index is rebuilt from it below.
        self.publish_if_deferred_dirty()?;

        // 1. Durable table writes in ONE transaction: bulk-delete every row for the
        //    model, then plain-INSERT the fresh batch. One BEGIN/COMMIT → a single
        //    fsync for the whole re-embed (per-row autocommit was minutes of
        //    per-row durability syncs). INSERT (not upsert) skips the per-row
        //    existence SELECT — after the bulk delete nothing conflicts. NO
        //    resident-index mutation here; it is rebuilt once in step 2.
        let row_store = self.storage.row_store();
        row_store
            .begin_transaction()
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let db_result = (|| -> Result<(), SynapseKitError> {
            row_store
                .delete(
                    "vectors",
                    &StoragePredicate::Eq(
                        Column::new("vectors", "model_id"),
                        TypedValue::Text(model_id.to_string()),
                    ),
                )
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            for input in batch {
                let mut values = BTreeMap::new();
                values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
                values.insert("item_id".to_string(), TypedValue::Text(input.item_id.clone()));
                values.insert("vector_index".to_string(), TypedValue::Int(input.vector_index as i64));
                values.insert("model_id".to_string(), TypedValue::Text(input.model_id.clone()));
                values.insert("model_version".to_string(), TypedValue::Text(input.model_version.clone()));
                values.insert("kind".to_string(), TypedValue::Int(input.payload.kind.raw()));
                values.insert("dim".to_string(), TypedValue::Int(input.payload.dim as i64));
                values.insert("payload".to_string(), TypedValue::Blob(input.payload.bytes.clone()));
                match input.payload.scale {
                    Some(s) => { values.insert("scale".to_string(), TypedValue::Float(s as f64)); }
                    None => { values.insert("scale".to_string(), TypedValue::Null); }
                }
                values.insert("filed_at".to_string(), TypedValue::Timestamp(input.filed_at_unix_secs));
                row_store
                    .insert("vectors", values)
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            }
            Ok(())
        })();
        match db_result {
            Ok(()) => row_store
                .commit_transaction()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?,
            Err(e) => {
                let _ = row_store.rollback_transaction();
                return Err(e);
            }
        }

        // 2. Rebuild the resident binary index ONCE from the durable table (O(n)),
        //    and drop this model's Lane D float index (and HNSW graph) so they
        //    lazily rebuild on the next find_nearest_float call.
        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        state.float_indices.remove(model_id);
        state.hnsw_indices.remove(model_id);
        state.live_float_counts.remove(model_id);
        // Dirty-flag hygiene (VH-01): the graph was just dropped, so clear the
        // partition's dirty flag too — otherwise the next flush() sees a dirty
        // partition with no in-memory graph and deletes the still-serviceable
        // persisted hnsw_graph rows (reload re-derives bytes from the vectors
        // table, so those rows can never resurface deleted content).
        state.hnsw_graph_dirty.remove(model_id);
        self.rebuild_binary_index_from_table_locked(&mut state)?;
        Ok(())
    }

    /// Rebuild the resident BINARY index (sidecar array + BruteForce + MIH) from
    /// the durable `vectors` table in ONE pass. Used only by the batch re-embed
    /// path. Unlike `ensure_index_built_locked` it does NOT trust the sidecar
    /// live-count (a re-embed replaces every vector with the SAME row count, so a
    /// count check would wrongly keep the stale sidecar) — it always reads the
    /// table. Must be called with the state mutex held.
    ///
    /// Scoped to serving-generation rows only: a rebuild while a shadow build is
    /// in flight must not load shadow-generation vectors into the resident index
    /// (cf7de0c fix, B4). The generation predicate is derived from the durable
    /// vector_generations registry (not the in-memory cache) so a fresh reopen
    /// with an empty cache still uses the correct serving generation.
    fn rebuild_binary_index_from_table_locked(
        &self,
        state: &mut HotState,
    ) -> Result<(), SynapseKitError> {
        let reg_rows = self
            .storage
            .row_store()
            .query("vector_generations", Some(&StoragePredicate::IsTrue), &[], None, None)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let gen_pred = Self::serving_gen_predicate_core(&reg_rows, state);
        let records = self.fetch_all_binary_records(&gen_pred)?;
        state.live_binary_count = records.len() as u32;
        if let Some(ref mut store) = state.array_store {
            store.rebuild_from(&records)?;
            let rebuilt = store.snapshot();
            let (payloads, keys) = Self::array_to_payloads_keys(&rebuilt);
            state.brute_force_index.build(&payloads, &keys)?;
            state.mih_index.build(&payloads, &keys)?;
        } else {
            let payloads: Vec<VectorPayload> = records
                .iter()
                .map(|(_, bytes)| VectorPayload {
                    kind: VectorKind::Binary,
                    dim: 256,
                    bytes: bytes.clone(),
                    scale: None,
                })
                .collect();
            let keys: Vec<VectorRecordKey> = records.into_iter().map(|(k, _)| k).collect();
            state.brute_force_index.build(&payloads, &keys)?;
            state.mih_index.build(&payloads, &keys)?;
        }
        state.index_built = true;
        Self::select_index(state);
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Exact-key batch mutation (GLK shared-content 1.1, P0)
    // -----------------------------------------------------------------------

    /// Delete exactly the rows named by `keys` — the scoped batch-delete the
    /// shared-content migration uses instead of model-wide teardowns.
    /// Mirrors Swift `VectorStore.deleteVectors(keys:)`.
    ///
    /// Each key addresses one logical row position (item_id, vector_index,
    /// model_id); every model_version stored at that position is removed.
    /// Rows NOT named are never touched: one model partition may contain
    /// retained/shared keys and removed keys side by side without collateral
    /// mutation.
    pub fn delete_vectors(&self, keys: &[VectorExactKey]) -> Result<(), SynapseKitError> {
        if keys.is_empty() {
            return Ok(());
        }
        // Publish any in-flight deferred burst first so the resident index
        // reflects every appended vector before we tombstone against it.
        self.publish_if_deferred_dirty()?;

        let key_set: std::collections::BTreeSet<&VectorExactKey> = keys.iter().collect();
        let row_store = self.storage.row_store();
        row_store
            .begin_transaction()
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let db_result = (|| -> Result<(), SynapseKitError> {
            for key in &key_set {
                let predicate = StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new("vectors", "item_id"),
                        TypedValue::Text(key.item_id.clone()),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "vector_index"),
                        TypedValue::Int(key.vector_index as i64),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "model_id"),
                        TypedValue::Text(key.model_id.clone()),
                    ),
                ]);
                row_store
                    .delete("vectors", &predicate)
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            }
            Ok(())
        })();
        match db_result {
            Ok(()) => row_store
                .commit_transaction()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?,
            Err(e) => {
                let _ = row_store.rollback_transaction();
                return Err(e);
            }
        }

        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        // Lane D coherence: drop ONLY the touched models' cached float
        // indices (and HNSW graphs); other models' indices are untouched.
        for model_id in key_set
            .iter()
            .map(|k| k.model_id.as_str())
            .collect::<std::collections::BTreeSet<_>>()
        {
            state.float_indices.remove(model_id);
            state.hnsw_indices.remove(model_id);
            state.live_float_counts.remove(model_id);
            // Dirty-flag hygiene (VH-01): see delete_and_tombstone.
            state.hnsw_graph_dirty.remove(model_id);
        }
        if !state.index_built {
            return Ok(()); // table delete already applied; array not yet built
        }

        // Binary-lane coherence: tombstone every resident slot whose logical
        // position matches a deleted key, in ONE snapshot pass.
        let snap = state.brute_force_index.array().clone();
        let mut removed_count: u32 = 0;
        for slot_idx in 0..snap.count {
            if snap.is_tombstoned(slot_idx) {
                continue;
            }
            let k = &snap.keys[slot_idx];
            let pos = VectorExactKey {
                item_id: k.item_id.clone(),
                vector_index: k.vector_index,
                model_id: k.model_id.clone(),
            };
            if key_set.contains(&pos) {
                let owned_key = k.clone();
                if let Some(ref mut store) = state.array_store {
                    store.tombstone(&owned_key)?;
                }
                state.brute_force_index.remove(&owned_key)?;
                state.mih_index.remove(&owned_key)?;
                removed_count += 1;
            }
        }
        if removed_count > 0 {
            state.live_binary_count = state.live_binary_count.saturating_sub(removed_count);
            Self::select_index(&mut state);
        }
        Ok(())
    }

    /// Reconcile ONE model's partition against an explicit expected key set —
    /// the scoped rebuild the shared-content migration uses instead of
    /// `replace_model_vectors` against shared storage. Mirrors Swift
    /// `VectorStore.reconcileModelVectors(modelID:expected:)`.
    ///
    /// Every row in `expected` is upserted (exact-key idempotent). Every
    /// existing row of `model_id` whose (item_id, vector_index) is NOT named
    /// in `expected` is deleted. Rows of other models are never read or
    /// touched. Returns `(removed, upserted)` counts.
    pub fn reconcile_model_vectors(
        &self,
        model_id: &str,
        expected: &[VectorPayloadInput],
    ) -> Result<(usize, usize), SynapseKitError> {
        if let Some(bad) = expected.iter().find(|i| i.payload.kind == VectorKind::Int8) {
            return Err(SynapseKitError::Int8QuantizationPolicyUndefined(format!(
                "int8 writes are rejected: quantization policy is unspecified. \
                 reconcile_model_vectors received an int8 payload for item {}",
                bad.item_id
            )));
        }
        if let Some(stray) = expected.iter().find(|i| i.model_id != model_id) {
            return Err(SynapseKitError::InvalidPayload(format!(
                "reconcile_model_vectors(model_id: {model_id}) received an input for \
                 model {} — cross-partition writes are not permitted",
                stray.model_id
            )));
        }
        self.publish_if_deferred_dirty()?;

        // Read serving_gen BEFORE enumerating existing rows so both the
        // enumeration and the delete predicate are scoped to the same generation.
        // This is the B5 fix: without this scope, reconcile_model_vectors could
        // enumerate shadow-generation rows as "existing" and then delete them,
        // silently destroying a shadow build in progress.
        let serving_gen = self.serving_generation(model_id)?;

        // Enumerate only the serving-generation keys for this model.
        // Shadow-generation rows are excluded: they are owned by a concurrent
        // shadow build and must not be treated as stale.
        let row_store = self.storage.row_store();
        let enum_pred = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new("vectors", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "generation"),
                TypedValue::Int(serving_gen),
            ),
        ]);
        let existing_rows = row_store
            .query("vectors", Some(&enum_pred), &[], None, None)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let mut existing_keys: std::collections::BTreeSet<VectorExactKey> =
            std::collections::BTreeSet::new();
        for row in &existing_rows {
            let item_id = match row.get("item_id") {
                Some(TypedValue::Text(t)) => t.clone(),
                _ => continue,
            };
            let vector_index = match row.get("vector_index") {
                Some(TypedValue::Int(i)) => *i as u32,
                _ => continue,
            };
            existing_keys.insert(VectorExactKey {
                item_id,
                vector_index,
                model_id: model_id.to_string(),
            });
        }
        let expected_keys: std::collections::BTreeSet<VectorExactKey> = expected
            .iter()
            .map(|i| VectorExactKey {
                item_id: i.item_id.clone(),
                vector_index: i.vector_index,
                model_id: model_id.to_string(),
            })
            .collect();
        let stale_keys: Vec<&VectorExactKey> =
            existing_keys.difference(&expected_keys).collect();

        // One transaction: delete exactly the stale serving-gen keys, upsert the
        // expected rows. Other models' rows and shadow-gen rows are never touched.
        row_store
            .begin_transaction()
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let db_result = (|| -> Result<(), SynapseKitError> {
            for key in &stale_keys {
                // Delete predicate scoped to the serving generation so we never
                // touch a shadow-generation row even if one shares the same
                // (item_id, vector_index, model_id) key.
                let predicate = StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new("vectors", "item_id"),
                        TypedValue::Text(key.item_id.clone()),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "vector_index"),
                        TypedValue::Int(key.vector_index as i64),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "model_id"),
                        TypedValue::Text(key.model_id.clone()),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "generation"),
                        TypedValue::Int(serving_gen),
                    ),
                ]);
                row_store
                    .delete("vectors", &predicate)
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            }
            // serving_gen is already known (read above, before enumeration).
            for input in expected {
                let mut values = BTreeMap::new();
                values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
                values.insert("item_id".to_string(), TypedValue::Text(input.item_id.clone()));
                values.insert(
                    "vector_index".to_string(),
                    TypedValue::Int(input.vector_index as i64),
                );
                values.insert("model_id".to_string(), TypedValue::Text(input.model_id.clone()));
                values.insert(
                    "model_version".to_string(),
                    TypedValue::Text(input.model_version.clone()),
                );
                values.insert("kind".to_string(), TypedValue::Int(input.payload.kind.raw()));
                values.insert("dim".to_string(), TypedValue::Int(input.payload.dim as i64));
                values.insert(
                    "payload".to_string(),
                    TypedValue::Blob(input.payload.bytes.clone()),
                );
                match input.payload.scale {
                    Some(s) => {
                        values.insert("scale".to_string(), TypedValue::Float(s as f64));
                    }
                    None => {
                        values.insert("scale".to_string(), TypedValue::Null);
                    }
                }
                values.insert(
                    "filed_at".to_string(),
                    TypedValue::Timestamp(input.filed_at_unix_secs),
                );
                // generation: reconcile always targets the serving generation.
                values.insert("generation".to_string(), TypedValue::Int(serving_gen));
                row_store
                    .upsert(
                        "vectors",
                        values,
                        &[
                            "item_id".to_string(),
                            "vector_index".to_string(),
                            "model_id".to_string(),
                            // Conflict columns widened to include generation (v6 UNIQUE constraint).
                            "generation".to_string(),
                        ],
                    )
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            }
            Ok(())
        })();
        match db_result {
            Ok(()) => row_store
                .commit_transaction()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?,
            Err(e) => {
                let _ = row_store.rollback_transaction();
                return Err(e);
            }
        }

        // Coherence: this model's float index (and HNSW graph) lazily rebuild from
        // the table; the resident binary index is rebuilt once from the table.
        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        state.float_indices.remove(model_id);
        state.hnsw_indices.remove(model_id);
        state.live_float_counts.remove(model_id);
        // Dirty-flag hygiene (VH-01): the graph was just dropped, so clear the
        // partition's dirty flag too — otherwise the next flush() sees a dirty
        // partition with no in-memory graph and deletes the still-serviceable
        // persisted hnsw_graph rows (reload re-derives bytes from the vectors
        // table, so those rows can never resurface deleted content).
        state.hnsw_graph_dirty.remove(model_id);
        self.rebuild_binary_index_from_table_locked(&mut state)?;
        Ok((stale_keys.len(), expected.len()))
    }

    // -----------------------------------------------------------------------
    // Private: resident index lifecycle
    // -----------------------------------------------------------------------

    /// Ensure both indexes are populated. Idempotent — no-op once built.
    ///
    /// Must be called with the state mutex already locked.
    ///
    /// After building, `live_binary_count` is set from the loaded array and
    /// `select_index` is called to initialise the threshold routing.
    ///
    /// Build strategy (in priority order):
    ///   1. Sidecar present and its count matches the table binary-row count:
    ///      load from sidecar (one OS read, amortised).
    ///   2. Otherwise: fetch all binary rows once from the table (source of
    ///      truth), build the resident array, rewrite the sidecar if present.
    fn ensure_index_built_locked(
        &self,
        state: &mut HotState,
    ) -> Result<(), SynapseKitError> {
        if state.index_built {
            return Ok(());
        }

        // Build the generation predicate from the durable vector_generations registry.
        // We cannot call serving_gen_predicate() here because it acquires the state
        // mutex, which is already held by our caller (deadlock). Instead we query the
        // registry table directly (no mutex needed) and call serving_gen_predicate_core,
        // which builds the predicate AND refreshes state.serving_generations from the
        // authoritative DB values. This is correct on a fresh reopen where the cache is
        // empty: the durable registry always holds the committed serving generation.
        // Both binary_row_count and fetch_all_binary_records must use the SAME predicate
        // so the sidecar-freshness comparison is consistent.
        let reg_rows = self
            .storage
            .row_store()
            .query("vector_generations", Some(&StoragePredicate::IsTrue), &[], None, None)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let gen_pred = Self::serving_gen_predicate_core(&reg_rows, state);

        if let Some(ref mut store) = state.array_store {
            // Attempt to load from the on-disk sidecar.
            let _ = store.load(); // non-fatal: empty start on failure

            let snap = store.snapshot();
            let table_count = self.binary_row_count(&gen_pred)?;

            // Compare live-vs-live: snap.live_count() is the number of
            // non-tombstoned slots in the sidecar (written to the header
            // at flush time and recomputed here from the bitmap).
            // table_count is the number of live rows in the `vectors` table.
            // They agree iff the sidecar is up-to-date (C5 fix: using
            // snap.count here counts tombstoned slots and spuriously
            // triggers a full rebuild after every delete).
            if snap.live_count() == table_count {
                // Sidecar and table agree on live records — use the sidecar.
                state.live_binary_count = snap.live_count() as u32;
                let (payloads, keys) = Self::array_to_payloads_keys(&snap);
                state.brute_force_index.build(&payloads, &keys)?;
                state.mih_index.build(&payloads, &keys)?;
            } else {
                // Stale sidecar: rebuild from the table (serving generation only).
                state.sidecar_rebuild_count += 1;
                let records = self.fetch_all_binary_records(&gen_pred)?;
                state.live_binary_count = records.len() as u32;
                let store_ref = state.array_store.as_mut().unwrap();
                store_ref.rebuild_from(&records)?;
                let rebuilt = store_ref.snapshot();
                let (payloads, keys) = Self::array_to_payloads_keys(&rebuilt);
                state.brute_force_index.build(&payloads, &keys)?;
                state.mih_index.build(&payloads, &keys)?;
            }
        } else {
            // No sidecar: build the array in memory from the table (serving gen only).
            let records = self.fetch_all_binary_records(&gen_pred)?;
            state.live_binary_count = records.len() as u32;
            let payloads: Vec<VectorPayload> = records
                .iter()
                .map(|(_, bytes)| VectorPayload {
                    kind: VectorKind::Binary,
                    dim: 256,
                    bytes: bytes.clone(),
                    scale: None,
                })
                .collect();
            let keys: Vec<VectorRecordKey> = records.into_iter().map(|(k, _)| k).collect();
            state.brute_force_index.build(&payloads, &keys)?;
            state.mih_index.build(&payloads, &keys)?;
        }

        state.index_built = true;
        Self::select_index(state);
        Ok(())
    }

    /// Ensure the Lane D float index for ONE modelID is populated. Idempotent —
    /// no-op once that model's index is built.
    ///
    /// Must be called with the state mutex already locked. Builds a
    /// `FloatBruteForceIndex` from THIS model's float32 rows only (uniform
    /// stride, so the search dimension guard holds even when the table mixes
    /// models of differing float dimension — mission 6a-iii-core). Returns
    /// `true` when this model now has an index, `false` when the model has no
    /// float rows (no float lane for it; the caller returns no matches). The
    /// map entry's presence is the per-model "built" flag. Unlike the binary
    /// lane there is no sidecar for the float lane yet — the float resident
    /// array is rebuilt from the table on first use.
    /// scan the SQLite `vectors` table directly for float NN
    /// search, computing cosine distance per row. No cached index, no
    /// heap-resident vector array. Returns (distance, item_id) pairs.
    /// Scan the model's float rows and return the `k` best-scoring by cosine
    /// distance — `nearest = true` keeps the SMALLEST distances, `false` the
    /// largest. Maintains a bounded top-k ordered best-first while scanning
    /// (DoS fix): memory is O(k) and cost O(n log k), instead of materializing
    /// and sorting a score entry for every row on every recall — a large
    /// estate could otherwise exhaust CPU/memory from a normal MCP search.
    /// Table-scan float NN search. Dispatches the inline distance computation on
    /// `metric`; all three metrics branch identically to Swift's `_floatScanFromTable`.
    ///
    /// - "cosine": 1 − cos(a,b). Scale-invariant; the historical default.
    /// - "l2": Euclidean distance √Σ(aᵢ−bᵢ)². Magnitude-sensitive.
    /// - "dot": −Σ(aᵢbᵢ). Lower value = higher dot product = "closer".
    ///
    /// The bounded top-k heap is metric-agnostic: all three produce a lower-is-
    /// better distance scalar, so `better` (which picks the smaller distance for
    /// nearest, the larger for farthest) works unchanged.
    fn float_scan_from_table(
        &self,
        probe: &[f32],
        model_id: &str,
        k: usize,
        nearest: bool,
        metric: FloatMetric,
    ) -> Result<Vec<(f32, String)>, SynapseKitError> {
        // Use serving_generation() (registry-aware) so the scan is scoped to
        // the serving generation even on a fresh process reopen where the state
        // cache is empty.
        let serving_gen = self.serving_generation(model_id)?;
        let records = self.fetch_float_records(model_id, serving_gen)?;
        // Bounded top-k, kept ordered best-first (index 0 = best, last = worst).
        let mut top: Vec<(f32, String)> = Vec::with_capacity(k.min(64));
        // `a` is better than `b` when it should rank ahead in the result.
        let better = |a: f32, b: f32| if nearest { a < b } else { a > b };
        for (key, payload) in &records {
            let bytes = &payload.bytes;
            let dim = bytes.len() / 4;
            if dim != probe.len() { continue; }
            // Decode float vector from BLOB bytes (LE f32).
            let mut candidate = Vec::with_capacity(dim);
            for i in 0..dim {
                let off = i * 4;
                let bits = u32::from_le_bytes([
                    bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3],
                ]);
                candidate.push(f32::from_bits(bits));
            }
            // Dispatch on the selected float metric. All three branch inline so
            // the diskBacked table-scan path mirrors FloatBruteForceIndex exactly.
            // Lower value always means "closer" for all three metrics:
            //   cosine: 1−cos(a,b) ∈ [0,2]
            //   l2: √Σ(aᵢ−bᵢ)² ∈ [0,∞)
            //   dot: −Σ(aᵢbᵢ) — negated so largest dot → smallest dist → ranks first
            let dist = match metric {
                FloatMetric::Cosine => {
                    let mut dot: f32 = 0.0;
                    let mut norm_a: f32 = 0.0;
                    let mut norm_b: f32 = 0.0;
                    for j in 0..dim {
                        dot += probe[j] * candidate[j];
                        norm_a += probe[j] * probe[j];
                        norm_b += candidate[j] * candidate[j];
                    }
                    let denom = norm_a.sqrt() * norm_b.sqrt();
                    if denom > 0.0 { 1.0 - (dot / denom).clamp(-1.0, 1.0) } else { 1.0 }
                }
                FloatMetric::L2 => {
                    let mut sum_sq: f32 = 0.0;
                    for j in 0..dim { let d = probe[j] - candidate[j]; sum_sq += d * d; }
                    sum_sq.sqrt()
                }
                FloatMetric::Dot => {
                    let mut dot: f32 = 0.0;
                    for j in 0..dim { dot += probe[j] * candidate[j]; }
                    -dot
                }
            };
            // Bounded insert: skip if worse than the current worst and full.
            if k == 0 {
                continue;
            }
            if top.len() >= k && !better(dist, top[top.len() - 1].0) {
                continue;
            }
            let mut i = top.len();
            while i > 0 && better(dist, top[i - 1].0) {
                i -= 1;
            }
            top.insert(i, (dist, key.item_id.clone()));
            if top.len() > k {
                top.pop();
            }
        }
        Ok(top)
    }

    /// Evict all per-model float-lane indexes from the in-process heap.
    ///
    /// Safe to call at any time. After eviction the next `find_nearest_float`
    /// or `find_farthest_float` call lazily rebuilds from the `vectors` table
    /// (subject to the `ResidentIndexBudget` admission gate) when
    /// `residency_hint == RamResident`, or uses `float_scan_from_table` directly
    /// when `residency_hint == DiskBacked`. Callers that implement their own
    /// memory-pressure management may call this directly.
    ///
    /// # Admission accounting
    ///
    /// `float_index_footprints` is NOT cleared here. The accounting map is
    /// self-reconciling: on the next admission check, entries whose model is no
    /// longer in `float_indices` are dropped before the resident total is summed.
    /// Clearing it here would be redundant and hiding the intent — any stale
    /// entry is harmless because the reconcile pass runs first.
    pub fn evict_float_indices(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.float_indices.clear();
            // Also evict HNSW graphs and live counts: the float lane is fully
            // evicted as a unit. The next find_nearest_float rebuilds from the table.
            state.hnsw_indices.clear();
            state.live_float_counts.clear();
            // float_index_footprints is intentionally NOT cleared: the reconcile
            // step in ensure_float_index_built_locked drops stale entries on the
            // next admission check (float_indices is now empty, so all entries
            // would be stale and will be pruned). No action required here.
        }
    }

    // MARK: - HNSW graph maintenance (dreaming cadence duties)

    /// Clear all HNSW graphs for every modelID partition (ALPHA duty).
    ///
    /// Drops every in-process `HNSWIndex` entry and live count, and deletes all
    /// rows from the `hnsw_graph` table. The next `find_nearest_float` call at/above
    /// `hnsw_threshold` loads the (now-empty) table and falls back to exact scan
    /// until THETA rebuild writes fresh rows. `FloatBruteForceIndex` entries are
    /// RETAINED — farthest queries and below-threshold nearest queries continue
    /// uninterrupted.
    ///
    /// Called by the ALPHA cadence adapter when extreme vocabulary drift renders
    /// the existing graph topology incorrect. THETA rebuild fires shortly after and
    /// repopulates the table.
    pub fn clear_all_hnsw_indices(&self) -> Result<(), SynapseKitError> {
        // Delete all persisted rows outside the mutex (I/O first, then clear in-memory).
        self.storage.row_store()
            .delete("hnsw_graph", &StoragePredicate::IsTrue)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        let mut state = self.state.lock()
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        state.hnsw_indices.clear();
        state.live_float_counts.clear();
        state.hnsw_graph_dirty.clear();
        Ok(())
    }

    /// Rebuild the HNSW graph for one modelID partition from current float records.
    ///
    /// Fetches all float32 rows for `model_id` from the `vectors` table and
    /// re-inserts them into a fresh `HNSWIndex`. Persists the rebuilt graph to
    /// the `hnsw_graph` table so the next process open loads it rather than
    /// falling back to exact scan. Increments `hnsw_build_count` — a LOAD
    /// (via `load_hnsw_graph_if_present`) does NOT increment this counter.
    ///
    /// Called by the THETA cadence adapter after a daily basis retrain, so the
    /// graph topology stays aligned with re-embedded vectors.
    ///
    /// If the table has no float rows for `model_id`, any existing graph entry
    /// is removed and the `hnsw_graph` rows for this partition are deleted.
    pub fn rebuild_hnsw_index(&self, model_id: &str) -> Result<(), SynapseKitError> {
        // Read the serving generation BEFORE fetching float records so the
        // generation filter in fetch_float_records scopes the build correctly.
        // serving_generation() is registry-aware: on a fresh reopen it queries
        // the vector_generations table rather than relying on the empty state cache.
        let serving_gen = self.serving_generation(model_id)?;
        let records = self.fetch_float_records(model_id, serving_gen)?;
        {
            let mut state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            if records.is_empty() {
                state.hnsw_indices.remove(model_id);
                state.live_float_counts.remove(model_id);
                // Delete any stale rows for this partition.
                drop(state);
                self.storage.row_store()
                    .delete("hnsw_graph", &StoragePredicate::Eq(
                        Column::new("hnsw_graph", "model_id"),
                        TypedValue::Text(model_id.to_string()),
                    ))
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
                return Ok(());
            }
            let record_count = records.len() as u32;
            let mut hnsw = HNSWIndex::new_default();
            // Content-stable bulk build order (SPEC 1.10.0): sort rows by
            // (fnv1a64(payload bytes) ASC, key ASC) before insertion so
            // identical content yields an identical graph across independent
            // builds. fetch_float_records sorts by key alone, and keys ride
            // per-run-random item UUIDs — that order is stable within one
            // estate but NOT across provisionings of the same content
            // (REPLAY_DRIFT_RCA). The key remains the final backstop for
            // byte-identical vectors, which are interchangeable for every
            // ordering consumer.
            let mut build_order: Vec<(u64, &(VectorRecordKey, VectorPayload))> = records
                .iter()
                .map(|r| (crate::engine::fnv1a64(&r.1.bytes), r))
                .collect();
            build_order.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1 .0.cmp(&b.1 .0)));
            for (_, (key, payload)) in &build_order {
                if let Ok(floats) = payload.as_f32_vec() {
                    hnsw.insert(key.item_id.clone(), model_id.to_string(), floats);
                }
            }
            // D6 fix: stamp the freshly built graph with the current serving
            // generation BEFORE persisting. serving_gen was read above
            // (registry-aware); the state cache was already populated by
            // serving_generation() so the value is consistent across calls.
            hnsw.set_generation(serving_gen);
            state.hnsw_indices.insert(model_id.to_string(), hnsw);
            state.live_float_counts.insert(model_id.to_string(), record_count);
            *state.hnsw_build_count.entry(model_id.to_string()).or_insert(0) += 1;
        } // Release mutex before I/O.
        self.persist_hnsw_graph(model_id)?;
        Ok(())
    }

    /// Rebuild HNSW graphs for all modelIDs that currently have an active graph (THETA duty).
    ///
    /// Iterates over all active HNSW graph keys and calls `rebuild_hnsw_index` for
    /// each. ModelIDs below the threshold (no entry in `hnsw_indices`) are skipped
    /// — they have no graph to rebuild and will build lazily when they next cross
    /// the threshold. Called by the THETA cadence adapter after a full corpus
    /// basis retrain.
    pub fn rebuild_all_hnsw_indices(&self) -> Result<(), SynapseKitError> {
        // Snapshot the keys before mutation to avoid HashMap-during-iteration.
        let model_ids: Vec<String> = {
            let state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            state.hnsw_indices.keys().cloned().collect()
        };
        for model_id in &model_ids {
            self.rebuild_hnsw_index(model_id)?;
        }
        Ok(())
    }

    /// Compact HNSW tombstones for one modelID partition (BETA duty).
    ///
    /// Calls `HNSWIndex::compact()` which rebuilds the live-node graph discarding
    /// tombstoned entries and dead edges, then persists the compacted graph to
    /// the `hnsw_graph` table. Safe to call when no graph exists for `model_id`
    /// (compact is a no-op; persist writes zero rows then returns).
    pub fn compact_hnsw_tombstones(&self, model_id: &str) -> Result<(), SynapseKitError> {
        {
            let mut state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            if let Some(hnsw_idx) = state.hnsw_indices.get_mut(model_id) {
                hnsw_idx.compact();
            }
        } // Release mutex before I/O.
        self.persist_hnsw_graph(model_id)?;
        Ok(())
    }

    /// Compact HNSW tombstones for all active modelID partitions (BETA duty).
    ///
    /// Iterates over all active HNSW graphs and calls `compact_hnsw_tombstones`
    /// for each. Each partition's compacted graph is persisted to the `hnsw_graph`
    /// table. Called by the BETA cadence adapter.
    pub fn compact_all_hnsw_tombstones(&self) -> Result<(), SynapseKitError> {
        // Snapshot model IDs before iterating to avoid borrow conflicts.
        let model_ids: Vec<String> = {
            match self.state.lock() {
                Ok(state) => state.hnsw_indices.keys().cloned().collect(),
                Err(_) => return Ok(()),
            }
        };
        for model_id in &model_ids {
            self.compact_hnsw_tombstones(model_id)?;
        }
        Ok(())
    }

    // MARK: - HNSW persistence (hnsw_graph table)

    /// Persist the HNSW graph for one modelID partition to the `hnsw_graph` table.
    ///
    /// Serialises the in-memory `HNSWIndex` via `graph_rows()`, then executes a
    /// delete-then-insert transaction for this partition's rows. The delete removes
    /// any previously persisted rows; the insert writes the current compact graph.
    /// If no graph is active for `model_id`, this is a no-op.
    ///
    /// Called by THETA rebuild, BETA compact, and `flush()` for encode-path inserts.
    /// Must NOT be called with the state mutex held (I/O outside the lock).
    fn persist_hnsw_graph(&self, model_id: &str) -> Result<(), SynapseKitError> {
        // 1. Serialise the graph rows with the mutex held; release before I/O.
        let rows: Vec<GraphRow> = {
            let state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            match state.hnsw_indices.get(model_id) {
                Some(hnsw) => hnsw.graph_rows(),
                None => return Ok(()), // nothing to persist
            }
        };

        // 2. Delete existing rows for this partition, then insert the fresh set.
        let row_store = self.storage.row_store();
        row_store.begin_transaction()
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let result: Result<(), SynapseKitError> = (|| {
            row_store.delete(
                "hnsw_graph",
                &StoragePredicate::Eq(
                    Column::new("hnsw_graph", "model_id"),
                    TypedValue::Text(model_id.to_string()),
                ),
            )
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

            for row in &rows {
                let mut values = BTreeMap::new();
                values.insert("model_id".to_string(), TypedValue::Text(model_id.to_string()));
                values.insert("node_idx".to_string(), TypedValue::Int(row.node_idx as i64));
                values.insert("node_id".to_string(), TypedValue::Text(row.node_id.clone()));
                values.insert("layer".to_string(), TypedValue::Int(row.layer as i64));
                values.insert("neighbours".to_string(), TypedValue::Blob(row.neighbours_blob.clone()));
                // generation: emitted from HNSWIndex.graph_rows() as self.generation,
                // which was stamped by set_generation(serving_gen) in rebuild_hnsw_index
                // (D6 fix). Pre-v6 graphs have generation 0.
                values.insert("generation".to_string(), TypedValue::Int(row.generation));
                row_store.insert("hnsw_graph", values)
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            }
            Ok(())
        })();
        match result {
            Ok(()) => row_store.commit_transaction()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string())),
            Err(e) => {
                let _ = row_store.rollback_transaction();
                Err(e)
            }
        }
    }

    /// Query the `hnsw_graph` table for one modelID partition's rows.
    ///
    /// Returns a Vec of `GraphRow` in storage order (no sort guarantee). Returns
    /// an empty Vec if the table has no rows for `model_id`.
    fn query_hnsw_graph_rows(&self, model_id: &str) -> Result<Vec<GraphRow>, SynapseKitError> {
        let rows = self.storage.row_store()
            .query(
                "hnsw_graph",
                Some(&StoragePredicate::Eq(
                    Column::new("hnsw_graph", "model_id"),
                    TypedValue::Text(model_id.to_string()),
                )),
                &[],
                None,
                None,
            )
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        // Persisted hnsw_graph rows are UNTRUSTED input (VH-01 Finding C).
        // Every INTEGER is converted with a checked cast and bounds-tested
        // BEFORE it can size an allocation downstream.
        //
        // One invalid row abandons the WHOLE graph load (VH-01 F3): this
        // mirrors the engine's own policy — `load_from_graph_rows` rejects on
        // the first bad row — so both layers agree. Partial topology from
        // corrupt state is worse than a clean exact-scan fallback until the
        // next THETA rebuild corrects it. Matches Swift twin:
        // `_loadHNSWGraphIfPresent` returns on any invalid row.
        let mut graph_rows = Vec::with_capacity(rows.len());
        for row in rows {
            // node_idx: compact array index — must fit i32 and be ≥ 0.
            // A plain `as i32` would silently wrap out-of-range values.
            let node_idx = match row.get("node_idx") {
                Some(TypedValue::Int(v)) => match i32::try_from(*v) {
                    Ok(v) if v >= 0 => v,
                    _ => return Ok(Vec::new()),
                },
                _ => return Ok(Vec::new()),
            };
            let node_id = match row.get("node_id") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => return Ok(Vec::new()),
            };
            // layer: sizes the per-node layer allocation — must be ≥ 0 and
            // within the level-generation cap. A plain `as usize` would turn
            // a negative i64 into a huge allocation count.
            let layer = match row.get("layer") {
                Some(TypedValue::Int(v)) => match usize::try_from(*v) {
                    Ok(l) if l <= HNSW_MAX_PERSISTED_LAYER => l,
                    _ => return Ok(Vec::new()),
                },
                _ => return Ok(Vec::new()),
            };
            // neighbours: packed LE i32 — must be whole i32s and within the
            // per-layer fan-out cap (layer 0 persists at most M0 neighbours).
            let neighbours_blob = match row.get("neighbours") {
                Some(TypedValue::Blob(b))
                    if b.len() % 4 == 0 && b.len() <= HNSW_M0 * 4 =>
                {
                    b.clone()
                }
                _ => return Ok(Vec::new()),
            };
            // generation column added in schema v6. Pre-v6 rows (or InMemory
            // databases that replayed migrations) will have DEFAULT 0.
            let generation = match row.get("generation") {
                Some(TypedValue::Int(v)) => *v,
                _ => 0,
            };
            graph_rows.push(GraphRow { node_idx, node_id, layer, neighbours_blob, generation });
        }
        Ok(graph_rows)
    }

    /// Load the HNSW graph for one modelID from the `hnsw_graph` table.
    ///
    /// Queries `hnsw_graph` for rows matching `model_id`, builds the
    /// `node_idx → (item_id, bytes)` map from the float records in `vectors`,
    /// reconstructs the `HNSWIndex` via `load_from_graph_rows`, and stores the
    /// result in `hnsw_indices`. Nodes whose float vector is missing from the
    /// `vectors` table (deleted since last persist) are silently excluded —
    /// they cannot surface as search results.
    ///
    /// If no rows exist in the table (graph never built for this partition), this
    /// is a no-op: `hnsw_indices` is not modified, and `find_nearest_float` falls
    /// back to exact scan. Does NOT increment `hnsw_build_count` — a load is not
    /// a rebuild.
    ///
    /// Must NOT be called with the state mutex held (I/O outside the lock).
    fn load_hnsw_graph_if_present(&self, model_id: &str) -> Result<(), SynapseKitError> {
        // 1. Query hnsw_graph rows for this partition.
        let graph_rows = self.query_hnsw_graph_rows(model_id)?;
        if graph_rows.is_empty() {
            return Ok(());
        }

        // 2. Determine serving generation (registry-aware: works on fresh reopen
        //    where the state cache is empty). This is the expected_generation for
        //    both float-record scoping and graph-row filtering.
        let serving_gen = self.serving_generation(model_id)?;

        // 3. Fetch float records for the serving generation only, to build the
        //    node_idx → (item_id, bytes) map.
        let float_records = self.fetch_float_records(model_id, serving_gen)?;
        // Build item_id → bytes lookup from the float lane.
        let mut item_bytes: std::collections::HashMap<String, Vec<u8>> =
            std::collections::HashMap::with_capacity(float_records.len());
        for (key, payload) in &float_records {
            item_bytes.insert(key.item_id.clone(), payload.bytes.clone());
        }

        // Build node_idx → (item_id, bytes) map. Each node_idx maps to the
        // node_id (item_id) in the graph row, looked up against float records.
        // Nodes absent from item_bytes (deleted vectors) are excluded — they are
        // silently skipped by load_from_graph_rows.
        let mut node_bytes: std::collections::HashMap<i32, (String, Vec<u8>)> =
            std::collections::HashMap::new();
        // Track node_idx already seen (graph rows may have multiple layers per node).
        let mut seen: std::collections::HashSet<i32> = std::collections::HashSet::new();
        for row in &graph_rows {
            if !seen.insert(row.node_idx) {
                continue;
            }
            if let Some(bytes) = item_bytes.get(&row.node_id) {
                node_bytes.insert(row.node_idx, (row.node_id.clone(), bytes.clone()));
            }
            // Absent from item_bytes → deleted vector. Not added to node_bytes;
            // load_from_graph_rows allocates a tombstone placeholder.
        }

        // 4. Reconstruct the HNSWIndex from the persisted rows.
        // serving_gen was determined above via serving_generation() (registry-
        // aware), so this is correct even on a fresh process reopen where the
        // state cache is empty.
        let mut hnsw = HNSWIndex::new_default();
        hnsw.load_from_graph_rows(&graph_rows, &node_bytes, model_id, serving_gen);

        if !hnsw.has_graph() {
            // All nodes were deleted: nothing to load.
            return Ok(());
        }

        // 4. Store the loaded graph. Use entry().or_insert so a concurrent load
        // (if two threads raced here) is idempotent.
        let mut state = self.state.lock()
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        state.hnsw_indices.entry(model_id.to_string()).or_insert(hnsw);
        Ok(())
    }

    /// Count persisted rows in the `hnsw_graph` table for one modelID (test helper).
    ///
    /// Exit gate A: assert row count > 0 after rebuild. Not part of the stable
    /// production API — exposed for integration tests in `tests/`.
    pub fn hnsw_graph_row_count(&self, model_id: &str) -> Result<usize, SynapseKitError> {
        let rows = self.query_hnsw_graph_rows(model_id)?;
        Ok(rows.len())
    }

    /// Return the number of times the HNSW graph was rebuilt (not loaded) for
    /// one modelID (test helper).
    ///
    /// Exit gate B: assert hnsw_build_count == 0 after a process-restart open
    /// (load path, not build path). Not part of the stable production API —
    /// exposed for integration tests in `tests/`.
    pub fn hnsw_build_count_for(&self, model_id: &str) -> u32 {
        self.state.lock()
            .map(|s| *s.hnsw_build_count.get(model_id).unwrap_or(&0))
            .unwrap_or(0)
    }

    /// True when an HNSW graph is resident in memory for `model_id`.
    ///
    /// The positive residency probe for the exit gates: build-count
    /// instruments prove no REBUILD happened, but both the loaded-graph path
    /// and the exact-scan fallback leave it at zero — only this probe
    /// distinguishes "served from the loaded graph" from "fallback quietly
    /// covered it". Twin of Swift `hnswIndexResident(for:)`.
    pub fn hnsw_index_resident(&self, model_id: &str) -> bool {
        self.state.lock()
            .map(|s| s.hnsw_indices.contains_key(model_id))
            .unwrap_or(false)
    }

    /// True when a `FloatBruteForceIndex` is resident in memory for `model_id`.
    ///
    /// Used by admission tests to assert whether the float index was cached
    /// or refused. When the admission gate refuses a build the index is not
    /// cached and this probe returns false, confirming the refusal. Absent the
    /// gate, the index would always be resident after the first query on a
    /// non-empty estate. Twin of Swift `floatIndexResident(for:)`.
    pub fn float_index_resident(&self, model_id: &str) -> bool {
        self.state.lock()
            .map(|s| s.float_indices.contains_key(model_id))
            .unwrap_or(false)
    }

    /// Total count of float-index admission refusals since this `VectorStore`
    /// was opened. Incremented once per `ensure_float_index_built_locked` call
    /// that projects a footprint exceeding the ceiling. A refused build falls
    /// back to the table-scan path and returns correct results; refusals are
    /// counted so tests can assert the gate fired. Twin of Swift
    /// `admissionRefusalCount`.
    pub fn admission_refusal_count(&self) -> u64 {
        self.state.lock()
            .map(|s| s.admission_refusal_count)
            .unwrap_or(0)
    }

    /// Build the per-model `FloatBruteForceIndex` if not yet cached, subject to
    /// the estate's `ResidentIndexBudget`.
    ///
    /// Returns `Ok(true)` when the index is (or was already) resident.
    /// Returns `Ok(false)` in two cases:
    ///   1. No float rows exist for `model_id` — nothing to cache.
    ///   2. Admission refused: the projected footprint plus the current resident
    ///      total would exceed the configured ceiling. The query falls back to
    ///      `float_scan_from_table`, which returns correct results without
    ///      allocating the refused index.
    ///
    /// Both callers (`find_nearest_float` and `find_farthest_float`) already
    /// treat `Ok(false)` as "fall through to float_scan_from_table" — no
    /// call-site change is required.
    ///
    /// # Admission gate placement
    ///
    /// The count-and-project check runs BEFORE `fetch_float_records`. Calling
    /// `fetch_float_records` materialises every payload in heap, which is the
    /// spike this mission exists to prevent. A post-fetch check would allocate
    /// the index and then decide to refuse — too late.
    fn ensure_float_index_built_locked(
        &self,
        state: &mut HotState,
        model_id: &str,
    ) -> Result<bool, SynapseKitError> {
        if state.float_indices.contains_key(model_id) {
            return Ok(true);
        }
        // Read serving generation from state cache. On fresh reopen the cache is
        // empty, defaulting to 0. load_hnsw_graph_if_present subsequently calls
        // serving_generation() (registry-aware) and populates the cache; the float
        // index rebuilt here with gen=0 is bypassed by the HNSW path until the
        // cache is warm (find_farthest_float is the only caller that would expose
        // the stale index — out of scope for shadow-swap missions, and the float
        // index is invalidated on the next add_payload or delete_all_vectors).
        let serving_gen = state.serving_generations.get(model_id).copied().unwrap_or(0);

        // ── Admission gate ────────────────────────────────────────────────────
        //
        // Resolve the configured ceiling. SystemFraction queries physical RAM
        // at call time so the value tracks hot-add or detection on first call.
        // None = Unbounded or undetectable platform → no cap applied.
        let config = self.storage.configuration();
        let ceiling_opt = config.resident_index_budget.ceiling_bytes(physical_memory_bytes());

        // footprint_to_record: Some(bytes) when we went through the admission
        // check and were admitted. Recorded in float_index_footprints only
        // AFTER a successful build (avoids phantom entries on build failure).
        let mut footprint_to_record: Option<u64> = None;

        if let Some(ceiling) = ceiling_opt {
            // Build the predicate once; it is used for both count and sample.
            // Uses a macro-style closure to avoid repeating the three-clause
            // AND predicate.
            let make_pred = || {
                StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new("vectors", "kind"),
                        TypedValue::Int(VectorKind::Float32.raw()),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "model_id"),
                        TypedValue::Text(model_id.to_string()),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "generation"),
                        TypedValue::Int(serving_gen),
                    ),
                ])
            };

            // Step 1: count rows without fetching payloads.
            let record_count = self.storage.row_store()
                .count("vectors", Some(&make_pred()))
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

            if record_count == 0 {
                // No float rows — do NOT cache an empty index: a later ingest of
                // this model's first float row must be able to build a real index
                // on the next search.
                return Ok(false);
            }

            // Step 2: sample one row to learn the stride (dim * 4 bytes/float32).
            let dim_opt: Option<u64> = self.storage.row_store()
                .query("vectors", Some(&make_pred()), &[], Some(1), None)
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?
                .into_iter()
                .next()
                .and_then(|r| r.get("dim").cloned())
                .and_then(|v| match v { TypedValue::Int(n) => Some(n as u64), _ => None });

            if let Some(dim) = dim_opt {
                let stride: u64 = dim * 4;

                // Step 3: project footprint.
                //
                // OVERHEAD = 2_000 bytes/record above the packed stride.
                // Measured: Swift ~266 bytes/record overhead, Rust ~1,714
                // bytes/record overhead (BRR §6.1). Both ports use the larger
                // (Rust) figure, rounded up to 2_000, so the projection never
                // under-estimates in either port and both ports make the SAME
                // admission decision for identical inputs — a Part 3 test
                // requirement.
                //
                // GRAPH_ALLOW = stride + OVERHEAD + 256 bytes/record ABOVE the
                // HNSW threshold. Each HNSWIndex.Node owns a second full copy of
                // the vector (stride bytes), a second copy of key overhead, and
                // neighbour lists (≲256 bytes at hnswM=16). This is an analytic
                // bound read off the struct definition (BRR §6.2), not an RSS
                // measurement.
                const OVERHEAD: u64 = 2_000;
                let graph_allow: u64 = stride + OVERHEAD + 256;

                let projected: u64 = if record_count < self.hnsw_threshold as usize {
                    record_count as u64 * (stride + OVERHEAD)
                } else {
                    record_count as u64 * (stride + OVERHEAD + graph_allow)
                };

                // Step 4: reconcile the footprint map, then sum.
                //
                // Drop entries whose model is no longer in float_indices — their
                // index was evicted by one of the ~9 clear sites (evict_float_indices,
                // delete_all_vectors, publish_shadow_generation, etc.). This
                // self-reconciliation is WHY those sites need no accounting edit:
                // float_indices is the single source of truth, and the map tracks
                // it lazily here. A running counter maintained across those sites
                // would drift when any site is missed; the map cannot drift.
                let stale: Vec<String> = state.float_index_footprints.keys()
                    .filter(|k| !state.float_indices.contains_key(k.as_str()))
                    .cloned()
                    .collect();
                for k in stale {
                    state.float_index_footprints.remove(&k);
                }
                let current_total: u64 = state.float_index_footprints.values().sum();

                // Step 5: check ceiling.
                if current_total + projected > ceiling {
                    // Refuse admission. The query falls back to float_scan_from_table,
                    // which returns correct results without allocating the index.
                    // No throw, no empty result when rows exist.
                    state.admission_refusal_count += 1;
                    report!({
                        use std::time::{SystemTime, UNIX_EPOCH};
                        let ts = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64())
                            .unwrap_or(0.0);
                        let mut tags = std::collections::HashMap::new();
                        tags.insert("kit".to_string(), "SynapseKit".to_string());
                        tags.insert("model_id".to_string(), model_id.to_string());
                        tags.insert("projected_bytes".to_string(), projected.to_string());
                        tags.insert("resident_total_bytes".to_string(), current_total.to_string());
                        tags.insert("ceiling_bytes".to_string(), ceiling.to_string());
                        StatSample::metric(
                            "synapsekit.float_index.admission_refused".to_string(),
                            1.0,
                            tags,
                            ts,
                        )
                    });
                    return Ok(false);
                }

                // Admitted. Record the footprint optimistically; it is inserted into
                // float_index_footprints only after a successful build below.
                footprint_to_record = Some(projected);
            } else {
                // Stride unknown: the sampled row carried no readable `dim`. The
                // schema declares `dim` NOT NULL, so this is unreachable for
                // well-formed data — but the branch must still fail SAFE. Building
                // without a projection would let a single malformed row bypass the
                // ceiling entirely, which is precisely the unbounded-residency
                // defect this gate exists to close. Decline instead: the caller
                // falls through to float_scan_from_table and the query is still
                // answered correctly. The Swift twin declines here for the same
                // reason, so the two ports agree on this case as well.
                return Ok(false);
            }
        }
        // ── End admission gate ────────────────────────────────────────────────

        // Admitted (or Unbounded / undetectable platform): fetch all records and build.
        let records = self.fetch_float_records(model_id, serving_gen)?;
        if records.is_empty() {
            // No float rows for this model — do NOT cache an empty index.
            return Ok(false);
        }
        let record_count = records.len() as u32;
        let payloads: Vec<VectorPayload> = records.iter().map(|(_, p)| p.clone()).collect();
        let keys: Vec<VectorRecordKey> = records.into_iter().map(|(k, _)| k).collect();
        let mut index = FloatBruteForceIndex::new();
        index.build(&payloads, &keys)?;
        state.float_indices.insert(model_id.to_string(), index);
        // Record the live count so find_nearest_float can decide whether to activate
        // HNSW on the next query. Only set when building the index from the table;
        // add_payload increments this value for subsequent incremental inserts.
        state.live_float_counts.insert(model_id.to_string(), record_count);

        // Record projected footprint only after successful build to prevent phantom
        // entries in the accounting map if build() errors.
        if let Some(footprint) = footprint_to_record {
            state.float_index_footprints.insert(model_id.to_string(), footprint);
        }

        Ok(true)
    }

    /// Fetch the float32 rows for ONE modelID from the `vectors` table, sorted
    /// by VectorRecordKey natural order (arch spec §4.2: deterministic partition
    /// index, so the cross-language scan order matches). Scoping the fetch to a
    /// single modelID guarantees a uniform stride (one dimension per model), so
    /// the resulting FloatBruteForceIndex never mixes dimensions across models
    /// (mission 6a-iii-core).
    ///
    /// `serving_gen` filters to only the rows that belong to the current serving
    /// generation, excluding any in-flight shadow rows. Pass 0 for models that
    /// have never been swapped (DEFAULT 0 on the `generation` column).
    fn fetch_float_records(
        &self,
        model_id: &str,
        serving_gen: i64,
    ) -> Result<Vec<(VectorRecordKey, VectorPayload)>, SynapseKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "vectors",
                Some(&StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new("vectors", "kind"),
                        TypedValue::Int(VectorKind::Float32.raw()),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "model_id"),
                        TypedValue::Text(model_id.to_string()),
                    ),
                    // Serving-generation filter: exclude shadow rows (generation ≠ serving).
                    StoragePredicate::Eq(
                        Column::new("vectors", "generation"),
                        TypedValue::Int(serving_gen),
                    ),
                ])),
                &[],
                None,
                None,
            )
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        // model_id and model_version repeat for every row in a partition.
        // Interning collapses N identical String heap allocations to one
        // shared instance per unique value.
        let mut intern_cache: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        let intern = |cache: &mut std::collections::HashMap<String, String>, s: String| -> String {
            if let Some(existing) = cache.get(&s) {
                existing.clone()
            } else {
                cache.insert(s.clone(), s.clone());
                s
            }
        };
        let mut records: Vec<(VectorRecordKey, VectorPayload)> = Vec::with_capacity(rows.len());
        for row in rows {
            let item_id = match row.get("item_id") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => continue,
            };
            let vector_index = match row.get("vector_index") {
                Some(TypedValue::Int(v)) => *v as u32,
                _ => continue,
            };
            let raw_model_id = match row.get("model_id") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => continue,
            };
            let raw_model_version = match row.get("model_version") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => continue,
            };
            let payload = match decode_payload(&row) {
                Ok(p) if p.kind == VectorKind::Float32 => p,
                _ => continue,
            };
            let key = VectorRecordKey::new(
                item_id,
                vector_index,
                intern(&mut intern_cache, raw_model_id),
                intern(&mut intern_cache, raw_model_version),
            );
            records.push((key, payload));
        }
        records.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(records)
    }

    /// Build a serving-generation predicate from already-fetched `vector_generations`
    /// registry rows. Pure function: touches no mutex, no storage, no mutable state.
    ///
    /// This is the single authoritative predicate definition for the binary lane.
    /// Called by `serving_gen_predicate_core` (locked context) and directly by
    /// `serving_gen_predicate` (unlocked context, mutex-poisoned fallback).
    ///
    /// Predicate shape:
    ///   (model_id NOT IN known AND generation = 0)
    ///   OR (model_id = M1 AND generation = SG1)
    ///   OR ...
    fn build_serving_gen_predicate(reg_rows: &[StorageRow]) -> StoragePredicate {
        if reg_rows.is_empty() {
            // No registry entries: all models are at generation 0 (pre-swap baseline).
            return StoragePredicate::Eq(
                Column::new("vectors", "generation"),
                TypedValue::Int(0),
            );
        }
        let mut known_model_ids: Vec<TypedValue> = Vec::new();
        let mut per_model_clauses: Vec<StoragePredicate> = Vec::new();
        for row in reg_rows {
            let mid = match row.get("model_id") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => continue,
            };
            let sg = match row.get("serving_generation") {
                Some(TypedValue::Int(v)) => *v,
                _ => continue,
            };
            known_model_ids.push(TypedValue::Text(mid.clone()));
            per_model_clauses.push(StoragePredicate::all(vec![
                StoragePredicate::Eq(
                    Column::new("vectors", "model_id"),
                    TypedValue::Text(mid),
                ),
                StoragePredicate::Eq(
                    Column::new("vectors", "generation"),
                    TypedValue::Int(sg),
                ),
            ]));
        }
        if known_model_ids.is_empty() {
            // Registry rows had no parseable model_id/serving_generation: fall back to gen 0.
            return StoragePredicate::Eq(
                Column::new("vectors", "generation"),
                TypedValue::Int(0),
            );
        }
        let unknown_clause = StoragePredicate::all(vec![
            StoragePredicate::Not(Box::new(StoragePredicate::In(
                Column::new("vectors", "model_id"),
                known_model_ids,
            ))),
            StoragePredicate::Eq(
                Column::new("vectors", "generation"),
                TypedValue::Int(0),
            ),
        ]);
        let mut all_clauses = vec![unknown_clause];
        all_clauses.extend(per_model_clauses);
        StoragePredicate::any(all_clauses)
    }

    /// Build a serving-generation predicate from already-fetched registry rows
    /// and update the in-memory cache in one pass.
    ///
    /// Callable from locked contexts (state mutex already held): callers fetch
    /// the registry rows themselves, pass their `&mut HotState`, and receive the
    /// predicate without touching the mutex again. Also used by
    /// `serving_gen_predicate()` after locking.
    ///
    /// Delegates predicate construction to `build_serving_gen_predicate` and then
    /// reflects the fetched values into `state.serving_generations` so the cache
    /// stays current with the durable registry after every index build.
    fn serving_gen_predicate_core(
        reg_rows: &[StorageRow],
        state: &mut HotState,
    ) -> StoragePredicate {
        // Refresh the in-memory cache from the durable registry while we have
        // the rows in hand. This keeps the cache current for subsequent write-path
        // routing without a separate DB query.
        for row in reg_rows {
            if let (Some(TypedValue::Text(mid)), Some(TypedValue::Int(sg))) = (
                row.get("model_id"),
                row.get("serving_generation"),
            ) {
                state.serving_generations.insert(mid.clone(), *sg);
            }
        }
        Self::build_serving_gen_predicate(reg_rows)
    }

    /// Count serving-generation binary rows in the `vectors` table.
    ///
    /// Constrains to `kind = Binary AND <gen_pred>` where `gen_pred` is the
    /// serving-generation predicate built by `serving_gen_predicate_core`.
    ///
    /// Used by `ensure_index_built_locked` to detect a stale sidecar.
    /// Both this count and the rows from `fetch_all_binary_records` must use
    /// the SAME predicate so the sidecar-freshness comparison is consistent.
    fn binary_row_count(&self, gen_pred: &StoragePredicate) -> Result<usize, SynapseKitError> {
        let pred = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new("vectors", "kind"),
                TypedValue::Int(VectorKind::Binary.raw()),
            ),
            gen_pred.clone(),
        ]);
        let rows = self
            .storage
            .row_store()
            .query("vectors", Some(&pred), &[], None, None)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.len())
    }

    /// Fetch serving-generation binary rows from the `vectors` table once,
    /// sorted by VectorRecordKey natural order.
    ///
    /// Constrains to `kind = Binary AND <gen_pred>` so that rows written under
    /// an active shadow generation are excluded from the resident binary index.
    /// This closes the cf7de0c finding: a resident index rebuild while a shadow
    /// is in flight must not load shadow-generation vectors, which are neither
    /// at the serving generation nor yet published.
    ///
    /// `gen_pred` must be the caller's serving-generation predicate, built from
    /// the durable `vector_generations` registry via `serving_gen_predicate_core`
    /// (or `build_serving_gen_predicate`). It is passed in rather than derived
    /// here because both callers already hold the state mutex. It must NOT be
    /// derived from the in-memory serving-generation cache: that cache is empty
    /// on a fresh reopen, which would collapse the predicate to `generation = 0`
    /// and build the resident binary index from no rows at all once a swap has
    /// advanced the serving generation past 0.
    fn fetch_all_binary_records(
        &self,
        gen_pred: &StoragePredicate,
    ) -> Result<Vec<(VectorRecordKey, Vec<u8>)>, SynapseKitError> {
        let pred = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new("vectors", "kind"),
                TypedValue::Int(VectorKind::Binary.raw()),
            ),
            gen_pred.clone(),
        ]);
        let rows = self
            .storage
            .row_store()
            .query("vectors", Some(&pred), &[], None, None)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        let mut records: Vec<(VectorRecordKey, Vec<u8>)> = Vec::with_capacity(rows.len());
        for row in rows {
            if let Some(sv) = decode_stored_vector_light(&row)? {
                records.push(sv);
            }
        }

        // Sort by key for deterministic partition index (arch spec §4.2).
        records.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(records)
    }

    /// Extract live (non-tombstoned) payloads and keys from a ResidentVectorArray.
    ///
    /// Helper for building both indexes from an array snapshot. Returns
    /// parallel (payloads, keys) vecs suitable for `DenseIndex::build`.
    fn array_to_payloads_keys(
        array: &crate::engine::resident::ResidentVectorArray,
    ) -> (Vec<VectorPayload>, Vec<VectorRecordKey>) {
        let mut payloads: Vec<VectorPayload> = Vec::new();
        let mut keys: Vec<VectorRecordKey> = Vec::new();
        for slot_idx in 0..array.count {
            if array.is_tombstoned(slot_idx) {
                continue;
            }
            let bytes = array.vector_bytes(slot_idx).to_vec();
            payloads.push(VectorPayload {
                kind: VectorKind::Binary,
                dim: 256,
                bytes,
                scale: None,
            });
            keys.push(array.keys[slot_idx].clone());
        }
        (payloads, keys)
    }

    /// Update `is_mih_active` based on `live_binary_count` vs `mih_threshold`.
    ///
    /// Promotes to MIH when count reaches threshold; demotes when it falls
    /// below. Parallel to Swift `_selectIndex()`.
    fn select_index(state: &mut HotState) {
        let use_mih = state.live_binary_count >= state.mih_threshold;
        if use_mih && !state.is_mih_active {
            state.is_mih_active = true;
        } else if !use_mih && state.is_mih_active {
            state.is_mih_active = false;
        }
    }

    /// Delete one (item_id, vector_index, model_id) row from the table and
    /// tombstone the matching slot in the resident array.
    fn delete_and_tombstone(
        &self,
        item_id: &str,
        vector_index: u32,
        model_id: &str,
    ) -> Result<(), SynapseKitError> {
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new("vectors", "item_id"),
                TypedValue::Text(item_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "vector_index"),
                TypedValue::Int(vector_index as i64),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
        ]);
        self.storage
            .row_store()
            .delete("vectors", &predicate)
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        let mut state = self.state.lock().map_err(|_| {
            SynapseKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        // The deleted row may have been a float32 vector for this modelID.
        // Invalidate THIS model's Lane D index (and HNSW graph) so the next
        // find_nearest_float rebuilds from the table. Other models' indices are untouched.
        state.float_indices.remove(model_id);
        state.hnsw_indices.remove(model_id);
        state.live_float_counts.remove(model_id);
        // Dirty-flag hygiene (VH-01): the graph was just dropped, so clear the
        // partition's dirty flag too — otherwise the next flush() sees a dirty
        // partition with no in-memory graph and deletes the still-serviceable
        // persisted hnsw_graph rows (reload re-derives bytes from the vectors
        // table, so those rows can never resurface deleted content).
        state.hnsw_graph_dirty.remove(model_id);
        if !state.index_built {
            return Ok(()); // table delete already applied; array not yet built
        }

        // Scan the BruteForce snapshot to find the exact VectorRecordKey
        // (which includes model_version — not available at the call site).
        let snap = state.brute_force_index.array().clone();
        let mut removed = false;
        for slot_idx in 0..snap.count {
            if snap.is_tombstoned(slot_idx) {
                continue;
            }
            let k = &snap.keys[slot_idx];
            if k.item_id == item_id
                && k.vector_index == vector_index
                && k.model_id == model_id
            {
                let owned_key = k.clone();
                if let Some(ref mut store) = state.array_store {
                    store.tombstone(&owned_key)?;
                }
                state.brute_force_index.remove(&owned_key)?;
                state.mih_index.remove(&owned_key)?;
                removed = true;
                break; // UNIQUE(item_id, vector_index, model_id) — one match max
            }
        }
        if removed {
            state.live_binary_count = state.live_binary_count.saturating_sub(1);
            Self::select_index(&mut state);
        }
        Ok(())
    }

    // ── Shadow-swap API ───────────────────────────────────────────────────

    /// Begin a shadow generation for the given model IDs.
    ///
    /// For each model: shadow_generation = serving_generation + 1, registry row
    /// upserted with shadow_state = 'building'. While a model has an active
    /// shadow, ALL vector writes for that model land tagged with shadow_generation
    /// and bypass all resident structures (resident array, float indices, HNSW).
    /// Models not listed are unaffected.
    ///
    /// Re-entrant begin (crash-mid-build recovery path): if the registry already
    /// has a 'building' shadow for a model, the stale shadow's vector rows are
    /// deleted via `abandon_shadow_generation` before the new generation is
    /// allocated. Generation numbering is still max(stale_shadow, serving) + 1 so
    /// no previously-issued generation number is ever re-used, even if its rows
    /// have been deleted. This is the B2 fix: before this change, the stale rows
    /// persisted forever because `shadow_state='building'` caused reclaim to skip
    /// them, yet they were never at the serving generation.
    ///
    /// Each model that successfully begins is added to `open_shadows` — the B3
    /// in-flight tracker that distinguishes live shadows from abandoned DB rows.
    ///
    /// Returns a map from model_id to the allocated shadow generation number.
    /// Mirror of Swift `VectorStore.beginShadowGeneration(modelIDs:)`.
    pub fn begin_shadow_generation(
        &self,
        model_ids: &[&str],
    ) -> Result<std::collections::HashMap<String, i64>, SynapseKitError> {
        let mut result = std::collections::HashMap::new();
        for &model_id in model_ids {
            let serving = self.serving_generation(model_id)?;

            // Query the registry to discover any stale 'building' shadow.
            // Read existing_max BEFORE any abandon so the generation number
            // accounts for the stale shadow even after its rows are deleted
            // (generation numbers must never be re-issued).
            let row_store = self.storage.row_store();
            let rows = row_store
                .query(
                    "vector_generations",
                    Some(&StoragePredicate::Eq(
                        Column::new("vector_generations", "model_id"),
                        TypedValue::Text(model_id.to_string()),
                    )),
                    &[],
                    Some(1),
                    None,
                )
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

            let existing_max = if let Some(row) = rows.first() {
                match row.get("shadow_generation") {
                    Some(TypedValue::Int(sg)) => std::cmp::max(*sg, serving),
                    _ => serving,
                }
            } else {
                serving
            };

            // If a stale 'building' shadow exists, abandon it first: delete its
            // vector rows and clear the registry shadow columns. This is the B2
            // fix — previously the stale rows were merely numbered past, leaving
            // them permanently unreachable (not at serving gen, never promoted,
            // exempt from reclaim because shadow_state='building').
            let has_stale_shadow = rows.first().map(|r| {
                matches!(
                    (r.get("shadow_generation"), r.get("shadow_state")),
                    (Some(TypedValue::Int(_)), Some(TypedValue::Text(s))) if s == "building"
                )
            }).unwrap_or(false);
            if has_stale_shadow {
                self.abandon_shadow_generation(&[model_id])?;
            }

            let new_shadow = existing_max + 1;

            // Upsert the registry row: serving_generation unchanged, new shadow
            // allocated, state set to 'building'.
            let mut values = std::collections::BTreeMap::new();
            values.insert("model_id".to_string(), TypedValue::Text(model_id.to_string()));
            values.insert("serving_generation".to_string(), TypedValue::Int(serving));
            values.insert("shadow_generation".to_string(), TypedValue::Int(new_shadow));
            values.insert("shadow_state".to_string(), TypedValue::Text("building".to_string()));
            row_store
                .upsert("vector_generations", values, &["model_id".to_string()])
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

            // Update in-memory caches under the state lock.
            // open_shadows receives this model: it is now genuinely in-flight in
            // this process (B3: distinguishes live from abandoned DB rows).
            let mut state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            state.serving_generations.insert(model_id.to_string(), serving);
            state.shadow_generations.insert(model_id.to_string(), new_shadow);
            state.shadow_states.insert(model_id.to_string(), "building".to_string());
            state.shadow_payload_bytes.insert(model_id.to_string(), 0);
            state.open_shadows.insert(model_id.to_string());
            drop(state);

            result.insert(model_id.to_string(), new_shadow);
        }
        Ok(result)
    }

    /// Atomically publish the shadow generation for the given model IDs.
    ///
    /// ONE storage transaction flips serving_generation = shadow_generation and
    /// clears shadow_generation / sets shadow_state = 'pending-reclaim' for all
    /// named models. A reader sees the old generation set or the new set, never a
    /// mixture. If the transaction does not commit, the old generation continues
    /// to serve (crash-mid-publish safe).
    ///
    /// After the flip commits: drops resident float/HNSW indices for the swapped
    /// models, deletes retired hnsw_graph rows, rebuilds the binary resident
    /// array from new serving rows, and rebuilds the HNSW graph for each model
    /// (D6 fix: `rebuild_hnsw_index` stamps and persists the graph with the new
    /// serving generation before returning). A crash between flip-commit and
    /// rebuild leaves a generation-mismatched graph → treated as absent (§4).
    ///
    /// Mirror of Swift `VectorStore.publishShadowGeneration(modelIDs:)`.
    pub fn publish_shadow_generation(&self, model_ids: &[&str]) -> Result<(), SynapseKitError> {
        if model_ids.is_empty() {
            return Ok(());
        }

        // Collect shadow generation for each model before the flip.
        let mut shadow_by_model: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
        for &model_id in model_ids {
            let sg = {
                let state = self.state.lock()
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
                state.shadow_generations.get(model_id).copied()
            };
            let sg = match sg {
                Some(v) => v,
                None => {
                    // Not cached — query the registry.
                    match self.shadow_generation(model_id)? {
                        Some(v) => v,
                        None => continue, // No active shadow — skip.
                    }
                }
            };
            shadow_by_model.insert(model_id.to_string(), sg);
        }
        if shadow_by_model.is_empty() {
            return Ok(());
        }

        // ONE atomic transaction: serving_gen = shadow_gen, shadow_gen = NULL,
        // shadow_state = 'pending-reclaim'. A concurrent reader fetching the
        // registry before the commit sees the old generation; after commit the
        // new generation.
        let row_store = self.storage.row_store();
        row_store
            .begin_transaction()
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        let flip_result = (|| -> Result<(), SynapseKitError> {
            for (model_id, shadow_gen) in &shadow_by_model {
                let mut values = std::collections::BTreeMap::new();
                values.insert("model_id".to_string(), TypedValue::Text(model_id.clone()));
                values.insert("serving_generation".to_string(), TypedValue::Int(*shadow_gen));
                values.insert("shadow_generation".to_string(), TypedValue::Null);
                values.insert("shadow_state".to_string(), TypedValue::Text("pending-reclaim".to_string()));
                row_store
                    .upsert("vector_generations", values, &["model_id".to_string()])
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            }
            Ok(())
        })();
        match flip_result {
            Ok(()) => row_store
                .commit_transaction()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?,
            Err(e) => {
                let _ = row_store.rollback_transaction();
                return Err(e);
            }
        }

        // Flip committed. Update in-memory generation caches.
        {
            let mut state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            for (model_id, shadow_gen) in &shadow_by_model {
                state.serving_generations.insert(model_id.clone(), *shadow_gen);
                state.shadow_generations.remove(model_id);
                state.shadow_states.insert(model_id.clone(), "pending-reclaim".to_string());
                // Remove from open_shadows: the shadow has been promoted, it is
                // no longer an in-flight build. (B3)
                state.open_shadows.remove(model_id);
                // Drop stale float and HNSW indices — they were built on the old
                // serving generation. A crash here leaves the maps empty, which is safe:
                // the query path falls back to load_hnsw_graph_if_present / table scan.
                state.float_indices.remove(model_id);
                state.hnsw_indices.remove(model_id);
            }
        }

        // Delete hnsw_graph rows of retired generations (all ≠ new serving gen).
        // Safe to run outside the flip transaction: the generation mismatch check
        // in load_hnsw_graph_if_present already treats stale rows as absent.
        for (model_id, new_serving_gen) in &shadow_by_model {
            row_store
                .delete(
                    "hnsw_graph",
                    &StoragePredicate::all(vec![
                        StoragePredicate::Eq(
                            Column::new("hnsw_graph", "model_id"),
                            TypedValue::Text(model_id.clone()),
                        ),
                        StoragePredicate::Not(Box::new(StoragePredicate::Eq(
                            Column::new("hnsw_graph", "generation"),
                            TypedValue::Int(*new_serving_gen),
                        ))),
                    ]),
                )
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        }

        // Rebuild binary resident array from the new serving rows (all models).
        // This replaces the entire resident array so the binary lane serves the
        // new generation.
        self.rebuild_binary_index_from_table()?;

        // Rebuild HNSW graph for each swapped model from new serving float rows.
        // D6 fix: rebuild_hnsw_index stamps the graph with the current serving
        // generation (now shadow_gen) before persisting — the serving_generation
        // cache was updated above, so _servingGeneration returns the new value.
        let swapped: Vec<&str> = shadow_by_model.keys().map(|s| s.as_str()).collect();
        for model_id in swapped {
            self.rebuild_hnsw_index(model_id)?;
        }

        Ok(())
    }

    /// Abort the shadow build for the given model IDs, deleting all rows written
    /// under the active shadow generation.
    ///
    /// For each model: if the registry row's shadow_state is not 'building' or
    /// shadow_generation is NULL, this is a no-op for that model (idempotent).
    /// Otherwise:
    ///   1. Deletes every `vectors` row at (model_id, shadow_generation).
    ///   2. Deletes any `hnsw_graph` rows at (model_id, shadow_generation).
    ///   3. Upserts the registry row: serving_generation UNCHANGED,
    ///      shadow_generation = NULL, shadow_state = NULL.
    ///   4. Clears shadow_generations, shadow_states, open_shadows for the model.
    ///
    /// This is the ABORT half of the generation lifecycle: every vector on disk
    /// is either at the serving generation or permanently gone; no row can persist
    /// at a 'building' shadow generation that will never be promoted.
    ///
    /// Returns a map from model_id to the count of `vectors` rows deleted.
    /// Mirror of Swift `VectorStore.abandonShadowGeneration(modelIDs:)`.
    pub fn abandon_shadow_generation(
        &self,
        model_ids: &[&str],
    ) -> Result<std::collections::HashMap<String, usize>, SynapseKitError> {
        let row_store = self.storage.row_store();
        let mut summary: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

        for &model_id in model_ids {
            // Query the registry to determine whether a 'building' shadow exists.
            let rows = row_store
                .query(
                    "vector_generations",
                    Some(&StoragePredicate::Eq(
                        Column::new("vector_generations", "model_id"),
                        TypedValue::Text(model_id.to_string()),
                    )),
                    &[],
                    Some(1),
                    None,
                )
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

            let row = match rows.first() {
                Some(r) => r,
                None => continue, // No registry entry: model never began a shadow.
            };

            let shadow_gen = match (row.get("shadow_generation"), row.get("shadow_state")) {
                (Some(TypedValue::Int(sg)), Some(TypedValue::Text(state_str)))
                    if state_str == "building" =>
                {
                    *sg
                }
                _ => continue, // No active 'building' shadow: no-op for this model.
            };

            let serving_gen = match row.get("serving_generation") {
                Some(TypedValue::Int(v)) => *v,
                _ => 0,
            };

            // SAFETY CHECK: never delete a serving-generation row.
            // This invariant must hold even if the registry is corrupt.
            debug_assert_ne!(
                shadow_gen, serving_gen,
                "abandon: shadow_gen must not equal serving_gen"
            );
            if shadow_gen == serving_gen {
                continue;
            }

            // 1. Delete all vectors rows at this shadow generation for this model.
            let vec_pred = StoragePredicate::all(vec![
                StoragePredicate::Eq(
                    Column::new("vectors", "model_id"),
                    TypedValue::Text(model_id.to_string()),
                ),
                StoragePredicate::Eq(
                    Column::new("vectors", "generation"),
                    TypedValue::Int(shadow_gen),
                ),
            ]);
            let deleted = row_store
                .delete("vectors", &vec_pred)
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

            // 2. Delete any hnsw_graph rows written for this shadow generation.
            // (Normally none exist at abandon time — graphs are only persisted at
            // publish — but defensive cleanup handles edge cases.)
            row_store
                .delete(
                    "hnsw_graph",
                    &StoragePredicate::all(vec![
                        StoragePredicate::Eq(
                            Column::new("hnsw_graph", "model_id"),
                            TypedValue::Text(model_id.to_string()),
                        ),
                        StoragePredicate::Eq(
                            Column::new("hnsw_graph", "generation"),
                            TypedValue::Int(shadow_gen),
                        ),
                    ]),
                )
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

            // 3. Clear registry shadow columns; serving_generation is unchanged.
            let mut values = std::collections::BTreeMap::new();
            values.insert("model_id".to_string(), TypedValue::Text(model_id.to_string()));
            values.insert("serving_generation".to_string(), TypedValue::Int(serving_gen));
            values.insert("shadow_generation".to_string(), TypedValue::Null);
            values.insert("shadow_state".to_string(), TypedValue::Null);
            row_store
                .upsert("vector_generations", values, &["model_id".to_string()])
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

            // 4. Clear in-memory caches under the state lock.
            if let Ok(mut state) = self.state.lock() {
                state.shadow_generations.remove(model_id);
                state.shadow_states.remove(model_id);
                state.shadow_payload_bytes.remove(model_id);
                // Remove from open_shadows: this shadow is no longer in-flight.
                state.open_shadows.remove(model_id);
            }

            if deleted > 0 {
                summary.insert(model_id.to_string(), deleted);
            }
        }
        Ok(summary)
    }

    /// Measured peak shadow payload bytes for the most recent (or current)
    /// shadow build for `model_id`. Returns 0 if no shadow has been started.
    ///
    /// The value is the sum of `payload.bytes.len()` of every shadow row written
    /// via `add_payload`/`add_payloads` while a shadow is active.
    /// Mirror of Swift `VectorStore.peakShadowStorageBytes(for:)`.
    pub fn peak_shadow_storage_bytes(&self, model_id: &str) -> i64 {
        self.state.lock()
            .map(|s| s.shadow_payload_bytes.get(model_id).copied().unwrap_or(0))
            .unwrap_or(0)
    }

    /// The generation of the HNSW graph instance that last answered a float
    /// nearest-neighbour query for `model_id`. Returns `None` if no float query
    /// has been served since this `VectorStore` was opened.
    ///
    /// Gate 5 reads this after publish + query to assert the swap promoted the
    /// graph to the new serving generation before the query was answered.
    /// Mirror of Swift `VectorStore.lastServedGraphGeneration(for:)`.
    pub fn last_served_graph_generation(&self, model_id: &str) -> Option<i64> {
        self.state.lock()
            .ok()
            .and_then(|s| s.last_served_graph_gen.get(model_id).copied())
    }

    /// Idempotent, resumable, batched reclaim of superseded generation rows.
    ///
    /// Deletes `vectors` rows whose generation ≠ the model's serving_generation
    /// AND that are NOT the model's active 'building' shadow (reclaimable = no
    /// active shadow OR shadow_state is 'pending-reclaim'). Also deletes
    /// mismatched hnsw_graph rows, then clears shadow_state 'pending-reclaim'
    /// from the registry. Reclaims abandoned 'building' shadows.
    ///
    /// Killing mid-reclaim and re-running finishes without error and changes no
    /// query result (serving_generation is already the committed value before
    /// this call). Returns a per-model count of deleted `vectors` rows.
    ///
    /// Mirror of Swift `VectorStore.reclaimSupersededGenerations(batchLimit:)`.
    ///
    /// `batch_limit: None` — unbounded pass; deletes all superseded rows for each
    /// model and clears the 'pending-reclaim' registry state. Production BETA path.
    ///
    /// `batch_limit: Some(n)` — bounded pass; deletes at most `n` superseded rows
    /// per model using a SELECT-then-DELETE WHERE IN pattern (SQLite's
    /// DELETE…LIMIT requires `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`, which is absent
    /// in PersistenceKit-bundled SQLite). When bounded, the registry state is NOT
    /// cleared — the operation is explicitly partial so a second unbounded pass
    /// can finish the job (Gate 4 resumability test).
    pub fn reclaim_superseded_generations(
        &self,
        batch_limit: Option<usize>,
    ) -> Result<std::collections::HashMap<String, usize>, SynapseKitError> {
        let row_store = self.storage.row_store();
        // Fetch all registry rows.
        let reg_rows = row_store
            .query(
                "vector_generations",
                Some(&StoragePredicate::IsTrue),
                &[],
                None,
                None,
            )
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        // Read the open_shadows set once under the lock. This is the B3 fix:
        // only models that are genuinely in-flight in THIS process are protected.
        // A 'building' row whose model is NOT in open_shadows was left by a prior
        // crashed process and is an abandoned shadow — its rows are reclaimable.
        //
        // Do NOT use shadow_generations as the in-flight signal: shadow_generation()
        // populates that cache merely by READING the registry, so it loses the
        // "opened in this process" distinction after any read.
        let open_shadows_snapshot = self.state.lock()
            .map(|s| s.open_shadows.clone())
            .unwrap_or_default();

        let mut summary: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

        for row in &reg_rows {
            let model_id = match row.get("model_id") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => continue,
            };
            let serving_gen = match row.get("serving_generation") {
                Some(TypedValue::Int(v)) => *v,
                _ => continue,
            };

            // Determine whether to protect an active shadow row.
            //
            // Old rule: protect any 'building' shadow (too broad — protected
            // abandoned rows from crashed processes forever).
            //
            // New rule (B3): protect a 'building' shadow ONLY when the model
            // is in open_shadows (meaning begin_shadow_generation was called in
            // THIS process). A 'building' row for a model NOT in open_shadows
            // is an abandoned shadow — reclaim its rows.
            let active_shadow: Option<i64> = match (
                row.get("shadow_generation"),
                row.get("shadow_state"),
            ) {
                (Some(TypedValue::Int(sg)), Some(TypedValue::Text(state)))
                    if state == "building" && open_shadows_snapshot.contains(&model_id) =>
                {
                    // Genuinely in-flight shadow: protect it.
                    Some(*sg)
                }
                (Some(TypedValue::Int(_sg)), Some(TypedValue::Text(state)))
                    if state == "building" && !open_shadows_snapshot.contains(&model_id) =>
                {
                    // Abandoned 'building' shadow from a prior crashed process.
                    // Clear the registry shadow columns so reclaim can proceed.
                    let mut values = std::collections::BTreeMap::new();
                    values.insert("model_id".to_string(), TypedValue::Text(model_id.clone()));
                    values.insert("serving_generation".to_string(), TypedValue::Int(serving_gen));
                    values.insert("shadow_generation".to_string(), TypedValue::Null);
                    values.insert("shadow_state".to_string(), TypedValue::Null);
                    let _ = row_store.upsert("vector_generations", values, &["model_id".to_string()]);
                    None // treat as no active shadow — rows will be reclaimed below
                }
                _ => None,
            };

            // Build the superseded-row predicate: model_id = X AND generation ≠ serving
            // AND (if active in-flight shadow) generation ≠ active shadow.
            let mut pred_parts = vec![
                StoragePredicate::Eq(
                    Column::new("vectors", "model_id"),
                    TypedValue::Text(model_id.clone()),
                ),
                StoragePredicate::Not(Box::new(StoragePredicate::Eq(
                    Column::new("vectors", "generation"),
                    TypedValue::Int(serving_gen),
                ))),
            ];
            if let Some(active) = active_shadow {
                pred_parts.push(StoragePredicate::Not(Box::new(StoragePredicate::Eq(
                    Column::new("vectors", "generation"),
                    TypedValue::Int(active),
                ))));
            }
            let pred = StoragePredicate::all(pred_parts);

            let deleted = if let Some(cap) = batch_limit {
                // Bounded path: SELECT ids LIMIT cap → DELETE WHERE IN (ids).
                // Cannot use DELETE…LIMIT directly: SQLITE_ENABLE_UPDATE_DELETE_LIMIT
                // is absent in PersistenceKit-bundled SQLite.
                let id_rows = row_store
                    .query("vectors", Some(&pred), &[], Some(cap), None)
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
                if id_rows.is_empty() {
                    // No superseded rows remain — bounded pass is a no-op.
                    0
                } else {
                    let ids: Vec<TypedValue> = id_rows
                        .iter()
                        .filter_map(|r| r.get("id").cloned())
                        .collect();
                    let del_pred = StoragePredicate::all(vec![
                        StoragePredicate::Eq(
                            Column::new("vectors", "model_id"),
                            TypedValue::Text(model_id.clone()),
                        ),
                        StoragePredicate::In(
                            Column::new("vectors", "id"),
                            ids,
                        ),
                    ]);
                    row_store
                        .delete("vectors", &del_pred)
                        .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?
                }
            } else {
                // Unbounded path: delete all superseded rows for this model.
                row_store
                    .delete("vectors", &pred)
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?
            };

            if batch_limit.is_some() {
                // Bounded pass: do NOT clear registry state. The operation is
                // explicitly partial; leave 'pending-reclaim' so the next unbounded
                // pass can finish and clear it.
                if deleted > 0 {
                    summary.insert(model_id, deleted);
                }
                continue;
            }

            // Unbounded path: delete mismatched hnsw_graph rows (any generation ≠ serving).
            row_store
                .delete(
                    "hnsw_graph",
                    &StoragePredicate::all(vec![
                        StoragePredicate::Eq(
                            Column::new("hnsw_graph", "model_id"),
                            TypedValue::Text(model_id.clone()),
                        ),
                        StoragePredicate::Not(Box::new(StoragePredicate::Eq(
                            Column::new("hnsw_graph", "generation"),
                            TypedValue::Int(serving_gen),
                        ))),
                    ]),
                )
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

            // Clear 'pending-reclaim' state from registry.
            let shadow_state = match row.get("shadow_state") {
                Some(TypedValue::Text(s)) => Some(s.as_str()),
                _ => None,
            };
            if shadow_state == Some("pending-reclaim") {
                let mut values = std::collections::BTreeMap::new();
                values.insert("model_id".to_string(), TypedValue::Text(model_id.clone()));
                values.insert("serving_generation".to_string(), TypedValue::Int(serving_gen));
                values.insert("shadow_generation".to_string(), TypedValue::Null);
                values.insert("shadow_state".to_string(), TypedValue::Null);
                row_store
                    .upsert("vector_generations", values, &["model_id".to_string()])
                    .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
                // Evict 'pending-reclaim' state from the in-memory cache.
                if let Ok(mut state) = self.state.lock() {
                    state.shadow_states.remove(&model_id);
                }
            }

            if deleted > 0 {
                summary.insert(model_id, deleted);
            }
        }
        Ok(summary)
    }

    // ── Private shadow-swap helpers ───────────────────────────────────────

    /// Return the current serving generation for `model_id`.
    ///
    /// Reads from the in-memory cache first; on a cache miss, queries the
    /// `vector_generations` table and populates the cache. Absent registry row
    /// means generation 0 (the pre-swap baseline — all estates start here).
    ///
    /// Mirror of Swift `VectorStore._servingGeneration(for:)`.
    fn serving_generation(&self, model_id: &str) -> Result<i64, SynapseKitError> {
        // Fast path: already cached in HotState.
        {
            let state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            if let Some(&gen) = state.serving_generations.get(model_id) {
                return Ok(gen);
            }
        }
        // Slow path: query the registry table.
        let rows = self.storage.row_store()
            .query(
                "vector_generations",
                Some(&StoragePredicate::Eq(
                    Column::new("vector_generations", "model_id"),
                    TypedValue::Text(model_id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        let gen = match rows.first().and_then(|r| r.get("serving_generation")) {
            Some(TypedValue::Int(v)) => *v,
            _ => 0,
        };
        // Populate cache.
        if let Ok(mut state) = self.state.lock() {
            state.serving_generations.insert(model_id.to_string(), gen);
        }
        Ok(gen)
    }

    /// Return the active shadow generation for `model_id` if one is in flight.
    ///
    /// Returns `None` when no 'building' shadow exists (never-swapped models,
    /// or after publish). Reads from the in-memory cache first; queries the
    /// registry table on a miss. Mirror of Swift `VectorStore._shadowGeneration(for:)`.
    fn shadow_generation(&self, model_id: &str) -> Result<Option<i64>, SynapseKitError> {
        // Fast path: cached.
        {
            let state = self.state.lock()
                .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
            if let Some(&sg) = state.shadow_generations.get(model_id) {
                return Ok(Some(sg));
            }
        }
        // Slow path: registry query.
        let rows = self.storage.row_store()
            .query(
                "vector_generations",
                Some(&StoragePredicate::Eq(
                    Column::new("vector_generations", "model_id"),
                    TypedValue::Text(model_id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        let row = match rows.first() {
            Some(r) => r,
            None => return Ok(None),
        };
        // Only 'building' shadows are active. 'pending-reclaim' is not.
        match (row.get("shadow_generation"), row.get("shadow_state")) {
            (Some(TypedValue::Int(sg)), Some(TypedValue::Text(state_str)))
                if state_str == "building" =>
            {
                let sg = *sg;
                if let Ok(mut state) = self.state.lock() {
                    state.shadow_generations.insert(model_id.to_string(), sg);
                    state.shadow_states.insert(model_id.to_string(), state_str.clone());
                }
                Ok(Some(sg))
            }
            _ => {
                // Not building — remove any stale cache entry.
                if let Ok(mut state) = self.state.lock() {
                    state.shadow_generations.remove(model_id);
                }
                Ok(None)
            }
        }
    }

    /// Build a generation predicate for table-wide queries that read from
    /// multiple model_ids (e.g. `recent_item_ids`, `find_by_keyword`,
    /// `fetch_all_binary_records`).
    ///
    /// Returns a predicate that accepts ONLY serving-generation rows for each
    /// model registered in `vector_generations`, plus generation = 0 for any
    /// model_id not in the registry (the default for pre-migration rows and
    /// never-swapped models).
    ///
    /// Updates the in-memory serving-generation cache as a side effect.
    /// Delegates predicate construction to `serving_gen_predicate_core`
    /// (cache-updating) or `build_serving_gen_predicate` (cache-bypass fallback
    /// when the mutex is poisoned — a store-fatal condition, but safe to continue).
    ///
    /// Mirror of Swift `VectorStore._servingGenPredicate()`.
    fn serving_gen_predicate(&self) -> Result<StoragePredicate, SynapseKitError> {
        let reg_rows = self
            .storage
            .row_store()
            .query(
                "vector_generations",
                Some(&StoragePredicate::IsTrue),
                &[],
                None,
                None,
            )
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;

        // Lock briefly to update the in-memory cache via serving_gen_predicate_core.
        // On mutex-poison fall back to the pure predicate builder (no cache update).
        let pred = match self.state.lock() {
            Ok(mut state) => Self::serving_gen_predicate_core(&reg_rows, &mut state),
            Err(_) => Self::build_serving_gen_predicate(&reg_rows),
        };
        Ok(pred)
    }

    /// Rebuild the binary resident array from the `vectors` table.
    ///
    /// Used after a generation swap to refresh the in-memory binary lane with
    /// new-serving rows. Delegates to `rebuild_binary_index_from_table_locked`
    /// which handles both the array-store and no-store paths.
    fn rebuild_binary_index_from_table(&self) -> Result<(), SynapseKitError> {
        let mut state = self.state.lock()
            .map_err(|e| SynapseKitError::StoreUnavailable(e.to_string()))?;
        self.rebuild_binary_index_from_table_locked(&mut state)
    }
}

// ── Row decode helpers ────────────────────────────────────────────────────

/// Decode a `VectorPayload` from a storage row.
///
/// Returns `Err(DecodingFailure)` when a required column is missing or malformed.
///
/// Int8 payloads return `Err(Int8QuantizationPolicyUndefined)`: the
/// quantization policy has not been ratified so a decoded int8 payload
/// cannot be safely used by any consumer. This is a symmetric fail-closed
/// guard: since writes are rejected (`add_payload` returns
/// `Int8QuantizationPolicyUndefined`), no int8 rows should be present in
/// production. The guard defends against hand-crafted rows.
/// See SYNAPSEKIT_SPEC §I-4a.
fn decode_payload(
    row: &persistence_kit::StorageRow,
) -> Result<VectorPayload, SynapseKitError> {
    let kind_raw = match row.get("kind") {
        Some(TypedValue::Int(v)) => *v,
        _ => return Err(SynapseKitError::DecodingFailure("missing kind column".to_string())),
    };
    let kind = VectorKind::from_raw(kind_raw)
        .ok_or_else(|| SynapseKitError::DecodingFailure(format!("unknown VectorKind {kind_raw}")))?;
    // Symmetric read-side guard: int8 payloads cannot be decoded until the
    // quantization policy is ratified. Propagates as an Err to callers.
    // `vectors_for_item` skips the row; `get_payload` surfaces the error
    // directly. Prevents silent consumption of hand-crafted int8 rows.
    if kind == VectorKind::Int8 {
        return Err(SynapseKitError::Int8QuantizationPolicyUndefined(
            "int8 rows cannot be decoded: quantization policy is unspecified. \
             See SYNAPSEKIT_SPEC §I-4a."
                .to_string(),
        ));
    }
    let dim = match row.get("dim") {
        Some(TypedValue::Int(v)) => *v as u32,
        _ => return Err(SynapseKitError::DecodingFailure("missing dim column".to_string())),
    };
    let bytes = match row.get("payload") {
        Some(TypedValue::Blob(b)) => b.clone(),
        _ => return Err(SynapseKitError::DecodingFailure("missing payload column".to_string())),
    };
    let scale = match row.get("scale") {
        Some(TypedValue::Float(f)) => Some(*f as f32),
        Some(TypedValue::Null) | None => None,
        _ => None,
    };
    Ok(VectorPayload { kind, dim, bytes, scale })
}

fn decode_stored_vector(
    row: &persistence_kit::StorageRow,
) -> Result<Option<StoredVector>, SynapseKitError> {
    // The `id` column is TEXT in SQLite (no native UUID column type), so the
    // SQLite backend hands it back as `Text` on read, while the InMemory backend
    // preserves the inserted `Uuid`. Accept BOTH: decoding `Uuid` only silently
    // dropped every persisted vector on read-back, so `find_nearest` over a
    // reopened estate returned no matches and the vector recall lane went dark.
    // Mirrors the Swift VectorStore.decodeRowUUID fix (parity-is-absolute).
    let id = match row.get("id") {
        Some(TypedValue::Uuid(u)) => u.to_string(),
        Some(TypedValue::Text(s)) => match Uuid::parse_str(s) {
            Ok(u) => u.to_string(),
            Err(_) => return Ok(None),
        },
        _ => return Ok(None),
    };
    let item_id = match row.get("item_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return Ok(None),
    };
    let vector_index = match row.get("vector_index") {
        Some(TypedValue::Int(v)) => *v as u32,
        _ => return Ok(None),
    };
    let model_id = match row.get("model_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return Ok(None),
    };
    let model_version = match row.get("model_version") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return Ok(None),
    };
    // Parity with Swift `storedVector(from:)` which returns nil for
    // malformed/undecodable rows. Decode failures (int8 guard, missing
    // columns) skip the row rather than propagating an error.
    let payload = match decode_payload(row) {
        Ok(p) => p,
        Err(_) => return Ok(None),
    };
    // StoredVector still carries an Engram for the convenience API.
    // Only Binary payloads can produce a StoredVector; other kinds
    // are accessible via the get_payload path.
    let engram = match payload.as_engram() {
        Ok(e) => e,
        Err(_) => return Ok(None),
    };
    // filed_at is a unix-milliseconds i64. A timestamp column reads back as `Timestamp`
    // on the InMemory backend and as a primitive `Int` on the SQLite backend
    // (the column stores the integer). Accept both — decoding only `Timestamp`
    // dropped every persisted vector on reopen, blanking the vector recall lane
    // (see the Swift VectorStore.decodeRowDate fix, parity-is-absolute).
    let filed_at = match row.get("filed_at") {
        Some(TypedValue::Timestamp(t)) => *t,
        Some(TypedValue::Int(i)) => *i,
        _ => return Ok(None),
    };
    // generation column added in schema v6; pre-v6 rows (or InMemory databases
    // replaying migrations) default to 0 — the baseline serving generation.
    let generation = match row.get("generation") {
        Some(TypedValue::Int(v)) => *v,
        _ => 0,
    };
    Ok(Some(StoredVector {
        id,
        item_id,
        vector_index,
        model_id,
        model_version,
        engram,
        filed_at,
        generation,
    }))
}

/// Lightweight decode: extract only (VectorRecordKey, bytes) from a row.
///
/// Used by `fetch_all_binary_records` to build the resident array. Does
/// not attempt to decode the Engram — just extracts the raw bytes from the
/// `payload` column and the key fields. Only processes Binary rows.
fn decode_stored_vector_light(
    row: &persistence_kit::StorageRow,
) -> Result<Option<(VectorRecordKey, Vec<u8>)>, SynapseKitError> {
    let item_id = match row.get("item_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return Ok(None),
    };
    let vector_index = match row.get("vector_index") {
        Some(TypedValue::Int(v)) => *v as u32,
        _ => return Ok(None),
    };
    let model_id = match row.get("model_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return Ok(None),
    };
    let model_version = match row.get("model_version") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return Ok(None),
    };
    let bytes = match row.get("payload") {
        Some(TypedValue::Blob(b)) => b.clone(),
        _ => return Ok(None),
    };
    // Only include Binary payloads (kind=0) in the resident array.
    let kind_raw = match row.get("kind") {
        Some(TypedValue::Int(v)) => *v,
        _ => return Ok(None),
    };
    if kind_raw != VectorKind::Binary.raw() {
        return Ok(None);
    }
    let key = VectorRecordKey::new(item_id, vector_index, model_id, model_version);
    Ok(Some((key, bytes)))
}
