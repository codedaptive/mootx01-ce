// VectorStore.swift
//
// Storage layer for VectorKit, backed by PersistenceKit.
//
// Schema (version 3, with `ext` JSON slot added post-Lane F):
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
//   ext            TEXT                         -- ADR-012 JSON extension slot
// )
// UNIQUE(item_id, vector_index, model_id)
// INDEX(model_id, item_id)
// ```
//
// Refactored 2026-05-19 (mission 6) per
// DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md section 4.6: replaced
// direct SQLite I/O with PersistenceKit's RowStore + BlobStore
// protocols. Dense-embedding k-NN is VectorKit's own concern (ADR-008
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
/// ADR-012.
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
/// Telemetry: emits `vectorkit.*` metrics via IntellectusLib when
/// monitoring is enabled. Off by default; the emit call is a
/// short-circuited no-op (single Atomic<Bool> load) when disabled.
public actor VectorStore {

    private let log = Logger(subsystem: "com.mootx01.kit", category: "VectorStore")
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

    /// Live keys tracked incrementally across the deferred window so replacement
    /// detection stays O(batch) per call instead of re-scanning the (stale) index
    /// snapshot every write. Seeded from the published snapshot by
    /// `beginDeferredIndex()`; nil when not in deferred mode.
    private var deferredLiveKeys: Set<VectorRecordKey>? = nil

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
    private var floatIndices: [String: FloatBruteForceIndex] = [:]

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
    private(set) var sidecarRebuildCount: Int = 0

    /// Number of on-disk sidecar writes performed by the resident store in
    /// this VectorStore's lifetime.
    ///
    /// Returns 0 when there is no sidecar (memory-only store). Exposed for
    /// test assertions only — the import-scale regression test asserts a
    /// bulk ingest of N vectors costs O(batches) sidecar writes, not O(N).
    var sidecarWriteCount: Int {
        get async { await arrayStore?.sidecarWriteCount ?? 0 }
    }

    // MARK: - Schema declaration (version 3, multi-vector, item_id, ext slot)

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
    ///   - Added: `ext` JSON nullable — the ADR-012 forward-compat slot.
    ///     Reserves the slot, not a shape; 1.0 writes NULL and never reads it.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "VectorKit",
        version: 3,
        tables: [
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
                    // Reserve-space forward-compat slot (ADR-012). Nullable
                    // `.json`, present from schema v3. Future per-vector typed
                    // metadata (quantisation provenance, embedding-run tags)
                    // serializes here migration-free. 1.0 writes NULL and never
                    // reads it.
                    .json("ext", nullable: true)
                ],
                primaryKey: ["id"],
                uniqueConstraints: [["item_id", "vector_index", "model_id"]]
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
    /// The `.vec` filename convention lives here in VectorKit (the kit that owns
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
    ///     table binary-row count; if they disagree the array is rebuilt
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
        deferredPendingLimit: Int = 50_000
    ) {
        self.storage               = storage
        self.mihThreshold          = mihThreshold
        self.mihBandCount          = mihBandCount
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
    /// Telemetry: emits `vectorkit.index.insert_latency_ms` when enabled.
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

    /// Upsert a typed payload (binary or float32).
    ///
    /// This is the general write path. `addVector` is a convenience
    /// wrapper for the binary/Engram case.
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
    /// - Throws: `VectorKitError.int8QuantizationPolicyUndefined` when the
    ///   payload kind is `.int8`. Int8 writes are rejected fail-closed because
    ///   the quantization policy (symmetric vs asymmetric, per-vector vs
    ///   per-dim scale) has not been ratified. Use `.float` (float32 lane) or
    ///   the binary Engram lane instead. See VECTORKIT_SPEC §I-4a.
    ///
    /// Telemetry: emits `vectorkit.index.insert_latency_ms` when enabled.
    public func addPayload(
        itemID: String,
        vectorIndex: UInt32,
        payload: VectorPayload,
        modelID: String,
        modelVersion: String,
        filedAt: Date
    ) async throws {
        // PRECONDITION GUARD: int8 writes are rejected fail-closed.
        // The quantization policy (symmetric vs asymmetric, per-vector vs
        // per-dim scale) has not been ratified. Persisting an int8 payload now
        // would lock in undefined dequantization semantics. Use .float or the
        // binary Engram lane. See VECTORKIT_SPEC §I-4a and arch spec §10.3.
        if payload.kind == .int8 {
            throw VectorKitError.int8QuantizationPolicyUndefined(
                "int8 writes are rejected: quantization policy is unspecified. " +
                "Use .float or the binary Engram lane. See VECTORKIT_SPEC §I-4a."
            )
        }

        let startTime = Date().timeIntervalSince1970

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
            "filed_at":     .timestamp(filedAt)
        ]
        _ = try await storage.rowStore.upsert(
            table: "vectors",
            values: values,
            conflictColumns: ["item_id", "vector_index", "model_id"]
        )

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
            }
        }

        let endTime = Date().timeIntervalSince1970
        Intellectus.report(.metric(
            name: "vectorkit.index.insert_latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "VectorKit", "model_id": modelID],
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
    /// rows one-by-one (the (distance ASC, itemID ASC) total order is applied
    /// at query time, not insert time).
    ///
    /// - Parameter batch: the payloads to upsert. Empty is a no-op.
    public func addPayloads(_ batch: [VectorPayloadInput]) async throws {
        guard !batch.isEmpty else { return }

        // PRECONDITION GUARD: reject any int8 payload in the batch fail-closed.
        // The quantization policy has not been ratified; a batch containing even
        // one int8 payload must be rejected entirely — no partial writes. The
        // first offending item is reported. See VECTORKIT_SPEC §I-4a.
        if let bad = batch.first(where: { $0.payload.kind == .int8 }) {
            throw VectorKitError.int8QuantizationPolicyUndefined(
                "int8 writes are rejected: quantization policy is unspecified. " +
                "Offending item: \(bad.itemID). " +
                "Use .float or the binary Engram lane. See VECTORKIT_SPEC §I-4a."
            )
        }

        let startTime = Date().timeIntervalSince1970

        // 1. Upsert every row to the table (durable source of truth).
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
                "filed_at":     .timestamp(input.filedAt)
            ]
            _ = try await storage.rowStore.upsert(
                table: "vectors",
                values: values,
                conflictColumns: ["item_id", "vector_index", "model_id"]
            )
        }

        // 2. Mirror the binary rows into the resident array + both indexes
        //    in one amortised pass.
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
                var live = deferredLiveKeys ?? []
                var seenInBatch = Set<VectorRecordKey>()
                var newKeyCount: UInt32 = 0
                var replacedKeys = Set<VectorRecordKey>()
                for k in batchKeys {
                    if live.contains(k) {
                        // Already live (earlier window write or pre-existing) →
                        // this is a replacement, not a new key.
                        replacedKeys.insert(k)
                    } else if !seenInBatch.contains(k) {
                        newKeyCount += 1
                    }
                    seenInBatch.insert(k)
                    live.insert(k)
                }
                if let store = arrayStore {
                    // Sidecar present: stage into the resident array store now.
                    await store.tombstoneDeferred(keys: replacedKeys)
                    try await store.appendBatch(records: binaryRecords)
                } else {
                    // Memory-only: accumulate; publishResidentIndex() merges all
                    // pending records into the resident index in one pass.
                    deferredPendingRecords.append(contentsOf: binaryRecords)
                }
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
        for input in batch where input.payload.kind == .float32 {
            floatIndices.removeValue(forKey: input.modelID)
        }

        let endTime = Date().timeIntervalSince1970
        Intellectus.report(.metric(
            name: "vectorkit.index.batch_insert_latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "VectorKit", "batch_size": "\(batch.count)"],
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
        var keys = Set<VectorRecordKey>()
        keys.reserveCapacity(Int(snap.count))
        for i in 0..<Int(snap.count) where !snap.isTombstoned(i) {
            keys.insert(snap.keys[i])
        }
        deferredLiveKeys = keys
        deferredPendingRecords = []
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
        guard wasDirty else { return }

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
                records: Self.dedupLastWins(pending)
            )
        }
        await bruteForceIndex.build(from: merged)
        await mihIndex.build(from: merged)
        // Recompute the live count authoritatively from the final snapshot so any
        // incremental drift over the window is corrected.
        var liveCount: UInt32 = 0
        for i in 0..<Int(merged.count) where !merged.isTombstoned(i) { liveCount += 1 }
        liveBinaryCount = liveCount
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
        let cur = await bruteForceIndex.currentSnapshot()
        let merged = Self.mergeBatchIntoSnapshot(snapshot: cur, records: pending)
        await bruteForceIndex.build(from: merged)
        await mihIndex.build(from: merged)
        // Recompute live count and reseed the live-key set authoritatively from
        // the flushed snapshot so subsequent replacement detection remains correct.
        var liveCount: UInt32 = 0
        var liveKeys = Set<VectorRecordKey>()
        for i in 0..<Int(merged.count) where !merged.isTombstoned(i) {
            liveCount += 1
            liveKeys.insert(merged.keys[i])
        }
        liveBinaryCount = liveCount
        deferredLiveKeys = liveKeys
        // deferredIndexActive stays true, deferredIndexDirty stays true.
    }

    /// Keep only the last occurrence of each key, preserving first-seen order of
    /// the survivors. Used to collapse a memory-only deferral buffer before the
    /// single merge, since `mergeBatchIntoSnapshot` appends every record (two
    /// records with one key would otherwise both go live).
    private static func dedupLastWins(
        _ records: [(key: VectorRecordKey, bytes: [UInt8])]
    ) -> [(key: VectorRecordKey, bytes: [UInt8])] {
        guard !records.isEmpty else { return records }
        var lastIndex: [VectorRecordKey: Int] = [:]
        lastIndex.reserveCapacity(records.count)
        for (i, r) in records.enumerated() { lastIndex[r.key] = i }
        var out: [(key: VectorRecordKey, bytes: [UInt8])] = []
        out.reserveCapacity(lastIndex.count)
        for (i, r) in records.enumerated() where lastIndex[r.key] == i {
            out.append(r)
        }
        return out
    }

    /// Flush any pending write-behind sidecar mutation to disk.
    ///
    /// The single `addPayload` binary path is write-behind: it mutates the
    /// in-memory resident array and marks the sidecar dirty without writing
    /// (TASK #24). Callers persist the sidecar by calling `flush()` at a
    /// quiesce point (e.g. after an import loop, before process exit, on a
    /// periodic checkpoint). No-op when there is no sidecar or nothing is
    /// dirty. Crash safety does not depend on flush: the `vectors` table is
    /// the durable source and the sidecar is rebuilt on the next open if it
    /// is stale.
    public func flush() async throws {
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
        let predicate = StoragePredicate.and([
            .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
            .eq(Column(table: "vectors", name: "vector_index"), .int(Int64(vectorIndex))),
            .eq(Column(table: "vectors", name: "model_id"), .text(modelID))
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
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
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
    /// Returns up to `limit` matches sorted by (distance ASC, itemID ASC)
    /// — the universal tie-break rule (retrieval algorithms ref §0.3).
    ///
    /// Telemetry: emits `vectorkit.search.latency_ms` and
    /// `vectorkit.search.result_count` when monitoring is enabled.
    public func findNearest(
        probe: Engram,
        modelID: String,
        limit: Int
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
        let hits = try await hotIndex.search(
            probe: probePayload,
            metric: .hamming,
            k: limit,
            filter: filter
        )

        // Both indexes apply (distance ASC, itemID ASC) sort per the oracle
        // contract (retrieval algorithms ref §0.3).
        // Map DenseHit → VectorMatch without re-sorting.
        let result: [VectorMatch] = hits.map { hit in
            VectorMatch(
                itemID: hit.key.itemID,
                distance: Int(hit.rawDistance),
                modelID: hit.key.modelID
            )
        }

        let endTime = Date().timeIntervalSince1970
        let resultCount = result.count
        Intellectus.report(.metric(
            name: "vectorkit.search.latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "VectorKit", "model_id": modelID],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "vectorkit.search.result_count",
            value: Double(resultCount),
            tags: ["kit": "VectorKit", "model_id": modelID],
            ts: endTime
        ))

        return result
    }

    /// k-nearest-neighbours over the float32 (Lane D) vectors by cosine
    /// distance, using the in-house FloatBruteForceIndex — the production
    /// exact path (Bob's storage amendment 2026-06-12: no external engine).
    ///
    /// On the first call (or after a process restart) the float index is
    /// built once from the float32 rows in the `vectors` table; subsequent
    /// calls scan the resident float array. The scan restricts to
    /// `modelID`'s partition (spec I-4: cross-model comparisons forbidden).
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
    public func findNearestFloat(
        probe: [Float],
        modelID: String,
        limit: Int
    ) async throws -> [VectorMatch] {
        guard limit > 0, !probe.isEmpty else { return [] }

        // Build (once, lazily) the Lane D index for THIS modelID from its float
        // rows only — uniform stride, so the search dimension guard is satisfied
        // even when the table holds several models' float rows of differing
        // dimension (mission 6a-iii-core). Returns the model's index, or nil when
        // the model has no float rows (no float lane for it).
        guard let modelIndex = try await _ensureFloatIndexBuilt(modelID: modelID) else {
            return []
        }

        let probePayload = VectorPayload(floats: probe)
        // The index already holds only this model's rows, but keep the modelID
        // metadata filter for defence-in-depth (a future shared-build path would
        // still be correctly scoped).
        let filter = MetadataFilter(modelID: modelID)

        // FloatBruteForceIndex computes cosine distance and applies the
        // (distance ASC, itemID ASC) tie-break (retrieval algorithms ref §0.3).
        let hits = try await modelIndex.search(
            probe: probePayload,
            metric: .float(.cosine),
            k: limit,
            filter: filter
        )

        // Map DenseHit → VectorMatch. The float lane's rawDistance is the
        // cosine-distance Float bit pattern reinterpreted as Int32 (see
        // FloatBruteForceIndex); recover the float and quantise to the
        // VectorMatch integer-distance convention (×10_000, the same scale
        // the Rust DenseHit uses) so the cross-language rank-identity
        // fixtures compare like-for-like.
        return hits.map { hit in
            let cosineDistance = hit.floatDistance ?? 1.0
            return VectorMatch(
                itemID: hit.key.itemID,
                distance: Int((cosineDistance * 10_000).rounded()),
                modelID: hit.key.modelID
            )
        }
    }

    /// k-FARTHEST neighbours over the float32 (Lane D) vectors by cosine —
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
    public func findFarthestFloat(
        probe: [Float],
        modelID: String,
        limit: Int
    ) async throws -> [VectorMatch] {
        guard limit > 0, !probe.isEmpty else { return [] }

        // Same lazy per-model build as findNearestFloat: the model's float
        // index, or nil when the model has no float rows.
        guard let modelIndex = try await _ensureFloatIndexBuilt(modelID: modelID) else {
            return []
        }

        let probePayload = VectorPayload(floats: probe)
        let filter = MetadataFilter(modelID: modelID)

        // FloatBruteForceIndex.searchFarthest applies the SAME cosine and the
        // (itemID ASC) tie-break, ordered by distance DESCENDING.
        let hits = try await modelIndex.searchFarthest(
            probe: probePayload,
            metric: .float(.cosine),
            k: limit,
            filter: filter
        )

        // Map DenseHit → VectorMatch exactly as findNearestFloat does so the
        // cross-language rank-identity fixtures compare like-for-like.
        return hits.map { hit in
            let cosineDistance = hit.floatDistance ?? 1.0
            return VectorMatch(
                itemID: hit.key.itemID,
                distance: Int((cosineDistance * 10_000).rounded()),
                modelID: hit.key.modelID
            )
        }
    }

    /// Keyword pre-filter: returns item IDs whose item_id
    /// contains the query as a substring. Full BM25 keyword scoring
    /// is CorpusKit's responsibility; this surface is for hybrid-
    /// retrieval callers that need a quick keyword pass.
    ///
    /// Telemetry: emits `vectorkit.search.keyword_result_count` when enabled.
    public func findByKeyword(_ query: String, limit: Int) async throws -> [String] {
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .like(Column(table: "vectors", name: "item_id"), "%\(query)%"),
            orderBy: [
                OrderClause(
                    column: Column(table: "vectors", name: "item_id"),
                    direction: .ascending
                )
            ],
            limit: limit,
            offset: nil
        )
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            if case let .text(itemID) = row["item_id"] ?? .null {
                if seen.insert(itemID).inserted {
                    out.append(itemID)
                }
            }
        }

        let count = out.count
        Intellectus.report(.metric(
            name: "vectorkit.search.keyword_result_count",
            value: Double(count),
            tags: ["kit": "VectorKit"],
            ts: Date().timeIntervalSince1970
        ))

        return out
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
        floatIndices.removeValue(forKey: modelID)
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
        // (if present) is rewritten as a valid empty file.
        let emptyArray = ResidentVectorArray.empty(kind: .binary, stride: 32)
        await bruteForceIndex.build(from: emptyArray)
        await mihIndex.build(from: emptyArray)
        if let store = arrayStore {
            try await store.rebuild(from: [])
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
        // Dropping all map entries clears every model's index; each rebuilds
        // lazily (and empty) on the next findNearestFloat for that model.
        floatIndices.removeAll()
        log.info("VectorStore.destroyAllVectors: all rows deleted, resident array reset")
    }

    // MARK: - Private: resident index lifecycle

    /// Ensure both DenseIndexes are populated. Idempotent — no-op once built.
    ///
    /// Build strategy (in priority order):
    ///   1. Sidecar present and its live_count matches the table binary-row count:
    ///      load from sidecar (one OS mmap read, no per-row SQLite fetch).
    ///   2. Otherwise: fetch all binary rows once from the table (the
    ///      source of truth), build the resident array, rewrite the sidecar
    ///      if present. This one-time cost is amortised across all queries.
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

            // Compare live-vs-live: sidecar.liveCount is the number of
            // non-tombstoned slots written to the header at flush time.
            // tableCount is the number of live rows in the `vectors` table.
            // They agree iff the sidecar is up-to-date (C5 fix: using
            // snap.count here counts tombstoned slots and spuriously
            // triggers a full rebuild after every delete).
            if snap.liveCount == tableCount {
                // Sidecar and table agree on live records — use it directly.
                arr = snap
                log.info("VectorStore: loaded \(snap.liveCount) live vectors from sidecar")
            } else {
                // Stale sidecar: rebuild from the table and rewrite the sidecar.
                sidecarRebuildCount += 1
                let records = try await _fetchAllBinaryRecords()
                try await store.rebuild(from: records)
                arr = await store.snapshot()
                log.info("VectorStore: rebuilt from table (\(records.count) vectors, sidecar was stale: sidecar liveCount=\(snap.liveCount) table=\(tableCount))")
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
        await _selectIndex()
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
    private func _ensureFloatIndexBuilt(modelID: String) async throws -> FloatBruteForceIndex? {
        // The map entry's presence is the per-model "built" flag.
        if let existing = floatIndices[modelID] { return existing }
        let records = try await _fetchFloatRecords(modelID: modelID)
        guard let arr = Self.buildFloatArray(from: records) else {
            // No float rows for this model — no float lane for it. Do NOT cache
            // an empty index: a later ingest of this model's first float row
            // must be able to build a real index on the next search.
            return nil
        }
        let index = FloatBruteForceIndex()
        await index.build(from: arr)
        floatIndices[modelID] = index
        return index
    }

    /// Fetch the float32 rows for ONE modelID from the `vectors` table, sorted
    /// by VectorRecordKey natural order (arch spec §4.2: deterministic partition
    /// index, so the cross-language scan order matches). Scoping the fetch to a
    /// single modelID guarantees a uniform stride (one dimension per model), so
    /// the resulting resident array — and the FloatBruteForceIndex built from it
    /// — never mixes dimensions across models (mission 6a-iii-core).
    private func _fetchFloatRecords(
        modelID: String
    ) async throws -> [(key: VectorRecordKey, payload: VectorPayload)] {
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "kind"),
                    .int(Int64(VectorKind.float32.rawValue))),
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID))
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        var records: [(key: VectorRecordKey, payload: VectorPayload)] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            guard case let .text(itemID) = row["item_id"] ?? .null,
                  case let .int(vectorIndex) = row["vector_index"] ?? .null,
                  case let .text(modelID) = row["model_id"] ?? .null,
                  case let .text(modelVersion) = row["model_version"] ?? .null,
                  let payload = Self.decodePayload(from: row),
                  payload.kind == .float32 else { continue }
            let key = VectorRecordKey(
                itemID: itemID,
                vectorIndex: UInt32(vectorIndex),
                modelID: modelID,
                modelVersion: modelVersion
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
        var storage = [UInt8]()
        storage.reserveCapacity(records.count * Int(stride))
        var keys = [VectorRecordKey]()
        keys.reserveCapacity(records.count)
        for r in records {
            storage.append(contentsOf: r.payload.bytes)
            keys.append(r.key)
        }
        let tombstones = [UInt64](repeating: 0, count: (records.count + 63) / 64)
        let partitions = ResidentArrayStore.buildPartitions(keys: keys, tombstones: tombstones)
        return ResidentVectorArray(
            kind: .float32,
            stride: stride,
            count: UInt32(records.count),
            storage: storage,
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

    /// Count binary rows in the `vectors` table.
    ///
    /// Used by _ensureIndexBuilt to detect a stale sidecar. One table
    /// query with no per-row decode — just the count.
    private func _binaryRowCount() async throws -> UInt32 {
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .eq(Column(table: "vectors", name: "kind"),
                       .int(Int64(VectorKind.binary.rawValue))),
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
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .eq(Column(table: "vectors", name: "kind"),
                       .int(Int64(VectorKind.binary.rawValue))),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        var records: [(key: VectorRecordKey, bytes: [UInt8])] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            guard let sv = Self.storedVector(from: row) else { continue }
            let key = VectorRecordKey(
                itemID: sv.itemID,
                vectorIndex: sv.vectorIndex,
                modelID: sv.modelID,
                modelVersion: sv.modelVersion
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
        floatIndices.removeValue(forKey: modelID)
        // Only touch the resident array if it has been built. If not, the
        // table delete is already authoritative and the entry will be absent
        // when the array is first built on the next findNearest call.
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
    /// Returns nil when a required column is missing or malformed.
    ///
    /// Int8 payloads return nil: the quantization policy has not been ratified
    /// so a decoded int8 payload cannot be safely used by any consumer.
    /// Callers that need to detect an int8 row explicitly should read the
    /// `kind` column directly. This is a symmetric fail-closed guard: since
    /// writes are rejected (VectorStore.addPayload throws
    /// int8QuantizationPolicyUndefined), no int8 rows should be present in
    /// production. The guard defends against hand-crafted rows.
    /// See VECTORKIT_SPEC §I-4a.
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
        // Symmetric read-side guard: int8 payloads cannot be decoded until
        // the quantization policy is ratified. A nil return here causes the
        // calling read path (getPayload, vectors(forItemID:)) to surface nil
        // or skip the row — the same safe outcome as a missing row. This
        // prevents silent consumption of hand-crafted int8 rows.
        if kind == .int8 { return nil }
        let scale: Float?
        switch row["scale"] ?? .null {
        case .float(let d): scale = Float(d)
        default:            scale = nil
        }
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
        return StoredVector(
            id: id.uuidString,
            itemID: itemID,
            vectorIndex: UInt32(vectorIndex),
            modelID: modelID,
            modelVersion: modelVersion,
            engram: engram,
            filedAt: filedAt
        )
    }
}
