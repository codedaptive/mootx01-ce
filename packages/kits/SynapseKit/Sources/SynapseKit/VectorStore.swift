// VectorStore.swift
//
// Storage layer for SynapseKit, backed by PersistenceKit.
//
// Schema (version 5, adds hnsw_graph table for the approximate NN index):
// ```
// vectors (
//   id             UUID PRIMARY KEY,
//   item_id        TEXT NOT NULL,      -- the owning item (drawer/chunk UUID)
//   vector_index   INTEGER NOT NULL DEFAULT 0,  -- multi-vector: 0 for single-vector
//   model_id       TEXT NOT NULL,
//   model_version  TEXT NOT NULL,
//   kind           INTEGER NOT NULL DEFAULT 0,  -- VectorKind raw value (0=binary)
//   dim            INTEGER NOT NULL DEFAULT 256,
//   payload        BLOB NOT NULL,               -- 32 bytes for binary; dim*4 for float32
//   scale          REAL,                        -- int8 dequant scale; NULL otherwise
//   filed_at       TIMESTAMP NOT NULL,
//   ext            TEXT                         -- nullable entity ext slots JSON extension slot
// )
// UNIQUE(item_id, vector_index, model_id)
// INDEX(model_id, item_id)
// INDEX(filed_at, item_id)   -- v4: covers recentItemIDs ORDER BY filed_at DESC, item_id ASC
//
// hnsw_graph (v5 addition — device-local, never in ConvergenceKit sync manifests):
// ```
// hnsw_graph (
//   model_id       TEXT NOT NULL,     -- which modelID partition this node belongs to
//   node_idx       INTEGER NOT NULL,  -- sequential Int32 node index within this partition
//   node_id        TEXT NOT NULL,     -- item_id of the originating VectorRecordKey
//   layer          INTEGER NOT NULL,  -- HNSW graph layer (0 = densest)
//   neighbours     BLOB NOT NULL      -- packed Int32 array of neighbour node_idx values
// )
// PRIMARY KEY (model_id, node_idx, layer)
// ```
//
// Refactored 2026-05-19 (mission 6) per
// current kit ownership section 4.6: replaced
// direct SQLite I/O with PersistenceKit's RowStore + BlobStore
// protocols. Dense-embedding k-NN is SynapseKit's own concern (SynapseKit-owned vector search
// persistencekit-vector-contract-correction); PersistenceKit backends
// (SQLite, PostgreSQL, InMemory) only accommodate vector storage.
// Backends are selected at the application layer via EstateConfiguration.
//
// VECTORKIT_REPORT_001 (2026-06-06): added IntellectusLib self-report
// telemetry to addVector, findNearest, and findByKeyword. The emit calls
// are placed at operation boundaries, after the result is computed, so
// the mathematical behavior is unchanged. When monitoring is disabled
// (the default), the Intellectus.report(_:) call short-circuits after
// a single Atomic<Bool> load; the startTime clock read is the only
// unconditional overhead added per operation.
//
// HOT-PATH WIRING: findNearest now scans a resident ResidentVectorArray
// via a DenseIndex (BruteForceIndex or MIHIndex) instead of issuing an
// O(N) full-table SQLite fetch on every query. The `vectors` table remains
// the durable source of truth. On first use, the resident array is populated
// once (from the .vec sidecar when a sidecarURL is supplied, or from a single
// table read). Every write keeps both the table and the resident array in sync.
//
// INDEX SELECTION POLICY (arch spec §3.2):
//   Below `mihThreshold` live binary vectors:  BruteForceIndex (Lane A).
//     → O(N) resident-array scan, ~0.41 ms at 10k, always sub-millisecond.
//   At/above `mihThreshold` live binary vectors: MIHIndex (Lane B).
//     → Sub-linear EXACT Hamming KNN; same results as brute-force, bit-for-bit.
//
// Both indexes are EXACT. The Lane B conformance gate (MIHIndexTests)
// proves MIHIndex == BruteForceIndex on every input. findNearest results
// are IDENTICAL regardless of which index is active — the only difference
// is query latency at large N.
//
// Default threshold: 50_000 binary vectors. Rationale (arch spec §3.2 /
// §1.6): a brute-force resident scan is bandwidth-bound at ~500µs per 1M
// vectors (cookbook §8.2), so at 50k it costs ~25µs — raw scan latency is
// NOT what the threshold protects. MIH wins on per-query candidate-set
// reduction and cache pressure, which grow linearly for brute force while
// MIH probes stay near-constant above this scale. At 50k,
// log2(50000) ≈ 15.6, so m=16 (sub_bits=16) gives expected bucket fill
// ≈ 50000/65536 ≈ 0.76 — right at the sub-linear sweet spot. The threshold
// is overridable on init for callers that measure different estate sizes.
//
// I-7 satisfied: both BruteForceIndex and MIHIndex delegate ALL Hamming
// arithmetic to EngramLib → SubstrateKernel (four-way conformance-gated).

import EngramLib
import Foundation
import MootProductIdentity
import IntellectusLib
import OSLog
import PersistenceKit

/// Logical position key for resident-array slot matching.
///
/// The resident binary array can accumulate multiple slots for the same
/// logical position (itemID, vectorIndex, modelID) when modelVersion changes
/// across upserts: the table's UNIQUE constraint (item_id, vector_index,
/// model_id) collapses to one row, but the in-memory array retains a slot
/// per unique VectorRecordKey — which includes modelVersion. Using logical
/// position rather than full VectorRecordKey equality allows replacement
/// detection and deletion to cover stale modelVersion slots.
/// (secfix/ws2-coredelete: hard-delete destruction contract)
struct VKLogicalPos: Hashable {
    let itemID: String
    let vectorIndex: UInt32
    let modelID: String
}

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

/// Storage for model-tagged vectors. Wraps a PersistenceKit Storage
/// instance; the kit does not see backend selection.
///
/// Concurrency: VectorStore is an actor. RowStore calls are async;
/// the public API mirrors PersistenceKit's async surface.
///
/// Schema version 3: current production schema. Version 2 added
/// multi-vector support, `item_id`, `vector_index`, `kind`, `dim`,
/// `scale`, and `payload`; version 3 added the `ext` JSON slot per
/// nullable entity ext slots.
///
/// Hot-path: findNearest dispatches through a DenseIndex seam. Below
/// `mihThreshold` binary vectors the active index is BruteForceIndex
/// (Lane A, always sub-millisecond). At/above the threshold the active
/// index is MIHIndex (Lane B, sub-linear EXACT). Both indexes produce
/// IDENTICAL results — the Lane B conformance gate proves this. The
/// array is built once and kept in sync with every write. No per-query
/// table fetch. All Hamming arithmetic routes through EngramLib →
/// SubstrateKernel (I-7 absolute, arch spec §3.4).
///
/// Telemetry: emits `synapsekit.*` metrics via IntellectusLib when
/// monitoring is enabled. Off by default; the emit call is a
/// short-circuited no-op (single Atomic<Bool> load) when disabled.
public actor VectorStore {

    private let log = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "SynapseKit.VectorStore")
    let storage: any Storage

    // MARK: - Resident hot-path scan structures

    /// Sidecar-backed persistent store for the packed resident array.
    ///
    /// Present when the caller supplies a sidecarURL at init. When nil,
    /// the resident array is held purely in memory (rebuilt from the table
    /// on first use; not persisted between process restarts). Either way,
    /// the active DenseIndex scans the same array format — the sidecar is
    /// an optimisation for warm restart latency, not a correctness requirement.
    private let arrayStore: ResidentArrayStore?

    /// Live binary vector count across all model partitions.
    ///
    /// Maintained by addPayload (increment) and _deleteAndTombstone /
    /// deleteAllVectors / destroyAllVectors (decrement). Used by
    /// _selectIndex to decide whether to promote to MIH or demote to
    /// brute-force after each write. Actor-serialised; no concurrent
    /// path touches this without holding the actor boundary.
    /// Actor-local transient state (not persisted to SQLite) — a stored
    /// Int is appropriate here; the no-Bool rule applies to entity fields.
    private var liveBinaryCount: UInt32 = 0

    /// Threshold for index promotion (default: 50_000 binary vectors).
    ///
    /// Below this count: BruteForceIndex is active (Lane A, O(N) scan,
    /// always sub-ms at small N). At/above: MIHIndex is built and active
    /// (Lane B, sub-linear exact). Overridable at init for callers with
    /// different estate-size characteristics or test scenarios that must
    /// cross the threshold with a small corpus.
    ///
    /// Not persisted — the selection is re-derived from the live count on
    /// each mutation and at index-build time.
    public let mihThreshold: UInt32

    /// Band count for MIHIndex when active.
    ///
    /// m=16 (sub_bits=16) targets the 50k default threshold per §1.6:
    /// at 50k, log2(50000)≈15.6 ≈ 16. Callers may specify a different
    /// m at init if they override the threshold.
    private let mihBandCount: MIHBandCount

    // MARK: - Active index (DenseIndex seam)
    //
    // The active index is always one of:
    //   • bruteForceIndex  (lane A)  — when liveBinaryCount < mihThreshold
    //   • mihIndex         (lane B)  — when liveBinaryCount >= mihThreshold
    //
    // Both are kept alive; only one is the hotIndex at any given time.
    // This avoids allocating a new actor on every threshold crossing.

    /// Lane A: the brute-force oracle. Always correct; used as the
    /// conformance reference and as the active index below the threshold.
    private let bruteForceIndex: BruteForceIndex

    /// Lane B: Multi-Index Hashing, sub-linear EXACT Hamming k-NN.
    /// Activated when liveBinaryCount reaches mihThreshold.
    private let mihIndex: MIHIndex

    /// The currently active DenseIndex. Swapped by _selectIndex when the
    /// liveBinaryCount crosses the threshold boundary.
    ///
    /// Declared as `any DenseIndex` so both actor types fit without a
    /// type-erasing wrapper. The concrete index is the actor itself —
    /// no boxing overhead beyond the existential metadata.
    private var hotIndex: any DenseIndex

    /// True once the resident array has been loaded into the active index.
    ///
    /// Set by _ensureIndexBuilt() on the first findNearest or write call.
    /// Actor-serialised — a Bool is appropriate for actor-local control state.
    private var indexBuilt: Bool = false

    /// Deferred-index (bulk-write) mode. While active, `addPayloads` appends to
    /// the durable `vectors` table and the resident array but SKIPS the resident
    /// MIH + brute-force index rebuild; `publishResidentIndex()` performs a single
    /// rebuild at the end of the burst. This turns a bulk import from O(N²) — a
    /// full rebuild over the whole accumulated snapshot on every write — into
    /// O(N): one rebuild after the last write. Activated by `beginDeferredIndex()`
    /// (the corpus ingest drain wraps a drain burst); the immediate per-write
    /// rebuild remains the default for single captures and every direct caller.
    private var deferredIndexActive: Bool = false

    /// True when at least one deferred `addPayloads` has appended since the last
    /// publish. Gates `publishResidentIndex()` so the publish is a no-op when
    /// nothing was deferred (the drain barrier may fire on an idle corpus).
    private var deferredIndexDirty: Bool = false

    /// Live full keys grouped by the schema's logical UNIQUE position. Grouping
    /// by `(itemID, vectorIndex, modelID)` is essential: a model-version change
    /// replaces the durable row and must also remove the old-version resident
    /// slot. Seeded from the published snapshot by `beginDeferredIndex()`.
    private var deferredLiveKeys: [VKLogicalPos: Set<VectorRecordKey>]? = nil

    /// Full keys superseded during the current window. Needed when a model
    /// version changes at the same logical position and the small-delta
    /// publisher updates the resident indexes incrementally.
    private var deferredReplacedKeys: Set<VectorRecordKey> = []

    /// Memory-only deferral buffer. With NO sidecar `arrayStore`, deferred
    /// `addPayloads` calls accumulate their binary records here (an O(batch)
    /// append) and `publishResidentIndex()` merges them all into the resident
    /// index in ONE pass at burst end — so a bulk import that spans several drain
    /// passes pays one rebuild, not one per pass. (With a sidecar the records go
    /// to the array store instead and this stays empty.) The persistent path is
    /// the natural home for a sidecar; until one is wired, the resident array is
    /// memory-only, so deferral lives here too.
    ///
    /// Bound: capped at `deferredPendingLimit` records. When a `addPayloads` call
    /// in deferred memory-only mode would push the buffer past the cap, an
    /// intermediate flush (`_flushDeferredPending()`) merges the accumulated
    /// records into the resident index and clears the buffer before continuing.
    /// This bounds peak RAM use during a long burst and prevents DoS / OOM when
    /// callers hold the deferred window open indefinitely.
    /// (secfix/punt-vector: unbounded deferred buffer fix)
    private var deferredPendingRecords: [(key: VectorRecordKey, bytes: [UInt8])] = []

    /// Small bursts update both resident indexes incrementally. A periodic
    /// full materialization compacts BruteForce tombstones and bounds overlay
    /// history without making every single-Drawer capture O(estate).
    private static let incrementalPublishLimit = 256
    private static let incrementalCompactionInterval = 1_024
    private var incrementalPublicationCount = 0

    /// Maximum number of records that `deferredPendingRecords` may hold before
    /// an intermediate flush is triggered (memory-only deferred path only).
    ///
    /// Default is 50_000 — matches the default MIH threshold; at this scale
    /// the resident array justifies a rebuild and the buffer's RAM footprint
    /// (~50k × (key + 32 bytes) ≈ ~6 MB) is bounded to a safe level.
    /// Configurable at init time (via `deferredPendingLimit:` parameter) so
    /// tests can set a small value to exercise the flush path quickly without
    /// flooding the index with production-scale record counts.
    private let deferredPendingLimit: Int

    // MARK: - Float lane (Lane D) resident scan

    /// Lane D: the in-house exact float indices (FloatBruteForceIndex), ONE PER
    /// modelID, over the float32 rows in the `vectors` table. Production exact
    /// path per Bob's storage amendment (2026-06-12): floats live in resident
    /// float arrays scanned by FloatBruteForceIndex — no external engine.
    ///
    /// ## Why per-modelID (mission 6a-iii-core)
    ///
    /// FloatBruteForceIndex requires a SINGLE stride (one dimension) per index,
    /// and `search` throws `invalidPayload` when the probe dimension does not
    /// match the array stride. Different models emit different float dimensions
    /// (RI/PPMI high-dim, FDC its own dim, MiniLM 384, …). With an N-provider
    /// corpus the `vectors` table holds float rows for several models at once,
    /// so a SINGLE shared index built from the first record's stride would be
    /// corrupt for every other model and throw on query. Spec I-4 already keeps
    /// models on disjoint partitions and forbids cross-model comparison, so the
    /// correct structure is one index per modelID: each is built from that
    /// model's rows only (uniform stride) and scanned in isolation. For a
    /// single-model corpus the map holds exactly one entry — byte-identical
    /// behaviour to the prior single shared index.
    ///
    /// The float lane is reproducible-within-config, NOT four-way bit-identical
    /// (arch spec §6) — distinct from the binary Hamming lane's four-way
    /// determinism. It is therefore kept on its own indices, separate from
    /// bruteForceIndex/mihIndex (which are binary-only, I-7).
    ///
    /// Built lazily per modelID on the first `findNearestFloat` for that model;
    /// the entry's presence in the map is the "built" flag (no separate bool).
    var floatIndices: [String: FloatBruteForceIndex] = [:]

    /// HNSW approximate nearest-neighbour index per modelID (Lane D, float lane).
    ///
    /// One HNSWIndex per modelID partition, activated when the live float count
    /// for that model reaches `hnswThreshold`. Loaded from the `hnsw_graph` table
    /// on the first qualifying query (via `_loadHNSWGraphIfPresent`); built via
    /// `rebuildHNSWIndex` (THETA cadence); cleared by `clearAllHNSWIndices`.
    /// Updated incrementally on the encode path when a graph is already in memory.
    ///
    /// Search through this index is APPROXIMATE; `FloatBruteForceIndex` is the
    /// exact oracle and is always kept for farthest queries and recall validation.
    /// Above the threshold, nearest queries route through HNSW (sub-linear);
    /// below it, nearest queries use `FloatBruteForceIndex` (exact, O(N)).
    private var hnswIndices: [String: HNSWIndex] = [:]

    /// Number of times an HNSW graph was rebuilt from float vector records (not loaded from rows).
    ///
    /// Incremented by `rebuildHNSWIndex(for:)`. NOT incremented when the graph is
    /// loaded from `hnsw_graph` rows via `_loadHNSWGraphIfPresent`. Used by
    /// persistence tests (HP-1/HP-2) to assert that a reopen serves from stored
    /// rows without triggering a rebuild. Exposed at `internal` visibility so tests
    /// can read it via `@testable import`.
    internal private(set) var hnswBuildCount: [String: Int] = [:]

    /// modelID partitions whose in-memory HNSW graph has been modified since the
    /// last `flush()`. Encode-path inserts mark the partition dirty; `flush()`
    /// persists dirty partitions to the `hnsw_graph` table and clears the set.
    private var hnswGraphDirty: Set<String> = []

    /// Live float vector count per modelID partition.
    ///
    /// Initialised from the record count when `floatIndices[modelID]` is first
    /// built; incremented by `addPayload` for each successful float32 insert
    /// on an already-built partition. Used by `_findNearestFloatCached` to
    /// decide when to activate the HNSW index. An actor-local transient count
    /// (not persisted; rebuilt from the table count at first-access time).
    var liveFloatCounts: [String: UInt32] = [:]

    // MARK: - Shadow-swap generation state

    /// Per-model serving generation cached from the vector_generations table.
    /// Loaded on demand; evicted on publishShadowGeneration so the next read
    /// re-fetches. Absent key ⇒ serving generation 0 (no swap ever run).
    private var servingGenerations: [String: Int64] = [:]

    /// Per-model active shadow generation. Set by beginShadowGeneration;
    /// cleared by publishShadowGeneration. Absent key ⇒ no shadow active.
    private var shadowGenerations: [String: Int64] = [:]

    /// Per-model shadow state text ('building' or 'pending-reclaim').
    /// Mirrors the vector_generations.shadow_state column; kept in sync on
    /// every begin/publish/reclaim call.
    private var shadowStates: [String: String] = [:]

    /// Per-model generation of the last graph instance that answered a float
    /// nearest query. Written at query time from graph.generation; read via
    /// lastServedGraphGeneration(for:). Used by Gate 5 to verify the swap
    /// promoted the graph to the new serving generation before the query.
    private var lastServedGraphGen: [String: Int64] = [:]

    /// Running total of shadow-vector payload bytes written during the current
    /// (or most recent completed) beginShadowGeneration window per model.
    /// Reset on beginShadowGeneration; finalised on publishShadowGeneration.
    /// Exposed via peakShadowStorageBytes for test and metrics use.
    private var shadowPayloadBytes: [String: Int64] = [:]

    /// Set of model IDs for which this VectorStore instance has called
    /// beginShadowGeneration and not yet resolved (via publishShadowGeneration
    /// or abandonShadowGeneration). This is the ONLY signal reclaimSuperseded-
    /// Generations uses to determine whether a 'building' shadow is genuinely
    /// in flight or was abandoned by a prior process.
    ///
    /// Critical: do NOT use shadowGenerations for this purpose.
    /// _shadowGeneration(for:) populates shadowGenerations as a side effect
    /// of merely reading the registry, so a non-nil entry no longer means
    /// "opened in this process instance". openShadows is populated ONLY by
    /// beginShadowGeneration — it is not persisted and starts empty each time
    /// the VectorStore is opened.
    private var openShadows: Set<String> = []

    // MARK: - Float-index admission accounting

    /// Projected byte footprints for each currently-resident per-model float
    /// index, keyed by modelID — the same key space as `floatIndices`.
    ///
    /// This is a RECONCILING MAP, not a running counter. At admission time the
    /// map is first reconciled against `floatIndices`: any entry whose modelID
    /// is absent from `floatIndices` (because the index was evicted at one of
    /// the nine clear sites across VectorStore) is dropped in the same pass.
    /// The total is then computed from what remains. This makes ALL existing
    /// clear sites self-correcting with zero edits to any of them — the index
    /// map is the single source of truth and the footprint map always follows it.
    /// A running counter maintained independently would require correct
    /// decrement at every clear site; one missed site drifts the total upward
    /// until every estate is refused indefinitely.
    private var floatIndexFootprints: [String: Int] = [:]

    /// Cumulative count of float-index admission refusals since this
    /// VectorStore was opened. Incremented each time an index build is
    /// skipped because the projected resident set would exceed the ceiling.
    /// Exposed so tests can assert that refusals occurred without inspecting
    /// log output. Twin of Rust `float_index_admission_refusals`.
    private(set) var floatIndexAdmissionRefusalCount: Int = 0

    /// Live float vector count per modelID above which HNSWIndex activates.
    ///
    /// Default `hnswDefaultThreshold` (5 000) — see HNSWIndex.swift §Crossover
    /// for the derivation. Overridable at init time (via `hnswThreshold:`)
    /// so tests can cross the threshold with a small corpus.
    public let hnswThreshold: UInt32

    /// Retained memory pressure source (Apple platforms only). Releasing this
    /// reference would stop future pressure deliveries. The handler creates a
    /// Task that crosses the actor boundary via `await self.evictFloatIndices()`.
    /// `nonisolated(unsafe)` is required because Swift 6 actor init assigns
    /// this after capturing `[weak self]`, placing the write outside the actor's
    /// isolation boundary. The write happens once in `init`; no concurrent
    /// mutation exists, so the `unsafe` annotation is correct here.
    #if canImport(Darwin)
    nonisolated(unsafe) private var memoryPressureSource: (any DispatchSourceProtocol)?
    #endif

    /// True when MIHIndex is the active hot index; false when BruteForceIndex
    /// is active. Tracks the routing decision so _selectIndex can detect
    /// no-op transitions without comparing `any DenseIndex` existentials
    /// (which Swift does not support).
    private var isMIHActive: Bool = false

    /// Number of times the sidecar was detected as stale and rebuilt from
    /// the `vectors` table in the lifetime of this VectorStore instance.
    ///
    /// Incremented by `_ensureIndexBuilt` on each stale-sidecar path. Zero
    /// means the sidecar was current on load (the normal path). Exposed
    /// for test assertions only — callers should not use this value to
    /// drive application logic.
    public private(set) var sidecarRebuildCount: Int = 0

    /// Number of on-disk sidecar writes performed by the resident store in
    /// this VectorStore's lifetime.
    ///
    /// Returns 0 when there is no sidecar (memory-only store). Exposed for
    /// test assertions only — the import-scale regression test asserts a
    /// bulk ingest of N vectors costs O(batches) sidecar writes, not O(N).
    var sidecarWriteCount: Int {
        get async { await arrayStore?.sidecarWriteCount ?? 0 }
    }

    // MARK: - Schema declaration (version 6)

    /// The kit id this store's schema-version ledger row is keyed by. The
    /// single source for `schemaDeclaration.kitID`; `formerKitIDs` lists the
    /// ids that row carried under earlier names of the kit.
    public static let kitID = "SynapseKit"

    /// Kit ids this store's ledger row carried before `kitID`, oldest first.
    /// The vector tier was renamed VectorKit → SynapseKit (the old name
    /// collided with Apple's MapKit VectorKit framework); every populated
    /// estate opened under the old name still keys its ledger row by it.
    /// `prepareSchemaLedger(storage:)` moves such a row to `kitID`, and the
    /// GeniusLocusKit 1.4 → 1.5 capsule reads its pair from here so there is
    /// one source of the rename.
    public static let formerKitIDs: [String] = ["VectorKit"]

    /// Move this store's schema-version ledger row from any id in
    /// `formerKitIDs` to `kitID` before `storage.migrate(to: schemaDeclaration)`.
    ///
    /// SECURITY: an absent ledger row under `kitID` makes `migrate(to:)` treat
    /// a populated estate as version 0 and replay the whole ladder against the
    /// current layout; the v5→v6 step rebuilds `vectors` through a copy table
    /// that folds every row's `generation` to 0 (darkening a swapped estate's
    /// recall) and fails outright when a serving and a shadow row share a key.
    /// Calling this first keeps the ladder from running on a populated estate
    /// that only changed its name. Outcomes per former id: `.renamed` moves
    /// the row (version and applied-at kept); `.noRow` is a fresh estate or
    /// one already carrying the current id, nothing changes; `.conflict`
    /// (rows under both ids) leaves both rows in place, logs one warning
    /// naming both ids and versions, and returns normally — the estate stays
    /// openable, and the following `migrate(to:)` reads the ladder position
    /// from the current-id row, so nothing replays. Same policy as the
    /// GeniusLocusKit 1.4 → 1.5 capsule; the operator resolves the duplicate.
    ///
    /// - Parameter storage: The estate storage the store will open on.
    /// - Throws: `SynapseKitError.storeUnavailable` when the rename call
    ///   itself fails (storage error). A conflicted ledger does not throw.
    public static func prepareSchemaLedger(storage: any Storage) async throws {
        try await SchemaLedgerPreparation.moveFormerRows(
            on: storage, from: formerKitIDs, to: kitID)
    }

    /// Schema declaration consumed by Storage.open(schema:).
    ///
    /// Column changes from v1:
    ///   - `drawer_id` renamed to `item_id`
    ///   - `engram` renamed to `payload` (carries typed vector bytes)
    ///   - Added: `vector_index` INTEGER DEFAULT 0 (multi-vector index)
    ///   - Added: `kind` INTEGER DEFAULT 0 (VectorKind raw value)
    ///   - Added: `dim` INTEGER DEFAULT 256 (vector dimensionality)
    ///   - Added: `scale` REAL nullable (int8 dequant; NULL otherwise)
    ///   UNIQUE constraint: (item_id, vector_index, model_id) — was
    ///   (drawer_id, model_id).
    ///
    /// Column changes from v2 → v3:
    ///   - Added: `ext` JSON nullable — the nullable entity ext slots forward-compat slot.
    ///     Reserves the slot, not a shape; 1.0 writes NULL and never reads it.
    ///
    /// Index changes v3 → v4:
    ///   - Added: `idx_vectors_filed_at_item` on (filed_at, item_id).
    ///     Covers `recentItemIDs` ORDER BY filed_at DESC, item_id ASC so
    ///     SQLite can do an ordered index scan rather than a full-table scan +
    ///     filesort. Before v4 every `recentItemIDs` call on a large estate
    ///
    /// Table additions v4 → v5:
    ///   - Added: `hnsw_graph` table (see file header for column list).
    ///     Schema declaration for the float-lane (Lane D) HNSW graph.
    ///
    /// Schema v5 → v6 (shadow-swap generation support):
    ///   - `vectors` gains `generation INTEGER NOT NULL DEFAULT 0`; UNIQUE
    ///     constraint changes to (item_id, vector_index, model_id, generation).
    ///   - New table `vector_generations` (model_id PK, serving_generation,
    ///     shadow_generation nullable, shadow_state nullable TEXT).
    ///   - `hnsw_graph` gains `generation INTEGER NOT NULL DEFAULT 0`.
    ///   - New index `idx_vectors_model_generation`.
    ///   Rows are written by THETA rebuild, BETA compaction, and incremental
    ///     encode-path inserts (flushed in `flush()`). NEVER included in
    ///     ConvergenceKit sync manifests; the graph is a rebuildable derived
    ///     accelerator — device-local only. Primary key is
    ///     (model_id, node_idx, layer): one row per node-per-layer neighbour
    ///     list. `neighbours` is a packed little-endian Int32 array of
    ///     node_idx values.
    ///     issued a full scan (10k-row probe_limit = O(N) on 109k chunks).
    ///     Combined with `columns:` projection, this also enables an
    ///     index-only covering scan — payload blobs never read from disk.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: kitID,
        version: 6,
        tables: [
            // v6: `generation INTEGER NOT NULL DEFAULT 0` column added.
            // UNIQUE constraint now includes generation so serving rows
            // (generation = serving_gen) and shadow rows (generation =
            // shadow_gen) for the same (item_id, vector_index, model_id)
            // can coexist during a shadow build. SQLite migration below
            // recreates the table to change the constraint.
            TableDeclaration(
                name: "vectors",
                columns: [
                    .uuid("id"),
                    .text("item_id", nullable: false),
                    .int("vector_index", nullable: false),
                    .text("model_id", nullable: false),
                    .text("model_version", nullable: false),
                    .int("kind", nullable: false),
                    .int("dim", nullable: false),
                    .blob("payload", nullable: false),
                    .float("scale", nullable: true),
                    .timestamp("filed_at", nullable: false),
                    // Reserve-space forward-compat slot. Nullable
                    // `.json`, present from schema v3. Future per-vector typed
                    // metadata (quantisation provenance, embedding-run tags)
                    // serializes here migration-free. 1.0 writes NULL and never
                    // reads it.
                    .json("ext", nullable: true),
                    // v6: shadow-swap generation. Serving rows carry the model's
                    // serving_generation (0 for estates with no prior swap).
                    // Shadow rows carry shadow_generation while a build is in
                    // flight. DEFAULT 0 ensures backward-compat reads from v5
                    // estates return serving-generation rows automatically.
                    ColumnDeclaration(name: "generation", type: .int, nullable: false, defaultValue: .int(0))
                ],
                primaryKey: ["id"],
                uniqueConstraints: [["item_id", "vector_index", "model_id", "generation"]]
            ),
            // v5: hnsw_graph — float-lane HNSW graph store. Device-local;
            // never in ConvergenceKit sync manifests (rebuildable derived
            // accelerator, not source-of-truth data). Primary key is
            // (model_id, node_idx, layer): one row per node-per-layer
            // neighbour list. `neighbours` is a packed little-endian Int32
            // array of node_idx values. Written by THETA rebuild, BETA
            // compaction, and incremental encode-path inserts.
            // v6: `generation` column added so VectorStore can load only the
            // serving-generation graph and reclaim retired generations.
            TableDeclaration(
                name: "hnsw_graph",
                columns: [
                    .text("model_id", nullable: false),
                    .int("node_idx", nullable: false),
                    .text("node_id", nullable: false),
                    .int("layer", nullable: false),
                    .blob("neighbours", nullable: false),
                    ColumnDeclaration(name: "generation", type: .int, nullable: false, defaultValue: .int(0))
                ],
                primaryKey: ["model_id", "node_idx", "layer"]
            ),
            // v6: vector_generations registry — one row per model_id that has
            // ever participated in a shadow swap. Absent row ⇒ serving_generation
            // = 0, no shadow active. `shadow_state` values:
            //   'building'        — shadow in flight, incomplete, reclaimable.
            //   'pending-reclaim' — flip committed, superseded rows not yet deleted.
            // NO Bool columns per schema invariant — state is the TEXT enum plus
            // nullable shadow_generation. Populated at beginShadowGeneration;
            // updated at publishShadowGeneration; shadow_state cleared by
            // reclaimSupersededGenerations.
            TableDeclaration(
                name: "vector_generations",
                columns: [
                    .text("model_id", nullable: false),
                    ColumnDeclaration(name: "serving_generation", type: .int, nullable: false, defaultValue: .int(0)),
                    .int("shadow_generation", nullable: true),
                    .text("shadow_state", nullable: true)
                ],
                primaryKey: ["model_id"]
            )
        ],
        indices: [
            IndexDeclaration(
                name: "idx_vectors_item",
                table: "vectors",
                columns: ["item_id"],
                unique: false
            ),
            IndexDeclaration(
                name: "idx_vectors_model_item",
                table: "vectors",
                columns: ["model_id", "item_id"],
                unique: false
            ),
            // v4: covers recentItemIDs ORDER BY filed_at DESC, item_id ASC.
            // SQLite can traverse this index in reverse for the DESC major
            // key, eliminating the full-scan + filesort. Combined with the
            // `columns: ["item_id", "filed_at"]` projection in recentItemIDs,
            // this also enables a covering scan — the main rows (payload blobs)
            // are never read. Migrated onto existing estates by Migration v3→v4.
            IndexDeclaration(
                name: "idx_vectors_filed_at_item",
                table: "vectors",
                columns: ["filed_at", "item_id"],
                unique: false
            ),
            // v6: serves serving-generation filter (WHERE model_id=? AND
            // generation=?) and batched reclamation scans. Migrated onto
            // existing estates by Migration v5→v6.
            IndexDeclaration(
                name: "idx_vectors_model_generation",
                table: "vectors",
                columns: ["model_id", "generation"],
                unique: false
            )
        ],
        migrations: [
            // v3 → v4: add idx_vectors_filed_at_item to existing estates.
            // Idempotent: SQLite's CREATE INDEX IF NOT EXISTS makes it safe to
            // replay. The index backfill is handled automatically by SQLite when
            // CREATE INDEX runs against a non-empty table.
            Migration(
                fromVersion: 3,
                toVersion: 4,
                operations: [
                    .addIndex(IndexDeclaration(
                        name: "idx_vectors_filed_at_item",
                        table: "vectors",
                        columns: ["filed_at", "item_id"],
                        unique: false
                    ))
                ]
            ),
            // v4 → v5: add hnsw_graph table to existing estates.
            // Idempotent: the .createTable operation emits CREATE TABLE IF NOT
            // EXISTS, so it is safe to replay on fresh databases (which also
            // apply this migration from the initial open). Rows are written by
            // THETA rebuild, BETA compaction, and incremental encode-path inserts
            // (flushed in flush()). The table starts empty on new estates until
            // the first THETA cadence fires or flush() is called after the corpus
            // exceeds hnswThreshold.
            Migration(
                fromVersion: 4,
                toVersion: 5,
                operations: [
                    .createTable(TableDeclaration(
                        name: "hnsw_graph",
                        columns: [
                            .text("model_id", nullable: false),
                            .int("node_idx", nullable: false),
                            .text("node_id", nullable: false),
                            .int("layer", nullable: false),
                            .blob("neighbours", nullable: false)
                        ],
                        primaryKey: ["model_id", "node_idx", "layer"]
                    ))
                ]
            ),
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
            // transaction on SQLite. They are also correct when replayed on a
            // fresh database: vectors_v6 is created, data copied from the
            // just-created (empty) vectors table, vectors dropped, and vectors_v6
            // renamed — net result is the same v6-schema table. Indices dropped
            // with the old table are re-added at the end of this migration.
            Migration(
                fromVersion: 5,
                toVersion: 6,
                operations: [
                    // (a) Recreate vectors with the new UNIQUE constraint.
                    .custom(
                        sqlite: "CREATE TABLE \"vectors_v6\" (\"id\" TEXT PRIMARY KEY NOT NULL, \"item_id\" TEXT NOT NULL, \"vector_index\" INTEGER NOT NULL DEFAULT 0, \"model_id\" TEXT NOT NULL, \"model_version\" TEXT NOT NULL, \"kind\" INTEGER NOT NULL DEFAULT 0, \"dim\" INTEGER NOT NULL DEFAULT 256, \"payload\" BLOB NOT NULL, \"scale\" REAL, \"filed_at\" TEXT NOT NULL, \"ext\" TEXT, \"generation\" INTEGER NOT NULL DEFAULT 0, UNIQUE(\"item_id\",\"vector_index\",\"model_id\",\"generation\"))",
                        postgresql: nil
                    ),
                    .custom(
                        sqlite: "INSERT INTO \"vectors_v6\" SELECT \"id\",\"item_id\",\"vector_index\",\"model_id\",\"model_version\",\"kind\",\"dim\",\"payload\",\"scale\",\"filed_at\",\"ext\",0 FROM \"vectors\"",
                        postgresql: nil
                    ),
                    .custom(
                        sqlite: "DROP TABLE \"vectors\"",
                        postgresql: nil
                    ),
                    .custom(
                        sqlite: "ALTER TABLE \"vectors_v6\" RENAME TO \"vectors\"",
                        postgresql: nil
                    ),
                    // Re-create all vectors indices dropped with the old table.
                    .addIndex(IndexDeclaration(
                        name: "idx_vectors_item",
                        table: "vectors",
                        columns: ["item_id"],
                        unique: false
                    )),
                    .addIndex(IndexDeclaration(
                        name: "idx_vectors_model_item",
                        table: "vectors",
                        columns: ["model_id", "item_id"],
                        unique: false
                    )),
                    .addIndex(IndexDeclaration(
                        name: "idx_vectors_filed_at_item",
                        table: "vectors",
                        columns: ["filed_at", "item_id"],
                        unique: false
                    )),
                    .addIndex(IndexDeclaration(
                        name: "idx_vectors_model_generation",
                        table: "vectors",
                        columns: ["model_id", "generation"],
                        unique: false
                    )),
                    // (b) Add generation column to hnsw_graph.
                    .addColumn(
                        table: "hnsw_graph",
                        column: ColumnDeclaration(name: "generation", type: .int, nullable: false, defaultValue: .int(0))
                    ),
                    // (c) Create vector_generations registry.
                    .createTable(TableDeclaration(
                        name: "vector_generations",
                        columns: [
                            .text("model_id", nullable: false),
                            ColumnDeclaration(name: "serving_generation", type: .int, nullable: false, defaultValue: .int(0)),
                            .int("shadow_generation", nullable: true),
                            .text("shadow_state", nullable: true)
                        ],
                        primaryKey: ["model_id"]
                    ))
                ]
            )
        ]
    )

    // MARK: - Sidecar path convention

    /// Derive the conventional resident-array sidecar URL for an estate's
    /// storage: a `.vec` file beside the SQLite database
    /// (`<estate>.sqlite` → `<estate>.vectors.vec`).
    ///
    /// Returns nil for non-file backends (in-memory, PostgreSQL) where a local
    /// sidecar does not apply — those rebuild the resident array from the table
    /// on each open, which is correct for ephemeral / server-hosted backends.
    /// The `.vec` filename convention lives here in SynapseKit (the kit that owns
    /// the sidecar format) so every caller derives the same stable path.
    public static func defaultSidecarURL(for storage: any Storage) -> URL? {
        guard case let .sqlite(url, _) = storage.configuration.backend else { return nil }
        return url.deletingPathExtension().appendingPathExtension("vectors.vec")
    }

    // MARK: - Init

    /// Construct against an already-opened Storage with optional sidecar persistence.
    ///
    /// The caller is responsible for calling
    /// `storage.open(schema: VectorStore.schemaDeclaration)` before using the store.
    ///
    /// - Parameters:
    ///   - storage: A PersistenceKit Storage instance. The `vectors` table must
    ///     already be present (opened by the caller).
    ///   - sidecarURL: Optional path to a `.vec` packed binary sidecar.
    ///     When supplied, the resident array is loaded from this file on
    ///     first use (one OS read via mmap, amortised) and kept in sync on
    ///     every write. A stale or absent sidecar is detected by comparing
    ///     its live-slot count (sidecar header `live_count` field) to the
    ///     table's serving-generation binary-row count; if they disagree the array is rebuilt
    ///     from the table and the sidecar is rewritten (C5 fix: comparing
    ///     live-vs-live avoids spurious rebuilds after tombstone operations).
    ///     When nil, the array is built from the table on first use and held
    ///     in memory only (rebuilt each process start). Callers with a stable
    ///     file path alongside the SQLite file should supply a sidecarURL.
    ///   - mihThreshold: Live binary-vector count at which the store promotes
    ///     from BruteForceIndex (Lane A) to MIHIndex (Lane B). Default 50_000.
    ///     Below the threshold, brute-force is already sub-millisecond and the
    ///     MIH build cost is not justified. At/above the threshold, MIH is
    ///     sub-linear and faster. Both indexes are EXACT — results are identical.
    ///   - mihBandCount: MIH band count m used when the MIH index is active.
    ///     Default .m16 (sub_bits=16), optimal for the 50k default threshold
    ///     per §1.6 (log2(50000)≈15.6 → m=16). Pass a different value if you
    ///     override mihThreshold significantly.
    public init(
        storage: any Storage,
        sidecarURL: URL? = nil,
        mihThreshold: UInt32 = 50_000,
        mihBandCount: MIHBandCount = .m16,
        deferredPendingLimit: Int = 50_000,
        hnswThreshold: UInt32 = hnswDefaultThreshold
    ) {
        self.storage               = storage
        self.mihThreshold          = mihThreshold
        self.mihBandCount          = mihBandCount
        self.hnswThreshold         = hnswThreshold
        self.arrayStore            = sidecarURL.map { ResidentArrayStore(sidecarURL: $0) }
        self.deferredPendingLimit  = deferredPendingLimit
        // Allocate both index actors once; hotIndex starts as brute-force
        // (correct for the empty / pre-threshold state).
        let bf  = BruteForceIndex()
        let mih = MIHIndex(bandCount: mihBandCount)
        self.bruteForceIndex = bf
        self.mihIndex        = mih
        self.hotIndex        = bf   // starts in Lane A; promoted by _selectIndex
        // Float indices are built lazily per modelID on first findNearestFloat;
        // the map starts empty (no pre-built index).

        // Register for critical memory pressure on Apple platforms. The handler
        // evicts all cached float-lane indexes and falls back to the table scan.
        // The DispatchSource is retained for the actor's lifetime so deliveries
        // continue across the actor's existence. A Task is used to cross the
        // actor-isolation boundary safely.
        #if canImport(Darwin)
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: .critical,
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.evictFloatIndices() }
        }
        src.resume()
        self.memoryPressureSource = src
        #endif
    }

    // MARK: - Residency management

    // MARK: Admission projection constants
    //
    // Both constants are deliberately IDENTICAL in the Swift and Rust ports so
    // the two ports make the SAME admission decision for the same (recordCount,
    // stride) inputs — a hard requirement of the Part 3 cross-port agreement test.
    //
    // OVERHEAD (2000 bytes/record): the parallel VectorRecordKey array that sits
    // beside the packed float payload in FloatBruteForceIndex. Measured RSS overhead
    // at N=50,000 dim-384 vectors was 266 bytes/record in Swift and 1,714 in Rust
    // (Rust String has no small-string optimisation; freed source slabs stay in RSS).
    // Both ports use the LARGER (Rust) figure, rounded up to 2000, so the projection
    // never under-estimates in either port. Measurement data in BRR §6.1.
    //
    // GRAPH_ALLOW (stride + OVERHEAD + 256 bytes/record): above hnswThreshold VectorStore
    // holds an HNSWIndex IN ADDITION to FloatBruteForceIndex. Each HNSWIndex.Node owns
    // a second full copy of the vector (stride bytes, HNSWIndex.swift:108-120 vectorBytes),
    // a second copy of the key overhead (OVERHEAD bytes), and neighbour lists of up to
    // 2M=32 Int32 at layer 0 with hnswM=16 (HNSWIndex.swift:64), i.e. ≲ 256 bytes/record.
    // This is an ANALYTIC bound read off the struct definition, not an RSS measurement.
    // Ignoring the graph would under-project by ~2× exactly where estates are largest.
    private static let floatIndexOverheadPerRecord: Int = 2000

    /// Project the heap footprint in bytes for one per-model FloatBruteForceIndex
    /// (plus HNSWIndex above the threshold) given `recordCount` and `stride`.
    ///
    /// The formula uses the Rust overhead figure in both ports so admission decisions
    /// agree across languages for the same inputs. See the constant block above for
    /// the full derivation.
    ///
    /// - Parameters:
    ///   - recordCount: number of float32 rows for the model in the serving generation.
    ///   - stride: bytes per vector payload (dim × 4 for float32).
    /// - Returns: projected byte cost of holding this model's float-lane index in heap.
    private func _projectFloatIndexBytes(recordCount: Int, stride: Int) -> Int {
        let overhead = Self.floatIndexOverheadPerRecord
        // Above the HNSW threshold the graph lives alongside the brute-force index.
        // GRAPH_ALLOW = stride + overhead + 256 (neighbour lists). See constant block.
        if recordCount >= Int(hnswThreshold) {
            let graphAllow = stride + overhead + 256
            return recordCount * (stride + overhead + graphAllow)
        }
        return recordCount * (stride + overhead)
    }

    /// Attempt to build the FloatBruteForceIndex for `modelID`, subject to the
    /// estate's `residentIndexBudget` admission ceiling.
    ///
    /// The check MUST happen before `_fetchFloatRecords` materialises every payload
    /// into memory — checking after the fetch would allocate the very spike this
    /// admission gate exists to prevent. The gate therefore:
    ///   1. Counts rows via RowStore.count (no payload transferred).
    ///   2. Derives stride from one sampled row (single-row fetch, minimal transfer).
    ///   3. Projects the total heap cost.
    ///   4. Reconciles `floatIndexFootprints` against the live `floatIndices` map
    ///      (any evicted entry is dropped — see `floatIndexFootprints` for why this
    ///      self-reconciling design replaces a running counter).
    ///   5. If sum + projection exceeds the ceiling: refuses, logs, increments
    ///      `floatIndexAdmissionRefusalCount`, and returns `nil`.
    ///   6. Only if admitted: fetches the full record set, builds the index,
    ///      records the footprint, seeds `liveFloatCounts`, and returns the index.
    ///
    /// Callers that receive `nil` MUST fall through to the table-scan path so the
    /// query returns correct results — a refusal is a cache miss, not an error.
    ///
    /// - Returns: the built `FloatBruteForceIndex`, or `nil` when:
    ///   (a) no float rows exist for the model (caller's scan returns empty), or
    ///   (b) the projected resident set would exceed the admission ceiling.
    private func _buildFloatIndexIfAdmitted(modelID: String) async throws -> FloatBruteForceIndex? {
        let servingGen = try await _servingGeneration(for: modelID)

        // Step 1: count rows without materialising payloads.
        let rowCount = try await storage.rowStore.count(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "kind"),
                    .int(Int64(VectorKind.float32.rawValue))),
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                .eq(Column(table: "vectors", name: "generation"), .int(servingGen))
            ])
        )
        guard rowCount > 0 else {
            // No float rows for this model: the scan path will return empty results.
            return nil
        }

        // Step 2: derive stride from one sampled row.
        let sampleRows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "kind"),
                    .int(Int64(VectorKind.float32.rawValue))),
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                .eq(Column(table: "vectors", name: "generation"), .int(servingGen))
            ]),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let sampleRow = sampleRows.first,
              let samplePayload = Self.decodePayload(from: sampleRow),
              samplePayload.kind == .float32 else {
            // Cannot determine stride; fall back to the scan path conservatively.
            return nil
        }
        let stride = samplePayload.bytes.count

        // Step 3: project byte cost.
        let projection = _projectFloatIndexBytes(recordCount: rowCount, stride: stride)

        // Step 4: reconcile the footprint map against the live index map.
        // Drop entries for models whose index has been evicted. The index map is
        // the single source of truth; this pass makes all nine clear sites across
        // VectorStore self-correcting without any edit to those sites.
        let liveKeys = Set(floatIndices.keys)
        floatIndexFootprints = floatIndexFootprints.filter { liveKeys.contains($0.key) }
        let currentResidentTotal = floatIndexFootprints.values.reduce(0, +)

        // Step 5: apply the ceiling.
        let ceiling = storage.configuration.residentIndexBudget.resolveCeiling(
            physicalMemoryBytes: UInt64(ProcessInfo.processInfo.physicalMemory)
        )
        if let cap = ceiling, currentResidentTotal + projection > cap {
            floatIndexAdmissionRefusalCount += 1
            log.warning(
                "VectorStore: float-index admission refused modelID=\(modelID, privacy: .public) projection=\(projection) residentTotal=\(currentResidentTotal) ceiling=\(cap) — falling back to table-scan"
            )
            return nil
        }

        // Step 6: admitted — fetch full records, build, record footprint.
        let records = try await _fetchFloatRecords(modelID: modelID)
        guard let arr = Self.buildFloatArray(from: records) else {
            // Records vanished between count and fetch (race with deletion).
            // Return nil so caller uses the scan; scan will return empty.
            return nil
        }
        let index = FloatBruteForceIndex()
        await index.build(from: arr)
        // Seed the live count so the HNSW threshold check is accurate from the
        // very first query on this partition.
        liveFloatCounts[modelID] = UInt32(records.count)
        // Record the footprint for future admission decisions.
        floatIndexFootprints[modelID] = projection
        return index
    }

    /// Evict all per-model float-lane indexes from the in-process heap.
    ///
    /// Clears `floatIndices`, `hnswIndices`, and `liveFloatCounts`. After
    /// eviction the next `findNearestFloat` or `findFarthestFloat` call lazily
    /// rebuilds from the `vectors` table when `residencyHint == .ramResident`,
    /// or uses the table scan directly when `residencyHint == .diskBacked`.
    ///
    /// Called automatically on Apple platforms under critical memory pressure
    /// (registered in `init`). Callers that manage their own pressure budget
    /// may call this directly.
    public func evictFloatIndices() {
        floatIndices.removeAll(keepingCapacity: false)
        // HNSW graph and live-count tracking are derivative of the float lane;
        // evict them together so the next findNearestFloat sees a clean state.
        hnswIndices.removeAll(keepingCapacity: false)
        liveFloatCounts.removeAll(keepingCapacity: false)
        log.info("VectorStore: float-lane indexes (BruteForce + HNSW) evicted under memory pressure")
    }

    /// Invalidate the HNSW lane for one modelID partition after a durable
    /// mutation (delete / replace / reconcile / batch write) touched its rows.
    ///
    /// Drops the in-memory graph, the live-count seed, and the partition's
    /// dirty flag (VH-01 Finding A: every `floatIndices` invalidation must be
    /// paired with this, or `findNearestFloat` keeps serving the stale graph —
    /// HNSW nodes own raw vector bytes, so deleted/replaced content would
    /// surface from memory after the durable rows are gone).
    ///
    /// Persisted `hnsw_graph` rows are deliberately NOT deleted here: the next
    /// qualifying `findNearestFloat` reloads them via `_loadHNSWGraphIfPresent`,
    /// which re-derives every node's bytes from the `vectors` table — nodes
    /// whose row was deleted load as placeholder tombstones and cannot surface.
    /// The dirty flag IS dropped so a later `flush()` does not see a dirty
    /// partition with no in-memory graph and persist-delete those
    /// still-serviceable rows.
    func _invalidateHNSWLane(for modelID: String) {
        hnswIndices.removeValue(forKey: modelID)
        liveFloatCounts.removeValue(forKey: modelID)
        hnswGraphDirty.remove(modelID)
    }

    /// Drop every resident HNSW graph, live float count and dirty flag at
    /// once. Used by the whole-record float vacuum after the `hnsw_graph`
    /// rows are deleted: the graphs described rows that are gone.
    func _invalidateAllHNSWLanes() {
        hnswIndices.removeAll()
        liveFloatCounts.removeAll()
        hnswGraphDirty.removeAll()
    }

    // MARK: - HNSW graph maintenance (dreaming cadence duties)

    /// Clear all HNSW graphs for every modelID partition (ALPHA duty).
    ///
    /// Drops every in-process HNSWIndex entry AND deletes all persisted
    /// `hnsw_graph` rows. The next `findNearestFloat` call at/above
    /// `hnswThreshold` falls back to exact scan until DreamingDaemon's THETA
    /// cadence fires a fresh rebuild. FloatBruteForceIndex entries are RETAINED
    /// — farthest queries and below-threshold nearest queries continue
    /// uninterrupted.
    ///
    /// Called by DreamingDaemon on extreme vocabulary drift (ALPHA auto-reindex
    /// path) when the embedding basis changes enough to render the existing
    /// graph topology incorrect.
    public func clearAllHNSWIndices() async throws {
        // Delete all persisted hnsw_graph rows so the query path falls back to
        // exact scan until DreamingDaemon's THETA cadence fires a rebuild. The
        // embedding basis has shifted; the old graph topology is incorrect and
        // must not be served or loaded from the table.
        _ = try await storage.rowStore.delete(table: "hnsw_graph", where: .isTrue)
        for idx in hnswIndices.values {
            await idx.clear()
        }
        hnswIndices.removeAll(keepingCapacity: false)
        hnswGraphDirty.removeAll(keepingCapacity: false)
        log.info("VectorStore: all HNSW graphs cleared (ALPHA extreme-drift duty)")
    }

    /// Rebuild the HNSW graph for one modelID partition from current float records (THETA duty).
    ///
    /// Fetches all float32 rows for `modelID` from the `vectors` table, then
    /// re-inserts them into a fresh HNSWIndex. Called after a basis retrain
    /// (THETA cadence) so the graph stays aligned with re-embedded vectors. A
    /// fresh graph avoids tombstone accumulation from the incremental insert path
    /// and rebuilds the neighbour topology from the new embedding geometry.
    ///
    /// If the table has no float rows for `modelID`, any existing graph entry
    /// is removed (keeping the map consistent with the table state).
    public func rebuildHNSWIndex(for modelID: String) async throws {
        let records = try await _fetchFloatRecords(modelID: modelID)
        guard !records.isEmpty else {
            hnswIndices.removeValue(forKey: modelID)
            // Remove any stale persisted rows for an empty partition.
            _ = try await storage.rowStore.delete(
                table: "hnsw_graph",
                where: .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID))
            )
            return
        }
        let hnsw = HNSWIndex()
        // Content-stable bulk build order (SPEC 1.10.0): sort rows by
        // (fnv1a64(payload bytes) ASC, key ASC) before insertion so identical
        // content yields an identical graph across independent builds.
        // _fetchFloatRecords sorts by key alone, and keys ride per-run-random
        // item UUIDs — that order is stable within one estate but NOT across
        // provisionings of the same content (REPLAY_DRIFT_RCA). The key remains
        // the final backstop for byte-identical vectors, which are
        // interchangeable for every ordering consumer.
        var buildOrder = records.map { (hash: fnv1a64($0.payload.bytes), rec: $0) }
        buildOrder.sort { a, b in
            a.hash != b.hash ? a.hash < b.hash : a.rec.key < b.rec.key
        }
        for entry in buildOrder {
            if let floats = try? entry.rec.payload.asFloats() {
                await hnsw.insert(itemID: entry.rec.key.itemID, modelID: modelID, vector: floats)
            }
        }
        hnswIndices[modelID] = hnsw
        liveFloatCounts[modelID] = UInt32(records.count)
        // D6 fix: stamp the freshly built graph with the model's CURRENT serving
        // generation BEFORE persisting. Without this, a THETA rebuild after a swap
        // (serving gen N>0) writes gen-0 rows that _loadHNSWGraphIfPresent rejects
        // forever (generation mismatch → graph permanently absent).
        // publishShadowGeneration runs rebuildHNSWIndex AFTER the registry flip, so
        // serving_generation is already the new value here; the redundant setGeneration
        // + second _persistHNSWGraph in publishShadowGeneration were removed.
        let currentServingGen = try await _servingGeneration(for: modelID)
        await hnsw.setGeneration(currentServingGen)
        // Persist the freshly built graph to hnsw_graph so subsequent process
        // launches load the topology from disk rather than rebuilding. Track
        // rebuild count (distinguishes disk-load from rebuild in tests).
        try await _persistHNSWGraph(for: modelID)
        hnswBuildCount[modelID, default: 0] += 1
        log.info("VectorStore: HNSW graph rebuilt for modelID=\(modelID, privacy: .public), nodes=\(records.count), generation=\(currentServingGen)")
    }

    /// Rebuild HNSW graphs for all modelIDs that currently have an active graph (THETA duty).
    ///
    /// Iterates over `hnswIndices.keys` and calls `rebuildHNSWIndex(for:)` for
    /// each. ModelIDs below the threshold (no entry in `hnswIndices`) are skipped
    /// — they have no graph to rebuild; the next qualifying `findNearestFloat`
    /// call loads from the `hnsw_graph` table if rows exist. Called by
    /// DreamingDaemon's THETA cycle after a full corpus basis retrain.
    public func rebuildAllHNSWIndices() async throws {
        // Snapshot the keys before mutation to avoid dict-during-iteration.
        let modelIDs = Array(hnswIndices.keys)
        for modelID in modelIDs {
            try await rebuildHNSWIndex(for: modelID)
        }
    }

    /// Compact HNSW tombstones for one modelID partition (BETA duty).
    ///
    /// Calls `HNSWIndex.compact()` which rebuilds the live-node graph discarding
    /// tombstoned entries and dead edges. This is a wear-model compaction: HNSW
    /// tombstones accumulate over time as items are updated or deleted; BETA
    /// compaction reclaims their memory and restores graph quality. Safe to call
    /// when no graph exists for `modelID` (no-op).
    /// True when an HNSW graph is resident in memory for `modelID`.
    ///
    /// Internal (not private) as the positive residency probe for the exit
    /// gates: build-count instruments prove no REBUILD happened, but both the
    /// loaded-graph path and the exact-scan fallback leave it at zero — only
    /// this probe distinguishes "served from the loaded graph" from "fallback
    /// quietly covered it". Twin of Rust `hnsw_index_resident`.
    func hnswIndexResident(for modelID: String) -> Bool {
        hnswIndices[modelID] != nil
    }

    /// True when a float-lane FloatBruteForceIndex is resident in memory for `modelID`.
    ///
    /// Internal (not private) as the positive residency probe for admission tests:
    /// a refusal leaves this false; an admitted build sets it true. Twin of Rust
    /// `float_index_resident`.
    func floatIndexResident(for modelID: String) -> Bool {
        floatIndices[modelID] != nil
    }

    public func compactHNSWTombstones(for modelID: String) async throws {
        guard let idx = hnswIndices[modelID] else { return }
        await idx.compact()
        // Persist the compacted graph: tombstones have been removed, so the
        // persisted topology must be updated to match the live-node-only graph.
        try await _persistHNSWGraph(for: modelID)
        log.info("VectorStore: HNSW compact completed for modelID=\(modelID, privacy: .public)")
    }

    /// Compact HNSW tombstones for all active modelID partitions (BETA duty).
    ///
    /// Iterates over all active HNSW graphs and calls `compact()` on each.
    /// Called by DreamingDaemon's BETA cycle.
    public func compactAllHNSWTombstones() async throws {
        let modelIDs = Array(hnswIndices.keys)
        for modelID in modelIDs {
            try await compactHNSWTombstones(for: modelID)
        }
    }

    // MARK: - HNSW graph persistence (private and internal test helpers)

    /// Count persisted rows in the `hnsw_graph` table for one modelID partition.
    ///
    /// Internal — exposed for persistence exit-gate tests via `@testable import SynapseKit`
    /// (exit gate A: "SELECT count(*) FROM hnsw_graph > 0"). Not for production use;
    /// production code reads graphs via `_loadHNSWGraphIfPresent`.
    internal func hnswGraphRowCount(for modelID: String) async throws -> Int {
        try await storage.rowStore.count(
            table: "hnsw_graph",
            where: .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID))
        )
    }

    /// Persist the in-memory HNSW graph for one modelID partition to the
    /// `hnsw_graph` SQLite table.
    ///
    /// Replaces all existing rows for `modelID` with the current graph topology
    /// in a single transaction (delete-then-insert). Tombstoned nodes are
    /// excluded by `HNSWIndex.graphRows()` — the persisted graph is always
    /// live-node-only. If no graph is loaded for `modelID`, any stale rows are
    /// deleted.
    ///
    /// Called by: `rebuildHNSWIndex(for:)` (THETA), `compactHNSWTombstones(for:)`
    /// (BETA), and `flush()` for partitions marked dirty by encode-path inserts.
    private func _persistHNSWGraph(for modelID: String) async throws {
        guard let hnsw = hnswIndices[modelID] else {
            // No in-memory graph — delete any stale persisted rows.
            _ = try await storage.rowStore.delete(
                table: "hnsw_graph",
                where: .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID))
            )
            return
        }
        let hasGraph = await hnsw.hasGraph
        guard hasGraph else {
            _ = try await storage.rowStore.delete(
                table: "hnsw_graph",
                where: .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID))
            )
            return
        }
        let rows = await hnsw.graphRows()

        // Replace all rows for this modelID atomically: delete then insert.
        // A single transaction keeps the table consistent across the two
        // operations (no window where reads would see a partial graph).
        try await storage.rowStore.beginTransaction()
        do {
            _ = try await storage.rowStore.delete(
                table: "hnsw_graph",
                where: .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID))
            )
            for row in rows {
                let values: [String: TypedValue] = [
                    "model_id":   .text(modelID),
                    "node_idx":   .int(Int64(row.nodeIdx)),
                    "node_id":    .text(row.nodeID),
                    "layer":      .int(Int64(row.layer)),
                    "neighbours": .blob(row.neighboursBlob),
                    // v6: tag with the graph's generation so load can filter to
                    // the serving generation and reclaim can delete retired rows.
                    "generation": .int(row.generation)
                ]
                _ = try await storage.rowStore.insert(table: "hnsw_graph", values: values)
            }
            try await storage.rowStore.commitTransaction()
        } catch {
            try? await storage.rowStore.rollbackTransaction()
            throw error
        }
        log.info("VectorStore: HNSW graph persisted for modelID=\(modelID, privacy: .public), rows=\(rows.count)")
    }

    /// Load the HNSW graph for one modelID partition from the `hnsw_graph`
    /// table, if rows exist.
    ///
    /// Queries `hnsw_graph` for all rows matching `modelID`. If none exist,
    /// returns without mutating `hnswIndices` (caller falls back to exact scan).
    /// If rows exist, fetches the corresponding float vectors from `vectors`,
    /// reconstructs the `HNSWIndex` from the persisted topology + float bytes,
    /// and stores it in `hnswIndices[modelID]`.
    ///
    /// This is the only graph-load path on the query side. The query path NEVER
    /// triggers an inline rebuild — if no rows exist, the fallback is exact scan
    /// until DreamingDaemon's THETA cadence fires a rebuild.
    private func _loadHNSWGraphIfPresent(for modelID: String) async throws {
        // Query all hnsw_graph rows for this modelID.
        let dbRows = try await storage.rowStore.query(
            table: "hnsw_graph",
            where: .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID)),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        guard !dbRows.isEmpty else { return }

        // Fetch the current serving generation so we only load matching rows.
        // A mismatch (stale graph from a prior generation) is treated as absent
        // per §4 of the design contract — the query path falls back to exact scan.
        let servingGen = try await _servingGeneration(for: modelID)

        // Decode rows to HNSWIndex.GraphRow values and build itemID → nodeIdx.
        // Persisted graph rows are UNTRUSTED input (VH-01 Finding C): every
        // INTEGER is converted with a checked cast and bounds-tested BEFORE it
        // can size an allocation downstream. `Int32(exactly:)` rejects negative
        // and out-of-i32-range Int64 values without trapping (a plain `Int32(v)`
        // traps on overflow — house-style rule: no unguarded narrowing).
        //
        // One invalid row abandons the WHOLE graph load (VH-01 F3): this mirrors
        // the engine's own policy — `loadFromGraphRows` rejects on the first bad
        // row — so both layers agree: partial topology from corrupt state is worse
        // than a clean exact-scan fallback until the next THETA rebuild corrects it.
        // Matches Rust twin: query_hnsw_graph_rows returns Ok(Vec::new()) on
        // any invalid row, causing load_hnsw_graph_if_present to skip the load.
        var graphRows: [HNSWIndex.GraphRow] = []
        var itemIDToNodeIdx: [String: Int32] = [:]
        for dbRow in dbRows {
            guard case let .int(rawNodeIdx) = dbRow["node_idx"] ?? .null,
                  case let .text(nodeID)    = dbRow["node_id"]  ?? .null,
                  case let .int(rawLayer)   = dbRow["layer"]    ?? .null,
                  case let .blob(nb)        = dbRow["neighbours"] ?? .null
            else { return }
            // Checked narrowing: node_idx must be ≥ 0 and fit Int32.
            guard let nodeIdx = Int32(exactly: rawNodeIdx), nodeIdx >= 0 else { return }
            // layer must be ≥ 0 and within the level-generation cap.
            guard rawLayer >= 0, rawLayer <= Int64(hnswMaxPersistedLayer) else { return }
            let layer = Int(rawLayer)
            // neighbours: packed LE i32 — must be whole i32s within the fan-out cap.
            guard nb.count % 4 == 0, nb.count <= hnswM0 * 4 else { return }
            // Decode generation (v6+). Default 0 for v5 estates.
            let rowGen: Int64
            switch dbRow["generation"] ?? .null {
            case let .int(g): rowGen = g
            default:          rowGen = 0
            }
            graphRows.append(HNSWIndex.GraphRow(
                nodeIdx:        nodeIdx,
                nodeID:         nodeID,
                layer:          layer,
                neighboursBlob: nb,
                generation:     rowGen
            ))
            // Only the first row for each node establishes the idx mapping;
            // subsequent layers for the same node reuse the same nodeIdx.
            if itemIDToNodeIdx[nodeID] == nil {
                itemIDToNodeIdx[nodeID] = nodeIdx
            }
        }
        guard !graphRows.isEmpty else { return }

        // Fetch float records and build nodeBytes keyed by nodeIdx.
        // Nodes whose float vector was deleted between persist and load are
        // silently skipped by loadFromGraphRows (topology remains valid until
        // the next THETA rebuild corrects it).
        let floatRecords = try await _fetchFloatRecords(modelID: modelID)
        var nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [:]
        nodeBytes.reserveCapacity(floatRecords.count)
        for rec in floatRecords {
            if let nodeIdx = itemIDToNodeIdx[rec.key.itemID] {
                nodeBytes[nodeIdx] = (itemID: rec.key.itemID, bytes: rec.payload.bytes)
            }
        }

        // Reconstruct the HNSW graph from persisted topology + float bytes.
        // Pass expectedGeneration so loadFromGraphRows rejects rows that belong
        // to a retired generation (§4 of the design contract).
        // modelID is passed so loaded nodes carry the correct partition tag;
        // HNSWIndex.search filters by node.modelID == modelID and returns empty
        // for nodes with the default empty string modelID.
        let hnsw = HNSWIndex()
        await hnsw.loadFromGraphRows(graphRows, nodeBytes: nodeBytes, modelID: modelID,
                                     expectedGeneration: servingGen)
        guard await hnsw.hasGraph else { return }
        hnswIndices[modelID] = hnsw
        log.info("VectorStore: HNSW graph loaded from table for modelID=\(modelID, privacy: .public), rows=\(graphRows.count)")
    }

    // MARK: - Write

    /// Upsert a binary (Engram) vector.
    ///
    /// Inserts or replaces the row at (itemID, vectorIndex=0, modelID).
    /// For the common single-vector case; multi-vector callers use
    /// addPayload(itemID:vectorIndex:payload:modelID:modelVersion:filedAt:).
    ///
    /// Keeps the resident hot-path array in sync with the table write.
    ///
    /// Telemetry: emits `synapsekit.index.insert_latency_ms` when enabled.
    public func addVector(
        itemID: String,
        engram: Engram,
        modelID: String,
        modelVersion: String,
        filedAt: Date
    ) async throws {
        let payload = VectorPayload(engram: engram)
        try await addPayload(
            itemID: itemID,
            vectorIndex: 0,
            payload: payload,
            modelID: modelID,
            modelVersion: modelVersion,
            filedAt: filedAt
        )
    }

    /// Upsert a typed payload (binary, float32, or int8).
    ///
    /// This is the general write path. `addVector` is a convenience
    /// wrapper for the binary/Engram case; `writeSpanVectors` is the
    /// atomic per-item path for encoder span rows (int8).
    ///
    /// For binary payloads: writes the row to the `vectors` table AND
    /// mirrors the vector into the resident array AND updates the active
    /// DenseIndex incrementally. If the write pushes `liveBinaryCount`
    /// across the MIH threshold, the store promotes from BruteForceIndex to
    /// MIHIndex (or demotes, if an upsert replaces an existing slot — count
    /// stays the same). Non-binary payloads are written to the table only.
    ///
    /// Sidecar persistence is WRITE-BEHIND (TASK #24): the in-memory resident
    /// array is updated immediately but the `.vec` sidecar is marked dirty,
    /// not rewritten, on each call. Call `flush()` at a quiesce point to
    /// persist. Crash safety is preserved because the `vectors` table is the
    /// durable source — a stale sidecar is rebuilt from the table on the next
    /// open. For importing many vectors at once, prefer `addPayloads(_:)`,
    /// which bounds both sidecar writes and index builds to O(batches).
    ///
    /// Int8 payloads (the ratified symmetric per-vector quantisation,
    /// SYNAPSEKIT_SPEC §I-4a) are table-only like float32: they never enter
    /// the resident Hamming array or a float index.
    ///
    /// Telemetry: emits `synapsekit.index.insert_latency_ms` when enabled.
    public func addPayload(
        itemID: String,
        vectorIndex: UInt32,
        payload: VectorPayload,
        modelID: String,
        modelVersion: String,
        filedAt: Date
    ) async throws {
        let startTime = Date().timeIntervalSince1970

        // Determine write generation. If the model has an active shadow ('building'),
        // tag this row with shadow_gen and bypass all resident structures. If no
        // shadow is active, tag with the serving generation and proceed normally.
        let shadowGen = try await _shadowGeneration(for: modelID)
        let writeGen: Int64
        let isShadowWrite: Bool
        if let sg = shadowGen {
            writeGen = sg
            isShadowWrite = true
        } else {
            writeGen = try await _servingGeneration(for: modelID)
            isShadowWrite = false
        }

        // Accumulate peak shadow payload bytes (measured, not estimated).
        if isShadowWrite {
            shadowPayloadBytes[modelID, default: 0] += Int64(payload.bytes.count)
        }

        let values: [String: TypedValue] = [
            "id":           .uuid(UUID()),
            "item_id":      .text(itemID),
            "vector_index": .int(Int64(vectorIndex)),
            "model_id":     .text(modelID),
            "model_version":.text(modelVersion),
            "kind":         .int(Int64(payload.kind.rawValue)),
            "dim":          .int(Int64(payload.dim)),
            "payload":      .blob(Data(payload.bytes)),
            // Scale: .null for nil; PersistenceKit has no Optional TypedValue case.
            "scale":        payload.scale.map { TypedValue.float(Double($0)) } ?? TypedValue.null,
            "filed_at":     .timestamp(filedAt),
            // Shadow-swap generation tag (§2 of the design contract).
            "generation":   .int(writeGen)
        ]
        _ = try await storage.rowStore.upsert(
            table: "vectors",
            values: values,
            conflictColumns: ["item_id", "vector_index", "model_id", "generation"]
        )

        // Shadow writes: table-only. Resident structures serve the current
        // serving generation and must not be contaminated by shadow rows.
        guard !isShadowWrite else {
            let endTime = Date().timeIntervalSince1970
            Intellectus.report(.metric(
                name: "synapsekit.index.insert_latency_ms",
                value: (endTime - startTime) * 1000.0,
                tags: ["kit": "SynapseKit", "shadow": "true"],
                ts: endTime
            ))
            return
        }

        // Mirror binary payloads into the resident hot-path array.
        // Non-binary lanes remain table-only (I-7: Hamming is binary-only,
        // integer arithmetic, absolute).
        if payload.kind == .binary {
            // Ensure the resident index is coherent before mutating it.
            try await _ensureIndexBuilt()

            let key = VectorRecordKey(
                itemID: itemID,
                vectorIndex: vectorIndex,
                modelID: modelID,
                modelVersion: modelVersion
            )

            // Determine whether this is a new slot (insert) or a replacement
            // (upsert over an existing logical position). Only new slots change
            // the live count. We match by (itemID, vectorIndex, modelID) only —
            // NOT by full VectorRecordKey — so a changed modelVersion is still
            // recognised as a replacement and the stale slot is tombstoned.
            // Matching by full key would leave stale modelVersion slots live in
            // the resident array (secfix/ws2-coredelete: hard-delete contract).
            let preMutationSnap = await bruteForceIndex.currentSnapshot()
            let staleSlotKeys: [VectorRecordKey] = preMutationSnap.keys.indices.compactMap { i in
                guard !preMutationSnap.isTombstoned(i) else { return nil }
                let k = preMutationSnap.keys[i]
                guard k.itemID == itemID,
                      k.vectorIndex == vectorIndex,
                      k.modelID == modelID else { return nil }
                return k
            }
            let isReplacement = !staleSlotKeys.isEmpty

            let vectorPayload = VectorPayload(kind: .binary, dim: 256, bytes: payload.bytes)
            if let store = arrayStore {
                // Sidecar path (write-behind): tombstone ALL prior slots for
                // this logical position (itemID, vectorIndex, modelID) — this
                // covers stale modelVersion slots that tombstoneDeferred([key])
                // would miss when modelVersion changed. Then append the new slot
                // and update both indexes incrementally. The sidecar is persisted
                // at the next quiesce point via flush(); crash safety is preserved
                // by the table-rebuild path (the `vectors` table is the durable
                // source — see VectorStore header HOT-PATH note).
                await store.tombstoneDeferred(keys: Set(staleSlotKeys))
                try await store.appendDeferred(key: key, bytes: payload.bytes)
                // Remove stale slots from both indexes before adding the new slot.
                // BruteForceIndex.add only tombstones exact-key matches; calling
                // remove() first covers stale modelVersion cases.
                for staleKey in staleSlotKeys {
                    try await bruteForceIndex.remove(key: staleKey)
                    try await mihIndex.remove(key: staleKey)
                }
                try await bruteForceIndex.add(key: key, vector: vectorPayload)
                try await mihIndex.add(key: key, vector: vectorPayload)
            } else {
                // Memory-only path: remove all prior slots for this logical
                // position before adding the new one. BruteForceIndex.add's
                // built-in tombstoning only covers exact-key matches (same
                // modelVersion); stale slots require explicit remove() calls.
                for staleKey in staleSlotKeys {
                    try await bruteForceIndex.remove(key: staleKey)
                    try await mihIndex.remove(key: staleKey)
                }
                try await bruteForceIndex.add(key: key, vector: vectorPayload)
                // Keep MIHIndex in sync via incremental add/update.
                try await mihIndex.add(key: key, vector: vectorPayload)
            }

            // Update live count and re-select the active index.
            if !isReplacement {
                liveBinaryCount += 1
            }
            _selectIndex()
        } else if payload.kind == .float32 {
            // Mirror float32 payloads into the Lane D float index for THIS
            // modelID so findNearestFloat sees this write without a full table
            // rescan. Only when this model's float index is already built (its
            // presence in `floatIndices` is the built flag) — otherwise the
            // table write is authoritative and the row is picked up when
            // findNearestFloat lazily builds this model's index on first use.
            if let modelIndex = floatIndices[modelID] {
                let key = VectorRecordKey(
                    itemID: itemID,
                    vectorIndex: vectorIndex,
                    modelID: modelID,
                    modelVersion: modelVersion
                )
                // The upsert above may have replaced an existing row; the
                // float index tombstones the prior slot for this key before
                // appending the new one, mirroring the table's ON CONFLICT
                // UPDATE so a stale float vector cannot survive in the scan.
                try await modelIndex.remove(key: key)
                try await modelIndex.add(key: key, vector: payload)
                // Increment the live count. A strict replacement check (to
                // avoid counting updates twice) would require a lookup in the
                // brute-force snapshot — expensive per-insert. Because
                // hnswThreshold is 5 000, a count that drifts by ±1 per
                // replacement is insignificant: the worst case activates HNSW
                // one insert early, which is correct. True net-new status is
                // resolved when the index is first built (records.count) and
                // HNSW activation is idempotent.
                liveFloatCounts[modelID, default: 0] += 1
                // Mirror into the HNSW graph if one is loaded for this modelID.
                // HNSWIndex.insert handles upsert (tombstones any prior node for
                // this itemID, inserts the new vector). If no graph is loaded,
                // this is a no-op — the graph will be loaded from hnsw_graph rows
                // on the first qualifying findNearestFloat call. Mark the
                // partition dirty so flush() persists the updated topology.
                // Incremental inserts keep ARRIVAL order (SPEC 1.10.0): only
                // bulk rebuilds (rebuildHNSWIndex, compact) apply the
                // content-stable (vecHash, key) build order, so cross-run graph
                // identity is guaranteed for bulk-built graphs only; the next
                // THETA rebuild converges an incrementally-grown graph.
                if let hnswIdx = hnswIndices[modelID] {
                    if let floats = try? payload.asFloats() {
                        await hnswIdx.insert(itemID: itemID, modelID: modelID, vector: floats)
                        hnswGraphDirty.insert(modelID)
                    }
                }
            }
        }

        let endTime = Date().timeIntervalSince1970
        Intellectus.report(.metric(
            name: "synapsekit.index.insert_latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "SynapseKit", "model_id": modelID],
            ts: endTime
        ))
    }

    /// Bulk-upsert N typed payloads in one call — the import/migration path.
    ///
    /// This is the amortised counterpart to `addPayload` for import,
    /// migration, and any caller that has many vectors ready at once
    /// (TASK #24). It bounds the cost of large ingests:
    ///
    ///   • Each row is upserted to the `vectors` table (the durable source
    ///     of truth — O(N) table writes, unavoidable and not the disease).
    ///   • For the binary lane: prior slots for replaced keys are tombstoned
    ///     in ONE pass, all new slots are appended in ONE pass, the sidecar
    ///     is written ONCE (via appendBatch), and both indexes are rebuilt
    ///     ONCE from the final array — not per row. So a batch of N binary
    ///     vectors costs O(1) sidecar writes and O(1) index builds, versus
    ///     the per-row path's O(N) of each.
    ///   • Float32 rows mirror into the Lane D index (or invalidate it for a
    ///     lazy rebuild) once at the end.
    ///
    /// The memory-only (no-sidecar) path builds the combined array once and
    /// calls `build` once, so it is bounded too — no per-row array clone.
    ///
    /// Ordering: rows are upserted in the order supplied. Within the resident
    /// array the batch is appended after existing slots; the partition index
    /// and search results remain correct because both indexes are rebuilt
    /// from the final array. Search output is identical to inserting the same
    /// rows one-by-one (the (distance ASC, vecHash ASC, itemID ASC) total order is applied
    /// at query time, not insert time).
    ///
    /// - Parameter batch: the payloads to upsert. Empty is a no-op.
    public func addPayloads(_ batch: [VectorPayloadInput]) async throws {
        guard !batch.isEmpty else { return }

        let startTime = Date().timeIntervalSince1970

        // 1. Upsert every row to the table (durable source of truth).
        // Partition batch into shadow writes (for models with an active 'building'
        // shadow) and serving writes (all others). Shadow writes land in the table
        // only — they must NOT enter the resident array or float indices. Serving
        // writes follow the existing path unchanged.
        var shadowInputs: [VectorPayloadInput] = []
        var servingInputs: [VectorPayloadInput] = []
        for input in batch {
            let shadowGen = try await _shadowGeneration(for: input.modelID)
            let writeGen: Int64
            let isShadow: Bool
            if let sg = shadowGen {
                writeGen = sg; isShadow = true
            } else {
                writeGen = try await _servingGeneration(for: input.modelID); isShadow = false
            }
            if isShadow {
                shadowPayloadBytes[input.modelID, default: 0] += Int64(input.payload.bytes.count)
                shadowInputs.append(input)
            } else {
                servingInputs.append(input)
            }
            let values: [String: TypedValue] = [
                "id":           .uuid(UUID()),
                "item_id":      .text(input.itemID),
                "vector_index": .int(Int64(input.vectorIndex)),
                "model_id":     .text(input.modelID),
                "model_version":.text(input.modelVersion),
                "kind":         .int(Int64(input.payload.kind.rawValue)),
                "dim":          .int(Int64(input.payload.dim)),
                "payload":      .blob(Data(input.payload.bytes)),
                "scale":        input.payload.scale.map { TypedValue.float(Double($0)) } ?? TypedValue.null,
                "filed_at":     .timestamp(input.filedAt),
                // Shadow-swap generation tag (§2 of the design contract).
                "generation":   .int(writeGen)
            ]
            _ = try await storage.rowStore.upsert(
                table: "vectors",
                values: values,
                conflictColumns: ["item_id", "vector_index", "model_id", "generation"]
            )
        }

        // Shadow writes are table-only; skip all resident-structure updates for them.
        let batch = servingInputs

        // 2. Mirror the binary rows into the resident array + both indexes
        //    in one amortised pass (serving writes only).
        let binaryRecords: [(key: VectorRecordKey, bytes: [UInt8])] = batch.compactMap { input in
            guard input.payload.kind == .binary else { return nil }
            let key = VectorRecordKey(
                itemID: input.itemID,
                vectorIndex: input.vectorIndex,
                modelID: input.modelID,
                modelVersion: input.modelVersion
            )
            return (key: key, bytes: input.payload.bytes)
        }

        if !binaryRecords.isEmpty {
            try await _ensureIndexBuilt()

            let batchKeys = binaryRecords.map(\.key)

            if deferredIndexActive {
                // Deferred path (bulk write): DEFER the index rebuild to
                // publishResidentIndex(). Replacement detection uses the
                // incrementally-maintained live-key set, so the whole window stays
                // O(batch) per call rather than O(N) (no per-call snapshot scan).
                var live = deferredLiveKeys ?? [:]
                var seenInBatch = Set<VKLogicalPos>()
                var newKeyCount: UInt32 = 0
                var replacedKeys = Set<VectorRecordKey>()
                for k in batchKeys {
                    let pos = VKLogicalPos(
                        itemID: k.itemID,
                        vectorIndex: k.vectorIndex,
                        modelID: k.modelID
                    )
                    if let existing = live[pos] {
                        // The durable UNIQUE key excludes modelVersion, so every
                        // full key already resident at this logical position is
                        // superseded — including an old model version.
                        replacedKeys.formUnion(existing)
                    } else if !seenInBatch.contains(pos) {
                        newKeyCount += 1
                    }
                    seenInBatch.insert(pos)
                    live[pos] = [k]
                }
                if let store = arrayStore {
                    // Sidecar present: stage into the resident array store now.
                    await store.tombstoneDeferred(keys: replacedKeys)
                    try await store.appendBatch(records: binaryRecords)
                }
                // Retain the compact delta in both sidecar and memory-only
                // modes. Small publications apply it directly to the resident
                // indexes; large publications materialize the final snapshot.
                deferredPendingRecords.append(contentsOf: binaryRecords)
                deferredReplacedKeys.formUnion(replacedKeys)
                deferredLiveKeys = live
                liveBinaryCount += newKeyCount
                deferredIndexDirty = true
                // Back-pressure (memory-only path): if the buffer has grown past
                // the cap, flush it now to prevent unbounded RAM growth.
                // The intermediate flush merges all accumulated records into the
                // resident index in one pass, clears the buffer, reseeds
                // deferredLiveKeys from the new snapshot, and recomputes
                // liveBinaryCount — while keeping deferredIndexActive = true
                // so the burst continues uninterrupted for the caller.
                // This bounds peak RAM to roughly deferredPendingLimit × record
                // size regardless of how many addPayloads calls are made within
                // one deferred window.
                if arrayStore == nil && deferredPendingRecords.count > deferredPendingLimit {
                    await _flushDeferredPending()
                }
                // Indexes intentionally NOT rebuilt and _selectIndex NOT called
                // here: publishResidentIndex() (or the next intermediate flush)
                // does both once.
            } else {
                // Immediate path (default — single captures and every direct
                // caller): rebuild both indexes once from the final snapshot.
                //
                // Determine which keys in the batch replace a live slot (so the
                // live count only grows by the number of genuinely new logical
                // positions). Match by (itemID, vectorIndex, modelID), NOT by
                // full VectorRecordKey, so a changed modelVersion is still
                // recognised as a replacement (secfix/ws2-coredelete).
                let preSnap = await bruteForceIndex.currentSnapshot()

                // Build a map from logical position to all live full keys at
                // that position (may include stale modelVersion slots).
                var liveByPos: [VKLogicalPos: Set<VectorRecordKey>] = [:]
                for i in 0..<Int(preSnap.count) where !preSnap.isTombstoned(i) {
                    let k = preSnap.keys[i]
                    let pos = VKLogicalPos(itemID: k.itemID, vectorIndex: k.vectorIndex, modelID: k.modelID)
                    liveByPos[pos, default: []].insert(k)
                }

                // Count genuinely new logical positions.
                var seenPosInBatch = Set<VKLogicalPos>()
                var newKeyCount: UInt32 = 0
                for k in batchKeys {
                    let pos = VKLogicalPos(itemID: k.itemID, vectorIndex: k.vectorIndex, modelID: k.modelID)
                    let isNew = liveByPos[pos] == nil && !seenPosInBatch.contains(pos)
                    if isNew { newKeyCount += 1 }
                    seenPosInBatch.insert(pos)
                }

                // Collect ALL live keys that the batch covers (including stale
                // modelVersion slots that exact-key intersection would miss).
                let batchPositions = Set(batchKeys.map {
                    VKLogicalPos(itemID: $0.itemID, vectorIndex: $0.vectorIndex, modelID: $0.modelID)
                })
                var allStaleKeys = Set<VectorRecordKey>()
                for pos in batchPositions {
                    if let stale = liveByPos[pos] { allStaleKeys.formUnion(stale) }
                }

                if let store = arrayStore {
                    // Tombstone every replaced full key in one pass (including
                    // stale modelVersion slots), append the whole batch in one
                    // pass, write the sidecar once.
                    await store.tombstoneDeferred(keys: allStaleKeys)
                    try await store.appendBatch(records: binaryRecords)
                    // Rebuild both indexes ONCE from the final snapshot.
                    let snap = await store.snapshot()
                    await bruteForceIndex.build(from: snap)
                    await mihIndex.build(from: snap)
                } else {
                    // Memory-only: merge batch into snapshot. mergeBatchIntoSnapshot
                    // uses logical-position tombstoning to cover stale modelVersion
                    // slots, then build both indexes once.
                    let merged = Self.mergeBatchIntoSnapshot(
                        snapshot: preSnap,
                        records: binaryRecords
                    )
                    await bruteForceIndex.build(from: merged)
                    await mihIndex.build(from: merged)
                }

                liveBinaryCount += newKeyCount
                _selectIndex()
            }
        }

        // 3. Float lane: invalidate the Lane D index for every modelID that has
        //    a float row in the batch, so the next findNearestFloat rebuilds
        //    that model's index once from the table. A lazy rebuild is cheaper
        //    than N incremental float adds and matches the delete-path coherence
        //    policy. Dropping the map entry is the invalidation (its presence is
        //    the built flag); other models' indices are untouched.
        if storage.configuration.residencyHint == .ramResident {
            // diskBacked scans SQLite directly (no cache). ramResident still
            // uses floatIndices — invalidate so stale entries don't survive.
            // The batch may have REPLACED existing float rows (upsert), so
            // each touched model's HNSW lane is invalidated alongside — a
            // stale graph would otherwise keep serving the pre-batch vector
            // bytes (VH-01 Finding A). floatIndices keeps its historical
            // unscoped removeAll; the HNSW invalidation is scoped to the
            // models actually present in the batch.
            let touchedFloatModels = Set(
                batch.lazy.filter { $0.payload.kind == .float32 }.map(\.modelID))
            if !touchedFloatModels.isEmpty {
                floatIndices.removeAll()
                for modelID in touchedFloatModels {
                    _invalidateHNSWLane(for: modelID)
                }
            }
        }

        let endTime = Date().timeIntervalSince1970
        Intellectus.report(.metric(
            name: "synapsekit.index.batch_insert_latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "SynapseKit", "batch_size": "\(batch.count)"],
            ts: endTime
        ))
    }

    // MARK: - Deferred-index bulk writes

    /// Enter deferred-index mode for a burst of `addPayloads` writes.
    ///
    /// While active, each `addPayloads` appends to the durable table and the
    /// resident array but defers the MIH + brute-force index rebuild;
    /// `publishResidentIndex()` rebuilds once at the end. The corpus ingest drain
    /// wraps a drain burst in begin/publish so a bulk import pays ONE index
    /// rebuild instead of one per write (O(N) vs O(N²)). Idempotent: re-entering
    /// an already-active window keeps the existing seeded live-key set.
    ///
    /// Works with OR without a sidecar: with a sidecar, deferred writes go to the
    /// resident array store; without one (the current CorpusKit/serve resident
    /// array is memory-only), they accumulate in `deferredPendingRecords` and the
    /// single rebuild at publish merges them in one pass.
    public func beginDeferredIndex() async throws {
        guard !deferredIndexActive else { return }
        try await _ensureIndexBuilt()
        // Seed live keys from the currently-published snapshot so replacement
        // detection across the window is O(batch), not O(N), per call.
        let snap = await bruteForceIndex.currentSnapshot()
        var keys: [VKLogicalPos: Set<VectorRecordKey>] = [:]
        keys.reserveCapacity(Int(snap.count))
        for i in 0..<Int(snap.count) where !snap.isTombstoned(i) {
            let key = snap.keys[i]
            let pos = VKLogicalPos(
                itemID: key.itemID,
                vectorIndex: key.vectorIndex,
                modelID: key.modelID
            )
            keys[pos, default: []].insert(key)
        }
        deferredLiveKeys = keys
        deferredPendingRecords = []
        deferredReplacedKeys = []
        deferredIndexDirty = false
        deferredIndexActive = true
    }

    /// Rebuild the resident MIH + brute-force index once from the final resident
    /// array snapshot, ending deferred-index mode.
    ///
    /// A no-op rebuild (but still clears the mode) when nothing was deferred since
    /// the last publish. Called by the corpus ingest drain when a burst drains to
    /// empty, and by `awaitIngestDrain` so the index is current before the barrier
    /// reports the writes searchable.
    public func publishResidentIndex() async throws {
        let wasDirty = deferredIndexDirty
        deferredIndexActive = false
        deferredIndexDirty = false
        deferredLiveKeys = nil
        let pending = deferredPendingRecords
        deferredPendingRecords = []
        let replaced = deferredReplacedKeys
        deferredReplacedKeys = []
        guard wasDirty else { return }

        let delta = Self.dedupLastWins(pending)
        if delta.count <= Self.incrementalPublishLimit,
           incrementalPublicationCount < Self.incrementalCompactionInterval
        {
            for key in replaced {
                try await bruteForceIndex.remove(key: key)
                try await mihIndex.remove(key: key)
            }
            for record in delta {
                let payload = VectorPayload(
                    kind: .binary, dim: 256, bytes: record.bytes)
                try await bruteForceIndex.add(key: record.key, vector: payload)
                try await mihIndex.add(key: record.key, vector: payload)
            }
            incrementalPublicationCount += 1
            _selectIndex()
            return
        }

        let merged: ResidentVectorArray
        if let store = arrayStore {
            // Sidecar path: the records were staged into the array store.
            merged = await store.snapshot()
        } else {
            // Memory-only: merge every accumulated record into the pre-burst
            // snapshot in ONE pass. Dedup last-wins so a key re-ingested within
            // the window keeps its latest bytes (mergeBatchIntoSnapshot appends
            // every record, so a duplicate key must not produce two live slots).
            let cur = await bruteForceIndex.currentSnapshot()
            merged = Self.mergeBatchIntoSnapshot(
                snapshot: cur,
                records: delta
            )
        }
        await bruteForceIndex.build(from: merged)
        await mihIndex.build(from: merged)
        // Recompute the live count authoritatively from the final snapshot so any
        // incremental drift over the window is corrected.
        var liveCount: UInt32 = 0
        for i in 0..<Int(merged.count) where !merged.isTombstoned(i) { liveCount += 1 }
        liveBinaryCount = liveCount
        incrementalPublicationCount = 0
        _selectIndex()
    }

    /// Intermediate flush for the memory-only deferred buffer.
    ///
    /// Called when `deferredPendingRecords` exceeds `deferredPendingLimit` during
    /// a deferred burst. Merges the accumulated records into the resident index in
    /// one pass, clears the buffer, reseeds `deferredLiveKeys` from the resulting
    /// snapshot, and recomputes `liveBinaryCount`. `deferredIndexActive` is kept
    /// `true` so the caller's burst window continues uninterrupted — this is an
    /// internal back-pressure valve, not an end of burst.
    ///
    /// Not called for the sidecar path: with a sidecar, records are staged into
    /// `arrayStore` immediately (no in-memory buffer to flush).
    private func _flushDeferredPending() async {
        guard !deferredPendingRecords.isEmpty else { return }
        let pending = Self.dedupLastWins(deferredPendingRecords)
        deferredPendingRecords = []
        deferredReplacedKeys = []
        let cur = await bruteForceIndex.currentSnapshot()
        let merged = Self.mergeBatchIntoSnapshot(snapshot: cur, records: pending)
        await bruteForceIndex.build(from: merged)
        await mihIndex.build(from: merged)
        // Recompute live count and reseed the live-key set authoritatively from
        // the flushed snapshot so subsequent replacement detection remains correct.
        var liveCount: UInt32 = 0
        var liveKeys: [VKLogicalPos: Set<VectorRecordKey>] = [:]
        for i in 0..<Int(merged.count) where !merged.isTombstoned(i) {
            liveCount += 1
            let key = merged.keys[i]
            let pos = VKLogicalPos(
                itemID: key.itemID,
                vectorIndex: key.vectorIndex,
                modelID: key.modelID
            )
            liveKeys[pos, default: []].insert(key)
        }
        liveBinaryCount = liveCount
        deferredLiveKeys = liveKeys
        incrementalPublicationCount = 0
        // deferredIndexActive stays true, deferredIndexDirty stays true.
    }

    /// Keep only the last occurrence at each durable logical position.
    /// `modelVersion` is deliberately excluded: several revisions in one
    /// deferred burst must publish only the final version at the table's
    /// `(itemID, vectorIndex, modelID)` UNIQUE key.
    private static func dedupLastWins(
        _ records: [(key: VectorRecordKey, bytes: [UInt8])]
    ) -> [(key: VectorRecordKey, bytes: [UInt8])] {
        guard !records.isEmpty else { return records }
        var lastIndex: [VKLogicalPos: Int] = [:]
        lastIndex.reserveCapacity(records.count)
        for (i, r) in records.enumerated() {
            lastIndex[VKLogicalPos(
                itemID: r.key.itemID,
                vectorIndex: r.key.vectorIndex,
                modelID: r.key.modelID
            )] = i
        }
        var out: [(key: VectorRecordKey, bytes: [UInt8])] = []
        out.reserveCapacity(lastIndex.count)
        for (i, r) in records.enumerated() {
            let pos = VKLogicalPos(
                itemID: r.key.itemID,
                vectorIndex: r.key.vectorIndex,
                modelID: r.key.modelID
            )
            if lastIndex[pos] == i { out.append(r) }
        }
        return out
    }

    /// Flush any pending write-behind mutations to disk.
    ///
    /// Two flush duties:
    ///
    /// 1. **Sidecar flush** — the `addPayload` binary path is write-behind: it
    ///    mutates the in-memory resident array and marks the sidecar dirty
    ///    without writing. The sidecar is persisted here (no-op when nothing is
    ///    dirty or when there is no sidecar). Crash safety does not depend on
    ///    flush: the `vectors` table is the durable source and the sidecar is
    ///    rebuilt on the next open if it is stale.
    ///
    /// 2. **HNSW graph flush** — encode-path inserts (`addPayload` → HNSW
    ///    mirror) mark affected modelID partitions in `hnswGraphDirty`. This
    ///    call persists any dirty partition to the `hnsw_graph` table so the
    ///    updated topology survives process restart. No-op when no partition is
    ///    marked dirty.
    ///
    /// Call at a quiesce point (after an import loop, before process exit, or
    /// on a periodic checkpoint).
    public func flush() async throws {
        // Persist HNSW partitions dirtied by encode-path inserts.
        if !hnswGraphDirty.isEmpty {
            // Snapshot and clear before the async writes so concurrent inserts
            // that arrive during the flush round-trip are captured in the NEXT
            // flush call, not silently dropped.
            let dirtyPartitions = hnswGraphDirty
            hnswGraphDirty.removeAll(keepingCapacity: false)
            for modelID in dirtyPartitions {
                try await _persistHNSWGraph(for: modelID)
            }
        }
        try await arrayStore?.flush()
    }

    /// Merge a batch of (key, bytes) records into a snapshot in one pass.
    ///
    /// Used by the memory-only `addPayloads` path. Replaced keys (present in
    /// the snapshot, live) are tombstoned in place; the new slots are
    /// appended after the existing storage. Produces a single array the
    /// indexes build from once — no per-row clone.
    private static func mergeBatchIntoSnapshot(
        snapshot: ResidentVectorArray,
        records: [(key: VectorRecordKey, bytes: [UInt8])]
    ) -> ResidentVectorArray {
        // Tombstone any live slot whose logical position (itemID, vectorIndex,
        // modelID) matches a record in the batch, including stale modelVersion
        // slots. Matching by full VectorRecordKey would miss stale modelVersion
        // slots and leave ghost copies in the resident array
        // (secfix/ws2-coredelete: hard-delete destruction contract).
        let replacedPositions = Set(records.map {
            VKLogicalPos(itemID: $0.key.itemID, vectorIndex: $0.key.vectorIndex, modelID: $0.key.modelID)
        })
        var newTombstones = snapshot.tombstones
        for slotIdx in 0..<Int(snapshot.count) {
            let k = snapshot.keys[slotIdx]
            let pos = VKLogicalPos(itemID: k.itemID, vectorIndex: k.vectorIndex, modelID: k.modelID)
            if replacedPositions.contains(pos) {
                ResidentArrayStore.setTombstoneBit(&newTombstones, slot: slotIdx)
            }
        }

        var newStorage = snapshot.storage
        newStorage.reserveCapacity(newStorage.count + records.count * Int(snapshot.stride))
        var newKeys = snapshot.keys
        newKeys.reserveCapacity(newKeys.count + records.count)
        for r in records {
            newStorage.append(contentsOf: r.bytes)
            newKeys.append(r.key)
        }

        let newCount = UInt32(newKeys.count)
        let wordsNeeded = (Int(newCount) + 63) / 64
        while newTombstones.count < wordsNeeded { newTombstones.append(0) }
        let newPartitions = ResidentArrayStore.buildPartitions(keys: newKeys, tombstones: newTombstones)
        return ResidentVectorArray(
            kind: snapshot.kind,
            stride: snapshot.stride,
            count: newCount,
            storage: newStorage,
            keys: newKeys,
            modelPartitions: newPartitions,
            tombstones: newTombstones
        )
    }

    // MARK: - Read (binary convenience path)

    /// Fetch the Engram stored under (itemID, modelID) at vectorIndex 0,
    /// or nil if no row exists.
    public func getVector(
        itemID: String,
        modelID: String
    ) async throws -> Engram? {
        guard let payload = try await getPayload(
            itemID: itemID,
            vectorIndex: 0,
            modelID: modelID
        ) else { return nil }
        return try payload.asEngram()
    }

    /// Fetch the VectorPayload stored under (itemID, vectorIndex, modelID),
    /// or nil if no row exists.
    public func getPayload(
        itemID: String,
        vectorIndex: UInt32,
        modelID: String
    ) async throws -> VectorPayload? {
        // Filter to serving generation so shadow rows are never surfaced.
        let servingGen = try await _servingGeneration(for: modelID)
        let predicate = StoragePredicate.and([
            .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
            .eq(Column(table: "vectors", name: "vector_index"), .int(Int64(vectorIndex))),
            .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
            .eq(Column(table: "vectors", name: "generation"), .int(servingGen))
        ])
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: predicate,
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        return Self.decodePayload(from: row)
    }

    /// Return every row for itemID, ordered by filed_at ASC.
    public func vectors(forItemID itemID: String) async throws -> [StoredVector] {
        // Use the table-wide serving-gen predicate so shadow rows are excluded.
        // vectors(forItemID:) scans all models for this item, so we use _servingGenPredicate
        // which handles every model's serving generation.
        let genFilter = try await _servingGenPredicate()
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
                genFilter
            ]),
            orderBy: [
                OrderClause(
                    column: Column(table: "vectors", name: "filed_at"),
                    direction: .ascending
                )
            ],
            limit: nil,
            offset: nil
        )
        var out: [StoredVector] = []
        for row in rows {
            guard let stored = Self.storedVector(from: row) else { continue }
            out.append(stored)
        }
        return out
    }

    // MARK: - Search

    /// k-nearest-neighbours by Hamming distance, using the resident
    /// packed array — no per-query SQLite fetch.
    ///
    /// Dispatches through the DenseIndex seam. Below `mihThreshold` live
    /// binary vectors the active index is BruteForceIndex (Lane A, O(N)
    /// kernel scan, sub-millisecond). At/above the threshold the active
    /// index is MIHIndex (Lane B, sub-linear EXACT). Both indexes return
    /// IDENTICAL results — the Lane B conformance gate proves this.
    ///
    /// On the first call, _ensureIndexBuilt() populates the resident array
    /// from the .vec sidecar (one mmap load) or from a single full-table
    /// read (amortised: paid once per process lifetime). Subsequent calls
    /// scan the in-memory packed array — O(N × stride) bytes walked for
    /// brute-force, or sub-linear for MIH, not O(N) SQLite row fetches.
    ///
    /// All Hamming arithmetic routes through the active DenseIndex →
    /// EngramLib → SubstrateKernel (I-7 absolute, arch spec §3.4).
    ///
    /// Returns up to `limit` matches sorted by (distance ASC, vecHash ASC,
    /// itemID ASC) — the universal tie-break rule (SPEC 1.9.0 B-6; vecHash
    /// is the FNV-1a content hash, stable across estate provisionings).
    ///
    /// Telemetry: emits `synapsekit.search.latency_ms` and
    /// `synapsekit.search.result_count` when monitoring is enabled.
    public func findNearest(
        probe: Engram,
        modelID: String,
        limit: Int,
        metric: DenseMetric = .binary(.hamming)
    ) async throws -> [VectorMatch] {
        let startTime = Date().timeIntervalSince1970

        // Populate the resident index on first call (amortised, not per-query).
        try await _ensureIndexBuilt()

        guard limit > 0 else { return [] }

        // Convert probe Engram to the typed payload the binary engine expects.
        let probePayload = VectorPayload(engram: probe)

        // Restrict the scan to this model's partition via MetadataFilter.
        // BruteForceIndex resolves this to a partition range in O(log m)
        // and walks only the model's slots — not the full array.
        // MIHIndex applies the same filter per-candidate during band probing.
        let filter = MetadataFilter(modelID: modelID)

        // Delegate all Hamming arithmetic to the active DenseIndex (I-7).
        // hotIndex is either bruteForceIndex or mihIndex — both implement the
        // DenseIndex seam and produce identical results (conformance gate).
        // Jaccard (W2.5 M1) always routes to the brute-force engine: MIH's
        // band structure is Hamming-specific and cannot serve Jaccard order.
        // Hamming keeps the hot index (brute force or MIH, conformance-gated).
        let servingIndex: any DenseIndex
        if case .binary(.jaccard) = metric {
            servingIndex = bruteForceIndex
        } else {
            servingIndex = hotIndex
        }
        let hits = try await servingIndex.search(
            probe: probePayload,
            metric: metric,
            k: limit,
            filter: filter
        )

        // Both indexes apply the (distance ASC, vecHash ASC, itemID ASC)
        // sort per the oracle contract (SPEC 1.9.0 B-6).
        // Map DenseHit → VectorMatch without re-sorting.
        // D5: tag with serving generation. The binary resident array is built from
        // serving-gen rows (_fetchAllBinaryRecords filters to servingGen), so all
        // hits are serving-gen rows. MetadataFilter restricts to modelID, so all
        // hits share the same modelID and one servingGen lookup covers all.
        let servingGen = try await _servingGeneration(for: modelID)
        let result: [VectorMatch] = hits.map { hit in
            // Jaccard (W2.5 M1): rawDistance is a Float bit pattern.
            // VectorMatch.distance must stay a MONOTONE ordering key — map
            // the [0,1] jaccard distance onto the 0…256 integer scale
            // (matching Hamming's range so shared consumers keep working)
            // and carry the exact similarity in `score`.
            if let jd = hit.jaccardDistance {
                return VectorMatch(
                    itemID: hit.key.itemID,
                    distance: Int((jd * 256.0).rounded()),
                    modelID: hit.key.modelID,
                    generation: servingGen,
                    score: 1.0 - jd
                )
            }
            return VectorMatch(
                itemID: hit.key.itemID,
                distance: Int(hit.rawDistance),
                modelID: hit.key.modelID,
                generation: servingGen
            )
        }

        let endTime = Date().timeIntervalSince1970
        let resultCount = result.count
        Intellectus.report(.metric(
            name: "synapsekit.search.latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "SynapseKit", "model_id": modelID],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "synapsekit.search.result_count",
            value: Double(resultCount),
            tags: ["kit": "SynapseKit", "model_id": modelID],
            ts: endTime
        ))

        return result
    }

    /// k-nearest-neighbours over the float32 (Lane D) vectors by cosine
    /// distance, using the in-house FloatBruteForceIndex — the production
    /// exact path (Bob's storage amendment 2026-06-12: no external engine).
    ///
    /// On the `.ramResident` path the float index is built lazily on the first
    /// qualifying call and cached in heap; subsequent calls scan the resident
    /// array. If the projected index size would exceed the estate's
    /// `residentIndexBudget` ceiling, the index is not cached and the query
    /// falls back to the table-scan path. The scan restricts to `modelID`'s
    /// partition (spec I-4: cross-model comparisons forbidden).
    ///
    /// Cosine is the float lane's ranking metric: it is scale-invariant, so
    /// the answer-vs-question-echo case the SimHash-Hamming lane could not
    /// separate (a 256-bit projection of a 384-d vector loses the magnitude
    /// signal) ranks correctly here. Results are sorted by (cosine distance
    /// ASC, itemID ASC) — the universal tie-break (retrieval algorithms ref
    /// §0.3), applied inside FloatBruteForceIndex.
    ///
    /// Determinism: the float lane is reproducible-within-config, NOT
    /// four-way bit-identical (arch spec §6). Rank order is stable across
    /// languages on shared fixtures; raw cosine values are not asserted
    /// bit-identical.
    ///
    /// - Parameters:
    ///   - probe: the query's pooled float vector (from
    ///     `EmbeddingProvider.embedFloat`). Its dimension must match the
    ///     stored float vectors for `modelID`.
    ///   - modelID: restricts the scan to this model's partition.
    ///   - limit: maximum number of matches to return.
    /// - Returns: up to `limit` matches, nearest first. Empty if `limit`
    ///   is non-positive, the probe is empty, or no float rows exist.
    ///
    /// Residency dispatch: `.diskBacked` always scans SQLite directly (no heap copy).
    /// `.ramResident` attempts to serve from a cached FloatBruteForceIndex via
    /// `_findNearestFloatCached`. When the cache returns `nil` — because the estate's
    /// `residentIndexBudget` ceiling is exceeded or no rows exist — execution falls
    /// through to the same table-scan path that `.diskBacked` uses. The query always
    /// returns correct results; a refused index is a cache miss, not an error.
    /// k-NEAREST neighbours over the float32 (Lane D) vectors.
    ///
    /// - Parameters:
    ///   - probe: the query's pooled float vector.
    ///   - modelID: restricts the scan to this model's partition.
    ///   - limit: maximum number of matches to return.
    ///   - metric: the distance function. Defaults to `.cosine` so callers that
    ///     do not pass a metric see byte-identical behaviour (no silent change).
    ///     The ramResident (brute-force / HNSW) and diskBacked (table-scan) paths
    ///     both respect this parameter.
    public func findNearestFloat(
        probe: [Float],
        modelID: String,
        limit: Int,
        metric: FloatMetric = .cosine
    ) async throws -> [VectorMatch] {
        guard limit > 0, !probe.isEmpty else { return [] }
        if storage.configuration.residencyHint == .ramResident,
           let cached = try await _findNearestFloatCached(probe: probe, modelID: modelID, limit: limit, metric: metric) {
            return cached
        }
        // Table-scan path: used for .diskBacked estates, after admission refusal,
        // and when no float rows exist for the model.
        // D5: fetch serving generation before the scan so VectorMatch can be tagged.
        // _floatScanFromTable also fetches it internally (D1 fix) — the second call
        // hits the in-memory servingGenerations cache and costs nothing.
        let servingGen = try await _servingGeneration(for: modelID)
        let hits = try await _floatScanFromTable(
            modelID: modelID, probe: probe, k: limit, direction: .nearest, metric: metric)
        return hits.map { hit in
            VectorMatch(
                itemID: hit.key.itemID,
                distance: Int((hit.distance * 10_000).rounded()),
                modelID: hit.key.modelID,
                generation: servingGen  // D5: rows are filtered to servingGen by _floatScanFromTable
            )
        }
    }

    /// Float NN search via the cached FloatBruteForceIndex (ramResident path).
    ///
    /// Builds the FloatBruteForceIndex lazily on first call for a given modelID via
    /// `_buildFloatIndexIfAdmitted`, which applies the estate's `residentIndexBudget`
    /// admission ceiling. At/above `hnswThreshold` live float vectors, queries are
    /// routed through the HNSW approximate index (also built lazily on first qualifying
    /// call) for sub-linear nearest-neighbour performance. Below the threshold the exact
    /// FloatBruteForceIndex is used (O(N) scan, always sub-millisecond at small N).
    ///
    /// Returns `nil` when the index was not admitted (ceiling exceeded) or when no
    /// float rows exist for the model. A `nil` return signals the public caller to fall
    /// through to the table-scan path, which returns correct results. One seam: the
    /// table-scan path lives only in `findNearestFloat`, not duplicated here.
    ///
    /// Farthest queries always use FloatBruteForceIndex regardless of threshold —
    /// HNSW is a nearest-only structure. See `_findFarthestFloatCached`.
    private func _findNearestFloatCached(probe: [Float], modelID: String, limit: Int, metric: FloatMetric = .cosine) async throws -> [VectorMatch]? {
        // D4+D5 fix: resolve serving generation once at the top. Used for:
        //   (a) generation check on the HNSW graph (D4)
        //   (b) VectorMatch generation tag on exact-scan results (D5)
        // _servingGeneration is cached in servingGenerations after first call — zero cost.
        let servingGen = try await _servingGeneration(for: modelID)

        // Build FloatBruteForceIndex lazily on first access for this modelID, subject
        // to the estate's residentIndexBudget admission ceiling. The brute-force index
        // is always built (when admitted); farthest queries depend on it even when HNSW
        // is active for nearest queries.
        if floatIndices[modelID] == nil {
            guard let index = try await _buildFloatIndexIfAdmitted(modelID: modelID) else {
                // Not admitted (ceiling exceeded) or no rows.
                // nil signals the public caller to fall through to the table-scan path.
                return nil
            }
            floatIndices[modelID] = index
        }

        // Route to HNSW when the live float count reaches the crossover threshold.
        // Below the threshold FloatBruteForceIndex is faster — brute-force is
        // bandwidth-bound and at 5 000 vectors the scan takes ~1 µs, while the
        // HNSW graph construction + pointer-chasing overhead exceeds that.
        let liveCount = liveFloatCounts[modelID] ?? 0
        if liveCount >= hnswThreshold {
            // Serve from the in-memory graph if already loaded or built.
            // If not, attempt to load from the persisted hnsw_graph table.
            // The query path NEVER triggers an inline graph build — builds are
            // scheduled through DreamingDaemon's THETA cadence. If no rows
            // exist in the table (first run, or after ALPHA clear),
            // _loadHNSWGraphIfPresent returns without mutating hnswIndices and
            // the exact-scan fallback below handles the query.
            if hnswIndices[modelID] == nil {
                try await _loadHNSWGraphIfPresent(for: modelID)
            }
            if let hnswIndex = hnswIndices[modelID] {
                // §4 of the design contract: check the graph's generation BEFORE
                // use. A stale graph (generation ≠ serving_gen) is treated as
                // absent and falls through to exact scan. This is the mechanism
                // that makes the swap immune to the inherited stale-cache defect
                // without repairing the invalidation path (BRR §4 INTENTIONALLY_LEFT).
                let graphGen = await hnswIndex.generation
                if graphGen == servingGen {
                    // HNSWIndex.search is synchronous (actor-isolated, no async work);
                    // `await` crosses the actor boundary.
                    let results = try await hnswIndex.search(probe: probe, modelID: modelID, k: limit)
                    // Record the generation of the graph instance that answered this query.
                    lastServedGraphGen[modelID] = graphGen
                    return results
                }
                // D4 fix: stale graph — discard and fall through to the SHARED
                // exact-scan path below. Do NOT duplicate the fallback here.
                // ONE seam: interrupt case 4 (crash between publish and HNSW rebuild)
                // must serve real results from the exact lane, never return nil.
                // The float index IS built above (admission succeeded), so in practice
                // the guard-let below always serves.
                hnswIndices.removeValue(forKey: modelID)
            }
            // No resident graph (none persisted, or stale graph just discarded)
            // — fall through to exact scan.
        }

        // Below threshold or no HNSW graph available: exact scan via FloatBruteForceIndex.
        // FloatBruteForceIndex was built from serving-gen rows (_fetchFloatRecords filters
        // to servingGen). D5: tag matches with servingGen to satisfy the generation contract.
        guard let modelIndex = floatIndices[modelID] else { return nil }
        let probePayload = VectorPayload(floats: probe)
        let filter = MetadataFilter(modelID: modelID)
        // Pass the caller-selected float metric. DenseMetric.float(_) wraps FloatMetric
        // for the FloatBruteForceIndex.search API. Default is .cosine.
        let hits = try await modelIndex.search(probe: probePayload, metric: .float(metric), k: limit, filter: filter)
        return hits.map { hit in
            VectorMatch(
                itemID: hit.key.itemID,
                distance: Int(((hit.floatDistance ?? 1.0) * 10_000).rounded()),
                modelID: hit.key.modelID,
                generation: servingGen  // D5: FloatBruteForceIndex built from serving rows
            )
        }
    }

    /// k-FARTHEST neighbours over the float32 (Lane D) vectors —
    /// the most DISSIMILAR rows first (anti-similarity retrieval, mission
    /// 6b-modifiers-antisim). The "find things UNLIKE this" objective.
    ///
    /// Identical to `findNearestFloat` in every respect — same lazy per-model
    /// index build, same modelID partition scope (spec I-4), same cosine
    /// metric, same VectorMatch quantisation — EXCEPT it ranks by FARTHEST:
    /// the bottom-K by cosine similarity (largest cosine distance first). It
    /// is NOT a negated nearest-list; the farthest rows are not in the
    /// nearest top-K, so the index scans and orders by the opposite end via
    /// `FloatBruteForceIndex.searchFarthest`. No new distance math.
    ///
    /// Determinism: like `findNearestFloat`, the float lane is reproducible-
    /// within-config, NOT four-way bit-identical (arch spec §6). Rank order
    /// is stable across languages on shared fixtures; raw cosine values are
    /// not asserted bit-identical.
    ///
    /// - Parameters:
    ///   - probe: the query's pooled float vector. Its dimension must match
    ///     the stored float vectors for `modelID`.
    ///   - modelID: restricts the scan to this model's partition.
    ///   - limit: maximum number of matches to return.
    /// - Returns: up to `limit` matches, FARTHEST (most dissimilar) first.
    ///   Empty if `limit` is non-positive, the probe is empty, or no float
    ///   rows exist for the model.
    ///
    /// Residency dispatch: `.diskBacked` always scans SQLite directly (no heap copy).
    /// `.ramResident` attempts to serve from a cached FloatBruteForceIndex via
    /// `_findFarthestFloatCached`. When the cache returns `nil` — because the estate's
    /// `residentIndexBudget` ceiling is exceeded or no rows exist — execution falls
    /// through to the same table-scan path that `.diskBacked` uses. The query always
    /// returns correct results; a refused index is a cache miss, not an error.
    /// Always uses FloatBruteForceIndex regardless of HNSW threshold — HNSW is a
    /// nearest-only structure and anti-similarity retrieval requires a full scan
    /// that provides no speed benefit over brute-force. See `_findFarthestFloatCached`.
    /// k-FARTHEST neighbours over the float32 (Lane D) vectors.
    ///
    /// Identical to `findNearestFloat` in every respect except it ranks by FARTHEST
    /// (the most dissimilar rows first — anti-similarity retrieval). HNSW is not used
    /// regardless of threshold: HNSW is nearest-only. Always delegates to
    /// `FloatBruteForceIndex.searchFarthest` (ramResident) or `_floatScanFromTable`
    /// in descending-distance order (diskBacked).
    ///
    /// - Parameters:
    ///   - probe: the query's pooled float vector.
    ///   - modelID: restricts the scan to this model's partition.
    ///   - limit: maximum number of matches to return.
    ///   - metric: the distance function. Defaults to `.cosine`. Both the
    ///     ramResident (FloatBruteForceIndex) and diskBacked (table-scan) paths
    ///     respect this parameter so the same metric is used for nearest and
    ///     farthest queries on the same request.
    public func findFarthestFloat(
        probe: [Float],
        modelID: String,
        limit: Int,
        metric: FloatMetric = .cosine
    ) async throws -> [VectorMatch] {
        guard limit > 0, !probe.isEmpty else { return [] }
        if storage.configuration.residencyHint == .ramResident,
           let cached = try await _findFarthestFloatCached(probe: probe, modelID: modelID, limit: limit, metric: metric) {
            return cached
        }
        // Table-scan path: used for .diskBacked estates, after admission refusal,
        // and when no float rows exist for the model.
        // D5: fetch serving generation for VectorMatch generation tag.
        // _floatScanFromTable also fetches it (D1 fix) — second call hits cache.
        let servingGen = try await _servingGeneration(for: modelID)
        let hits = try await _floatScanFromTable(
            modelID: modelID, probe: probe, k: limit, direction: .farthest, metric: metric)
        return hits.map { hit in
            VectorMatch(
                itemID: hit.key.itemID,
                distance: Int((hit.distance * 10_000).rounded()),
                modelID: hit.key.modelID,
                generation: servingGen  // D5: rows filtered to servingGen by _floatScanFromTable (D1)
            )
        }
    }

    /// Farthest float search via the cached FloatBruteForceIndex (ramResident path).
    ///
    /// Always uses FloatBruteForceIndex regardless of HNSW threshold. HNSW is a
    /// nearest-only graph; anti-similarity (farthest) retrieval requires a full scan
    /// over all live nodes and gains no speed benefit from the graph structure.
    /// Builds the index lazily on first call for a given modelID via
    /// `_buildFloatIndexIfAdmitted`, which applies the estate's `residentIndexBudget`
    /// admission ceiling.
    ///
    /// Returns `nil` when the index was not admitted (ceiling exceeded) or when no
    /// float rows exist for the model. A `nil` return signals the public caller to fall
    /// through to the table-scan path. One seam: the table-scan path lives only in
    /// `findFarthestFloat`, not duplicated here.
    private func _findFarthestFloatCached(probe: [Float], modelID: String, limit: Int, metric: FloatMetric = .cosine) async throws -> [VectorMatch]? {
        // D5: resolve serving generation for VectorMatch generation tag.
        // FloatBruteForceIndex is built from serving rows (_fetchFloatRecords filters).
        let servingGen = try await _servingGeneration(for: modelID)
        if floatIndices[modelID] == nil {
            guard let index = try await _buildFloatIndexIfAdmitted(modelID: modelID) else {
                // Not admitted (ceiling exceeded) or no rows.
                // nil signals the public caller to fall through to the table-scan path.
                return nil
            }
            floatIndices[modelID] = index
        }
        guard let modelIndex = floatIndices[modelID] else { return nil }
        let probePayload = VectorPayload(floats: probe)
        let filter = MetadataFilter(modelID: modelID)
        // Pass the caller-selected float metric. DenseMetric.float(_) wraps FloatMetric
        // for the FloatBruteForceIndex.searchFarthest API. Default is .cosine.
        let hits = try await modelIndex.searchFarthest(probe: probePayload, metric: .float(metric), k: limit, filter: filter)
        return hits.map { hit in
            VectorMatch(
                itemID: hit.key.itemID,
                distance: Int(((hit.floatDistance ?? 1.0) * 10_000).rounded()),
                modelID: hit.key.modelID,
                generation: servingGen  // D5: FloatBruteForceIndex built from serving rows
            )
        }
    }

    /// Keyword pre-filter: returns item IDs whose item_id
    /// contains the query as a substring. Full BM25 keyword scoring
    /// is CorpusKit's responsibility; this surface is for hybrid-
    /// retrieval callers that need a quick keyword pass.
    ///
    /// Telemetry: emits `synapsekit.search.keyword_result_count` when enabled.
    public func findByKeyword(_ query: String, limit: Int) async throws -> [String] {
        // Empty query would become LIKE '%%', scanning every row — fail-safe: return
        // empty immediately. No caller depends on empty-query-returns-all (confirmed).
        guard !query.isEmpty else { return [] }
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
        // collected or the table is exhausted.
        var seen = Set<String>()
        var out: [String] = []
        let pageSize = 8192
        var offset = 0
        // D2 fix: build the generation predicate ONCE outside the page loop —
        // _servingGenPredicate hits the registry table and updates the in-memory cache;
        // repeating it per page would be wasteful AND would give inconsistent results
        // if a swap commits mid-iteration. The predicate is stable for this call's lifetime.
        let genFilter = try await _servingGenPredicate()
        while out.count < limit {
            // Project only `item_id` — payload blobs are irrelevant here and
            // can be enormous on rich estates. A LIKE scan over item_id is
            // already fast (item_id is short text); reading the full row would
            // transfer the payload blob from disk on every scanned row.
            // The `columns: ["item_id"]` projection pushes SELECT item_id ...
            // down into SQLite so the payload is never loaded. On the SQLite
            // backend this delegates to the overriding `query(columns:)` that
            // emits a narrow SELECT; all other backends fall back to the full
            // read, which is still correct (they return a superset of columns).
            // Note: `generation` and `model_id` are referenced in genFilter but NOT
            // in the columns projection — SQLite evaluates WHERE before SELECT, so
            // the predicate columns need not appear in the SELECT list.
            let rows = try await storage.rowStore.query(
                table: "vectors",
                where: .and([
                    .like(Column(table: "vectors", name: "item_id"), "%\(query)%"),
                    genFilter  // D2: restrict to serving-generation rows only
                ]),
                orderBy: [
                    OrderClause(
                        column: Column(table: "vectors", name: "item_id"),
                        direction: .ascending
                    )
                ],
                limit: pageSize,
                offset: offset,
                columns: ["item_id"]
            )
            for row in rows {
                if case let .text(itemID) = row["item_id"] ?? .null {
                    if seen.insert(itemID).inserted, out.count < limit {
                        out.append(itemID)
                    }
                }
            }
            if rows.count < pageSize { break }  // table exhausted
            offset += pageSize
        }

        let count = out.count
        Intellectus.report(.metric(
            name: "synapsekit.search.keyword_result_count",
            value: Double(count),
            tags: ["kit": "SynapseKit"],
            ts: Date().timeIntervalSince1970
        ))

        return out
    }

    /// The most recently filed DISTINCT item IDs, newest first.
    ///
    /// The probe-enumeration surface for sweep consumers (the contradiction
    /// hunter, VectorSimilaritySignal): a bounded sweep should examine the
    /// NEWEST content first — new memories are the ones that need
    /// contradiction/association screening against the existing estate, and
    /// a recency window composes with the hunter's `filedAfter` watermark.
    /// `findByKeyword`'s ascending-item_id order is a UUID lottery: on a
    /// 109k-chunk estate a 10k-item window is static and newly-captured
    /// chunks' content-addressed UUIDs almost never sort into it, so
    /// bounded sweeps never saw new content.
    ///
    /// `limit` counts DISTINCT item IDs (rows are many-per-item); pages the
    /// row query until `limit` IDs are collected or the table is exhausted.
    /// Ties on filed_at break by item_id ascending for determinism.
    public func recentItemIDs(limit: Int) async throws -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let pageSize = 8192
        var offset = 0
        // D3 fix: build generation predicate once before the page loop.
        // Without this filter, shadow rows from all models pollute the recency
        // window — e.g. a shadow-only item (written under beginShadowGeneration
        // but not yet published) would appear as if it were live content.
        let genFilter = try await _servingGenPredicate()
        while out.count < limit {
            // Project only `item_id` and `filed_at` — those are the only
            // columns this function needs. Combined with the composite index
            // `idx_vectors_filed_at_item` (v4, columns: [filed_at, item_id]),
            // SQLite would satisfy this as a covering index scan when `where: nil`,
            // but the generation predicate (D3) references `generation` and
            // `model_id`, which are NOT in that index. SQLite must therefore
            // consult the main table for each candidate row.
            // TRADE-OFF: correctness (only serving rows) takes priority over the
            // covering-index optimisation here. The query remains bounded (pageSize
            // limit) and the payload blob is still excluded by the column projection.
            let rows = try await storage.rowStore.query(
                table: "vectors",
                where: genFilter,  // D3: restrict to serving-generation rows only
                orderBy: [
                    OrderClause(
                        column: Column(table: "vectors", name: "filed_at"),
                        direction: .descending
                    ),
                    OrderClause(
                        column: Column(table: "vectors", name: "item_id"),
                        direction: .ascending
                    ),
                ],
                limit: pageSize,
                offset: offset,
                columns: ["item_id", "filed_at"]
            )
            for row in rows {
                if case let .text(itemID) = row["item_id"] ?? .null {
                    if seen.insert(itemID).inserted, out.count < limit {
                        out.append(itemID)
                    }
                }
            }
            if rows.count < pageSize { break }  // table exhausted
            offset += pageSize
        }
        return out
    }

    // MARK: - Shadow-swap API

    /// Begin a shadow generation for the given model IDs.
    ///
    /// For each model: shadow_generation = max(existing_shadow, serving) + 1,
    /// registry row upserted with shadow_state = 'building'. While a model has
    /// an active shadow, ALL vector writes land tagged with shadow_generation and
    /// bypass all resident structures (resident array, float indices, HNSW).
    /// Models not listed are unaffected.
    ///
    /// Re-entrant begin on a model with a pre-existing 'building' shadow (from
    /// a prior crash or abandoned reindex) DELETES the stale shadow's vectors
    /// and hnsw_graph rows before allocating a new generation. This ensures the
    /// governing invariant — every row is at its serving generation or at the
    /// currently active shadow — is restored immediately rather than waiting for
    /// a later reclaim cycle. The new shadow_gen is still max(stale, serving) + 1
    /// so no generation number is reissued.
    ///
    /// This is the crash-mid-build recovery path (Part 5).
    ///
    /// - Parameter modelIDs: Models to begin a shadow for.
    /// - Returns: Map from modelID to the allocated shadow generation number.
    @discardableResult
    public func beginShadowGeneration(modelIDs: [String]) async throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for modelID in modelIDs {
            let serving = try await _servingGeneration(for: modelID)
            let existingMax: Int64
            let rows = try await storage.rowStore.query(
                table: "vector_generations",
                where: .eq(Column(table: "vector_generations", name: "model_id"), .text(modelID)),
                orderBy: [],
                limit: nil,
                offset: nil
            )
            if let row = rows.first, case let .int(sg) = row["shadow_generation"] ?? .null {
                // Pre-existing shadow: delete its rows now (crash recovery).
                // Use max(existing shadow, serving) + 1 so no generation number
                // that might still have rows on disk is ever reissued.
                _ = try await storage.rowStore.delete(
                    table: "vectors",
                    where: .and([
                        .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                        .eq(Column(table: "vectors", name: "generation"), .int(sg))
                    ])
                )
                _ = try await storage.rowStore.delete(
                    table: "hnsw_graph",
                    where: .and([
                        .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID)),
                        .eq(Column(table: "hnsw_graph", name: "generation"), .int(sg))
                    ])
                )
                existingMax = max(sg, serving)
            } else {
                existingMax = serving
            }
            let newShadow = existingMax + 1

            // Upsert the registry row.
            _ = try await storage.rowStore.upsert(
                table: "vector_generations",
                values: [
                    "model_id":          .text(modelID),
                    "serving_generation":.int(serving),
                    "shadow_generation": .int(newShadow),
                    "shadow_state":      .text("building")
                ],
                conflictColumns: ["model_id"]
            )

            // Update caches. Record this model in openShadows so reclaim knows
            // this process instance holds the shadow lock.
            servingGenerations[modelID] = serving
            shadowGenerations[modelID] = newShadow
            shadowStates[modelID] = "building"
            shadowPayloadBytes[modelID] = 0
            openShadows.insert(modelID)
            result[modelID] = newShadow
        }
        return result
    }

    /// Atomically publish the shadow generation for the given model IDs.
    ///
    /// ONE storage transaction flips serving_generation = shadow_generation and
    /// clears shadow_generation / sets shadow_state = 'pending-reclaim' for all
    /// named models. A reader sees the old set or the new set, never a mixture.
    /// If the transaction does not commit, the old generation continues to serve.
    ///
    /// After the flip commits (and before this method returns): drops resident
    /// float/HNSW structures for the swapped models, rebuilds the HNSW graph from
    /// the new serving rows, writes hnsw_graph rows tagged with the new serving
    /// generation, deletes hnsw_graph rows of retired generations, and refreshes
    /// the binary resident array/indices so the binary lane serves the new set.
    ///
    /// A crash between flip-commit and graph rebuild leaves a graph whose generation
    /// mismatches serving → treated as absent (§4), exact lane serves correctly.
    public func publishShadowGeneration(modelIDs: [String]) async throws {
        guard !modelIDs.isEmpty else { return }

        // Collect the shadow generation for each model before the flip.
        var shadowByModel: [String: Int64] = [:]
        for modelID in modelIDs {
            let sg: Int64?
            if let cached = shadowGenerations[modelID] {
                sg = cached
            } else {
                sg = try await _shadowGeneration(for: modelID)
            }
            guard let sg else {
                // No active shadow — skip this model.
                continue
            }
            shadowByModel[modelID] = sg
        }
        guard !shadowByModel.isEmpty else { return }

        // ONE atomic transaction: serving_gen = shadow_gen, shadow_gen = NULL,
        // shadow_state = 'pending-reclaim'. A reader fetching the registry inside
        // this transaction sees the old set; after commit it sees the new set.
        try await storage.rowStore.beginTransaction()
        do {
            for (modelID, shadowGen) in shadowByModel {
                _ = try await storage.rowStore.upsert(
                    table: "vector_generations",
                    values: [
                        "model_id":          .text(modelID),
                        "serving_generation":.int(shadowGen),
                        "shadow_generation": .null,
                        "shadow_state":      .text("pending-reclaim")
                    ],
                    conflictColumns: ["model_id"]
                )
            }
            try await storage.rowStore.commitTransaction()
        } catch {
            try? await storage.rowStore.rollbackTransaction()
            throw error
        }

        // Flip committed. Update in-memory caches and close the open-shadow set.
        for (modelID, shadowGen) in shadowByModel {
            servingGenerations[modelID] = shadowGen
            shadowGenerations.removeValue(forKey: modelID)
            shadowStates[modelID] = "pending-reclaim"
            openShadows.remove(modelID)
        }

        // Post-flip: rebuild resident structures from the new serving generation.
        // Crash here leaves a generation-mismatched graph → treated as absent (§4).
        let swappedModelIDs = Array(shadowByModel.keys)

        // Drop stale float/HNSW indices for swapped models.
        for modelID in swappedModelIDs {
            floatIndices.removeValue(forKey: modelID)
            hnswIndices.removeValue(forKey: modelID)
        }

        // Delete HNSW graph rows belonging to retired generations (all generations
        // except the new serving generation for each swapped model).
        for (modelID, newServingGen) in shadowByModel {
            _ = try await storage.rowStore.delete(
                table: "hnsw_graph",
                where: .and([
                    .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID)),
                    .not(.eq(Column(table: "hnsw_graph", name: "generation"), .int(newServingGen)))
                ])
            )
        }

        // Rebuild binary resident array from the new serving rows (all models).
        try await _rebuildBinaryIndexFromTable()

        // Rebuild HNSW graph for each swapped model from the new serving float rows.
        // D6 fix: rebuildHNSWIndex now stamps the graph with the current serving
        // generation and persists it before returning. Because this call happens
        // AFTER the registry flip above, serving_generation is already the new
        // generation — no redundant setGeneration + second _persistHNSWGraph needed.
        for modelID in swappedModelIDs {
            try await rebuildHNSWIndex(for: modelID)
        }
    }

    /// Measured peak shadow payload bytes for the most recent (or current)
    /// shadow build for `modelID`. Returns 0 if no shadow has been started.
    /// The value is the sum of `payload.bytes.count` of every shadow row written.
    public func peakShadowStorageBytes(for modelID: String) -> Int64 {
        shadowPayloadBytes[modelID] ?? 0
    }

    /// Abort an in-progress or abandoned shadow generation for the given model IDs.
    ///
    /// This is the abort half of the shadow lifecycle. Every shadow MUST end via
    /// either `publishShadowGeneration` (success path) or `abandonShadowGeneration`
    /// (failure path). There is no third outcome.
    ///
    /// For each model ID:
    ///   - If shadow_state is not 'building', or shadow_generation is NULL, the
    ///     model is a no-op. Skip it. This makes the call idempotent.
    ///   - Delete every `vectors` row with that model_id AND generation equal to
    ///     the shadow generation. Serving-generation rows are NEVER deleted.
    ///   - Delete every `hnsw_graph` row with that model_id AND the same shadow
    ///     generation.
    ///   - Upsert the registry row leaving serving_generation unchanged and
    ///     setting shadow_generation = NULL and shadow_state = NULL.
    ///   - Clear the model's entries from shadowGenerations, shadowStates,
    ///     shadowPayloadBytes, and openShadows.
    ///
    /// Calling this method twice is safe: the second call finds no 'building'
    /// shadow and returns an empty map without deleting anything.
    ///
    /// - Parameter modelIDs: Models whose in-progress shadow should be aborted.
    /// - Returns: Map from modelID to the count of vectors rows deleted.
    @discardableResult
    public func abandonShadowGeneration(modelIDs: [String]) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for modelID in modelIDs {
            // Fetch the registry row directly (bypass the read-through cache so
            // we see the actual persisted state, not a cached 'building' entry
            // from a previous beginShadowGeneration call in this session).
            let rows = try await storage.rowStore.query(
                table: "vector_generations",
                where: .eq(Column(table: "vector_generations", name: "model_id"), .text(modelID)),
                orderBy: [],
                limit: 1,
                offset: nil
            )
            guard let row = rows.first,
                  case let .int(shadowGen) = row["shadow_generation"] ?? .null,
                  case let .text(state) = row["shadow_state"] ?? .null,
                  state == "building" else {
                // No 'building' shadow — nothing to abort.
                continue
            }
            let serving: Int64
            if case let .int(sg) = row["serving_generation"] ?? .null {
                serving = sg
            } else {
                serving = 0
            }

            // Delete the shadow generation's vectors rows. Serving rows are safe:
            // the predicate requires generation == shadowGen, which is > serving.
            let deletedVectors = try await storage.rowStore.delete(
                table: "vectors",
                where: .and([
                    .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                    .eq(Column(table: "vectors", name: "generation"), .int(shadowGen))
                ])
            )

            // Delete the shadow generation's hnsw_graph rows.
            _ = try await storage.rowStore.delete(
                table: "hnsw_graph",
                where: .and([
                    .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID)),
                    .eq(Column(table: "hnsw_graph", name: "generation"), .int(shadowGen))
                ])
            )

            // Clear the registry entry: serving_generation unchanged, shadow gone.
            _ = try await storage.rowStore.upsert(
                table: "vector_generations",
                values: [
                    "model_id":          .text(modelID),
                    "serving_generation":.int(serving),
                    "shadow_generation": .null,
                    "shadow_state":      .null
                ],
                conflictColumns: ["model_id"]
            )

            // Clear in-memory caches.
            shadowGenerations.removeValue(forKey: modelID)
            shadowStates.removeValue(forKey: modelID)
            shadowPayloadBytes.removeValue(forKey: modelID)
            openShadows.remove(modelID)

            if deletedVectors > 0 {
                result[modelID] = deletedVectors
            }
        }
        return result
    }

    /// The generation of the HNSW graph instance that last answered a float
    /// nearest-neighbour query for `modelID`. Returns nil if no float query has
    /// been served since this VectorStore was opened.
    ///
    /// Gate 5 reads this after publish + query to assert the swap promoted the
    /// graph to the new serving generation before the query was answered.
    public func lastServedGraphGeneration(for modelID: String) -> Int64? {
        lastServedGraphGen[modelID]
    }

    /// Idempotent, resumable, batched reclaim of superseded generation rows.
    ///
    /// Deletes `vectors` rows whose generation is neither the model's
    /// serving_generation nor a shadow generation that is GENUINELY IN FLIGHT in
    /// this process instance. A 'building' shadow is in flight only when its
    /// modelID appears in the `openShadows` set — meaning this VectorStore called
    /// `beginShadowGeneration` for that model without yet calling
    /// `publishShadowGeneration` or `abandonShadowGeneration`. A 'building' shadow
    /// whose modelID is NOT in `openShadows` was left by a prior crashed process and
    /// is treated as abandoned: its rows are deleted and the registry entry is cleared.
    ///
    /// Also deletes mismatched `hnsw_graph` rows and clears `shadow_state =
    /// 'pending-reclaim'` from the registry on unbounded passes.
    ///
    /// Killing mid-reclaim and re-running finishes without error and changes
    /// no query result (serving generation is already the committed value).
    ///
    /// - Parameter batchLimit: When non-nil, delete AT MOST this many superseded
    ///   `vectors` rows per model in this pass and leave 'pending-reclaim' registry
    ///   state intact so a subsequent call resumes. When nil (the default, used by
    ///   the production BETA path), the pass is unbounded: all superseded rows are
    ///   deleted and registry state is fully cleared. The cap exists for incremental
    ///   reclamation in resource-constrained environments and for Gate 4's
    ///   resumability test, which manufactures a partial-reclaim state by capping
    ///   the first pass below the superseded row count.
    ///
    /// Implementation: bounded passes use SELECT id … LIMIT n + DELETE WHERE id IN
    /// (those ids), never DELETE … LIMIT, which requires SQLITE_ENABLE_UPDATE_DELETE_LIMIT
    /// and is not available in all SQLite builds.
    ///
    /// - Returns: A summary of rows deleted per model for metrics.
    @discardableResult
    public func reclaimSupersededGenerations(batchLimit: Int? = nil) async throws -> [String: Int] {
        // Fetch all registry rows to find models with pending-reclaim state.
        let regRows = try await storage.rowStore.query(
            table: "vector_generations",
            where: .isTrue,
            orderBy: [],
            limit: nil,
            offset: nil
        )

        var summary: [String: Int] = [:]

        for row in regRows {
            guard case let .text(modelID) = row["model_id"] ?? .null,
                  case let .int(servingGen) = row["serving_generation"] ?? .null else { continue }

            // Determine whether a 'building' shadow is genuinely in flight:
            // only if this process instance opened it (modelID is in openShadows).
            // A 'building' shadow whose modelID is NOT in openShadows was left by
            // a prior crashed process — its rows are abandoned and must be reclaimed.
            let activeShadow: Int64?
            if case let .int(sg) = row["shadow_generation"] ?? .null,
               case let .text(state) = row["shadow_state"] ?? .null,
               state == "building",
               openShadows.contains(modelID) {
                // Genuinely in flight — protect from deletion.
                activeShadow = sg
            } else if case let .int(sg) = row["shadow_generation"] ?? .null,
                      case let .text(state) = row["shadow_state"] ?? .null,
                      state == "building",
                      !openShadows.contains(modelID) {
                // Abandoned 'building' shadow from a prior process — reclaim it now.
                // Delete its rows unconditionally before proceeding to the normal
                // superseded-generation sweep.
                _ = try await storage.rowStore.delete(
                    table: "vectors",
                    where: .and([
                        .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                        .eq(Column(table: "vectors", name: "generation"), .int(sg))
                    ])
                )
                _ = try await storage.rowStore.delete(
                    table: "hnsw_graph",
                    where: .and([
                        .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID)),
                        .eq(Column(table: "hnsw_graph", name: "generation"), .int(sg))
                    ])
                )
                // Clear the abandoned shadow from the registry.
                _ = try await storage.rowStore.upsert(
                    table: "vector_generations",
                    values: [
                        "model_id":          .text(modelID),
                        "serving_generation":.int(servingGen),
                        "shadow_generation": .null,
                        "shadow_state":      .null
                    ],
                    conflictColumns: ["model_id"]
                )
                shadowGenerations.removeValue(forKey: modelID)
                shadowStates.removeValue(forKey: modelID)
                activeShadow = nil
            } else {
                activeShadow = nil
            }

            // Build the predicate that identifies superseded vectors rows:
            // model_id = X AND generation ≠ servingGen AND (if active shadow) generation ≠ activeShadow.
            // The delete is idempotent: re-running finds zero matching rows and returns 0.
            // serving_generation is committed before this call, so correctness is unaffected
            // whether this pass completes fully or is killed mid-way.
            var predParts: [StoragePredicate] = [
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                .not(.eq(Column(table: "vectors", name: "generation"), .int(servingGen)))
            ]
            if let active = activeShadow {
                predParts.append(.not(.eq(Column(table: "vectors", name: "generation"), .int(active))))
            }
            let pred: StoragePredicate = .and(predParts)

            // Bounded pass: SELECT ids LIMIT batchLimit → DELETE WHERE id IN (...).
            // Never uses DELETE…LIMIT because SQLITE_ENABLE_UPDATE_DELETE_LIMIT is
            // absent in many SQLite builds (including the PersistenceKit-bundled one).
            let totalDeleted: Int
            if let cap = batchLimit {
                // Fetch at most `cap` row IDs matching the superseded predicate.
                let idRows = try await storage.rowStore.query(
                    table: "vectors",
                    where: pred,
                    orderBy: [],
                    limit: cap,
                    offset: nil,
                    columns: ["id"]
                )
                if idRows.isEmpty {
                    totalDeleted = 0
                } else {
                    // Build an IN predicate over the fetched IDs and delete exactly those rows.
                    let ids = idRows.compactMap { $0["id"] }
                    totalDeleted = try await storage.rowStore.delete(
                        table: "vectors",
                        where: .and([
                            .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                            .in(Column(table: "vectors", name: "id"), ids)
                        ])
                    )
                }
                // Bounded pass: leave registry state intact so the next pass can resume.
                // hnsw_graph cleanup and registry clear happen only on the unbounded pass.
                if totalDeleted > 0 {
                    summary[modelID] = totalDeleted
                }
                continue
            } else {
                totalDeleted = try await storage.rowStore.delete(
                    table: "vectors",
                    where: pred
                )
            }

            // Unbounded pass: also delete mismatched hnsw_graph rows and clear registry.

            // Delete mismatched hnsw_graph rows (any generation != serving).
            _ = try await storage.rowStore.delete(
                table: "hnsw_graph",
                where: .and([
                    .eq(Column(table: "hnsw_graph", name: "model_id"), .text(modelID)),
                    .not(.eq(Column(table: "hnsw_graph", name: "generation"), .int(servingGen)))
                ])
            )

            // Clear 'pending-reclaim' state from registry.
            if case let .text(state) = row["shadow_state"] ?? .null, state == "pending-reclaim" {
                _ = try await storage.rowStore.upsert(
                    table: "vector_generations",
                    values: [
                        "model_id":          .text(modelID),
                        "serving_generation":.int(servingGen),
                        "shadow_generation": .null,
                        "shadow_state":      .null
                    ],
                    conflictColumns: ["model_id"]
                )
                shadowStates.removeValue(forKey: modelID)
            }

            if totalDeleted > 0 {
                summary[modelID] = totalDeleted
            }
        }
        return summary
    }

    // MARK: - Delete

    /// Delete the row at (itemID, vectorIndex=0, modelID). No-op if not present.
    ///
    /// Removes from the `vectors` table AND tombstones the corresponding
    /// slot in the resident array so future findNearest calls skip it.
    public func deleteVector(itemID: String, modelID: String) async throws {
        // If a deferred-index burst is in flight, publish it first so the resident
        // index reflects every appended vector before we tombstone against it.
        if deferredIndexDirty { try await publishResidentIndex() }
        try await _deleteAndTombstone(itemID: itemID, vectorIndex: 0, modelID: modelID)
    }

    /// Delete all rows for (itemID, modelID) regardless of vector_index.
    /// Used for multi-vector items where all token vectors must be removed.
    public func deleteAllVectors(itemID: String, modelID: String) async throws {
        // Publish any in-flight deferred burst first (see deleteVector).
        if deferredIndexDirty { try await publishResidentIndex() }
        _ = try await storage.rowStore.delete(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID))
            ])
        )
        // The deletion may have removed float32 rows for this modelID.
        // Invalidate THIS model's Lane D index so the next findNearestFloat
        // rebuilds it from the table (the authoritative source) rather than
        // scanning stale float slots. The delete call carries no kind, so we
        // cannot tombstone selectively here; a lazy rebuild is correct and is
        // paid once on next search. Other models' indices are untouched
        // (dropping the map entry is the invalidation).
        // ramResident float coherence (SECURITY): drop this model's cached
        // FloatBruteForceIndex so a subsequent findNearestFloat cannot return
        // the just-deleted vectors from memory. The HNSW lane is invalidated
        // alongside (VH-01 Finding A): its nodes own raw vector bytes, so a
        // stale graph would keep serving the deleted content.
        floatIndices.removeValue(forKey: modelID)
        _invalidateHNSWLane(for: modelID)
        // Tombstone every resident slot for this (itemID, modelID) pair.
        // Only if the index has been built — if not, the delete is already
        // reflected in the table and will be absent on first build.
        if indexBuilt {
            // Iterate the brute-force array (the backing store for both indexes).
            let snap = await bruteForceIndex.currentSnapshot()
            var removed: UInt32 = 0
            for slotIdx in 0..<Int(snap.count) {
                guard !snap.isTombstoned(slotIdx) else { continue }
                let k = snap.keys[slotIdx]
                guard k.itemID == itemID && k.modelID == modelID else { continue }
                if let store = arrayStore {
                    try await store.tombstone(key: k)
                }
                // Remove from both indexes so both stay coherent.
                try await bruteForceIndex.remove(key: k)
                try await mihIndex.remove(key: k)
                removed += 1
            }
            if removed > 0 {
                liveBinaryCount = liveBinaryCount > removed ? liveBinaryCount - removed : 0
                _selectIndex()
            }
        }
    }

    /// Replace a model's ENTIRE vector set — the BATCH reindex re-embed path,
    /// deliberately SEPARATE from the shared 1-off `addPayloads` / `deleteAllVectors`
    /// (which live captures use unchanged). Those mutate the resident index PER key,
    /// and every BruteForceIndex remove/add rebuilds all partitions (O(n)), so tens
    /// of thousands of them — a full re-embed — is O(n²). This path writes the
    /// durable table in ONE transaction (bulk delete + plain insert → a single
    /// fsync, no per-row existence SELECT) and rebuilds the resident binary index
    /// ONCE from the table (O(n)). Mirrors Rust `VectorStore::replace_model_vectors`.
    public func replaceModelVectors(modelID: String, _ batch: [VectorPayloadInput]) async throws {
        // Flush any in-flight deferred burst so the table is the single source of
        // truth before the resident index is rebuilt from it below.
        if deferredIndexDirty { try await publishResidentIndex() }

        // 1. Durable table writes in ONE transaction. If the model has an active
        //    'building' shadow, replace only the shadow-generation rows (serving rows
        //    remain intact to serve queries). If no shadow, replace all rows.
        let shadowGen = try await _shadowGeneration(for: modelID)
        let servingGen = try await _servingGeneration(for: modelID)
        let writeGen = shadowGen ?? servingGen

        if shadowGen != nil {
            shadowPayloadBytes[modelID, default: 0] +=
                batch.reduce(0) { $0 + Int64($1.payload.bytes.count) }
        }

        try await storage.rowStore.beginTransaction()
        do {
            if let sg = shadowGen {
                // Shadow path: delete only shadow-generation rows for this model.
                _ = try await storage.rowStore.delete(
                    table: "vectors",
                    where: .and([
                        .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                        .eq(Column(table: "vectors", name: "generation"), .int(sg))
                    ])
                )
            } else {
                // Serving path: replace all generations for this model.
                _ = try await storage.rowStore.delete(
                    table: "vectors",
                    where: .eq(Column(table: "vectors", name: "model_id"), .text(modelID))
                )
            }
            for input in batch {
                let values: [String: TypedValue] = [
                    "id":           .uuid(UUID()),
                    "item_id":      .text(input.itemID),
                    "vector_index": .int(Int64(input.vectorIndex)),
                    "model_id":     .text(input.modelID),
                    "model_version":.text(input.modelVersion),
                    "kind":         .int(Int64(input.payload.kind.rawValue)),
                    "dim":          .int(Int64(input.payload.dim)),
                    "payload":      .blob(Data(input.payload.bytes)),
                    "scale":        input.payload.scale.map { TypedValue.float(Double($0)) } ?? TypedValue.null,
                    "filed_at":     .timestamp(input.filedAt),
                    "generation":   .int(writeGen)
                ]
                _ = try await storage.rowStore.insert(table: "vectors", values: values)
            }
            try await storage.rowStore.commitTransaction()
        } catch {
            try? await storage.rowStore.rollbackTransaction()
            throw error
        }

        // Shadow path: table-only write. Resident structures serve the current
        // serving generation and must not be rebuilt from shadow rows.
        guard shadowGen == nil else { return }

        // 2. Rebuild the resident binary index ONCE from the durable table (O(n)),
        //    and drop this model's Lane D float index so it lazily rebuilds too.
        // ramResident float coherence (SECURITY): the model's vectors were
        // replaced, so drop its cached FloatBruteForceIndex — otherwise
        // findNearestFloat would search the pre-replace vectors. The HNSW
        // lane is invalidated alongside (VH-01 Finding A): its nodes own the
        // pre-replace raw bytes and would keep serving them.
        floatIndices.removeValue(forKey: modelID)
        _invalidateHNSWLane(for: modelID)
        try await _rebuildBinaryIndexFromTable()
    }

    /// Rebuild the resident BINARY index (sidecar array + BruteForce + MIH) from
    /// the durable `vectors` table in ONE pass. Used only by the batch re-embed.
    /// Unlike `_ensureIndexBuilt` it does NOT trust the sidecar live-count (a
    /// re-embed replaces every vector with the SAME row count, so a count check
    /// would wrongly keep the stale sidecar) — it always reads the table.
    func _rebuildBinaryIndexFromTable() async throws {
        let records = try await _fetchAllBinaryRecords()
        let arr: ResidentVectorArray
        if let store = arrayStore {
            try await store.rebuild(from: records, generations: try await _generationStamp())
            arr = await store.snapshot()
        } else {
            arr = ResidentArrayStore.buildArray(from: records, kind: .binary, stride: 32)
        }
        await bruteForceIndex.build(from: arr)
        await mihIndex.build(from: arr)
        var liveCount: UInt32 = 0
        for i in 0..<Int(arr.count) where !arr.isTombstoned(i) {
            liveCount += 1
        }
        liveBinaryCount = liveCount
        indexBuilt = true
        _selectIndex()
    }

    // MARK: - Exact-key batch mutation (GLK shared-content 1.1, P0)

    /// Delete exactly the rows named by `keys` — the scoped batch-delete the
    /// shared-content migration uses instead of model-wide teardowns.
    ///
    /// Each key addresses one logical row position (itemID, vectorIndex,
    /// modelID); every modelVersion stored at that position is removed (a
    /// version bump must not orphan the stale row). Rows NOT named are never
    /// touched: one model partition may contain retained/shared keys and
    /// removed keys side by side without collateral mutation.
    ///
    /// Durable writes run in one transaction; the resident binary index is
    /// updated in one pass and Lane D float indices are invalidated only for
    /// the modelIDs the keys touch.
    public func deleteVectors(keys: [VectorExactKey]) async throws {
        guard !keys.isEmpty else { return }
        // Publish any in-flight deferred burst first so the resident index
        // reflects every appended vector before we tombstone against it.
        if deferredIndexDirty { try await publishResidentIndex() }

        let keySet = Set(keys)
        try await storage.rowStore.beginTransaction()
        do {
            for key in keySet {
                _ = try await storage.rowStore.delete(
                    table: "vectors",
                    where: .and([
                        .eq(Column(table: "vectors", name: "item_id"), .text(key.itemID)),
                        .eq(Column(table: "vectors", name: "vector_index"), .int(Int64(key.vectorIndex))),
                        .eq(Column(table: "vectors", name: "model_id"), .text(key.modelID))
                    ])
                )
            }
            try await storage.rowStore.commitTransaction()
        } catch {
            try? await storage.rowStore.rollbackTransaction()
            throw error
        }

        // Lane D coherence: a deleted key may have addressed a float row. Drop
        // ONLY the touched models' cached float indices so the next
        // findNearestFloat rebuilds them from the table; other models' float
        // indices are untouched (scoped invalidation). The HNSW lane is
        // invalidated alongside (VH-01 Finding A): a stale graph owns the
        // deleted vectors' raw bytes and would keep serving them.
        for modelID in Set(keySet.map(\.modelID)) {
            floatIndices.removeValue(forKey: modelID)
            _invalidateHNSWLane(for: modelID)
        }

        // Binary-lane coherence: tombstone every resident slot whose logical
        // position matches a deleted key, in ONE snapshot pass. Slots at other
        // positions — including other keys of the same model — are untouched.
        if indexBuilt {
            let snap = await bruteForceIndex.currentSnapshot()
            var removed: UInt32 = 0
            for slotIdx in 0..<Int(snap.count) {
                guard !snap.isTombstoned(slotIdx) else { continue }
                let k = snap.keys[slotIdx]
                let pos = VectorExactKey(
                    itemID: k.itemID, vectorIndex: Int(k.vectorIndex), modelID: k.modelID)
                guard keySet.contains(pos) else { continue }
                if let store = arrayStore {
                    try await store.tombstone(key: k)
                }
                try await bruteForceIndex.remove(key: k)
                try await mihIndex.remove(key: k)
                removed += 1
            }
            if removed > 0 {
                liveBinaryCount = liveBinaryCount > removed ? liveBinaryCount - removed : 0
                _selectIndex()
            }
        }
    }

    /// Reconcile ONE model's partition against an explicit expected key set —
    /// the scoped rebuild the shared-content migration uses instead of
    /// `replaceModelVectors` (which clears the whole partition) against
    /// shared storage.
    ///
    /// Every row in `expected` is upserted (exact-key idempotent). Every
    /// existing row of `modelID` whose (itemID, vectorIndex) is NOT named in
    /// `expected` is deleted. Rows of other models are never read or touched.
    /// This lets a rebuild retain shared representations in place while
    /// removing only the keys no lane claims.
    ///
    /// - Returns: the count of rows deleted (stale keys) and upserted.
    /// - Throws: `SynapseKitError.invalidPayload` when an input's modelID
    ///   differs from `modelID` (a cross-partition write is a caller bug).
    @discardableResult
    public func reconcileModelVectors(
        modelID: String,
        expected: [VectorPayloadInput]
    ) async throws -> (removed: Int, upserted: Int) {
        if let stray = expected.first(where: { $0.modelID != modelID }) {
            throw SynapseKitError.invalidPayload(
                "reconcileModelVectors(modelID: \(modelID)) received an input for "
                + "model \(stray.modelID) — cross-partition writes are not permitted")
        }
        if deferredIndexDirty { try await publishResidentIndex() }

        // Determine the write generation using the same logic as addPayload (1367-1376):
        // route to the active shadow if one is in flight, otherwise to the serving
        // generation. This fixes finding 98bb0fb: without a "generation" key in the
        // upsert values, conflictColumns at 3269 resolves against generation = 0
        // (the column default), making reconciled rows invisible to readers after
        // any successful swap (serving_generation > 0).
        let shadowGenForWrite = try await _shadowGeneration(for: modelID)
        let writeGen: Int64
        if let sg = shadowGenForWrite {
            writeGen = sg
        } else {
            writeGen = try await _servingGeneration(for: modelID)
        }

        // Enumerate only the model's existing keys at writeGen (not across all
        // generations). Scoping to writeGen prevents deletions of serving-
        // generation rows during an open shadow build — without this scope,
        // staleKeys is computed across all generations and can name serving-gen
        // rows as stale relative to the shadow's expected set.
        let existingRows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                .eq(Column(table: "vectors", name: "generation"), .int(writeGen))
            ]),
            orderBy: [], limit: nil, offset: nil)
        var existingKeys = Set<VectorExactKey>()
        for row in existingRows {
            guard case let .text(itemID)? = row["item_id"],
                  case let .int(vectorIndex)? = row["vector_index"] else { continue }
            existingKeys.insert(VectorExactKey(
                itemID: itemID, vectorIndex: Int(vectorIndex), modelID: modelID))
        }
        let expectedKeys = Set(expected.map {
            VectorExactKey(itemID: $0.itemID, vectorIndex: Int($0.vectorIndex), modelID: modelID)
        })
        let staleKeys = existingKeys.subtracting(expectedKeys)

        // One transaction: delete exactly the stale keys, upsert the expected
        // rows. Other models' rows are never addressed. Stale-key deletes include
        // the generation predicate to stay within writeGen's slice.
        try await storage.rowStore.beginTransaction()
        do {
            for key in staleKeys {
                _ = try await storage.rowStore.delete(
                    table: "vectors",
                    where: .and([
                        .eq(Column(table: "vectors", name: "item_id"), .text(key.itemID)),
                        .eq(Column(table: "vectors", name: "vector_index"), .int(Int64(key.vectorIndex))),
                        .eq(Column(table: "vectors", name: "model_id"), .text(key.modelID)),
                        .eq(Column(table: "vectors", name: "generation"), .int(writeGen))
                    ])
                )
            }
            for input in expected {
                let values: [String: TypedValue] = [
                    "id":           .uuid(UUID()),
                    "item_id":      .text(input.itemID),
                    "vector_index": .int(Int64(input.vectorIndex)),
                    "model_id":     .text(input.modelID),
                    "model_version":.text(input.modelVersion),
                    "kind":         .int(Int64(input.payload.kind.rawValue)),
                    "dim":          .int(Int64(input.payload.dim)),
                    "payload":      .blob(Data(input.payload.bytes)),
                    "scale":        input.payload.scale.map { TypedValue.float(Double($0)) } ?? TypedValue.null,
                    "filed_at":     .timestamp(input.filedAt),
                    // Tag every row with the write generation (98bb0fb fix).
                    // Without this key the upsert's conflictColumns include "generation"
                    // but values does not, so SQLite resolves against the column default
                    // (0) — rows land invisible to readers once serving_generation > 0.
                    "generation":   .int(writeGen)
                ]
                _ = try await storage.rowStore.upsert(
                    table: "vectors",
                    values: values,
                    conflictColumns: ["item_id", "vector_index", "model_id", "generation"]
                )
            }
            try await storage.rowStore.commitTransaction()
        } catch {
            try? await storage.rowStore.rollbackTransaction()
            throw error
        }

        // Coherence: this model's float index lazily rebuilds from the table;
        // the resident binary index is rebuilt once from the table (the
        // reconcile may have touched an arbitrary mix of keys). The HNSW lane
        // is invalidated alongside (VH-01 Finding A): the reconcile may have
        // removed or replaced float rows whose raw bytes the graph still owns.
        floatIndices.removeValue(forKey: modelID)
        _invalidateHNSWLane(for: modelID)
        try await _rebuildBinaryIndexFromTable()
        return (removed: staleKeys.count, upserted: expected.count)
    }

    // MARK: - Lifecycle (GLK_PROVISION_001)

    /// Destroy all vector rows in this store.
    ///
    /// Deletes every row from the `vectors` table AND resets the resident
    /// array to empty. Called by
    /// `GeniusLocusKit.destroy(storage:corpusStorage:handle:)` as part of
    /// the coordinated estate teardown path. After this call the backing
    /// storage still exists (schema intact) but contains no vector data.
    ///
    /// The caller (GLK) is responsible for closing the estate through
    /// LocusKit before calling this method.
    public func destroyAllVectors() async throws {
        _ = try await storage.rowStore.delete(
            table: "vectors",
            where: .like(Column(table: "vectors", name: "id"), "%")
        )
        // Reset both indexes to empty. The table is now empty; the sidecar
        // (if present) is rewritten as a valid empty file under the registry
        // stamp (the registry survives a destroy: it names generations, not
        // rows), so the next open accepts the empty array instead of
        // rebuilding it from the empty table.
        let emptyArray = ResidentVectorArray.empty(kind: .binary, stride: 32)
        await bruteForceIndex.build(from: emptyArray)
        await mihIndex.build(from: emptyArray)
        if let store = arrayStore {
            try await store.rebuild(from: [], generations: try await _generationStamp())
        }
        // Reset live count and revert to brute-force (correct for empty state).
        liveBinaryCount = 0
        hotIndex = bruteForceIndex
        isMIHActive = false
        // Mark built so future findNearest calls skip the (empty) table fetch.
        indexBuilt = true
        // Abandon any in-flight deferred-index window — the store is now empty.
        deferredIndexActive = false
        deferredIndexDirty = false
        deferredLiveKeys = nil
        deferredPendingRecords = []
        // Reset the Lane D float indices as well — every float row was just
        // deleted, so every per-modelID resident float array must be cleared.
        // ramResident float coherence (SECURITY): destroyAllVectors is a
        // recall-index destroy, so every model's cached FloatBruteForceIndex
        // must be dropped or findNearestFloat would still return matches from
        // memory after the durable rows are gone.
        floatIndices.removeAll()
        // HNSW lane teardown (VH-01 Finding A): a full destroy must leave no
        // graph behind, in memory OR on disk. Drop every model's resident
        // graph, live-count seed, and dirty flag, and delete every persisted
        // hnsw_graph row — the topology describes vectors that no longer
        // exist, and the graph nodes own their raw bytes.
        hnswIndices.removeAll(keepingCapacity: false)
        liveFloatCounts.removeAll(keepingCapacity: false)
        hnswGraphDirty.removeAll(keepingCapacity: false)
        _ = try await storage.rowStore.delete(table: "hnsw_graph", where: .isTrue)
        log.info("VectorStore.destroyAllVectors: all rows deleted, resident array and HNSW lane reset")
    }

    // MARK: - Private: resident index lifecycle

    /// Ensure both DenseIndexes are populated. Idempotent — no-op once built.
    ///
    /// Build strategy (in priority order):
    ///   1. Sidecar present, its generation stamp equals the registry read
    ///      at open, and its live_count matches the table's
    ///      serving-generation binary-row count: load from sidecar (one OS
    ///      mmap read, no per-row SQLite fetch).
    ///   2. Otherwise: fetch all binary rows once from the table (the
    ///      source of truth), build the resident array, rewrite the sidecar
    ///      if present under the registry stamp. This one-time cost is
    ///      amortised across all queries.
    ///
    /// After building the array, _selectIndex is called to activate either
    /// BruteForceIndex or MIHIndex depending on the live count vs threshold.
    private func _ensureIndexBuilt() async throws {
        guard !indexBuilt else { return }

        let arr: ResidentVectorArray

        if let store = arrayStore {
            // Attempt to load from the on-disk sidecar.
            try await store.load()
            let snap = await store.snapshot()

            // Cross-check against the table to detect a stale sidecar
            // (crash mid-write, schema migration, etc.).
            let tableCount = try await _binaryRowCount()
            let currentStamp = try await _generationStamp()
            let sidecarStamp = await store.currentGenerationStamp()

            // Two checks, both required. (1) Generation: the header stamp
            // must equal the registry read now; a sidecar left behind by a
            // crash between the registry flip of publishShadowGeneration and
            // its sidecar rebuild carries the previous stamp and is rejected
            // even when the two generations hold the same number of rows (a
            // full reindex commonly does). (2) Compare live-vs-live:
            // sidecar.liveCount is the number of non-tombstoned slots written
            // to the header at flush time. tableCount is the number of
            // serving-generation binary rows in the `vectors` table — the
            // same row set _fetchAllBinaryRecords builds the sidecar from, so
            // superseded rows pending reclaim do not count. They agree iff the
            // sidecar is up-to-date (C5 fix: using snap.count here counts
            // tombstoned slots and spuriously triggers a full rebuild after
            // every delete).
            if sidecarStamp == currentStamp && snap.liveCount == tableCount {
                // Sidecar and table agree on generation and live records — use it directly.
                arr = snap
                log.info("VectorStore: loaded \(snap.liveCount) live vectors from sidecar")
            } else {
                // Stale sidecar: rebuild from the table and rewrite the sidecar
                // under the registry stamp the rows were fetched with.
                sidecarRebuildCount += 1
                let records = try await _fetchAllBinaryRecords()
                try await store.rebuild(from: records, generations: currentStamp)
                arr = await store.snapshot()
                log.info("VectorStore: rebuilt from table (\(records.count) vectors, sidecar was stale: sidecar liveCount=\(snap.liveCount) table=\(tableCount) stampMatched=\(sidecarStamp == currentStamp))")
            }
        } else {
            // No sidecar: build the array in memory from the table.
            // One-time cost; amortised across all subsequent findNearest calls.
            let records = try await _fetchAllBinaryRecords()
            arr = ResidentArrayStore.buildArray(
                from: records,
                kind: .binary,
                stride: 32
            )
            log.info("VectorStore: built in-memory resident array (\(arr.count) vectors)")
        }

        // Populate both indexes from the loaded array.
        await bruteForceIndex.build(from: arr)
        await mihIndex.build(from: arr)

        // Set liveBinaryCount from the loaded array (live = non-tombstoned slots).
        var liveCount: UInt32 = 0
        for i in 0..<Int(arr.count) where !arr.isTombstoned(i) {
            liveCount += 1
        }
        liveBinaryCount = liveCount

        indexBuilt = true

        // Select the appropriate active index for the loaded count.
        _selectIndex()
    }

    /// Ensure the Lane D float index is populated. Idempotent — no-op once built.
    ///
    /// Builds the FloatBruteForceIndex from the float32 rows in the
    /// `vectors` table (one query, paid once per process lifetime in the
    /// normal path). Unlike the binary lane there is no sidecar for the
    /// float lane yet — the float resident array is rebuilt from the table
    /// on first use. Float rows of differing dimension are not mixed: the
    /// index requires a single stride, so all float rows for the queried
    /// model share one dimension (spec I-4 keeps models on disjoint
    /// partitions, and one model emits one dimension).
    /// float NN search scans the SQLite `vectors` table directly
    /// via a cursor, computing distance per row and maintaining a top-k
    /// heap. No ResidentVectorArray, no FloatBruteForceIndex, no 2GB heap
    /// allocation. With PRAGMA mmap_size, each row read is an OS page-cache
    /// hit — zero malloc for the vector data.
    ///
    /// Returns the top-k (or bottom-k for farthest) scored results directly.
    private func _floatScanFromTable(
        modelID: String,
        probe: [Float],
        k: Int,
        direction: FloatSearchDirection,
        metric: FloatMetric = .cosine
    ) async throws -> [(distance: Float, key: VectorRecordKey)] {
        // D1 fix: filter to the serving generation so shadow rows are never mixed
        // into results. This is the DEFAULT diskBacked float query path and the
        // crash-window exact lane — without the filter it serves shadow + serving
        // rows together, which is the crash-window data-corruption defect.
        let servingGen = try await _servingGeneration(for: modelID)
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "kind"),
                    .int(Int64(VectorKind.float32.rawValue))),
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                .eq(Column(table: "vectors", name: "generation"), .int(servingGen))
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        // String interning for model fields.
        var internCache: [String: String] = [:]
        func intern(_ s: String) -> String {
            if let existing = internCache[s] { return existing }
            internCache[s] = s
            return s
        }
        // Bounded top-k (DoS fix): retain only the k best-scoring rows while
        // scanning rather than materializing + sorting every float row. `top`
        // is kept ordered best-first and capped at k, so memory is O(k) and
        // the cost is O(n log k) — independent of estate size. Previously this
        // reserved rows.count and sorted the full result on every recall, so a
        // large estate could exhaust CPU/memory from a normal MCP search.
        let nearest = (direction == .nearest)  // nearest keeps SMALLEST distances
        var top: [(distance: Float, key: VectorRecordKey)] = []
        top.reserveCapacity(min(k, 64))
        // Insert `e` into `top` keeping it ordered best-first, capped at k.
        func consider(_ e: (distance: Float, key: VectorRecordKey)) {
            if k <= 0 { return }
            // Better = smaller distance for nearest, larger for farthest.
            func better(_ a: Float, _ b: Float) -> Bool { nearest ? a < b : a > b }
            if top.count >= k, !better(e.distance, top[top.count - 1].distance) {
                return  // worse than the current worst; skip
            }
            // Linear insertion (k is small and caller-clamped).
            var i = top.count
            while i > 0, better(e.distance, top[i - 1].distance) { i -= 1 }
            top.insert(e, at: i)
            if top.count > k { top.removeLast() }
        }
        for row in rows {
            guard case let .text(itemID) = row["item_id"] ?? .null,
                  case let .int(vectorIndex) = row["vector_index"] ?? .null,
                  case let .text(rawModelID) = row["model_id"] ?? .null,
                  case let .text(rawModelVersion) = row["model_version"] ?? .null,
                  let payload = Self.decodePayload(from: row),
                  payload.kind == .float32 else { continue }
            // Decode float vector from BLOB — one row at a time, no
            // intermediate contiguous buffer. The BLOB bytes come from
            // mmap'd SQLite pages (PRAGMA mmap_size).
            let dim = payload.bytes.count / 4
            guard dim == probe.count else { continue }
            var candidate = [Float]()
            candidate.reserveCapacity(dim)
            var byteIdx = payload.bytes.startIndex
            for _ in 0..<dim {
                let b0 = payload.bytes[byteIdx]; byteIdx += 1
                let b1 = payload.bytes[byteIdx]; byteIdx += 1
                let b2 = payload.bytes[byteIdx]; byteIdx += 1
                let b3 = payload.bytes[byteIdx]; byteIdx += 1
                let bits = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
                candidate.append(Float(bitPattern: bits))
            }
            // Dispatch on the selected float metric. All three are inline here
            // to avoid a FloatBruteForceIndex allocation on the diskBacked path.
            // The ramResident path routes through FloatBruteForceIndex (which
            // dispatches the same three branches), so the math is consistent.
            //
            // - cosine: 1 − cos(a,b) — scale-invariant; the historical default.
            // - l2: Euclidean distance √Σ(aᵢ−bᵢ)² — magnitude-sensitive.
            // - dot: negative dot product −Σ(aᵢbᵢ) — matches dot-product-trained embeddings.
            //
            // Lower is always "closer" for all three metrics, so the top-k heap
            // (`consider`) is metric-agnostic. Cosine and l2 are distances;
            // dot returns a NEGATIVE value (−similarity) so larger dot→ smaller
            // value → ranks first in the heap, which is the correct nearest order.
            let dist: Float
            switch metric {
            case .cosine:
                var dotP: Float = 0, normA: Float = 0, normB: Float = 0
                for j in 0..<dim {
                    dotP  += probe[j] * candidate[j]
                    normA += probe[j] * probe[j]
                    normB += candidate[j] * candidate[j]
                }
                let denom = normA.squareRoot() * normB.squareRoot()
                dist = denom > 0 ? 1.0 - min(max(dotP / denom, -1.0), 1.0) : 1.0
            case .l2:
                var sumSq: Float = 0
                for j in 0..<dim { let d = probe[j] - candidate[j]; sumSq += d * d }
                dist = sumSq.squareRoot()
            case .dot:
                var dotP: Float = 0
                for j in 0..<dim { dotP += probe[j] * candidate[j] }
                dist = -dotP
            }
            let key = VectorRecordKey(
                itemID: itemID,
                vectorIndex: UInt32(vectorIndex),
                modelID: intern(rawModelID),
                modelVersion: intern(rawModelVersion)
            )
            consider((distance: dist, key: key))
        }
        // `top` is already ordered best-first and capped at k.
        return top
    }

    enum FloatSearchDirection { case nearest, farthest }

    /// Fetch the float32 rows for ONE modelID from the `vectors` table, sorted
    /// by VectorRecordKey natural order (arch spec §4.2: deterministic partition
    /// index, so the cross-language scan order matches). Scoping the fetch to a
    /// single modelID guarantees a uniform stride (one dimension per model), so
    /// the resulting resident array — and the FloatBruteForceIndex built from it
    /// — never mixes dimensions across models (mission 6a-iii-core).
    private func _fetchFloatRecords(
        modelID: String
    ) async throws -> [(key: VectorRecordKey, payload: VectorPayload)] {
        // Filter to the serving generation: queries must never return shadow rows.
        let servingGen = try await _servingGeneration(for: modelID)
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "kind"),
                    .int(Int64(VectorKind.float32.rawValue))),
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
                .eq(Column(table: "vectors", name: "generation"), .int(servingGen))
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        // modelID is the same for every row (single-modelID partition fetch).
        // Intern to avoid N identical String heap allocations.
        var internCache: [String: String] = [:]
        func intern(_ s: String) -> String {
            if let existing = internCache[s] { return existing }
            internCache[s] = s
            return s
        }
        var records: [(key: VectorRecordKey, payload: VectorPayload)] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            guard case let .text(itemID) = row["item_id"] ?? .null,
                  case let .int(vectorIndex) = row["vector_index"] ?? .null,
                  case let .text(rawModelID) = row["model_id"] ?? .null,
                  case let .text(rawModelVersion) = row["model_version"] ?? .null,
                  let payload = Self.decodePayload(from: row),
                  payload.kind == .float32 else { continue }
            let key = VectorRecordKey(
                itemID: itemID,
                vectorIndex: UInt32(vectorIndex),
                modelID: intern(rawModelID),
                modelVersion: intern(rawModelVersion)
            )
            records.append((key: key, payload: payload))
        }
        records.sort { $0.key < $1.key }
        return records
    }

    /// Build a float32 ResidentVectorArray from (key, payload) records.
    ///
    /// Returns nil when there are no records (the index stays empty and
    /// every search returns no matches). The stride is taken from the
    /// first record's byte count; all float rows for a given model share
    /// one dimension, so the stride is uniform within a partition.
    static func buildFloatArray(
        from records: [(key: VectorRecordKey, payload: VectorPayload)]
    ) -> ResidentVectorArray? {
        guard let first = records.first else { return nil }
        let stride = UInt32(first.payload.bytes.count)
        var storageBytes = Data()
        storageBytes.reserveCapacity(records.count * Int(stride))
        var keys = [VectorRecordKey]()
        keys.reserveCapacity(records.count)
        for r in records {
            storageBytes.append(contentsOf: r.payload.bytes)
            keys.append(r.key)
        }
        let tombstones = [UInt64](repeating: 0, count: (records.count + 63) / 64)
        let partitions = ResidentArrayStore.buildPartitions(keys: keys, tombstones: tombstones)
        return ResidentVectorArray(
            kind: .float32,
            stride: stride,
            count: UInt32(records.count),
            storage: storageBytes,
            keys: keys,
            modelPartitions: partitions,
            tombstones: tombstones
        )
    }

    /// Select the active DenseIndex based on the current live binary count.
    ///
    /// Called after every write that changes `liveBinaryCount` and after
    /// index build. No-ops when the correct index is already active.
    ///
    /// Policy:
    ///   liveBinaryCount < mihThreshold  → BruteForceIndex (Lane A)
    ///   liveBinaryCount >= mihThreshold → MIHIndex (Lane B)
    ///
    /// Both indexes are always kept in sync (via addPayload / remove /
    /// destroyAllVectors). The swap is purely a routing decision — no
    /// index needs to be rebuilt on promotion/demotion.
    ///
    /// Uses `isMIHActive` to track the current state because comparing
    /// `any DenseIndex` existentials directly is not supported in Swift.
    private func _selectIndex() {
        let count = liveBinaryCount
        let threshold = mihThreshold
        let useMIH = count >= threshold
        if useMIH && !isMIHActive {
            hotIndex = mihIndex
            isMIHActive = true
            log.info("VectorStore: promoted to MIHIndex (liveBinaryCount=\(count), threshold=\(threshold))")
        } else if !useMIH && isMIHActive {
            hotIndex = bruteForceIndex
            isMIHActive = false
            log.info("VectorStore: demoted to BruteForceIndex (liveBinaryCount=\(count), threshold=\(threshold))")
        }
        // No-op when already on the correct index.
    }

    /// Count serving-generation binary rows in the `vectors` table.
    ///
    /// Used by _ensureIndexBuilt to detect a stale sidecar. The count applies
    /// the SAME serving-generation predicate as _fetchAllBinaryRecords: the
    /// sidecar is built from serving-generation rows only, so the freshness
    /// comparison must count that same set (SPEC B-3a). Counting every binary
    /// row would include superseded generations awaiting reclaim
    /// (shadow_state 'pending-reclaim') and report the sidecar stale on every
    /// open of an estate that has completed a shadow swap — a full table read,
    /// resident-array rebuild, and sidecar rewrite per process start. The Rust
    /// port counts with the same predicate (`binary_row_count(&gen_pred)`).
    /// One table query with no per-row decode — just the count.
    private func _binaryRowCount() async throws -> UInt32 {
        let genFilter = try await _servingGenPredicate()
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "kind"),
                    .int(Int64(VectorKind.binary.rawValue))),
                genFilter
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        return UInt32(rows.count)
    }

    /// Fetch all binary rows from the `vectors` table once, sorted by
    /// VectorRecordKey natural order (arch spec §4.2: deterministic output).
    ///
    /// Called only when the sidecar is absent or stale (i.e. once per
    /// process lifetime in the normal path). Not called on every query.
    private func _fetchAllBinaryRecords() async throws -> [(key: VectorRecordKey, bytes: [UInt8])] {
        // Build a per-model serving-generation predicate so shadow rows are
        // excluded. The binary resident array must contain ONLY serving-generation
        // rows (§3 of the design contract).
        let genFilter = try await _servingGenPredicate()
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "kind"),
                    .int(Int64(VectorKind.binary.rawValue))),
                genFilter
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        // modelID and modelVersion repeat for every row in a partition.
        // Interning collapses 200K+ identical String heap allocations to
        // one shared instance per unique value.
        var internCache: [String: String] = [:]
        func intern(_ s: String) -> String {
            if let existing = internCache[s] { return existing }
            internCache[s] = s
            return s
        }
        var records: [(key: VectorRecordKey, bytes: [UInt8])] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            guard let sv = Self.storedVector(from: row) else { continue }
            let key = VectorRecordKey(
                itemID: sv.itemID,
                vectorIndex: sv.vectorIndex,
                modelID: intern(sv.modelID),
                modelVersion: intern(sv.modelVersion)
            )
            records.append((key: key, bytes: sv.engram.wireBytes))
        }
        // Sort by key for the deterministic partition index (arch spec §4.2).
        records.sort { $0.key < $1.key }
        return records
    }

    /// Remove one (itemID, vectorIndex, modelID) row from the table and
    /// tombstone ALL matching slots in both resident indexes.
    ///
    /// The modelVersion is not available at the call site; we scan the
    /// brute-force array snapshot to find ALL live VectorRecordKeys that
    /// match (itemID, vectorIndex, modelID). Multiple slots can accumulate
    /// in the resident array when modelVersion changes across upserts: the
    /// table UNIQUE constraint (item_id, vector_index, model_id) collapses
    /// them to one row, but the resident array retains a slot per modelVersion
    /// until the stale slot is explicitly tombstoned. Every slot must be
    /// tombstoned on delete so no in-memory copy of the deleted vector survives
    /// (hard-delete destruction contract — secfix/ws2-coredelete).
    private func _deleteAndTombstone(
        itemID: String,
        vectorIndex: UInt32,
        modelID: String
    ) async throws {
        _ = try await storage.rowStore.delete(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
                .eq(Column(table: "vectors", name: "vector_index"), .int(Int64(vectorIndex))),
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID))
            ])
        )
        // The deleted row may have been a float32 vector for this modelID.
        // Invalidate THIS model's Lane D index so the next findNearestFloat
        // rebuilds from the table. (See deleteAllVectors: the delete carries no
        // kind, so a lazy rebuild is the correct coherence path for the float
        // lane.) Other models' indices are untouched.
        // ramResident float coherence (SECURITY): the float lane's per-model
        // FloatBruteForceIndex IS cached in ramResident mode, so the durable
        // delete above must invalidate it or a subsequent findNearestFloat
        // returns the deleted vector from memory. Drop this model's float
        // index; it rebuilds lazily from the (now-updated) table on next use.
        // The HNSW lane is invalidated alongside (VH-01 Finding A): its nodes
        // own the deleted vector's raw bytes and would keep serving them.
        floatIndices.removeValue(forKey: modelID)
        _invalidateHNSWLane(for: modelID)
        // Only touch the resident BINARY array if it has been built. If not,
        // the table delete is already authoritative and the entry will be
        // absent when the array is first built on the next findNearest call.
        guard indexBuilt else { return }

        // Scan ALL slots in the brute-force array for this logical position.
        // Multiple live slots can exist when modelVersion changed across upserts
        // (stale modelVersion accumulation). Every matching slot must be
        // tombstoned so no in-memory copy survives the delete.
        // Do NOT break after the first match.
        let snap = await bruteForceIndex.currentSnapshot()
        var tombstonedCount = 0
        for slotIdx in 0..<Int(snap.count) {
            guard !snap.isTombstoned(slotIdx) else { continue }
            let k = snap.keys[slotIdx]
            guard k.itemID == itemID,
                  k.vectorIndex == vectorIndex,
                  k.modelID == modelID else { continue }
            if let store = arrayStore {
                try await store.tombstone(key: k)
            }
            // Remove from both indexes so both stay coherent.
            try await bruteForceIndex.remove(key: k)
            try await mihIndex.remove(key: k)
            tombstonedCount += 1
        }
        if tombstonedCount > 0 {
            liveBinaryCount = liveBinaryCount > UInt32(tombstonedCount)
                ? liveBinaryCount - UInt32(tombstonedCount)
                : 0
            _selectIndex()
        }
    }

    // MARK: - Row decode helpers

    /// Decode a VectorPayload from a storage row.
    ///
    /// Returns nil when a required column is missing or malformed. An int8
    /// row (SYNAPSEKIT_SPEC §I-4a) is malformed when its `scale` is NULL or
    /// its byte count differs from `dim`: the ratified policy stores exactly
    /// `dim` bytes and a per-vector scale, and a row without them cannot be
    /// dequantised, so it is skipped like any other undecodable row.
    static func decodePayload(from row: StorageRow) -> VectorPayload? {
        guard case let .int(kindRaw) = row["kind"] ?? .null,
              // Guard the narrowing conversion UInt8(kindRaw): SQLite columns are
              // Int64, so a hand-crafted row can carry any Int64 value. Converting
              // a negative or > 255 value to UInt8 traps in Swift. Reject the row
              // rather than crash.
              kindRaw >= 0, kindRaw <= 255,
              let kind = VectorKind(rawValue: UInt8(kindRaw)),
              case let .int(dim) = row["dim"] ?? .null,
              // Guard the narrowing conversion UInt32(dim): a negative dim from a
              // malformed row traps. Reject rather than crash.
              dim >= 0,
              case let .blob(bytes) = row["payload"] ?? .null else {
            return nil
        }
        let scale: Float?
        switch row["scale"] ?? .null {
        case .float(let d): scale = Float(d)
        default:            scale = nil
        }
        // Int8 rows carry exactly `dim` bytes and a non-null scale (§I-4a);
        // anything else cannot be dequantised and is skipped like a missing row.
        if kind == .int8, scale == nil || bytes.count != Int(dim) { return nil }
        return VectorPayload(
            kind: kind,
            dim: UInt32(dim),
            bytes: Array(bytes),
            scale: scale
        )
    }

    /// Decode a StoredVector (binary convenience type) from a storage row.
    ///
    /// Returns nil if the row is malformed or the payload is not binary.
    static func storedVector(from row: StorageRow) -> StoredVector? {
        guard case let .uuid(id) = row["id"] ?? .null,
              case let .text(itemID) = row["item_id"] ?? .null,
              case let .int(vectorIndex) = row["vector_index"] ?? .null,
              // Guard the narrowing conversion UInt32(vectorIndex): a negative
              // vector_index in a malformed row traps. Reject the row rather
              // than crash.
              vectorIndex >= 0,
              case let .text(modelID) = row["model_id"] ?? .null,
              case let .text(modelVersion) = row["model_version"] ?? .null,
              case let .timestamp(filedAt) = row["filed_at"] ?? .null else {
            return nil
        }
        guard let payload = decodePayload(from: row),
              let engram = try? payload.asEngram() else {
            return nil
        }
        // Decode generation (v6+). Absent column or NULL decodes to 0 so
        // pre-migration rows (v5 estates) are treated as serving generation 0.
        let generation: Int64
        switch row["generation"] ?? .null {
        case let .int(g): generation = g
        default:          generation = 0
        }
        return StoredVector(
            id: id.uuidString,
            itemID: itemID,
            vectorIndex: UInt32(vectorIndex),
            modelID: modelID,
            modelVersion: modelVersion,
            engram: engram,
            filedAt: filedAt,
            generation: generation
        )
    }

    // MARK: - Shadow-swap helpers (private)

    /// Return the serving generation for `modelID`, loading from the
    /// vector_generations table if not cached. Returns 0 for models that
    /// have no registry row (never swapped — all rows are serving gen 0).
    func _servingGeneration(for modelID: String) async throws -> Int64 {
        if let cached = servingGenerations[modelID] { return cached }
        let rows = try await storage.rowStore.query(
            table: "vector_generations",
            where: .eq(Column(table: "vector_generations", name: "model_id"), .text(modelID)),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        let gen: Int64
        if let row = rows.first, case let .int(g) = row["serving_generation"] ?? .null {
            gen = g
        } else {
            gen = 0
        }
        servingGenerations[modelID] = gen
        return gen
    }

    /// Return the active shadow generation for `modelID` if one is in flight,
    /// otherwise nil. Loads from the registry table if not cached.
    private func _shadowGeneration(for modelID: String) async throws -> Int64? {
        if let cached = shadowGenerations[modelID] { return cached }
        let rows = try await storage.rowStore.query(
            table: "vector_generations",
            where: .eq(Column(table: "vector_generations", name: "model_id"), .text(modelID)),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first,
              case let .int(sg) = row["shadow_generation"] ?? .null,
              case let .text(state) = row["shadow_state"] ?? .null,
              state == "building" else {
            shadowGenerations.removeValue(forKey: modelID)
            return nil
        }
        shadowGenerations[modelID] = sg
        shadowStates[modelID] = state
        return sg
    }

    /// The serving-generation stamp of the sidecar: `model_id` to
    /// `serving_generation` for every parseable `vector_generations` row, the
    /// same rows `_servingGenPredicate` scopes the table reads with. A sidecar
    /// is accepted at open only when its header stamp equals this map (see
    /// `_ensureIndexBuilt`). Rust twin: `generation_stamp_from_rows`.
    private func _generationStamp() async throws -> GenerationStamp {
        let regRows = try await storage.rowStore.query(
            table: "vector_generations",
            where: .isTrue,
            orderBy: [],
            limit: nil,
            offset: nil
        )
        var stamp: GenerationStamp = [:]
        for row in regRows {
            guard case let .text(mid) = row["model_id"] ?? .null,
                  case let .int(sg) = row["serving_generation"] ?? .null else { continue }
            stamp[mid] = sg
        }
        return stamp
    }

    /// Build a generation predicate for a table-wide query that reads from
    /// multiple model_ids (e.g. recentItemIDs, findByKeyword, _fetchAllBinaryRecords).
    ///
    /// Returns a predicate that accepts ONLY serving-generation rows for each
    /// known model, plus generation = 0 for any model_id not in the registry
    /// (default for pre-migration rows and never-swapped models).
    ///
    /// Loads serving generations for all registered models from the registry.
    private func _servingGenPredicate() async throws -> StoragePredicate {
        let regRows = try await storage.rowStore.query(
            table: "vector_generations",
            where: .isTrue,
            orderBy: [],
            limit: nil,
            offset: nil
        )
        if regRows.isEmpty {
            // No registry entries → all models are at generation 0.
            return .eq(Column(table: "vectors", name: "generation"), .int(0))
        }
        // Build: (model_id NOT IN known_models AND generation = 0)
        //   OR   (model_id = M1 AND generation = SG1)
        //   OR   (model_id = M2 AND generation = SG2) ...
        var knownModelIDs: [TypedValue] = []
        var perModelClauses: [StoragePredicate] = []
        for row in regRows {
            guard case let .text(mid) = row["model_id"] ?? .null,
                  case let .int(sg) = row["serving_generation"] ?? .null else { continue }
            knownModelIDs.append(.text(mid))
            servingGenerations[mid] = sg
            perModelClauses.append(.and([
                .eq(Column(table: "vectors", name: "model_id"), .text(mid)),
                .eq(Column(table: "vectors", name: "generation"), .int(sg))
            ]))
        }
        let unknownClause: StoragePredicate = .and([
            .not(.in(Column(table: "vectors", name: "model_id"), knownModelIDs)),
            .eq(Column(table: "vectors", name: "generation"), .int(0))
        ])
        let all = [unknownClause] + perModelClauses
        // Fold all clauses into a single OR.
        return .or(all)
    }
}

// MARK: - Schema-ledger preparation (shared by VectorStore and VectorRepresentationClaims)

/// Moves a kit's schema-version ledger row from its former ids to its current
/// id through `Storage.renameSchemaKit(from:to:)` (PERSISTENCEKIT_SPEC I-7a).
/// One implementation for both SynapseKit ledger rows (`VectorStore` and
/// `VectorRepresentationClaims`) so the two never drift on what a conflict
/// means. Rust twin: `synapsekit::vector_store::prepare_schema_ledger_for`.
enum SchemaLedgerPreparation {

    /// Kit-level logger for the ledger preparation. The enum has no instance,
    /// so it cannot share `VectorStore`'s per-store logger; the category is
    /// the kit's, matching the other module-level loggers in SynapseKit.
    private static let log = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "SynapseKit")

    /// Rename the ledger row under each id in `formerKitIDs` to `kitID`.
    ///
    /// SAFETY: `.conflict` is a warning, not a refusal. Rows under both a
    /// former id and the current id mean a runtime already opened the estate
    /// under the new id without the rename (the replay this preparation
    /// prevents), or the old row was restored by hand. Both rows stay in
    /// place, one warning names them, and the caller's `migrate(to:)` runs
    /// under the current id — whose row already records the ladder position,
    /// so no step replays. Refusing here would take away access to an
    /// estate's existing data; the GeniusLocusKit 1.4 → 1.5 capsule applies
    /// the same warn-and-leave-rows policy. Only a failed rename call throws.
    static func moveFormerRows(
        on storage: any Storage, from formerKitIDs: [String], to kitID: String
    ) async throws {
        for formerKitID in formerKitIDs {
            let outcome: SchemaKitRenameOutcome
            do {
                outcome = try await storage.renameSchemaKit(from: formerKitID, to: kitID)
            } catch {
                throw SynapseKitError.storeUnavailable(
                    "schema-version ledger rename \(formerKitID) → \(kitID) failed: \(error)")
            }
            switch outcome {
            case .renamed, .noRow:
                continue
            case let .conflict(oldVersion, newVersion):
                log.warning("schema-version ledger carries rows under both \(formerKitID, privacy: .public) (v\(oldVersion)) and \(kitID, privacy: .public) (v\(newVersion)); both left in place, migrating under \(kitID, privacy: .public)")
            }
        }
    }
}
