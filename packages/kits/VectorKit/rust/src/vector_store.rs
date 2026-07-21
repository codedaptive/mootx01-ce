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
//! Telemetry: emits `vectorkit.*` metrics via IntellectusLib when
//! monitoring is enabled. Off by default; off-path cost is one
//! AtomicBool load.

use crate::engine::brute_force::BruteForceIndex;
use crate::engine::float_brute_force::FloatBruteForceIndex;
use crate::engine::key::VectorRecordKey;
use crate::engine::metric::DenseMetric;
use crate::engine::mih::{MIHBandCount, MIHIndex};
use crate::engine::payload::{VectorKind, VectorPayload};
use crate::engine::resident_store::ResidentArrayStore;
use crate::engine::seam::{DenseIndex, MetadataFilter};
use crate::error::VectorKitError;
use engram_lib::Engram;
use intellectus_lib::{StatSample, report};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::Arc;
use persistence_kit::{
    BackendConfiguration, Column, ColumnDeclaration, IndexDeclaration, Migration, OrderClause,
    OrderDirection, SchemaDeclaration, SchemaOperation, Storage, StoragePredicate,
    TableDeclaration, TypedValue,
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
}

/// Result of a `VectorStore::find_nearest` call. Parallel to Swift
/// `VectorMatch`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VectorMatch {
    /// Renamed from `drawer_id` (Lane F rename).
    pub item_id: String,
    /// Hamming distance over the 256-bit engram. Range 0..=256.
    pub distance: i32,
    pub model_id: String,
}

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

    /// Live keys tracked incrementally across the deferred window so replacement
    /// detection stays O(batch) per call. Seeded by `begin_deferred_index`;
    /// `None` when not in deferred mode. Mirrors Swift `deferredLiveKeys`.
    deferred_live_keys: Option<std::collections::HashSet<VectorRecordKey>>,

    /// Memory-only deferral buffer (Rust twin of Swift `deferredPendingRecords`).
    /// With no sidecar `array_store`, deferred `add_payloads` records accumulate
    /// here and `publish_resident_index` merges them all in one pass at burst end.
    deferred_pending_records: Vec<(VectorRecordKey, Vec<u8>)>,

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

    /// Number of times the sidecar was detected as stale and rebuilt from
    /// the `vectors` table in the lifetime of this `VectorStore` instance.
    ///
    /// Incremented by `ensure_index_built_locked` on each stale-sidecar path.
    /// Zero means the sidecar was current on load (the normal path). Exposed
    /// for test assertions only — callers should not use this value to drive
    /// application logic.
    sidecar_rebuild_count: usize,
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
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "VectorKit",
            4,
            vec![TableDeclaration::new(
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
                ],
                vec!["id".to_string()],
            )
            .with_unique_constraints(vec![vec![
                "item_id".to_string(),
                "vector_index".to_string(),
                "model_id".to_string(),
            ]])],
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
        ])
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
    /// `.vec` filename convention lives here in VectorKit so every caller derives
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
                           DEFERRED_PENDING_LIMIT)
    }

    /// Internal constructor. All public constructors delegate here.
    fn new_internal(
        storage: Arc<dyn Storage>,
        array_store: Option<ResidentArrayStore>,
        mih_threshold: u32,
        mih_band_count: MIHBandCount,
        deferred_pending_limit: usize,
    ) -> Self {
        VectorStore {
            storage,
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
                deferred_pending_records: Vec::new(),
                deferred_pending_limit,
                // Float indices are built lazily per modelID on first
                // find_nearest_float; the map starts empty.
                float_indices: std::collections::HashMap::new(),
                sidecar_rebuild_count: 0,
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
                           deferred_pending_limit)
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
    pub fn open(storage: Arc<dyn Storage>) -> Result<Self, VectorKitError> {
        let schema = Self::schema_declaration();
        storage
            .open(&schema)
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
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
    /// Telemetry: emits `vectorkit.index.insert_latency_ms` when monitoring
    /// is enabled. Emitted at the operation boundary.
    pub fn add_vector(
        &self,
        item_id: &str,
        engram: &Engram,
        model_id: &str,
        model_version: &str,
        filed_at_unix_secs: i64,
    ) -> Result<(), VectorKitError> {
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
    /// Returns `VectorKitError::Int8QuantizationPolicyUndefined` when the
    /// payload kind is `Int8`. Int8 writes are rejected fail-closed because
    /// the quantization policy (symmetric vs asymmetric, per-vector vs per-dim
    /// scale) has not been ratified. Use `Float32` or `Binary` instead.
    /// See VECTORKIT_SPEC §I-4a.
    ///
    /// Telemetry: emits `vectorkit.index.insert_latency_ms` when monitoring
    /// is enabled. Emitted at the operation boundary.
    pub fn add_payload(
        &self,
        item_id: &str,
        vector_index: u32,
        payload: &VectorPayload,
        model_id: &str,
        model_version: &str,
        filed_at_unix_secs: i64,
    ) -> Result<(), VectorKitError> {
        // PRECONDITION GUARD: int8 writes are rejected fail-closed.
        // The quantization policy (symmetric vs asymmetric, per-vector vs
        // per-dim scale) has not been ratified. Persisting an int8 payload now
        // would lock in undefined dequantization semantics. Use Float32 or the
        // Binary Engram lane. See VECTORKIT_SPEC §I-4a and arch spec §10.3.
        if payload.kind == VectorKind::Int8 {
            return Err(VectorKitError::Int8QuantizationPolicyUndefined(
                "int8 writes are rejected: quantization policy is unspecified. \
                 Use Float32 or the Binary Engram lane. See VECTORKIT_SPEC §I-4a."
                    .to_string(),
            ));
        }

        let start = std::time::Instant::now();

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

        let row_store = self.storage.row_store();
        row_store
            .upsert(
                "vectors",
                values,
                &[
                    "item_id".to_string(),
                    "vector_index".to_string(),
                    "model_id".to_string(),
                ],
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;

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
                VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
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
                VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
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
            tags.insert("kit".to_string(), "VectorKit".to_string());
            tags.insert("model_id".to_string(), model_id_owned.clone());
            StatSample::metric(
                "vectorkit.index.insert_latency_ms".to_string(),
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
    /// (distance ASC, item_id ASC) total order is applied at query time).
    pub fn add_payloads(&self, batch: &[VectorPayloadInput]) -> Result<(), VectorKitError> {
        if batch.is_empty() {
            return Ok(());
        }

        // PRECONDITION GUARD: reject any int8 payload in the batch fail-closed.
        // The quantization policy has not been ratified; a batch containing even
        // one int8 payload must be rejected entirely — no partial writes. The
        // first offending item is reported. See VECTORKIT_SPEC §I-4a.
        if let Some(bad) = batch.iter().find(|i| i.payload.kind == VectorKind::Int8) {
            return Err(VectorKitError::Int8QuantizationPolicyUndefined(format!(
                "int8 writes are rejected: quantization policy is unspecified. \
                 Offending item: {}. \
                 Use Float32 or the Binary Engram lane. See VECTORKIT_SPEC §I-4a.",
                bad.item_id
            )));
        }

        let start = std::time::Instant::now();

        // 1. Upsert every row to the table (durable source of truth). Callers that
        //    write in bulk (the reindex re-embed) wrap this in an OUTER transaction
        //    so the whole batch commits with a single fsync instead of one per row;
        //    add_payloads itself does NOT open a transaction, because the ingest
        //    drain already calls it inside its own open transaction and a nested
        //    BEGIN is an error ("transaction within a transaction").
        let row_store = self.storage.row_store();
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
                .upsert(
                    "vectors",
                    values,
                    &[
                        "item_id".to_string(),
                        "vector_index".to_string(),
                        "model_id".to_string(),
                    ],
                )
                .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        }

        // 2. Mirror binary rows into the resident array + both indexes in one
        //    amortised pass.
        let binary_records: Vec<(VectorRecordKey, Vec<u8>)> = batch
            .iter()
            .filter(|i| i.payload.kind == VectorKind::Binary)
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
                VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
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
                        if live.contains(k) {
                            // Already live (earlier window write or pre-existing)
                            // → replacement, not a new key.
                            replaced.insert(k.clone());
                        } else if !seen_in_batch.contains(k) {
                            new_key_count += 1;
                        }
                        seen_in_batch.insert(k.clone());
                        live.insert(k.clone());
                    }
                    if state.array_store.is_some() {
                        // Sidecar present: stage into the resident array store now.
                        let store = state.array_store.as_mut().unwrap();
                        store.tombstone_deferred(&replaced);
                        store.append_batch(&binary_records)?;
                    } else {
                        // Memory-only: accumulate; publish_resident_index() merges
                        // all pending records into the resident index in one pass.
                        state.deferred_pending_records.extend(binary_records.iter().cloned());
                    }
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
            //    models' indices are untouched.
            for model_id in &float_model_ids {
                state.float_indices.remove(model_id);
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
            tags.insert("kit".to_string(), "VectorKit".to_string());
            tags.insert("batch_size".to_string(), batch_size.to_string());
            StatSample::metric(
                "vectorkit.index.batch_insert_latency_ms".to_string(),
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
    pub fn begin_deferred_index(&self) -> Result<(), VectorKitError> {
        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        if state.deferred_index_active {
            return Ok(());
        }
        self.ensure_index_built_locked(&mut state)?;
        // Seed live keys from the currently-published snapshot so replacement
        // detection across the window is O(batch), not O(N), per call.
        let keys: std::collections::HashSet<VectorRecordKey> = {
            let arr = state.brute_force_index.array();
            (0..arr.count)
                .filter(|&i| !arr.is_tombstoned(i))
                .map(|i| arr.keys[i].clone())
                .collect()
        };
        state.deferred_live_keys = Some(keys);
        state.deferred_pending_records.clear();
        state.deferred_index_dirty = false;
        state.deferred_index_active = true;
        Ok(())
    }

    /// Rebuild the resident MIH + brute-force index once from the final resident
    /// array snapshot, ending deferred-index mode. A no-op rebuild (but still
    /// clears the mode) when nothing was deferred since the last publish. Called
    /// by the corpus ingest drain when a burst drains to empty and by
    /// `await_ingest_drain`. Mirrors Swift `VectorStore.publishResidentIndex()`.
    pub fn publish_resident_index(&self) -> Result<(), VectorKitError> {
        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        let was_dirty = state.deferred_index_dirty;
        state.deferred_index_active = false;
        state.deferred_index_dirty = false;
        state.deferred_live_keys = None;
        let pending = std::mem::take(&mut state.deferred_pending_records);
        if !was_dirty {
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
            Self::merge_batch_into_snapshot(&cur, &Self::dedup_last_wins(pending))
        };
        let (payloads, keys) = Self::array_to_payloads_keys(&snap);
        state.brute_force_index.build(&payloads, &keys)?;
        state.mih_index.build(&payloads, &keys)?;
        // Recompute the live count authoritatively from the final snapshot so any
        // incremental drift over the window is corrected.
        let live = (0..snap.count).filter(|&i| !snap.is_tombstoned(i)).count() as u32;
        state.live_binary_count = live;
        Self::select_index(&mut state);
        Ok(())
    }

    /// Publish any in-flight deferred-index burst before a mutate-against-index
    /// operation (delete) so the resident index reflects every appended vector
    /// before we tombstone against it. No-op when no burst is dirty. Mirrors the
    /// Swift `if deferredIndexDirty { try await publishResidentIndex() }` guard.
    fn publish_if_deferred_dirty(&self) -> Result<(), VectorKitError> {
        let dirty = {
            let state = self.state.lock().map_err(|_| {
                VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
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
    pub fn flush(&self) -> Result<(), VectorKitError> {
        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        if let Some(ref mut store) = state.array_store {
            store.flush()?;
        }
        Ok(())
    }

    /// Collapse duplicate keys in the deferred memory buffer: keep only the last
    /// occurrence of each key, preserving first-seen order of the survivors.
    /// Applied before `merge_batch_into_snapshot` so duplicate keys in a single
    /// deferral window don't produce two live slots. Mirrors Swift `dedupLastWins`.
    fn dedup_last_wins(
        records: Vec<(VectorRecordKey, Vec<u8>)>,
    ) -> Vec<(VectorRecordKey, Vec<u8>)> {
        if records.is_empty() {
            return records;
        }
        let mut last_index: std::collections::HashMap<&VectorRecordKey, usize> =
            std::collections::HashMap::with_capacity(records.len());
        for (i, (k, _)) in records.iter().enumerate() {
            last_index.insert(k, i);
        }
        // Collect the indices to keep (last occurrence per key), in order.
        let keep: Vec<bool> = records
            .iter()
            .enumerate()
            .map(|(i, (k, _))| last_index.get(k) == Some(&i))
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
    fn flush_deferred_pending(state: &mut HotState) -> Result<(), VectorKitError> {
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
        let mut live_keys = std::collections::HashSet::new();
        for i in 0..merged.count {
            if !merged.is_tombstoned(i) {
                live_count += 1;
                live_keys.insert(merged.keys[i].clone());
            }
        }
        state.live_binary_count = live_count;
        // Replace the deferred live key set so the next batch's replacement
        // detection is based on what is actually in the rebuilt snapshot.
        state.deferred_live_keys = Some(live_keys);
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
    ) -> Result<Option<Engram>, VectorKitError> {
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
    ) -> Result<Option<VectorPayload>, VectorKitError> {
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
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        match rows.first() {
            None => Ok(None),
            Some(row) => decode_payload(row).map(Some),
        }
    }

    /// Return every row for `item_id`, ordered by `filed_at` ASC.
    pub fn vectors_for_item(
        &self,
        item_id: &str,
    ) -> Result<Vec<StoredVector>, VectorKitError> {
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
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
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
    /// Returns up to `k` matches sorted by (distance ASC, item_id ASC)
    /// — the universal tie-break rule (retrieval algorithms reference §0.3).
    ///
    /// Telemetry: emits `vectorkit.search.latency_ms` and
    /// `vectorkit.search.result_count` when monitoring is enabled.
    pub fn find_nearest(
        &self,
        probe: &Engram,
        model_id: &str,
        k: usize,
    ) -> Result<Vec<VectorMatch>, VectorKitError> {
        if k == 0 {
            return Ok(Vec::new());
        }
        let start = std::time::Instant::now();

        // Populate the resident index on first call (amortised, not per-query).
        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
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
        let hits = if state.is_mih_active {
            state.mih_index.search(&probe_payload, DenseMetric::HAMMING, k, Some(&filter))?
        } else {
            state.brute_force_index.search(&probe_payload, DenseMetric::HAMMING, k, Some(&filter))?
        };

        // Map DenseHit → VectorMatch. BruteForceIndex already enforces
        // (distance ASC, item_id ASC) per the oracle contract (§0.3).
        let result: Vec<VectorMatch> = hits
            .into_iter()
            .map(|h| VectorMatch {
                item_id: h.key.item_id.clone(),
                distance: h.raw_distance,
                model_id: model_id.to_string(),
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
            tags.insert("kit".to_string(), "VectorKit".to_string());
            tags.insert("model_id".to_string(), model_id_owned.clone());
            StatSample::metric("vectorkit.search.latency_ms".to_string(), elapsed_ms, tags.clone(), ts)
        });
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "VectorKit".to_string());
            tags.insert("model_id".to_string(), model_id_owned.clone());
            StatSample::metric("vectorkit.search.result_count".to_string(), result_count as f64, tags, ts)
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
    /// float NN search scans the SQLite `vectors` table directly.
    /// No FloatBruteForceIndex, no cached ResidentVectorArray, no multi-GB
    /// heap copy. With PRAGMA mmap_size, row reads come from the OS page
    /// cache. Cosine distance is computed per row; the result set is sorted
    /// and truncated to k.
    pub fn find_nearest_float(
        &self,
        probe: &[f32],
        model_id: &str,
        k: usize,
    ) -> Result<Vec<VectorMatch>, VectorKitError> {
        if k == 0 || probe.is_empty() {
            return Ok(Vec::new());
        }
        // float_scan_from_table returns the k nearest, ordered best-first.
        let scored = self.float_scan_from_table(probe, model_id, k, true)?;
        Ok(scored.into_iter().map(|(dist, item_id)| VectorMatch {
            item_id,
            distance: (dist * 10_000.0).round() as i32,
            model_id: model_id.to_string(),
        }).collect())
    }

    /// k-FARTHEST neighbours over the float32 (Lane D) vectors by cosine —
    /// the most DISSIMILAR rows first (anti-similarity retrieval, mission
    /// 6b-modifiers-antisim). Parallel to Swift `VectorStore.findFarthestFloat`.
    ///
    /// Identical to `find_nearest_float` in every respect — same lazy per-model
    /// index build, same model_id partition scope (spec I-4), same cosine
    /// metric, same VectorMatch quantisation — EXCEPT it ranks by FARTHEST
    /// (bottom-K by cosine similarity = largest cosine distance first) via
    /// `FloatBruteForceIndex::search_farthest`. It is NOT a negated
    /// nearest-list: the farthest rows are not in the nearest top-K, so the
    /// index orders by the opposite end. No new distance math.
    ///
    /// Determinism: like `find_nearest_float`, the float lane is reproducible-
    /// within-config, NOT four-way bit-identical (arch spec §6).
    ///
    /// Returns up to `k` matches, FARTHEST (most dissimilar) first. Empty if
    /// `k` is 0, the probe is empty, or no float rows exist for the model.
    pub fn find_farthest_float(
        &self,
        probe: &[f32],
        model_id: &str,
        k: usize,
    ) -> Result<Vec<VectorMatch>, VectorKitError> {
        if k == 0 || probe.is_empty() {
            return Ok(Vec::new());
        }
        // float_scan_from_table returns the k farthest, ordered best-first.
        let scored = self.float_scan_from_table(probe, model_id, k, false)?;
        Ok(scored.into_iter().map(|(dist, item_id)| VectorMatch {
            item_id,
            distance: (dist * 10_000.0).round() as i32,
            model_id: model_id.to_string(),
        }).collect())
    }

    /// Coarse keyword pre-filter: returns distinct item IDs whose
    /// `item_id` contains the query as a substring. Full BM25 lives in
    /// CorpusKit.
    pub fn find_by_keyword(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<String>, VectorKitError> {
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
        let predicate = StoragePredicate::Like(Column::new("vectors", "item_id"), pattern);
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
                .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
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
            tags.insert("kit".to_string(), "VectorKit".to_string());
            StatSample::metric(
                "vectorkit.search.keyword_result_count".to_string(),
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
    pub fn destroy_all_vectors(&self) -> Result<(), VectorKitError> {
        self.storage
            .row_store()
            .delete("vectors", &StoragePredicate::IsTrue)
            .map_err(|e| VectorKitError::StoreUnavailable(format!("destroy_all_vectors failed: {e}")))?;

        // Reset both indexes and live count to empty. The table is now empty.
        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
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
        // Reset the Lane D float indices — every float row was just deleted, so
        // every per-modelID resident float array must be cleared. Dropping all
        // map entries clears every model's index; each rebuilds lazily (and
        // empty) on the next find_nearest_float for that model.
        state.float_indices.clear();
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
    pub fn recent_item_ids(&self, limit: usize) -> Result<Vec<String>, VectorKitError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let order = vec![
            OrderClause::new(Column::new("vectors", "filed_at"), OrderDirection::Descending),
            OrderClause::new(Column::new("vectors", "item_id"), OrderDirection::Ascending),
        ];
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
                    None,
                    &order,
                    Some(PAGE_SIZE),
                    Some(offset),
                )
                .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
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
    ) -> Result<(), VectorKitError> {
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
    ) -> Result<(), VectorKitError> {
        self.publish_if_deferred_dirty()?;
        self.delete_and_tombstone(item_id, vector_index, model_id)
    }

    /// Delete all rows for `(item_id, model_id)` regardless of vector_index.
    pub fn delete_all_vectors(
        &self,
        item_id: &str,
        model_id: &str,
    ) -> Result<(), VectorKitError> {
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
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;

        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        // The deletion may have removed float32 rows for this modelID.
        // Invalidate THIS model's Lane D index so the next find_nearest_float
        // rebuilds from the table (the authoritative source). The delete carries
        // no kind, so a lazy rebuild is the correct coherence path for the float
        // lane. Other models' indices are untouched.
        state.float_indices.remove(model_id);
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
    ) -> Result<(), VectorKitError> {
        // Reject int8 fail-closed — same precondition as add_payloads.
        if let Some(bad) = batch.iter().find(|i| i.payload.kind == VectorKind::Int8) {
            return Err(VectorKitError::Int8QuantizationPolicyUndefined(format!(
                "int8 writes are rejected: quantization policy is unspecified. \
                 Offending item: {}. See VECTORKIT_SPEC §I-4a.",
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
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        let db_result = (|| -> Result<(), VectorKitError> {
            row_store
                .delete(
                    "vectors",
                    &StoragePredicate::Eq(
                        Column::new("vectors", "model_id"),
                        TypedValue::Text(model_id.to_string()),
                    ),
                )
                .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
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
                    .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
            }
            Ok(())
        })();
        match db_result {
            Ok(()) => row_store
                .commit_transaction()
                .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?,
            Err(e) => {
                let _ = row_store.rollback_transaction();
                return Err(e);
            }
        }

        // 2. Rebuild the resident binary index ONCE from the durable table (O(n)),
        //    and drop this model's Lane D float index so it lazily rebuilds too.
        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        state.float_indices.remove(model_id);
        self.rebuild_binary_index_from_table_locked(&mut state)?;
        Ok(())
    }

    /// Rebuild the resident BINARY index (sidecar array + BruteForce + MIH) from
    /// the durable `vectors` table in ONE pass. Used only by the batch re-embed
    /// path. Unlike `ensure_index_built_locked` it does NOT trust the sidecar
    /// live-count (a re-embed replaces every vector with the SAME row count, so a
    /// count check would wrongly keep the stale sidecar) — it always reads the
    /// table. Must be called with the state mutex held.
    fn rebuild_binary_index_from_table_locked(
        &self,
        state: &mut HotState,
    ) -> Result<(), VectorKitError> {
        let records = self.fetch_all_binary_records()?;
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
    pub fn delete_vectors(&self, keys: &[VectorExactKey]) -> Result<(), VectorKitError> {
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
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        let db_result = (|| -> Result<(), VectorKitError> {
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
                    .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
            }
            Ok(())
        })();
        match db_result {
            Ok(()) => row_store
                .commit_transaction()
                .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?,
            Err(e) => {
                let _ = row_store.rollback_transaction();
                return Err(e);
            }
        }

        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        // Lane D coherence: drop ONLY the touched models' cached float
        // indices; other models' float indices are untouched.
        for model_id in key_set
            .iter()
            .map(|k| k.model_id.as_str())
            .collect::<std::collections::BTreeSet<_>>()
        {
            state.float_indices.remove(model_id);
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
    ) -> Result<(usize, usize), VectorKitError> {
        if let Some(bad) = expected.iter().find(|i| i.payload.kind == VectorKind::Int8) {
            return Err(VectorKitError::Int8QuantizationPolicyUndefined(format!(
                "int8 writes are rejected: quantization policy is unspecified. \
                 reconcile_model_vectors received an int8 payload for item {}",
                bad.item_id
            )));
        }
        if let Some(stray) = expected.iter().find(|i| i.model_id != model_id) {
            return Err(VectorKitError::InvalidPayload(format!(
                "reconcile_model_vectors(model_id: {model_id}) received an input for \
                 model {} — cross-partition writes are not permitted",
                stray.model_id
            )));
        }
        self.publish_if_deferred_dirty()?;

        // Enumerate the model's existing logical keys from the durable table.
        let row_store = self.storage.row_store();
        let existing_rows = row_store
            .query(
                "vectors",
                Some(&StoragePredicate::Eq(
                    Column::new("vectors", "model_id"),
                    TypedValue::Text(model_id.to_string()),
                )),
                &[],
                None,
                None,
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
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

        // One transaction: delete exactly the stale keys, upsert the expected
        // rows. Other models' rows are never addressed.
        row_store
            .begin_transaction()
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        let db_result = (|| -> Result<(), VectorKitError> {
            for key in &stale_keys {
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
                    .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
            }
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
                row_store
                    .upsert(
                        "vectors",
                        values,
                        &[
                            "item_id".to_string(),
                            "vector_index".to_string(),
                            "model_id".to_string(),
                        ],
                    )
                    .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
            }
            Ok(())
        })();
        match db_result {
            Ok(()) => row_store
                .commit_transaction()
                .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?,
            Err(e) => {
                let _ = row_store.rollback_transaction();
                return Err(e);
            }
        }

        // Coherence: this model's float index lazily rebuilds from the table;
        // the resident binary index is rebuilt once from the table.
        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        state.float_indices.remove(model_id);
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
    ) -> Result<(), VectorKitError> {
        if state.index_built {
            return Ok(());
        }

        if let Some(ref mut store) = state.array_store {
            // Attempt to load from the on-disk sidecar.
            let _ = store.load(); // non-fatal: empty start on failure

            let snap = store.snapshot();
            let table_count = self.binary_row_count()?;

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
                // Stale sidecar: rebuild from the table.
                state.sidecar_rebuild_count += 1;
                let records = self.fetch_all_binary_records()?;
                state.live_binary_count = records.len() as u32;
                let store_ref = state.array_store.as_mut().unwrap();
                store_ref.rebuild_from(&records)?;
                let rebuilt = store_ref.snapshot();
                let (payloads, keys) = Self::array_to_payloads_keys(&rebuilt);
                state.brute_force_index.build(&payloads, &keys)?;
                state.mih_index.build(&payloads, &keys)?;
            }
        } else {
            // No sidecar: build the array in memory from the table.
            let records = self.fetch_all_binary_records()?;
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
    fn float_scan_from_table(
        &self,
        probe: &[f32],
        model_id: &str,
        k: usize,
        nearest: bool,
    ) -> Result<Vec<(f32, String)>, VectorKitError> {
        let records = self.fetch_float_records(model_id)?;
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
            // Cosine distance: 1 − dot(a,b)/(‖a‖·‖b‖).
            let mut dot: f32 = 0.0;
            let mut norm_a: f32 = 0.0;
            let mut norm_b: f32 = 0.0;
            for j in 0..dim {
                dot += probe[j] * candidate[j];
                norm_a += probe[j] * probe[j];
                norm_b += candidate[j] * candidate[j];
            }
            let denom = norm_a.sqrt() * norm_b.sqrt();
            let dist = if denom > 0.0 {
                1.0 - (dot / denom).clamp(-1.0, 1.0)
            } else {
                1.0
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

    fn ensure_float_index_built_locked(
        &self,
        state: &mut HotState,
        model_id: &str,
    ) -> Result<bool, VectorKitError> {
        if state.float_indices.contains_key(model_id) {
            return Ok(true);
        }
        let records = self.fetch_float_records(model_id)?;
        if records.is_empty() {
            // No float rows for this model — do NOT cache an empty index: a
            // later ingest of this model's first float row must be able to build
            // a real index on the next search.
            return Ok(false);
        }
        let payloads: Vec<VectorPayload> = records.iter().map(|(_, p)| p.clone()).collect();
        let keys: Vec<VectorRecordKey> = records.into_iter().map(|(k, _)| k).collect();
        let mut index = FloatBruteForceIndex::new();
        index.build(&payloads, &keys)?;
        state.float_indices.insert(model_id.to_string(), index);
        Ok(true)
    }

    /// Fetch the float32 rows for ONE modelID from the `vectors` table, sorted
    /// by VectorRecordKey natural order (arch spec §4.2: deterministic partition
    /// index, so the cross-language scan order matches). Scoping the fetch to a
    /// single modelID guarantees a uniform stride (one dimension per model), so
    /// the resulting FloatBruteForceIndex never mixes dimensions across models
    /// (mission 6a-iii-core).
    fn fetch_float_records(
        &self,
        model_id: &str,
    ) -> Result<Vec<(VectorRecordKey, VectorPayload)>, VectorKitError> {
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
                ])),
                &[],
                None,
                None,
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;

        // disk-default storage residency string interning: model_id and model_version repeat for
        // every row in a partition. Interning collapses N identical String
        // heap allocations to one shared instance per unique value.
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

    /// Count binary rows in the `vectors` table.
    ///
    /// Used by `ensure_index_built_locked` to detect a stale sidecar.
    fn binary_row_count(&self) -> Result<usize, VectorKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "vectors",
                Some(&StoragePredicate::Eq(
                    Column::new("vectors", "kind"),
                    TypedValue::Int(VectorKind::Binary.raw()),
                )),
                &[],
                None,
                None,
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.len())
    }

    /// Fetch all binary rows from the `vectors` table once, sorted by
    /// VectorRecordKey natural order.
    ///
    /// Called only when the sidecar is absent or stale — once per process
    /// lifetime in the normal path.
    fn fetch_all_binary_records(
        &self,
    ) -> Result<Vec<(VectorRecordKey, Vec<u8>)>, VectorKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "vectors",
                Some(&StoragePredicate::Eq(
                    Column::new("vectors", "kind"),
                    TypedValue::Int(VectorKind::Binary.raw()),
                )),
                &[],
                None,
                None,
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;

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
    ) -> Result<(), VectorKitError> {
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
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;

        let mut state = self.state.lock().map_err(|_| {
            VectorKitError::StoreUnavailable("VectorStore: index mutex poisoned".into())
        })?;
        // The deleted row may have been a float32 vector for this modelID.
        // Invalidate THIS model's Lane D index so the next find_nearest_float
        // rebuilds from the table. Other models' indices are untouched.
        state.float_indices.remove(model_id);
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
/// See VECTORKIT_SPEC §I-4a.
fn decode_payload(
    row: &persistence_kit::StorageRow,
) -> Result<VectorPayload, VectorKitError> {
    let kind_raw = match row.get("kind") {
        Some(TypedValue::Int(v)) => *v,
        _ => return Err(VectorKitError::DecodingFailure("missing kind column".to_string())),
    };
    let kind = VectorKind::from_raw(kind_raw)
        .ok_or_else(|| VectorKitError::DecodingFailure(format!("unknown VectorKind {kind_raw}")))?;
    // Symmetric read-side guard: int8 payloads cannot be decoded until the
    // quantization policy is ratified. Propagates as an Err to callers.
    // `vectors_for_item` skips the row; `get_payload` surfaces the error
    // directly. Prevents silent consumption of hand-crafted int8 rows.
    if kind == VectorKind::Int8 {
        return Err(VectorKitError::Int8QuantizationPolicyUndefined(
            "int8 rows cannot be decoded: quantization policy is unspecified. \
             See VECTORKIT_SPEC §I-4a."
                .to_string(),
        ));
    }
    let dim = match row.get("dim") {
        Some(TypedValue::Int(v)) => *v as u32,
        _ => return Err(VectorKitError::DecodingFailure("missing dim column".to_string())),
    };
    let bytes = match row.get("payload") {
        Some(TypedValue::Blob(b)) => b.clone(),
        _ => return Err(VectorKitError::DecodingFailure("missing payload column".to_string())),
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
) -> Result<Option<StoredVector>, VectorKitError> {
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
    Ok(Some(StoredVector {
        id,
        item_id,
        vector_index,
        model_id,
        model_version,
        engram,
        filed_at,
    }))
}

/// Lightweight decode: extract only (VectorRecordKey, bytes) from a row.
///
/// Used by `fetch_all_binary_records` to build the resident array. Does
/// not attempt to decode the Engram — just extracts the raw bytes from the
/// `payload` column and the key fields. Only processes Binary rows.
fn decode_stored_vector_light(
    row: &persistence_kit::StorageRow,
) -> Result<Option<(VectorRecordKey, Vec<u8>)>, VectorKitError> {
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
