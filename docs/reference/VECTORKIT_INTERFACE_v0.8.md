---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: VectorKit
languages: [swift, rust]
relates_to:
  - VECTORKIT_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of VectorKit in both ports: the EmbeddingProvider
  abstraction, the built-in FloatSimHashEmbeddingProvider, the
  StoredVector record, the VectorStore CRUD surface, the VectorMatch
  result type, and the VectorKitError enum. The companion SPEC carries
  the behavioral contracts (invariants I-1…I-7, conformance C-1…C-8).
---

# VectorKit Interface

## § 1 — Package layout

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
`vectors(forDrawerID:)` (SPEC § 4, I-1/I-3; § 5, B-5/B-9).

**Swift:**

```swift
public struct StoredVector: Sendable, Equatable {
    public let id: String            // UUID string, stable across upserts
    public let drawerID: String
    public let modelID: String
    public let modelVersion: String
    public let engram: Engram
    public let filedAt: Date         // round-tripped through TEXT ISO8601

    public init(id: String,
                drawerID: String,
                modelID: String,
                modelVersion: String,
                engram: Engram,
                filedAt: Date)
}
```

**Rust:**

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredVector {
    pub id: String,
    pub drawer_id: String,
    pub model_id: String,
    pub model_version: String,
    pub engram: Engram,
    pub filed_at: i64,   // Unix epoch seconds (TypedValue::Timestamp)
}
```

### `VectorMatch`

A nearest-neighbour result: one matched drawer, the Hamming distance,
and the producing model's id (SPEC § 4, I-2; § 5, B-6/B-10). Ordered by
distance ascending, ties by `drawerID`/`drawer_id` ascending.

**Swift:**

```swift
public struct VectorMatch: Sendable, Comparable, Equatable {
    public let drawerID: String
    public let distance: Int      // 0…256
    public let modelID: String

    public init(drawerID: String, distance: Int, modelID: String)
    public static func < (lhs: VectorMatch, rhs: VectorMatch) -> Bool  // by distance asc
}
```

**Rust:**

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VectorMatch {
    pub drawer_id: String,
    pub distance: i32,   // 0..=256
    pub model_id: String,
}

impl Ord for VectorMatch { /* distance asc, then drawer_id asc */ }
impl PartialOrd for VectorMatch { /* delegates to Ord */ }
```

### `VectorStore`

The PersistenceKit-backed store. A Swift `actor` (async surface mirrors
PersistenceKit's `RowStore`); a Rust struct holding `Arc<dyn Storage>`.
Constructed against an already-opened `Storage`; the caller opens the
schema (SPEC § 4, I-6). Methods are in § 3.

**Swift:**

```swift
public actor VectorStore {
    public static let schemaDeclaration: SchemaDeclaration
    public init(storage: any Storage)
    // CRUD + query methods: see § 3
}
```

**Rust:**

```rust
pub struct VectorStore { /* storage: Arc<dyn Storage> */ }

impl VectorStore {
    pub fn schema_declaration() -> SchemaDeclaration;
    pub fn new(storage: Arc<dyn Storage>) -> Self;
    pub fn open(storage: Arc<dyn Storage>) -> Result<Self, VectorKitError>; // opens schema, returns store
    // CRUD + query methods: see § 3
}
```

The `vectors` table schema (declared by `schemaDeclaration` /
`schema_declaration()`): columns `id` UUID PK, `drawer_id` TEXT,
`model_id` TEXT, `model_version` TEXT, `engram` BLOB (32 bytes, 4×UInt64
LE), `filed_at` TIMESTAMP; UNIQUE on `(drawer_id, model_id)` (SPEC § 4,
I-3/I-4); indices `idx_vectors_drawer` on `(drawer_id)` and
`idx_vectors_model_drawer` on `(model_id, drawer_id)`.

## § 3 — Public functions

### `embed`

Generate a model-tagged engram for text (SPEC § 5, B-1/B-2; I-5). See
`EmbeddingProvider` / `FloatSimHashEmbeddingProvider` in § 2 for the
signatures.

### `VectorStore.addVector` / `add_vector`

Upsert a model-tagged vector for a drawer; updates in place on
`(drawerID, modelID)` (SPEC § 5, B-3).

**Swift:**

```swift
public func addVector(
    drawerID: String,
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
    drawer_id: &str,
    engram: &Engram,
    model_id: &str,
    model_version: &str,
    filed_at_unix_secs: i64,
) -> Result<(), VectorKitError>;
```

### `VectorStore.getVector` / `get_vector`

Point read of the engram stored under `(drawerID, modelID)` (SPEC § 5,
B-4).

**Swift:**

```swift
public func getVector(drawerID: String, modelID: String) async throws -> Engram?
```

**Rust:**

```rust
pub fn get_vector(&self, drawer_id: &str, model_id: &str)
    -> Result<Option<Engram>, VectorKitError>;
```

### `VectorStore.vectors(forDrawerID:)` / `vectors_for_drawer`

Every row for a drawer (one per distinct model), ordered by `filed_at`
ascending (SPEC § 5, B-5).

**Swift:**

```swift
public func vectors(forDrawerID drawerID: String) async throws -> [StoredVector]
```

**Rust:**

```rust
pub fn vectors_for_drawer(&self, drawer_id: &str)
    -> Result<Vec<StoredVector>, VectorKitError>;
```

### `VectorStore.findNearest` / `find_nearest`

k-nearest by Hamming distance over rows tagged with the given model;
sorted distance ascending, ties by drawer id ascending (SPEC § 5,
B-6/B-10; I-2).

**Swift:**

```swift
public func findNearest(probe: Engram, modelID: String, limit: Int) async throws -> [VectorMatch]
```

**Rust:**

```rust
pub fn find_nearest(&self, probe: &Engram, model_id: &str, k: usize)
    -> Result<Vec<VectorMatch>, VectorKitError>;
```

### `VectorStore.findByKeyword` / `find_by_keyword`

Coarse substring pre-filter over `drawer_id`; returns distinct drawer
ids up to `limit`, ascending (SPEC § 5, B-7).

**Swift:**

```swift
public func findByKeyword(_ query: String, limit: Int) async throws -> [String]
```

**Rust:**

```rust
pub fn find_by_keyword(&self, query: &str, limit: usize)
    -> Result<Vec<String>, VectorKitError>;
```

### `VectorStore.deleteVector` / `delete_vector`

Idempotent delete of the row at `(drawerID, modelID)` (SPEC § 5, B-8).

**Swift:**

```swift
public func deleteVector(drawerID: String, modelID: String) async throws
```

**Rust:**

```rust
pub fn delete_vector(&self, drawer_id: &str, model_id: &str)
    -> Result<(), VectorKitError>;
```

### `VectorStore.destroyAllVectors` / `destroy_all_vectors` — GLK_PROVISION_001

Deletes all rows from the `vectors` table. Called by
`GeniusLocusKit.destroy(storage:corpusStorage:handle:)` as part of
coordinated estate teardown. After this call the backing storage is intact
(schema preserved) but contains no vector data. The caller is responsible for
closing the estate before calling this method.

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
}
```

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/VectorKit
```

(Targets: `EmbeddingProviderTests`, `FloatSimHashEmbeddingProviderTests`,
`VectorStoreTests`, `CapturePathBenchmarkTests`, `VectorKitTelemetryTests`.)

**Rust:**

```
cargo test -p vectorkit
```

(Suites: `simhash_provider_tests.rs`, `vector_store_tests.rs`,
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

// 3. File a model-tagged vector for a drawer.
let engram = try await provider.embed("the legal pad on my desk")
try await store.addVector(
    drawerID: "drawer-42",
    engram: engram,
    modelID: provider.modelID,
    modelVersion: provider.modelVersion,
    filedAt: now
)

// 4. Query nearest neighbours within the same model.
let probe = try await provider.embed("yellow notepad")
let hits = try await store.findNearest(probe: probe, modelID: "minilm-v6", limit: 10)
// hits: [VectorMatch] sorted near → far, each tagged "minilm-v6"
```

## § 7 — Swift/Rust Concordance

Every top-level public concept in VectorKit, mapped Swift↔Rust with the
shape rule that governs how the two ports may differ and the actual
conformance test that proves they agree. Read-anchored: each symbol was
verified in source at the cited file:line. The surface is a clean 1:1 —
six public types, identical names, no Apple-platform-bound types, no
Swift-only or Rust-only contract types.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Embedding abstraction | `EmbeddingProvider` (`Sources/VectorKit/EmbeddingProvider.swift:15`) | `EmbeddingProvider` (`rust/src/embedding_provider.rs:21`) | public protocol / pub trait | identical surface (`modelID`/`model_id`, `modelVersion`/`model_version`, `embed`, `embedBatch`/`embed_batch`); Swift `async throws` / Rust sync `Result` — sanctioned (no async runtime in the Rust port). `embedBatch` default impl: Swift public extension / Rust trait body | `EmbeddingProviderTests.swift::testEmbedReturnsEngram`, `testEmbedEmptyStringReturnsZeroEngram` ↔ `simhash_provider_tests.rs::empty_text_returns_zero_engram` | Confirmed |
| Built-in deterministic provider | `FloatSimHashEmbeddingProvider` (`Sources/VectorKit/FloatSimHashEmbeddingProvider.swift:36`) | `FloatSimHashEmbeddingProvider` (`rust/src/simhash_embedding_provider.rs:43`) | public struct / pub struct | identical; host inference closure (Swift `@Sendable (String) async throws -> [Float]` / Rust `Fn(&str) -> Result<Vec<f32>, String> + Send + Sync`) projected via canonical SubstrateLib FloatSimHash with per-provider `projectionSeed`/`projection_seed` | `FloatSimHashEmbeddingProviderTests.swift::testEmbedIsDeterministicForSameText`, `testDifferentSeedsProduceDifferentEngrams` ↔ `simhash_provider_tests.rs::provider_embed_is_deterministic_for_same_text`, `different_providers_produce_different_engrams_for_same_text` | Confirmed |
| Storage record | `StoredVector` (`Sources/VectorKit/StoredVector.swift:11`) | `StoredVector` (`rust/src/vector_store.rs:32`) | public struct / pub struct | fields identical except timestamp: Swift `filedAt: Date` (round-tripped through TEXT ISO8601) / Rust `filed_at: i64` (Unix epoch seconds, `TypedValue::Timestamp`) — sanctioned date-storage seam, value-equivalent across ports | `StoredVectorTests.swift::testInitRetainsAllFields`, `VectorStoreTests.swift::testModelAndVersionRoundTrip` ↔ `vector_store_tests.rs::model_and_version_round_trip`, `add_get_round_trip_preserves_engram_bytes` | Confirmed |
| Nearest-neighbour result | `VectorMatch` (`Sources/VectorKit/VectorMatch.swift:20`) | `VectorMatch` (`rust/src/vector_store.rs:45`) | public struct / pub struct | identical; ordering by distance asc then drawer id asc (Swift `Comparable` `<` / Rust `Ord`+`PartialOrd`); `distance` Swift `Int` / Rust `i32`, range 0…256 | `VectorMatchTests.swift::testComparableOrdersByDistanceAscending`, `testSortingProducesDistanceAscendingOrder` ↔ `vector_store_tests.rs::find_nearest_returns_k_results_sorted_by_distance_ascending` | Confirmed |
| PersistenceKit-backed store | `VectorStore` (`Sources/VectorKit/VectorStore.swift:51`) | `VectorStore` (`rust/src/vector_store.rs:67`) | public actor / pub struct | Swift `actor` (async CRUD mirrors PersistenceKit `RowStore`) / Rust `struct` over `Arc<dyn Storage>`, sync CRUD — sanctioned (no async runtime). Construction: Swift `init(storage:)` / Rust `new` + `open`. Schema: `schemaDeclaration` / `schema_declaration()` | `VectorStoreTests.swift::testAddGetRoundTripPreservesEngramBytes`, `testFindNearestReturnsKResultsSortedByDistanceAscending`, `testFindByKeywordReturnsMatchingDrawers` ↔ `vector_store_tests.rs::add_get_round_trip_preserves_engram_bytes`, `find_nearest_returns_k_results_sorted_by_distance_ascending`, `find_by_keyword_returns_matching_drawers` | Confirmed |
| Error enum | `VectorKitError` (`Sources/VectorKit/VectorKitError.swift:5`) | `VectorKitError` (`rust/src/error.rs:7`) | public enum / pub enum | identical case-for-case: `embeddingFailed`/`EmbeddingFailed`, `modelUnavailable`/`ModelUnavailable`, `storeUnavailable`/`StoreUnavailable`, `notFound`/`NotFound` (Swift lowerCamel / Rust UpperCamel — idiom) | `VectorKitErrorTests.swift::testIsThrowableErrorAndPreservesPayload`, `FloatSimHashEmbeddingProviderTests.swift::testInferenceFailurePropagates` ↔ `simhash_provider_tests.rs::inference_failure_surfaces_as_embedding_failed` | Confirmed |

## § Telemetry — VECTORKIT_REPORT_001

Added: 2026-06-06. VectorStore emits `vectorkit.*` metrics via
IntellectusLib when the global monitoring gate is enabled. Off by default.

### Dependencies added

- `Package.swift`: `IntellectusLib` in-repo dependency added to the
  `VectorKit` target and `VectorKitTests` test target. Authority:
  `DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28` + `MANAGER_1.0_PLAN §4`.
- `Cargo.toml`: `intellectus-lib = { path = "…/IntellectusLib/rust" }`
  added under `[dependencies]`.

### Emit surface

| Swift call site | Metric emitted | Tags |
|---|---|---|
| `addVector(drawerID:engram:modelID:modelVersion:filedAt:)` | `vectorkit.index.insert_latency_ms` | `kit="VectorKit"`, `model_id=<modelID>` |
| `findNearest(probe:modelID:limit:)` | `vectorkit.search.latency_ms` | `kit="VectorKit"`, `model_id=<modelID>` |
| `findNearest(probe:modelID:limit:)` | `vectorkit.search.result_count` | `kit="VectorKit"`, `model_id=<modelID>` |
| `findByKeyword(_:limit:)` | `vectorkit.search.keyword_result_count` | `kit="VectorKit"` |

Rust emit sites mirror the Swift ones exactly (`add_vector`, `find_nearest`,
`find_by_keyword`).

### Test suite: `VectorKitTelemetryTests` (Swift)

File: `Tests/VectorKitTests/VectorKitTelemetryTests.swift`

Four serialised suites, all bodies serialised under `GlobalTestLock`
(async mutex in `GlobalTestLock.swift`):

- `§1 VectorKitTelemetry — disabled gate`: 3 tests — no metrics emitted
  when monitoring is off.
- `§2 VectorKitTelemetry — enabled gate`: 3 tests — exact metric counts
  when monitoring is on (counts filtered to `vectorkit.*` namespace to
  exclude substrate-layer emissions from EngramLib/SubstrateKernel).
- `§3 VectorKitTelemetry — metric shapes`: 3 tests — metric names, values,
  and tags conform to spec.
- `§4 VectorKitTelemetry — conformance`: 2 tests — results are
  byte-identical with monitoring on and off.

### Test suite: `vectorkit_telemetry_tests` (Rust)

File: `rust/tests/vectorkit_telemetry_tests.rs`

11 tests serialised under `GLOBAL_LOCK: OnceLock<Mutex<()>>`. Mirrors
the Swift suite. Count assertions filter to `vectorkit.*` prefix to
exclude `substrate.kernel.backend_selected` emitted by SubstrateKernel
via EngramLib.

### GlobalTestLock isolation invariant

All tests in the `VectorKitTests` binary that call VectorStore emit
methods MUST hold `GlobalTestLock.shared` for their entire duration:

- `VectorStoreTests` — added `withLock` to all 15 tests.
- `CapturePathBenchmarkTests` — added `withLock` to the 3 VectorStore-
  exercising tests so benchmark P99 assertions have exclusive CPU access.
- `VectorKitTelemetryTests` — all test bodies wrapped in `withLock`.

---

*End of VectorKit Interface v0.8.*
