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
  Public API surface of VectorKit in both legs: the EmbeddingProvider
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
`VectorStoreTests`, `CapturePathBenchmarkTests`.)

**Rust:**

```
cargo test -p vectorkit
```

(Suites: `simhash_provider_tests.rs`, `vector_store_tests.rs`.)

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

---

*End of VectorKit Interface v0.8.*
