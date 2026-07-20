---
title: VectorKit Interface
status: accepted-1.1-target
version: 1.7.0
date: 2026-07-20
description: Public API surface for VectorKit in both the Swift and Rust ports.
spec_type: kit
authors: MOOTx01 maintainers
package: VectorKit
languages: [swift, rust]
relates_to:
  - docs/reference/VECTORKIT_SPEC.md
purpose: |
  Public API surface of VectorKit in both ports: the EmbeddingProvider
  abstraction, the built-in FloatSimHashEmbeddingProvider, the
  StoredVector record, the VectorPayloadInput batch-input type, the
  VectorStore CRUD surface (schema v2, Lane F — item_id/vector_index/
  kind/payload; single-row write-behind path addPayload/add_payload;
  batch amortised path addPayloads/add_payloads; flush quiesce),
  the VectorMatch result type, and the VectorKitError enum. The companion
  SPEC carries the behavioral contracts (invariants I-1…I-9, conformance
  C-1…C-13).
---

# VectorKit Interface

## § 1 — Package layout

### GLK identity and ownership rule (1.1 target)

`itemID` remains an opaque VectorKit string. The composition layer assigns its
meaning: GLK Corpus rows always use canonical `Drawer.id`, while standalone
CorpusKit may use document or optional passage index-unit IDs. GLK never stores
a passage/chunk ID in a Corpus vector row. Composed callers delete vectors by
declared item/lane/model ownership; whole-table destruction is not a GLK
cleanup or migration operation.

**Swift:** `packages/kits/VectorKit/`

- `Sources/VectorKit/VectorKit.swift` — module documentation only (no
  symbols; the kit's surface is the types below)
- `Sources/VectorKit/EmbeddingProvider.swift` — the `EmbeddingProvider`
  protocol
- `Sources/VectorKit/FloatSimHashEmbeddingProvider.swift` — the built-in
  provider
- `Sources/VectorKit/StoredVector.swift` — the storage record
- `Sources/VectorKit/VectorMatch.swift` — the nearest-neighbour result
- `Sources/VectorKit/VectorStore.swift` — the PersistenceKit-backed actor
- `Sources/VectorKit/VectorKitError.swift` — the error enum
- `Tests/VectorKitTests/`, `Package.swift`

**Rust:** `packages/kits/VectorKit/rust/` — crate `vectorkit`

- `src/lib.rs` — re-exports
- `src/embedding_provider.rs` — the `EmbeddingProvider` trait
- `src/simhash_embedding_provider.rs` — `FloatSimHashEmbeddingProvider`
- `src/vector_store.rs` — `StoredVector`, `VectorMatch`, `VectorStore`
- `src/error.rs` — `VectorKitError`
- depends on `engram-lib`, `substrate-lib`, `persistence-kit`, `uuid`

Both ports are backend-agnostic: `VectorStore` holds `any Storage` (Swift) /
`Arc<dyn Storage>` (Rust) and never names a backend. Over the on-disk SQLite
backend (`SQLiteStorage` / `persistence_kit::SqliteStorage`) the resident
binary array and the Lane D float lane persist across a process restart —
rebuilt from the durable `vectors` table, or loaded from the `.vec` sidecar
when one is supplied and current. This cross-restart persistence is a
conformance requirement gated in both ports (VECTORKIT_SPEC, "Cross-restart
persistence"). PostgreSQL is the remote-backed v1.1 path (federation).

## § 2 — Public types

### `EmbeddingProvider`

The abstraction over on-device embedding generation: text →
model-tagged `Engram` (SPEC § 4, I-1; § 5, B-1/B-2; I-5 empty-input
contract).

**Swift:**

```swift
public protocol EmbeddingProvider: Sendable {
    var modelID: String { get }
    var modelVersion: String { get }
    func embed(_ text: String) async throws -> Engram

    // Float lane source (Lane D): the pooled dense float vector the provider
    // computes on the way to the SimHash projection — retained, not recomputed.
    // Default impl throws (float lane is opt-in); providers that run a real
    // inference pass override to return the pooled vector. Empty input → [].
    func embedFloat(_ text: String) async throws -> [Float]

    // Batched embedding; default sequential impl in a public extension.
    // Providers with batched CoreML graphs override for throughput.
    // Order of outputs matches the order of inputs; empty entries in
    // the input array yield Engram.zero per the embed contract.
    func embedBatch(_ texts: [String]) async throws -> [Engram]
}
```

**Rust:**

```rust
pub trait EmbeddingProvider: Send + Sync {
    fn model_id(&self) -> &str;
    fn model_version(&self) -> &str;
    fn embed(&self, text: &str) -> Result<Engram, VectorKitError>;

    // Float lane source (Lane D): the pooled dense float vector. Default
    // impl errors (float lane is opt-in); providers that run a real
    // inference pass override to return the pooled vector. Empty input → [].
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError>;

    // Batched embedding; default sequential impl in the trait body.
    // Providers with batched inference (e.g. ONNX with a batch dim)
    // can override. Order of outputs matches the order of inputs;
    // empty entries yield `Engram::ZERO` per the `embed` contract.
    fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Engram>, VectorKitError> {
        let mut out = Vec::with_capacity(texts.len());
        for t in texts { out.push(self.embed(t)?); }
        Ok(out)
    }
}
```

### `FloatSimHashEmbeddingProvider`

The built-in deterministic provider: a host-supplied inference closure
produces a dense `[Float]` / `Vec<f32>`, which is projected to a 256-bit
`Engram` through SubstrateLib's canonical FloatSimHash using a stable
per-provider seed (SPEC § 4, I-4; § 5, B-1).

**Swift:**

```swift
public struct FloatSimHashEmbeddingProvider: EmbeddingProvider {
    public let modelID: String
    public let modelVersion: String
    public let projectionSeed: UInt64
    public let inference: @Sendable (String) async throws -> [Float]

    public init(
        modelID: String,
        modelVersion: String,
        projectionSeed: UInt64,
        inference: @escaping @Sendable (String) async throws -> [Float]
    )

    public func embed(_ text: String) async throws -> Engram
}
```

**Rust:**

```rust
pub struct FloatSimHashEmbeddingProvider { /* model_id, model_version, projection_seed, inference */ }

impl FloatSimHashEmbeddingProvider {
    pub fn new(
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        projection_seed: u64,
        inference: impl Fn(&str) -> Result<Vec<f32>, String> + Send + Sync + 'static,
    ) -> Self;
}

impl EmbeddingProvider for FloatSimHashEmbeddingProvider { /* model_id, model_version, embed */ }
```

### `StoredVector`

One row of the `vectors` table — the record returned by
`vectors(forItemID:)` (SPEC § 4, I-1/I-3; § 5, B-5/B-9). Lane F rename:
`drawerID` → `itemID` (mirrors the `drawer_id` → `item_id` column rename).
`vectorIndex` (0 for single-vector items; 0..N-1 for ColBERT token vectors)
was added in schema v2.

**Swift:**

```swift
public struct StoredVector: Sendable, Equatable {
    public let id: String            // UUID string, stable across upserts
    public let itemID: String        // GLK: Drawer UUID; standalone: opaque item id
    public let vectorIndex: UInt32   // 0 for single-vector; token slot for ColBERT
    public let modelID: String
    public let modelVersion: String
    public let engram: Engram        // binary payloads only; float/int8 via getPayload
    public let filedAt: Date         // round-tripped through TEXT ISO8601

    public init(id: String,
                itemID: String,
                vectorIndex: UInt32 = 0,
                modelID: String,
                modelVersion: String,
                engram: Engram,
                filedAt: Date)
}
```

**Rust:**

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct StoredVector {
    pub id: String,
    pub item_id: String,        // was drawer_id (Lane F rename)
    pub vector_index: u32,      // 0 for single-vector
    pub model_id: String,
    pub model_version: String,
    pub engram: Engram,         // binary payloads only
    pub filed_at: i64,          // Unix epoch seconds (TypedValue::Timestamp)
}
```

**Parity delta:** `filed_at` — Swift `Date` (TEXT ISO8601 round-trip, sub-ms
precision lost) / Rust `i64` (Unix epoch seconds). Value-equivalent across
ports; sanctioned date-storage seam.

### `VectorMatch`

A nearest-neighbour result: one matched item, the distance, and the
producing model's id (SPEC § 4, I-2; § 5, B-6/B-10). Ordered by distance
ascending, ties by `itemID`/`item_id` ascending. Lane F rename:
`drawerID` → `itemID`.

**Swift:**

```swift
public struct VectorMatch: Sendable, Comparable, Equatable {
    public let itemID: String    // GLK: Drawer UUID; standalone: opaque item id
    public let distance: Int     // Hamming 0…256 (binary lane) or cosine×10_000 (float lane)
    public let modelID: String

    public init(itemID: String, distance: Int, modelID: String)
    public static func < (lhs: VectorMatch, rhs: VectorMatch) -> Bool  // by distance asc, itemID asc tiebreak
}
```

**Rust:**

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VectorMatch {
    pub item_id: String,    // was drawer_id (Lane F rename)
    pub distance: i32,      // Hamming 0..=256 or cosine×10_000
    pub model_id: String,
}

impl Ord for VectorMatch { /* distance asc, then item_id asc */ }
impl PartialOrd for VectorMatch { /* delegates to Ord */ }
```

### `VectorPayloadInput`

One row of input for the bulk `addPayloads(_:)` / `add_payloads` path.
Bundles a `VectorPayload` with the index metadata that a single
`addPayload` call would otherwise take as separate arguments (SPEC §5,
B-3b). The import and migration path builds an array/slice of
these and submits them in one batch so the resident array, sidecar, and
both indexes are updated once for the whole batch rather than once per row.

**Swift:**

```swift
public struct VectorPayloadInput: Sendable, Equatable {
    public let itemID: String          // GLK: Drawer UUID; standalone: opaque item id
    public let vectorIndex: UInt32     // 0 for single-vector; token position for ColBERT
    public let payload: VectorPayload  // binary, float32, or int8 typed payload
    public let modelID: String
    public let modelVersion: String
    public let filedAt: Date           // passed in — never read from Date() inside the engine

    public init(
        itemID: String,
        vectorIndex: UInt32,
        payload: VectorPayload,
        modelID: String,
        modelVersion: String,
        filedAt: Date
    )
}
```

**Rust:**

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct VectorPayloadInput {
    pub item_id: String,
    pub vector_index: u32,
    pub payload: VectorPayload,
    pub model_id: String,
    pub model_version: String,
    pub filed_at_unix_secs: i64,   // Unix epoch seconds — never read from system clock
}
```

**Parity delta:** `filedAt` — Swift `Date` / Rust `i64` Unix epoch
seconds. Sanctioned date-storage seam (same as `StoredVector`).

### `VectorStore`

The PersistenceKit-backed store. A Swift `actor` (async surface mirrors
PersistenceKit's `RowStore`); a Rust `struct` holding `Arc<dyn Storage>`
behind a `Mutex`. Constructed against an already-opened `Storage`; the
caller opens the schema (SPEC § 4, I-6). Methods are in § 3.

**Swift:**

```swift
public actor VectorStore {
    public static let schemaDeclaration: SchemaDeclaration
    public let mihThreshold: UInt32   // default 50_000; promotion boundary BruteForce→MIH

    public init(
        storage: any Storage,
        sidecarURL: URL? = nil,        // optional .vec packed binary sidecar
        mihThreshold: UInt32 = 50_000,
        mihBandCount: MIHBandCount = .m16
    )
    // CRUD + query methods: see § 3
}
```

**Rust:**

```rust
pub struct VectorStore { /* Arc<Mutex<HotState>>, storage: Arc<dyn Storage>, … */ }

impl VectorStore {
    pub fn schema_declaration() -> SchemaDeclaration;
    pub fn new(storage: Arc<dyn Storage>) -> Self;
    pub fn open(storage: Arc<dyn Storage>) -> Result<Self, VectorKitError>; // opens schema, returns store
    // CRUD + query methods: see § 3
}
```

**`vectors` table schema — schema version 4 (Lane F multi-vector + forward-compatible ext slot + `filed_at` index):**
declared by `VectorStore.schemaDeclaration` / `VectorStore::schema_declaration()`.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `id` | UUID / TEXT | NOT NULL | Primary key. Stable across upserts. |
| `item_id` | TEXT | NOT NULL | Opaque item identity; canonical Drawer UUID for every GLK Corpus row. (Renamed from `drawer_id`.) |
| `vector_index` | INTEGER | NOT NULL DEFAULT 0 | 0 for single-vector; 0..N-1 for ColBERT token vectors. |
| `model_id` | TEXT | NOT NULL | Embedding model identifier. |
| `model_version` | TEXT | NOT NULL | Model weights version. |
| `kind` | INTEGER | NOT NULL DEFAULT 0 | `VectorKind` raw value: 0=Binary, 1=Float32, 2=Int8. |
| `dim` | INTEGER | NOT NULL DEFAULT 256 | Number of logical dimensions. |
| `payload` | BLOB | NOT NULL | Vector bytes: 32 bytes (binary); dim×4 (float32); dim (int8). (Renamed from `engram`.) |
| `scale` | REAL | NULL | Int8 dequantization scale. NULL for binary and float32. |
| `filed_at` | TIMESTAMP TEXT | NOT NULL | ISO8601 text (TEXT, not REAL). |
| `ext` | JSON | NULL | the forward-compatible ext-slot contract forward-compat slot (schema v3). Inert in 1.0 — written NULL / omitted on insert, never read. |

UNIQUE constraint: `(item_id, vector_index, model_id)`.
Indices: `idx_vectors_item` on `(item_id)`; `idx_vectors_model_item` on `(model_id, item_id)`;
`idx_vectors_filed_at_item` on `(filed_at, item_id)` (schema v4 — covers `recentItemIDs` ORDER BY, enabling an ordered index scan rather than full-table filesort).

(SPEC § 4, I-3/I-4; declared by `schemaDeclaration` / `schema_declaration()`.)

## § 3 — Public functions

### `embed`

Generate a model-tagged engram for text (SPEC § 5, B-1/B-2; I-5). See
`EmbeddingProvider` / `FloatSimHashEmbeddingProvider` in § 2 for the
signatures.

### `VectorStore.defaultSidecarURL(for:)` / `default_sidecar_path` (static sidecar helper)

Returns the conventional `.vectors.vec` sidecar URL / path for a SQLite-backed
storage, or `nil` / `None` for non-file backends (in-memory, PostgreSQL) where a
local sidecar does not apply. The filename convention (same base name as the
SQLite file, `.vectors.vec` extension) lives in VectorKit so every caller derives
the same stable path. Pass the result as the `sidecarURL` / `sidecar_path`
argument to `VectorStore.init` / `VectorStore::new` to enable sidecar persistence.

**Swift:**

```swift
public static func defaultSidecarURL(for storage: any Storage) -> URL?
```

**Rust:**

```rust
pub fn default_sidecar_path(storage: &Arc<dyn Storage>) -> Option<PathBuf>;
```

### `VectorStore.addVector` / `add_vector` (binary convenience)

Upsert a binary (Engram) vector at `vectorIndex=0`; updates in place on
`(itemID, 0, modelID)` (SPEC § 5, B-3). For multi-vector items use
`addPayload` / `add_payload` directly.

**Swift:**

```swift
public func addVector(
    itemID: String,       // was drawerID (Lane F rename)
    engram: Engram,
    modelID: String,
    modelVersion: String,
    filedAt: Date
) async throws
```

**Rust:**

```rust
pub fn add_vector(
    &self,
    item_id: &str,        // was drawer_id (Lane F rename)
    engram: &Engram,
    model_id: &str,
    model_version: &str,
    filed_at_unix_secs: i64,
) -> Result<(), VectorKitError>;
```

### `VectorStore.addPayload` / `add_payload` (general write path)

Upsert a binary or float32 typed payload at `(itemID, vectorIndex, modelID)`
(SPEC § 5, B-3/B-3a/I-3/I-4). This is the general write path; `addVector`
is a convenience wrapper for the binary/Engram case.

**Int8 payloads are rejected fail-closed** (SPEC §I-4a): `addPayload` / `add_payload` throws/returns
`VectorKitError.int8QuantizationPolicyUndefined` /
`VectorKitError::Int8QuantizationPolicyUndefined` when `payload.kind ==
.int8` / `VectorKind::Int8`. The `.int8` / `Int8` case is retained in
`VectorPayload` (no-removal doctrine) but is not yet persistable. Use
`.float` / `Float32` or the binary Engram lane instead. See VECTORKIT_SPEC
§I-4a and arch spec §10.3.

Write-behind policy (SPEC B-3a): the in-memory resident array
is updated immediately; the `.vec` sidecar is marked dirty but NOT
rewritten. Call `flush()` at a quiesce point to persist. Crash safety is
preserved by the table-rebuild path (the `vectors` table is the durable
source of truth; a stale sidecar is rebuilt from it on the next open).
For importing many vectors at once, prefer `addPayloads(_:)` /
`add_payloads` which bounds sidecar writes and index builds to O(batches).

**Swift:**

```swift
public func addPayload(
    itemID: String,
    vectorIndex: UInt32,
    payload: VectorPayload,
    modelID: String,
    modelVersion: String,
    filedAt: Date
) async throws
```

**Rust:**

```rust
pub fn add_payload(
    &self,
    item_id: &str,
    vector_index: u32,
    payload: &VectorPayload,
    model_id: &str,
    model_version: &str,
    filed_at_unix_secs: i64,
) -> Result<(), VectorKitError>;
```

### `VectorStore.addPayloads(_:)` / `add_payloads` (batch write)

Bulk-upsert N binary or float32 typed payloads in one call — the import and
migration path (SPEC § 5, B-3b).

**Int8 payloads in the batch are rejected fail-closed** (SPEC §I-4a): the
entire batch is rejected (no partial writes) if any element has `kind ==
.int8` / `Int8`. The first offending `itemID` is reported in the error.

For a batch of N items it performs:
- O(N) row upserts to the `vectors` table (durable source of truth —
  unavoidable and not the disease).
- Binary lane: ONE tombstone pass, ONE array append pass, ONE sidecar
  write (`ResidentArrayStore.appendBatch` / `append_batch`), and ONE
  rebuild of both `BruteForceIndex` and `MIHIndex` from the final array.
  Cost is O(batches) sidecar writes and O(batches) index builds regardless
  of batch size.
- Float32 lane: the Lane D float index for each modelID present in the batch
  is invalidated once for a lazy rebuild on the next `findNearestFloat` call
  for that model (cheaper than N incremental float adds). Lane D keeps one
  index per modelID (uniform stride per model); other models' indices are
  untouched.
- Empty batch is a no-op.
Search output is identical to N sequential `addPayload` calls for the same
inputs (the total order (distance ASC, itemID ASC) is applied at query
time, not insert time). Verified by C-10 (SPEC § 7).

**Swift:**

```swift
public func addPayloads(_ batch: [VectorPayloadInput]) async throws
```

**Rust:**

```rust
pub fn add_payloads(&self, batch: &[VectorPayloadInput]) -> Result<(), VectorKitError>;
```

### `VectorStore.replaceModelVectors(modelID:_:)` / `replace_model_vectors` (bulk re-embed path)

Replace the ENTIRE vector set for a model in one atomic operation — the bulk
re-embed path (distinct from `addPayloads` / `add_payloads`). Performs:
- A bulk-delete of all rows for `modelID` followed by plain-INSERT of the
  replacement batch in ONE transaction (one fsync; INSERT skips the per-row
  existence SELECT because after the bulk delete nothing conflicts).
- ONE resident binary index rebuild from the table after the transaction commits
  (O(N) — avoids the O(N²) cost of N individual `addPayload` removes and adds).

Int8 payloads are rejected fail-closed (same precondition as `addPayloads`):
any element with `kind == .int8` / `Int8` rejects the entire batch with
`VectorKitError.int8QuantizationPolicyUndefined` (SPEC § I-4a).
Any in-flight deferred-index window is flushed before the table write.
Behavioral contract: SPEC B-3d.

**Swift:**

```swift
public func replaceModelVectors(modelID: String, _ batch: [VectorPayloadInput]) async throws
```

**Rust:**

```rust
pub fn replace_model_vectors(
    &self,
    model_id: &str,
    batch: &[VectorPayloadInput],
) -> Result<(), VectorKitError>;
```

### `VectorStore.flush()` / `flush` (sidecar quiesce)

Flush any pending write-behind sidecar mutation to disk (SPEC § 5,
B-3c). The single `addPayload` binary path is write-behind:
it mutates the in-memory resident array and marks the sidecar dirty
without writing. Callers persist the sidecar by calling `flush()` at a
quiesce point (e.g. end of an import loop, before process exit, on a
periodic checkpoint). No-op when:
- there is no sidecar (memory-only store), OR
- `isDirty` is false (the in-memory array already matches the file), OR
- the last write was via `addPayloads` (which writes the sidecar eagerly).
Crash safety does not depend on `flush()`: the `vectors` table is the
durable source; the sidecar is rebuilt on the next open if it is stale.

**Swift:**

```swift
public func flush() async throws
```

**Rust:**

```rust
pub fn flush(&self) -> Result<(), VectorKitError>;
```

### `VectorStore.beginDeferredIndex()` / `begin_deferred_index` (deferred-index window open)

Opens a deferred-index window. While active, `addPayload` / `add_payload` and
`addPayloads` / `add_payloads` calls append to the durable table and the
resident array store as normal, but defer the MIH + brute-force index rebuild.
A bulk import wrapped in `beginDeferredIndex` + `publishResidentIndex` pays ONE
index rebuild regardless of batch count — O(N) instead of O(N²). Idempotent:
re-entering an already-active window is a no-op (existing live-key seed preserved).

Works with or without a sidecar: with a sidecar, deferred writes stage into the
resident array store; without one (memory-only path), records accumulate in a
deferred-pending buffer and are merged in one pass at `publishResidentIndex`.

**Swift:**

```swift
public func beginDeferredIndex() async throws
```

**Rust:**

```rust
pub fn begin_deferred_index(&self) -> Result<(), VectorKitError>;
```

### `VectorStore.publishResidentIndex()` / `publish_resident_index` (deferred-index window close)

Ends the deferred-index window opened by `beginDeferredIndex` /
`begin_deferred_index` by rebuilding the resident MIH + brute-force index ONCE
from the final accumulated snapshot. A no-op rebuild (mode is still cleared)
when nothing was deferred since the window opened. Called by the corpus ingest
drain when a burst completes.

**Swift:**

```swift
public func publishResidentIndex() async throws
```

**Rust:**

```rust
pub fn publish_resident_index(&self) -> Result<(), VectorKitError>;
```

### `VectorStore.getVector` / `get_vector` (binary convenience)

Point read of the Engram stored under `(itemID, vectorIndex=0, modelID)`,
or `nil` / `None` when no row exists. Does not fall back to another model
(SPEC § 5, B-4).

**Swift:**

```swift
public func getVector(itemID: String, modelID: String) async throws -> Engram?
```

**Rust:**

```rust
pub fn get_vector(&self, item_id: &str, model_id: &str)
    -> Result<Option<Engram>, VectorKitError>;
```

### `VectorStore.getPayload` / `get_payload` (general read path)

Point read of the `VectorPayload` stored under `(itemID, vectorIndex,
modelID)`, or `nil` / `None` when no row exists (SPEC § 5, B-4).

**Swift:**

```swift
public func getPayload(
    itemID: String,
    vectorIndex: UInt32,
    modelID: String
) async throws -> VectorPayload?
```

**Rust:**

```rust
pub fn get_payload(
    &self,
    item_id: &str,
    vector_index: u32,
    model_id: &str,
) -> Result<Option<VectorPayload>, VectorKitError>;
```

### `VectorStore.vectors(forItemID:)` / `vectors_for_item`

Every row for an item (one per distinct `(vectorIndex, modelID)` pair),
ordered by `filed_at` ascending (SPEC § 5, B-5). Lane F rename: was
`vectors(forDrawerID:)` / `vectors_for_drawer`.

**Swift:**

```swift
public func vectors(forItemID itemID: String) async throws -> [StoredVector]
```

**Rust:**

```rust
pub fn vectors_for_item(&self, item_id: &str)
    -> Result<Vec<StoredVector>, VectorKitError>;
```

### `VectorStore.findNearest` / `find_nearest`

k-nearest by Hamming distance over binary rows tagged with the given
model, via the resident DenseIndex (BruteForceIndex below
`mihThreshold`, MIHIndex at/above it — both exact). Sorted distance
ascending, ties by item id ascending (SPEC § 5, B-6/B-10; I-2).

**Swift:**

```swift
public func findNearest(probe: Engram, modelID: String, limit: Int) async throws -> [VectorMatch]
```

**Rust:**

```rust
pub fn find_nearest(&self, probe: &Engram, model_id: &str, k: usize)
    -> Result<Vec<VectorMatch>, VectorKitError>;
```

### `VectorStore.findNearestFloat` / `find_nearest_float`

k-nearest over the float32 (Lane D) vectors by COSINE distance, using the
in-house `FloatBruteForceIndex` (no external engine; SPEC § 4). The float
index is built lazily on first call from the
float32 rows in the `vectors` table and updated incrementally on float
writes. The scan is restricted to `modelID`'s partition (I-4). Cosine is
scale-invariant, so it ranks an answer above a near-duplicate of the
question — the case the SimHash-Hamming lane cannot serve. Results are
sorted (cosine distance ASC, item id ASC). `VectorMatch.distance` is the
cosine distance ×10_000 (the same integer scale both ports use, so the
cross-language rank-identity fixtures compare like-for-like). The float
lane is reproducible-within-config, NOT four-way bit-identical (arch spec
§6). Empty when `limit ≤ 0`, the probe is empty, or no float rows exist.

**Swift:**

```swift
public func findNearestFloat(probe: [Float], modelID: String, limit: Int) async throws -> [VectorMatch]
```

**Rust:**

```rust
pub fn find_nearest_float(&self, probe: &[f32], model_id: &str, k: usize)
    -> Result<Vec<VectorMatch>, VectorKitError>;
```

### `VectorStore.findFarthestFloat` / `find_farthest_float`

k-FARTHEST over the float32 (Lane D) vectors by COSINE — the most DISSIMILAR
rows first (anti-similarity retrieval, the "find things UNLIKE this"
objective; mission 6b-modifiers-antisim). Identical to `findNearestFloat` in
every respect — same lazy per-model index build, same `modelID` partition
scope (I-4), same cosine metric, same `VectorMatch` ×10_000 quantisation —
EXCEPT it ranks by FARTHEST: the bottom-K by cosine similarity (largest cosine
distance first), via `FloatBruteForceIndex.searchFarthest` /
`FloatBruteForceIndex::search_farthest`. It is NOT a negated nearest-list: the
farthest rows are not in the nearest top-K, so the index scans and orders by
the opposite end. No new distance math — the same cosine, the opposite sort.
The tie-break stays item-id ASC (identical to nearest, both directions). The
ranking direction is named by the `SearchDirection` enum
(`.nearest`/`.farthest` / `Nearest`/`Farthest`). Reproducible-within-config,
NOT four-way bit-identical (arch spec §6). Empty when `limit ≤ 0`, the probe is
empty, or no float rows exist.

**Swift:**

```swift
public enum SearchDirection: String, Sendable, Equatable { case nearest, farthest }

public func findFarthestFloat(probe: [Float], modelID: String, limit: Int) async throws -> [VectorMatch]

// On the engine seam (FloatBruteForceIndex):
public func searchFarthest(probe: VectorPayload, metric: DenseMetric, k: Int, filter: MetadataFilter?) async throws -> [DenseHit]
```

**Rust:**

```rust
pub enum SearchDirection { Nearest, Farthest }

pub fn find_farthest_float(&self, probe: &[f32], model_id: &str, k: usize)
    -> Result<Vec<VectorMatch>, VectorKitError>;

// On the engine seam (FloatBruteForceIndex):
pub fn search_farthest(&self, probe: &VectorPayload, metric: DenseMetric, k: usize, filter: Option<&MetadataFilter>)
    -> Result<Vec<DenseHit>, VectorKitError>;
```

### `VectorStore.findByKeyword` / `find_by_keyword`

Coarse substring pre-filter over `item_id`; returns distinct item ids up
to `limit`, ascending (SPEC § 5, B-7). `limit` counts DISTINCT item ids —
the table holds many rows per item (binary + float per model slot), so
the query pages internally until `limit` ids are collected or the table
is exhausted; a row-scoped limit silently shrank sweep windows ~10× on
production ensembles.

**Swift:**

```swift
public func findByKeyword(_ query: String, limit: Int) async throws -> [String]
```

**Rust:**

```rust
pub fn find_by_keyword(&self, query: &str, limit: usize)
    -> Result<Vec<String>, VectorKitError>;
```

### `VectorStore.recentItemIDs` / `recent_item_ids`

The most recently filed DISTINCT item ids, newest first (filed_at
descending, item_id ascending tiebreak; same distinct-id paging as
`findByKeyword`). The probe-enumeration surface for bounded sweep
consumers — the contradiction hunter's probe sample and
VectorSimilaritySignal's per-fire sample — so a bounded window always
contains the latest captures instead of a static UUID-ordered slice.

**Swift:**

```swift
public func recentItemIDs(limit: Int) async throws -> [String]
```

**Rust:**

```rust
pub fn recent_item_ids(&self, limit: usize)
    -> Result<Vec<String>, VectorKitError>;
```

### `VectorStore.deleteVector` / `delete_vector`

Idempotent delete of the binary row at `(itemID, vectorIndex=0, modelID)`
(SPEC § 5, B-8).

**Swift:**

```swift
public func deleteVector(itemID: String, modelID: String) async throws
```

**Rust:**

```rust
pub fn delete_vector(&self, item_id: &str, model_id: &str)
    -> Result<(), VectorKitError>;
```

### `VectorStore.deleteAllVectors` / `delete_all_vectors`

Delete all rows for `(itemID, modelID)` regardless of `vector_index`.
Used for multi-vector items where every token vector must be removed
(SPEC § 5, B-8).

**Swift:**

```swift
public func deleteAllVectors(itemID: String, modelID: String) async throws
```

**Rust:**

```rust
pub fn delete_all_vectors(&self, item_id: &str, model_id: &str)
    -> Result<(), VectorKitError>;
```

### `VectorStore::delete_payload` (Rust-only — parity delta)

Deletes the single row at `(item_id, vector_index, model_id)`. A finer-grained
delete than `delete_all_vectors` / `delete_vector` (which operate at the item
level); this targets one specific `(item, index, model)` triple. Any in-flight
deferred-index window is flushed before the delete so no deferred slot survives
in memory after the row is removed from the table.

**Parity:** No Swift equivalent — `deletePayload` does not exist in the Swift
port. The Swift delete surface is `deleteVector` (single-index convenience) and
`deleteAllVectors` (all indexes for a model). Callers needing per-index deletes
on the Swift side combine those two.

**Rust only:**

```rust
pub fn delete_payload(
    &self,
    item_id: &str,
    vector_index: u32,
    model_id: &str,
) -> Result<(), VectorKitError>;
```

### `VectorStore.destroyAllVectors` / `destroy_all_vectors`

Deletes all rows from the `vectors` table. This is a standalone administrative
operation available only when the caller owns every row in the store. GLK must
not call it for cleanup, expunge, rebuild, or migration because unrelated lanes
may share the table; GLK uses item/lane/model-scoped deletion. After this call
the backing schema remains intact but contains no vector data.

**Swift:**

```swift
public func destroyAllVectors() async throws
```

**Rust:**

```rust
pub fn destroy_all_vectors(&self) -> Result<(), VectorKitError>;
```

## § 4 — Errors

Cases match one-for-one across ports so cross-language conformance tests
share fixtures. Behavioral meaning: SPEC § 6.

**Swift:**

```swift
public enum VectorKitError: Error, Sendable, Equatable {
    case embeddingFailed(String)   // inference closure threw
    case modelUnavailable(String)  // model not loaded / unavailable
    case storeUnavailable(String)  // store open / row-decode failure
    case notFound                  // reserved; reads model absence as nil/empty
    case invalidPayload(String)    // malformed payload (wrong kind/dim/bytes)
    case decodingFailure(String)   // row decode failure

    // Thrown by addPayload / addPayloads when payload.kind == .int8.
    // Int8 writes are rejected fail-closed because the quantization policy
    // (symmetric vs asymmetric, per-vector vs per-dim scale) has not been
    // ratified. Use .float (float32 lane) or the binary Engram lane.
    // See VECTORKIT_SPEC §I-4a.
    case int8QuantizationPolicyUndefined(String)
}
```

**Rust:**

```rust
#[derive(Debug, PartialEq, Eq)]
pub enum VectorKitError {
    EmbeddingFailed(String),
    ModelUnavailable(String),
    StoreUnavailable(String),
    NotFound,
    InvalidPayload(String),
    DecodingFailure(String),
    /// Returned by `add_payload` / `add_payloads` when `payload.kind == Int8`.
    /// Int8 writes are rejected fail-closed: the quantization policy has not
    /// been ratified. Use `Float32` or `Binary` instead.
    /// See VECTORKIT_SPEC §I-4a.
    Int8QuantizationPolicyUndefined(String),
}
```

## § 5 — Conformance test entry points

**Swift:**

```
swift test --package-path packages/kits/VectorKit
```

(Targets: `EmbeddingProviderTests`, `FloatSimHashEmbeddingProviderTests`,
`VectorStoreTests`, `BulkIngestTests`, `CapturePathBenchmarkTests`,
`VectorKitTelemetryTests`.)

**Rust:**

```
cargo test -p vectorkit
```

(Suites: `simhash_provider_tests.rs`, `vector_store_tests.rs`,
`bulk_ingest_tests.rs`, `float_lane_tests.rs`,
`vectorkit_telemetry_tests.rs`.)

## § 6 — Examples

```swift
import EngramLib
import PersistenceKit
import VectorKit

// 1. Open a store against an application-selected backend.
try await storage.open(schema: VectorStore.schemaDeclaration)
let store = VectorStore(storage: storage)

// 2. Build a deterministic provider (host supplies inference).
let provider = FloatSimHashEmbeddingProvider(
    modelID: "minilm-v6",
    modelVersion: "1.0.0",
    projectionSeed: 0x4D49_4E4C_4D5F_7631,
    inference: { text in try await embedMiniLM(text) }   // → [Float]
)

// 3. File a model-tagged vector for an item (drawer UUID).
let engram = try await provider.embed("the legal pad on my desk")
try await store.addVector(
    itemID: "drawer-42",          // itemID (was drawerID, Lane F rename)
    engram: engram,
    modelID: provider.modelID,
    modelVersion: provider.modelVersion,
    filedAt: now
)

// 4. Query nearest neighbours within the same model.
let probe = try await provider.embed("yellow notepad")
let hits = try await store.findNearest(probe: probe, modelID: "minilm-v6", limit: 10)
// hits: [VectorMatch] sorted near → far, each tagged "minilm-v6"
// hit.itemID is the matched drawer UUID (was hit.drawerID)
```

## § 7 — Swift/Rust Concordance

Every top-level public concept in VectorKit, mapped Swift↔Rust with the
shape rule that governs how the two ports may differ. The six public types
are 1:1 by name. One method-level parity delta exists: `delete_payload`
(Rust-only — see § 3 and the `VectorStore` row below); all other methods
are present in both ports.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule |
|---|---|---|---|---|
| Embedding abstraction | `EmbeddingProvider` | `EmbeddingProvider` | public protocol / pub trait | identical surface (`modelID`/`model_id`, `modelVersion`/`model_version`, `embed`, `embedBatch`/`embed_batch`); Swift `async throws` / Rust sync `Result` — sanctioned (no async runtime in the Rust port). `embedBatch` default impl: Swift public extension / Rust trait body |
| Built-in deterministic provider | `FloatSimHashEmbeddingProvider` | `FloatSimHashEmbeddingProvider` | public struct / pub struct | identical; host inference closure (Swift `@Sendable (String) async throws -> [Float]` / Rust `Fn(&str) -> Result<Vec<f32>, String> + Send + Sync`) projected via canonical SubstrateLib FloatSimHash with per-provider `projectionSeed`/`projection_seed` |
| Storage record | `StoredVector` | `StoredVector` | public struct / pub struct | Lane F rename: `drawerID`→`itemID` / `drawer_id`→`item_id`; `vectorIndex`/`vector_index` UInt32/u32 added for multi-vector (ColBERT); timestamp seam: Swift `Date` (TEXT ISO8601) / Rust `i64` (Unix epoch) — sanctioned; `engram` field is binary-only convenience; typed payloads accessed via `getPayload` / `get_payload` |
| Nearest-neighbour result | `VectorMatch` | `VectorMatch` | public struct / pub struct | Lane F rename: `drawerID`→`itemID` / `drawer_id`→`item_id`; ordering by distance asc then item id asc (Swift `Comparable` `<` / Rust `Ord`+`PartialOrd`); `distance` Swift `Int` / Rust `i32` (Hamming 0…256 for binary lane; cosine×10_000 for float lane) |
| Batch input record | `VectorPayloadInput` | `VectorPayloadInput` | public struct / pub struct | identical fields: `itemID`/`item_id`, `vectorIndex`/`vector_index`, `payload`, `modelID`/`model_id`, `modelVersion`/`model_version`, `filedAt`/`filed_at_unix_secs`; timestamp seam: Swift `Date` / Rust `i64` — same as `StoredVector` (sanctioned). Value type, fully `Sendable`. No methods; data carrier only. |
| PersistenceKit-backed store | `VectorStore` | `VectorStore` | public actor / pub struct | Swift `actor` (async CRUD mirrors PersistenceKit `RowStore`) / Rust `struct` over `Arc<Mutex<HotState>>` + `Arc<dyn Storage>`, sync CRUD — sanctioned (no async runtime). Construction: Swift `init(storage:sidecarURL:mihThreshold:mihBandCount:deferredPendingLimit:)` / Rust `new(storage, sidecar_path)` + `open`; `defaultSidecarURL(for:)` / `default_sidecar_path` static helper returns the conventional `.vectors.vec` path. Schema v4 (multi-vector, `item_id`, `kind`, `payload`, `filed_at` index): `schemaDeclaration` / `schema_declaration()`. Hot-path: BruteForceIndex → MIHIndex at `mihThreshold` (default 50_000); float lane via `FloatBruteForceIndex`. Write paths: `addPayload` (write-behind) + `addPayloads` (O(1) sidecar/index per batch) + `replaceModelVectors` (bulk re-embed: delete all + plain-INSERT + one index rebuild) + `flush` (quiesce). Deferred-index control: `beginDeferredIndex` / `begin_deferred_index` + `publishResidentIndex` / `publish_resident_index` — wraps bulk imports in one index rebuild. **Parity delta:** `delete_payload` (Rust-only — deletes one `(item_id, vector_index, model_id)` row; no Swift equivalent). |
| Error enum | `VectorKitError` | `VectorKitError` | public enum / pub enum | identical case-for-case: `embeddingFailed`/`EmbeddingFailed`, `modelUnavailable`/`ModelUnavailable`, `storeUnavailable`/`StoreUnavailable`, `notFound`/`NotFound` (Swift lowerCamel / Rust UpperCamel — idiom) |

## Swift/Rust Concordance — engine types

Public engine types in `Sources/VectorKit/Engine/` and `rust/src/engine/` not
covered in the per-surface tables above.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule |
|---|---|---|---|---|
| Binary distance metric | `BinaryMetric` | `BinaryMetric` | public enum / pub enum | identical 2-case enum (hamming/Hamming, jaccard/Jaccard) |
| Float distance metric | `FloatMetric` | `FloatMetric` | public enum / pub enum | identical 3-case enum (cosine/Cosine, l2/L2, dot/Dot) |
| Dense metric wrapper | `DenseMetric` | `DenseMetric` | public enum / pub enum | identical 2-case enum (binary(BinaryMetric)/Binary(BinaryMetric), float(FloatMetric)/Float(FloatMetric)) |
| Brute-force index | `BruteForceIndex` | `BruteForceIndex` | public struct / pub struct | identical: conforms to / implements DenseIndex protocol/trait |
| Float brute-force index | `FloatBruteForceIndex` | `FloatBruteForceIndex` | public actor / pub struct | Swift `actor` / Rust `struct` (sanctioned async seam). Implements `DenseIndex`; backs the Lane D float nearest / farthest search. One instance per modelID inside `VectorStore`. Methods: `search` / `find_nearest` (nearest), `searchFarthest` / `search_farthest` (farthest), guided by `SearchDirection`. |
| Dense NN result | `DenseHit` | `DenseHit` | public struct / pub struct | 3-field struct: key/key VectorRecordKey, rawDistance/raw_distance Int32/i32, metric/metric DenseMetric. Float-lane consumers use typed accessors (hammingDistance/hamming_distance, floatDistance/float_distance). Ordering: rawDistance asc, key asc tiebreak. |
| Dense index protocol | `DenseIndex` | `DenseIndex` | public protocol / pub trait | Swift `protocol : Sendable` / Rust `trait : Send + Sync`; both require `findNearest`/`find_nearest` + `insert`/`insert` + `remove`/`remove` |
| Index backend selector | `IndexKind` | `IndexKind` | public enum / pub enum | identical 2-case enum (bruteForce/BruteForce, mih/Mih) |
| Lane classification tag | `LaneTag` | `LaneTag` | public enum / pub enum | identical 4-case enum (binaryDense/BinaryDense, floatDense/FloatDense, sparse/Sparse, lateInteraction/LateInteraction); used in fusion and late-interaction paths |
| MIH band count | `MIHBandCount` | `MIHBandCount` | public enum UInt32 / pub enum u32 | identical 3-case enum (eight=8/Eight, sixteen=16/Sixteen, thirtyTwo=32/ThirtyTwo) |
| Multi-index hash index | `MIHIndex` | `MIHIndex` | public struct / pub struct | identical: conforms to / implements DenseIndex; BandCount parameter |
| MaxSim result | `MaxSimHit` | `MaxSimHit` | public struct / pub struct | 2-field struct (itemID/item_id String, score). Parity delta: Swift score is Int (integer MaxSim score, larger = more relevant); Rust score is u32. No matchCount field. |
| MaxSim scorer | `MaxSimScorer` | `MaxSimScorer` | public struct / pub struct | identical: scores a query against a `ResidentVectorArray` using max-similarity (ColBERT-style) |
| Metadata predicate | `MetadataFilter` | `MetadataFilter` | public struct / pub struct | identical 2-field struct (modelID/model_id: String?/Option<String>, modelVersion/model_version: String?/Option<String>); nil = wildcard; accepts(_:)/accepts(&key) returns true when all non-nil constraints match the key's modelID/model_version. Convenience factory: `.exact(modelID:modelVersion:)` / construct by field. |
| Model-partition index entry | `ModelPartitionEntry` | `ModelPartitionEntry` | public struct / pub struct | Parity delta: Swift has (modelID: String, modelVersion: String, range: Range<Int>); Rust has (model_id: String, start: usize, end: usize) with a range() accessor — no model_version field. Both expose the same half-open index range; the Swift version carries modelVersion for convenience, the Rust version does not. |
| Resident vector array | `ResidentVectorArray` | `ResidentVectorArray` | public struct / pub struct | in-memory contiguous float32 array for MaxSim scoring; identical layout |
| Resident store | `ResidentArrayStore` | `ResidentArrayStore` | public actor / pub struct | Swift async actor / Rust struct with Arc<Mutex<...>> (no async runtime — sanctioned) |
| Vector kind discriminant | `VectorKind` | `VectorKind` | public enum UInt8 / pub enum u8 | identical 3-case enum (binary=0/Binary, float32=1/Float32, int8=2/Int8). The `float32` case is named `float32` (not `float`) in both ports. `int8` writes are rejected fail-closed by VectorStore (SPEC §I-4a). |
| Vector storage key | `VectorRecordKey` | `VectorRecordKey` | public struct / pub struct | identical 4-field struct (itemID/item_id String, vectorIndex/vector_index UInt32/u32, modelID/model_id String, modelVersion/model_version String). No kind field — kind is carried by VectorPayload. Comparable/Ord: lexicographic on (item_id, vector_index, model_id, model_version). |
| Typed vector envelope | `VectorPayload` | `VectorPayload` | public struct / pub struct | 4-field struct: kind/kind VectorKind, dim/dim UInt32/u32, bytes/bytes [UInt8]/Vec<u8>, scale/scale Float?/Option<f32>. Carries raw bytes + decode metadata. Int8 writes are rejected fail-closed in VectorStore; `scale` is preserved as a placeholder pending int8 policy ratification (SPEC § I-4a). |

## § 8 — Telemetry

`VectorStore` emits `vectorkit.*` metrics via IntellectusLib when the
global monitoring gate is enabled. Off by default; results are
byte-identical with monitoring on or off. The Rust emit sites mirror the
Swift ones exactly (`add_vector`, `add_payloads`, `find_nearest`,
`find_by_keyword`).

| Swift call site | Metric emitted | Tags |
|---|---|---|
| `addVector(itemID:engram:modelID:modelVersion:filedAt:)` / `addPayload(itemID:vectorIndex:payload:modelID:modelVersion:filedAt:)` | `vectorkit.index.insert_latency_ms` | `kit="VectorKit"`, `model_id=<modelID>` |
| `addPayloads(_ batch:)` | `vectorkit.index.batch_insert_latency_ms` | `kit="VectorKit"`, `batch_size=<N>` |
| `findNearest(probe:modelID:limit:)` | `vectorkit.search.latency_ms` | `kit="VectorKit"`, `model_id=<modelID>` |
| `findNearest(probe:modelID:limit:)` | `vectorkit.search.result_count` | `kit="VectorKit"`, `model_id=<modelID>` |
| `findByKeyword(_:limit:)` | `vectorkit.search.keyword_result_count` | `kit="VectorKit"` |

---

*End of VectorKit Interface.*

## Changelog

### 1.7.0 -- 2026-07-20

- Defined `itemID` as canonical Drawer identity for GLK Corpus rows while
  retaining opaque document/passage identities for standalone uses.
- Restricted whole-table `destroyAllVectors` to exclusively owned standalone
  stores; GLK deletion is ownership-scoped.

### 1.6.0 -- 2026-07-16
Seven public-surface gaps closed (verifier pass 2):
- Added `defaultSidecarURL(for:)` / `default_sidecar_path` static factory helper
  to § 3 (returns the `.vectors.vec` sidecar path for a SQLite-backed storage).
- Added `replaceModelVectors(modelID:_:)` / `replace_model_vectors` to § 3 (bulk
  re-embed path: delete-all + plain-INSERT + one index rebuild in one transaction).
- Added `beginDeferredIndex()` / `begin_deferred_index` to § 3 (opens a
  deferred-index window; subsequent writes accumulate without rebuilding indexes).
- Added `publishResidentIndex()` / `publish_resident_index` to § 3 (closes the
  deferred-index window with a single index rebuild from the accumulated snapshot).
- Added `delete_payload` (Rust-only parity delta) to § 3 — deletes one
  `(item_id, vector_index, model_id)` row; no Swift equivalent.
- Added `FloatBruteForceIndex` row to the Swift/Rust Concordance — engine types
  table (it was the only public `DenseIndex` conformer absent from the table).
- Updated § 7 intro (was "clean 1:1") to accurately state the six top-level types
  are 1:1 with one method-level parity delta (`delete_payload`). Updated the
  VectorStore concordance row to enumerate the full write-path surface.

### 1.5.0 -- 2026-07-16
Engine-types concordance audit — corrected eight wrong rows in the
Swift/Rust Concordance — engine types table:
- `FloatMetric`: was "2-case (cosine, dotProduct)" → 3-case (cosine, l2, dot).
- `DenseHit`: was "(itemID, distance, laneTag)" → (key: VectorRecordKey, rawDistance: Int32/i32, metric: DenseMetric).
- `LaneTag`: was "3-case (binary, float, unknown)" → 4-case (binaryDense/BinaryDense, floatDense/FloatDense, sparse/Sparse, lateInteraction/LateInteraction).
- `MetadataFilter`: was "itemID set membership" → 2-field struct (modelID, modelVersion) with nil-wildcard accepts() filter.
- `ModelPartitionEntry`: was "(modelID, modelVersion, startOffset UInt32)" → documented actual parity delta: Swift (modelID, modelVersion, range: Range<Int>) vs Rust (model_id, start, end usize; no model_version).
- `MaxSimHit`: was "3-field (itemID, score Float, matchCount)" → 2-field (itemID, score Int/u32; no matchCount).
- `VectorKind`: was "2-case (binary, float)" → 3-case (binary=0, float32=1, int8=2); case name is `float32` not `float`.
- `VectorRecordKey`: was "3-field (itemID, vectorIndex, kind: VectorKind)" → 4-field (itemID, vectorIndex, modelID, modelVersion); no kind field.
Schema table updated from v3 to v4 and the v4 index `idx_vectors_filed_at_item` added.
VectorStore concordance: Swift init updated to include `deferredPendingLimit` parameter; Rust `new` updated to show `sidecar_path` parameter; schema reference updated to v4.

### 1.4.0 -- 2026-07-13
findByKeyword / find_by_keyword: `limit` now counts DISTINCT item ids
(internal row paging) — a row-scoped limit shrank sweep windows ~10× on
production ensembles and left the contradiction hunter blind on large
estates. NEW `recentItemIDs(limit:)` / `recent_item_ids` — newest-first
distinct item ids (filed_at DESC, item_id ASC tiebreak), the
probe-enumeration surface for bounded sweeps (contradiction hunter,
VectorSimilaritySignal). Both ports at parity; regression tests pin the
distinct-id semantics on both.

### 1.3.0 -- 2026-06-17
Documented that both ports are backend-agnostic and persist vector state
across a process restart over the on-disk SQLite backend (`SQLiteStorage` /
`persistence_kit::SqliteStorage`): the resident binary array and the Lane D
float lane reconstruct from the durable `vectors` table (or load from a
current `.vec` sidecar) on reopen. This is a conformance requirement
(VECTORKIT_SPEC 1.3.0) gated in both ports. No public API surface change — the
SQLite backend ships in PersistenceKit and `VectorStore` already holds it
behind `any Storage` / `Arc<dyn Storage>`; this records the contract and
closes the Rust conformance-coverage gap. PostgreSQL remains v1.1 (federation).
Additive (MINOR).

### 1.1.0 -- 2026-06-17
Added the float-lane FARTHEST (anti-similarity) retrieval surface
(mission 6b-modifiers-antisim): the `SearchDirection` enum
(`.nearest`/`.farthest`), `VectorStore.findFarthestFloat` /
`find_farthest_float`, and the `FloatBruteForceIndex.searchFarthest` /
`search_farthest` engine method. Farthest ranks the bottom-K by cosine
similarity (largest cosine distance first) — the "find things UNLIKE this"
objective — reusing the SAME cosine and the same item-id-ascending tie-break,
only the sort order inverted. The nearest path (`findNearestFloat`,
`search`) is byte-identical and unchanged. Additive surface (MINOR).

### 1.0.2 -- 2026-06-17
Clarified the Lane D float lane behavior under `addPayloads` and across the
kit: Lane D keeps ONE `FloatBruteForceIndex` per modelID (uniform stride per
model), built lazily per model from that model's float rows. A batch invalidates
only the affected models' indices. This documents the behavior fix that lets an
N-provider corpus (CorpusKit mission 6a-iii-core) query several models' float
rows of differing dimension without shared-stride corruption. Public surface
unchanged (`findNearestFloat`/`find_nearest_float` signatures preserved).

### 1.2.0 -- 2026-06-17
Schema v2 → v3 (the forward-compatible ext-slot contract): added the nullable `.json` `ext` forward-compat slot to the `vectors` table. Both ports; inert in 1.0 (NULL / omitted on insert, never read). Updated the `vectors`-table schema section.

### 1.0.1 -- 2026-06-15
Added `VectorPayload` row to the Swift/Rust Concordance — engine types table. Type exists in both ports; the audit regex missed it because the Swift declaration does not use a keyword the regex tracks (VectorPayload is a plain `public struct`; the gap was solely a missing concordance row).

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
