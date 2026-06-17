---
title: CorpusKit Interface
status: active
authors: MOOTx01 maintainers
date: 2026-06-17
spec_type: kit
version: 1.5.0
description: Public API surface for CorpusKit in both the Swift and Rust ports.
package: CorpusKit
languages: [swift, rust]
relates_to:
  - CORPUSKIT_SPEC.md  (the contract this interface implements)
  - DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md  (authorizes the IntellectusLib dependency)
purpose: |
  Public API surface of CorpusKit in both ports: the Chunk content
  model and its content-addressed identity, the Chunker, the BM25Index
  actor, the BundleStore actor, HybridRecall, the Tokenizer protocol,
  the three CorpusKitProviders providers (Swift and Rust, both ports),
  the DeterministicTokenizer stand-in, the host-inference seam type,
  and the CorpusKitSync manifest. The companion SPEC carries the
  behavioral contracts (invariants I-1…I-8, conformance C-1…C-8b).
---

# CorpusKit Interface

## § 1 — Package layout

**Swift:** `packages/kits/CorpusKit/`

Two library targets plus tests:

- `Sources/CorpusKit/` — core surface (no model weights):
  - `Chunk.swift` — `Chunk`, `ScoredChunk`
  - `Chunker.swift` — `Chunker`, `ChunkerConfiguration`
  - `BM25Index.swift` — `BM25Index` (actor), `BM25Parameters`
  - `BundleStore.swift` — `BundleStore` (actor)
  - `HybridRecall.swift` — `HybridRecall`, `HybridRecallConfiguration`
  - `Tokenizer.swift` — `Tokenizer` protocol + default `keywordTokens`
  - `SyncManifest.swift` — `CorpusKitSync`
  - `CorpusKitError.swift` — `CorpusKitError`
  - `CorpusKit.swift` — module doc
- `Sources/CorpusKitProviders/` — providers (imply a model bundle):
  - `MiniLMTextProvider.swift`, `MPNetTextProvider.swift`,
    `EmbeddingGemmaProvider.swift`, `DeterministicTokenizer.swift`
- `Tests/CorpusKitTests/`, `Package.swift`

**Rust:** `packages/kits/CorpusKit/rust/` (crate `corpus-kit`,
lib `corpus_kit`) + `packages/kits/CorpusKit/rust-providers/`
(crate `corpus-kit-providers`, lib `corpus_kit_providers`)

- core `src/`: `chunk.rs`, `chunker.rs`, `bm25_index.rs`,
  `bundle_store.rs`, `hybrid_recall.rs`, `embedding_provider.rs`,
  `tokenizer.rs`, `sync_manifest.rs`, `error.rs`, `lib.rs`
- providers `src/`: `deterministic_tokenizer.rs`, `text_providers.rs`
  (`MiniLMTextProvider`, `MPNetTextProvider`, `EmbeddingGemmaProvider`,
  `InferenceFn`), `lib.rs`
- depends on `substrate-lib`, `engram-lib`, `eidetic-lib`,
  `persistence-kit`, `convergence-kit`, `vectorkit`

## § 2 — Public types

### `Chunk`

A unit of retrievable text with a content-addressed identity
(SPEC § 4, I-1). The id is a deterministic RFC 4122 v5 UUID over
`(sourceID, startOffset, text)`.

**Swift:**

```swift
public struct Chunk: Sendable, Equatable, Codable {
    public let id: UUID
    public let sourceID: String
    public let startOffset: Int
    public let length: Int
    public let text: String
    public let hlc: HLC                       // SubstrateLib
    public let metadata: [String: String]

    /// Content-addressed initializer: id derived from
    /// (sourceID, startOffset, text). The normal ingestion path.
    public init(sourceID: String, startOffset: Int, length: Int,
                text: String, hlc: HLC, metadata: [String: String] = [:])

    /// Explicit-id initializer: used when reconstructing a stored row.
    public init(id: UUID, sourceID: String, startOffset: Int, length: Int,
                text: String, hlc: HLC, metadata: [String: String] = [:])

    /// Derive the content-addressed v5 UUID directly (SPEC C-1).
    public static func deriveID(sourceID: String, startOffset: Int,
                                text: String) -> UUID
}
```

**Rust:**

```rust
pub struct Chunk {
    pub id: Uuid,
    pub source_id: String,
    pub start_offset: usize,
    pub length: usize,
    pub text: String,
    pub hlc: HLC,
    pub metadata: BTreeMap<String, String>,   // stable encoded bytes
}
impl Chunk {
    pub fn new(id: Uuid, source_id: impl Into<String>, start_offset: usize,
               length: usize, text: impl Into<String>, hlc: HLC,
               metadata: BTreeMap<String, String>) -> Self;
    pub fn content_addressed(source_id: impl Into<String>, start_offset: usize,
               length: usize, text: impl Into<String>, hlc: HLC,
               metadata: BTreeMap<String, String>) -> Self;
    pub fn derive_id(source_id: &str, start_offset: usize, text: &str) -> Uuid;
}
```

### `ScoredChunk`

A chunk plus its retrieval score, returned by hybrid recall
(SPEC § 5, B-4). Absent sub-scores are `nil` / `None`.

**Swift:**

```swift
public struct ScoredChunk: Sendable, Equatable {
    public let chunk: Chunk
    public let score: Float
    public let vectorScore: Float?
    public let keywordScore: Float?
    public init(chunk: Chunk, score: Float,
                vectorScore: Float? = nil, keywordScore: Float? = nil)
}
```

**Rust:**

```rust
pub struct ScoredChunk {
    pub chunk: Chunk,
    pub score: f32,
    pub vector_score: Option<f32>,
    pub keyword_score: Option<f32>,
}
impl ScoredChunk {
    pub fn new(chunk: Chunk, score: f32) -> Self;
    pub fn with_subscores(chunk: Chunk, score: f32,
                          vector_score: Option<f32>,
                          keyword_score: Option<f32>) -> Self;
}
```

### `ChunkerConfiguration`

Chunking parameters; defaults match the substrate reference
(target 800 chars, overlap 100). Overlap is clamped to
`[0, targetChars-1]` (SPEC § 5, B-1).

**Swift:**

```swift
public struct ChunkerConfiguration: Sendable {
    public let targetChars: Int
    public let overlapChars: Int
    public let respectSentences: Bool
    public init(targetChars: Int = 800, overlapChars: Int = 100,
                respectSentences: Bool = true)
}
```

**Rust:**

```rust
pub struct ChunkerConfiguration {
    pub target_chars: usize,
    pub overlap_chars: usize,
    pub respect_sentences: bool,
}
impl ChunkerConfiguration {
    pub fn new(target_chars: usize, overlap_chars: usize,
               respect_sentences: bool) -> Self;
}
impl Default for ChunkerConfiguration { /* 800 / 100 / true */ }
```

### `BM25Parameters`

Robertson–Spärck-Jones BM25 tuning (SPEC § 5, B-2). Defaults k1 = 1.5,
b = 0.75.

**Swift:**

```swift
public struct BM25Parameters: Sendable {
    public var k1: Double
    public var b: Double
    public init(k1: Double = 1.5, b: Double = 0.75)
}
```

**Rust:**

```rust
pub struct BM25Parameters { pub k1: f64, pub b: f64 }
impl BM25Parameters { pub const fn new(k1: f64, b: f64) -> Self; }
impl Default for BM25Parameters { /* 1.5 / 0.75 */ }
```

### `BM25Index`

In-memory BM25 inverted index over chunk text (SPEC § 5, B-2, B-3). An
`actor` in Swift; in Rust, owned state with `&mut self` on the mutating
verbs (`index_documents`, `remove`) and `&self` on reads (`search`,
`document_count`).

**Swift:**

```swift
public actor BM25Index {
    public init(tokenizer: any Tokenizer,
                parameters: BM25Parameters = BM25Parameters())
    public func index(_ chunks: [Chunk])
    public func remove(_ chunkID: UUID)
    public func search(_ query: String, limit: Int) -> [(UUID, Double)]
    public func documentCount() -> Int
}
```

**Rust:**

```rust
pub struct BM25Index { /* owned postings + stats */ }
impl BM25Index {
    pub fn new(tokenizer: Arc<dyn Tokenizer>) -> Self;
    pub fn with_parameters(tokenizer: Arc<dyn Tokenizer>,
                           parameters: BM25Parameters) -> Self;
    pub fn index_documents<'a, I>(&mut self, documents: I)
        where I: IntoIterator<Item = (Uuid, &'a str)>;
    pub fn remove(&mut self, doc_id: Uuid);
    pub fn search(&self, query: &str, limit: usize) -> Vec<(Uuid, f64)>;
    pub fn document_count(&self) -> usize;
}
```

### `BundleStore`

Append-only, idempotent storage for the content half of a bundle
(SPEC § 4, I-2, I-3). The chunks table joins to VectorKit by
`chunk.id.uuidString == storedVector.drawerID` (I-5). An `actor` in
Swift over a PersistenceKit `Storage`.

**Swift:**

```swift
public actor BundleStore {
    public static let schemaDeclaration: SchemaDeclaration   // chunks table, appendOnly
    public init(storage: any Storage)
    public func insert(_ chunks: [Chunk]) async throws        // idempotent (B-5)
    public func get(id: UUID) async throws -> Chunk?
    public func getMany(ids: [UUID]) async throws -> [Chunk]
    public func chunksForSource(_ sourceID: String) async throws -> [Chunk]
    public func count() async throws -> Int
    public func allChunks() async throws -> [Chunk]           // HLC-ordered
}
```

**Rust:**

```rust
pub struct BundleStore { /* Arc<dyn Storage> */ }
impl BundleStore {
    pub fn schema_declaration() -> SchemaDeclaration;
    pub fn new(storage: Arc<dyn Storage>) -> Self;
    pub fn open(storage: Arc<dyn Storage>) -> CorpusKitResult<Self>;  // applies schema
    pub fn insert(&self, chunks: &[Chunk]) -> CorpusKitResult<()>;
    pub fn get(&self, id: Uuid) -> CorpusKitResult<Option<Chunk>>;
    pub fn get_many(&self, ids: &[Uuid]) -> CorpusKitResult<Vec<Chunk>>;
    pub fn chunks_for_source(&self, source_id: &str) -> CorpusKitResult<Vec<Chunk>>;
    pub fn count(&self) -> CorpusKitResult<usize>;
    pub fn all_chunks(&self) -> CorpusKitResult<Vec<Chunk>>;
}
```

### `HybridRecallConfiguration`

Weights, the RRF constant, and optional MMR diversification
(SPEC § 5, B-4). Defaults: vector 0.6, keyword 0.4, rrfK 60, MMR off.

**Swift:**

```swift
public struct HybridRecallConfiguration: Sendable {
    public var vectorWeight: Double
    public var keywordWeight: Double
    public var rrfK: Double           // Cormack et al. recommend 60
    public var mmrLambda: Double?     // nil disables MMR
    public init(vectorWeight: Double = 0.6, keywordWeight: Double = 0.4,
                rrfK: Double = 60, mmrLambda: Double? = nil)
}
```

**Rust:**

```rust
pub struct HybridRecallConfiguration {
    pub vector_weight: f64,
    pub keyword_weight: f64,
    pub rrf_k: f64,
    pub mmr_lambda: Option<f64>,
}
impl Default for HybridRecallConfiguration { /* 0.6 / 0.4 / 60 / None */ }
```

### `Tokenizer` (protocol)

Tokenization protocol shared by every embedding provider; the BM25
index calls `keywordTokens` (SPEC § 4, I-6). Concrete tokenizers live
in `CorpusKitProviders`.

**Swift:**

```swift
public protocol Tokenizer: Sendable {
    var vocabID: String { get }
    var maxTokens: Int { get }
    var padTokenID: Int32 { get }
    var unknownTokenID: Int32 { get }
    func tokenize(_ text: String) -> [Int32]
    func keywordTokens(_ text: String) -> [String]
}
public extension Tokenizer {
    // default: lowercase, split on Unicode word boundaries
    func keywordTokens(_ text: String) -> [String]
}
```

**Rust:**

```rust
pub trait Tokenizer: Send + Sync {
    fn vocab_id(&self) -> &str;
    fn max_tokens(&self) -> usize;
    fn pad_token_id(&self) -> i32;
    fn unknown_token_id(&self) -> i32;
    fn tokenize(&self, text: &str) -> Vec<i32>;
    fn keyword_tokens(&self, text: &str) -> Vec<String> {
        default_keyword_tokens(text)
    }
}
pub fn default_keyword_tokens(text: &str) -> Vec<String>;
```

### Providers (`CorpusKitProviders` / `corpus-kit-providers`)

Three text providers sharing one shape: `modelID`, `modelVersion`,
`tokenizer` (held as an implementation detail — not part of
VectorKit's contract, preserving VectorKit's pure-compute isolation),
a stable `projectionSeed`, and an injected inference closure (CoreML
loading is the host app's job, SPEC § 5 B-6). Seeds are distinct per
provider so engrams never collide across models (I-4). All three
conform to **VectorKit's `EmbeddingProvider`** directly; each `embed`
enforces the empty-input contract
(`text.isEmpty → Engram.zero`) before tokenize/inference, so the
inference closure is never reached for empty input.

**Swift:**

```swift
public struct MiniLMTextProvider: EmbeddingProvider {
    public let modelID: String          // default "minilm-v6"
    public let modelVersion: String     // default "1.0.0"
    public let tokenizer: any Tokenizer  // default DeterministicTokenizer("minilm-l6-v2")
    public let projectionSeed: UInt64    // default 0x4D49_4E4C_4D_5F76_31 ("MINLM_v1")
    public let inference: @Sendable ([Int32]) async throws -> [Float]   // pooled 384-dim
    public init(modelID: String = "minilm-v6", modelVersion: String = "1.0.0",
                tokenizer: any Tokenizer = DeterministicTokenizer(vocabID: "minilm-l6-v2"),
                projectionSeed: UInt64 = 0x4D49_4E4C_4D_5F76_31,
                inference: @escaping @Sendable ([Int32]) async throws -> [Float])
    public func embed(_ text: String) async throws -> Engram
}

public struct MPNetTextProvider: EmbeddingProvider {
    // default modelID "mpnet-base-v2", seed 0x4D50_4E45_54_5F76_31 ("MPNET_v1"),
    // pooled 768-dim, tokenizer DeterministicTokenizer("mpnet-base")
    public init(modelID: String = "mpnet-base-v2", modelVersion: String = "1.0.0",
                tokenizer: any Tokenizer = DeterministicTokenizer(vocabID: "mpnet-base"),
                projectionSeed: UInt64 = 0x4D50_4E45_54_5F76_31,
                inference: @escaping @Sendable ([Int32]) async throws -> [Float])
    public func embed(_ text: String) async throws -> Engram
}

public struct EmbeddingGemmaProvider: EmbeddingProvider {
    // default modelID "embedding-gemma-300m", seed 0x454D_4247_4D_5F76_31 ("EMBGM_v1"),
    // pooled 768-dim, SentencePiece-shaped DeterministicTokenizer (vocab 256000, max 2048)
    public init(modelID: String = "embedding-gemma-300m", modelVersion: String = "1.0.0",
                tokenizer: any Tokenizer = DeterministicTokenizer(
                    vocabID: "embedding-gemma-300m", vocabSize: 256_000, maxTokens: 2048),
                projectionSeed: UInt64 = 0x454D_4247_4D_5F76_31,
                inference: @escaping @Sendable ([Int32]) async throws -> [Float])
    public func embed(_ text: String) async throws -> Engram
}

public struct DeterministicTokenizer: Tokenizer {
    public let vocabID: String
    public let vocabSize: Int32
    public let maxTokens: Int
    public let padTokenID: Int32        // 0
    public let unknownTokenID: Int32    // 1
    public init(vocabID: String = "deterministic-v1",
                vocabSize: Int32 = 30522, maxTokens: Int = 128)
    public func tokenize(_ text: String) -> [Int32]   // FNV-1a fold into [2, vocabSize)
}
```

**Rust:** the `corpus-kit-providers` crate ships all four providers —
`DeterministicTokenizer` plus the three named text providers. The named
providers carry a host-supplied inference seam (`InferenceFn`) mirroring
the Swift inference closure. `DeterministicTokenizer` is the internal
fallback tokenizer held by each named provider until the host injects a
real vocabulary; it is also the conformance fixture tokenizer.

```rust
/// Sync inference seam: token IDs in, pooled float vector out. The host
/// injects it, exactly as Swift providers take `([Int32]) async throws -> [Float]`.
pub type InferenceFn = Box<dyn Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static>;

pub struct DeterministicTokenizer { /* vocab_id, vocab_size, max_tokens */ }
impl DeterministicTokenizer {
    pub fn new() -> Self;
    pub fn with_parameters(vocab_id: impl Into<String>,
                           vocab_size: i32, max_tokens: usize) -> Self;
}
impl Default for DeterministicTokenizer { /* "deterministic-v1" / 30522 / 128 */ }
impl Tokenizer for DeterministicTokenizer { /* FNV-1a fold, matches Swift */ }

pub struct MiniLMTextProvider { /* model_id, model_version, tokenizer, projection_seed, inference */ }
impl MiniLMTextProvider {
    /// Swift defaults: model_id "minilm-v6", DeterministicTokenizer("minilm-l6-v2"),
    /// seed 0x4D49_4E4C_4D5F_7631 ("MINLM_v1"), vocab 30522, max 128 tokens.
    pub fn new(inference: impl Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static) -> Self;
    pub fn with_parameters(model_id: impl Into<String>, model_version: impl Into<String>,
                           tokenizer: Box<dyn Tokenizer>, projection_seed: u64,
                           inference: impl Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static) -> Self;
}
impl EmbeddingProvider for MiniLMTextProvider { /* embed, embed_float */ }

pub struct MPNetTextProvider { /* model_id, model_version, tokenizer, projection_seed, inference */ }
impl MPNetTextProvider {
    /// Swift defaults: model_id "mpnet-base-v2", DeterministicTokenizer("mpnet-base"),
    /// seed 0x4D50_4E45_545F_7631 ("MPNET_v1"), vocab 30522, max 128 tokens.
    pub fn new(inference: impl Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static) -> Self;
    pub fn with_parameters(model_id: impl Into<String>, model_version: impl Into<String>,
                           tokenizer: Box<dyn Tokenizer>, projection_seed: u64,
                           inference: impl Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static) -> Self;
}
impl EmbeddingProvider for MPNetTextProvider { /* embed, embed_float */ }

pub struct EmbeddingGemmaProvider { /* model_id, model_version, tokenizer, projection_seed, inference */ }
impl EmbeddingGemmaProvider {
    /// Swift defaults: model_id "embedding-gemma-300m",
    /// DeterministicTokenizer("embedding-gemma-300m", vocab 256000, max 2048),
    /// seed 0x454D_4247_4D5F_7631 ("EMBGM_v1").
    pub fn new(inference: impl Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static) -> Self;
    pub fn with_parameters(model_id: impl Into<String>, model_version: impl Into<String>,
                           tokenizer: Box<dyn Tokenizer>, projection_seed: u64,
                           inference: impl Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static) -> Self;
}
impl EmbeddingProvider for EmbeddingGemmaProvider { /* embed, embed_float */ }
```

> **Provider surface (both ports):** Swift and Rust providers conform to
> VectorKit's `EmbeddingProvider`. Tokenizer stays in CorpusKit as a
> per-provider implementation detail — not part of VectorKit's contract —
> preserving VectorKit's pure-compute isolation.
>
> The Rust `corpus-kit-providers` crate ships `MiniLMTextProvider`,
> `MPNetTextProvider`, and `EmbeddingGemmaProvider` alongside
> `DeterministicTokenizer`. The three named providers use the same
> host-inference seam model as Swift: `InferenceFn` (synchronous, token
> IDs in / pooled float vector out). No ONNX/Candle dependency is added;
> the kit owns only the tokenizer and projection; model weights remain
> the host's concern on every platform.

### Distributional-provider basis serialization (both ports)

The four stateful distributional providers — `RandomIndexingProvider`,
`PpmiProvider`, `LsaProvider`, `NmfProvider` — expose a versioned,
little-endian **basis serialization** API. A trained provider serializes
its basis to bytes and a deserializing initializer/constructor
reconstructs a provider whose embeddings are bit-identical to the
original. The same trained state produces a **byte-identical blob on both
ports**; this is the cross-port conformance contract (FDC is stateless and
has no basis — it carries no serialization API).

**Byte format (the contract).** Each blob is framed as
`MAGIC (4 ASCII bytes) | FORMAT_VERSION (1 byte) | payload`. Magic is
per-provider (`RIB1`, `PPB1`, `LSB1`, `NMB1`). All integers and floats are
**little-endian**; floats are IEEE-754 bit patterns (`Float.bitPattern` /
`f32::to_le_bytes`); strings are UInt32-length-prefixed UTF-8; arrays/maps
are UInt32-count-prefixed; map keys are emitted in ascending UTF-8 byte
order so both ports produce identical bytes. The shared codec lives in
`BasisCodec.swift` / `basis_codec.rs` (one definition per port). An unknown
format version, a magic mismatch, or a truncated blob is rejected with a
structured error — `CorpusKitError.decodingFailure` (Swift) /
`BasisCodecError` (Rust) — never a crash or panic.

**Swift:**

```swift
// On each of RandomIndexingProvider, PpmiProvider, LsaProvider, NmfProvider:
public func serializeBasis() -> Data
public convenience init(deserializing data: Data) throws  // throws CorpusKitError.decodingFailure

// Shared codec (CorpusKitProviders):
public let basisFormatVersion: UInt8  // current format version (1)
public struct BasisWriter { /* writeU32/writeU64/writeF32/writeString/… */ }
public struct BasisReader { /* readU32/…; throws on truncation/bad header */ }
```

**Rust:** the `corpus-kit-providers` crate exposes the mirror API.

```rust
// On each of RandomIndexingProvider, PpmiProvider, LsaProvider, NmfProvider:
pub fn serialize_basis(&self) -> Vec<u8>;
pub fn from_serialized_basis(bytes: &[u8]) -> Result<Self, BasisCodecError>;

// Shared codec:
pub const BASIS_FORMAT_VERSION: u8;        // 1
pub struct BasisWriter { /* write_u32/write_u64/write_f32/write_string/… */ }
pub struct BasisReader<'a> { /* read_u32/…; Err(Truncated) on short blob */ }
pub enum BasisCodecError { Truncated(String), MagicMismatch(String),
                           UnsupportedVersion(String), InvalidUtf8(String) }
```

> **Round-trip law.** For every provider and every text:
> `train → serialize → deserialize → embed(text)` is bit-identical to
> `train → embed(text)`. For LSA and NMF the serialized basis carries the
> raw factors (LSA: U / σ / Vᵀ; NMF: W / H) plus the term-document support
> (vocabulary + document count), so both query embeddings (fold-in) and
> training-document embeddings reproduce exactly on each port. The
> embed-irrelevant training scratch (PPMI co-occurrence counts; raw
> per-document TF rows) is intentionally not serialized.

### `TrainableEmbeddingBasis` seam (both ports)

The `TrainableEmbeddingBasis` protocol/trait is the **type-erasure seam** that
lets a host drive training and basis serialization through a type-erased
provider without a layering inversion. It is **declared in CorpusKit core**
(not VectorKit — training-on-corpus is a Corpus concern, and a future
pre-trained CoreML encoder must be able to NOT conform); the four
distributional providers (`RandomIndexingProvider`, `PpmiProvider`,
`LsaProvider`, `NmfProvider`) **conform in `CorpusKitProviders` /
`corpus-kit-providers`** (layering: providers → core). FDC, the deterministic
provider, and the named CoreML model cases do NOT conform.

It surfaces three operations:
- `trainOnCorpus(texts:)` — the conformer tokenizes each raw text with the
  canonical `defaultKeywordTokens` where its training API consumes term
  sequences (RI, PPMI), or passes raw text where its API consumes documents
  (LSA, NMF), and runs its own heterogeneous train+finalize sequence. It is
  deterministic (no `Date()`/`now`). Driving training through `trainOnCorpus`
  produces the **same trained state** — and therefore the same
  `serializeBasis()` blob byte-for-byte — as the direct 6a-i train/finalize
  API (the seam-honesty conformance gate). Provider construction config (LSA/NMF
  rank, SVD sweeps, iteration count, seeds) is the caller's choice; the seam
  governs only the training sequence.
- `serializeBasis()` / `serialize_basis()` — surfaces the 6a-i basis codec.
- reconstruction — dispatched by `EmbeddingModel.reconstruct(from:)` (Swift) /
  `EmbeddingModelConfig::reconstruct(&self, basis:)` (Rust), which routes the
  blob through the carried provider's conformance to the correct concrete
  type's deserializing initializer. Non-trainable models return
  `CorpusKitError.notTrainable` (Swift) / `CorpusKitError::NotTrainable` (Rust)
  — never a crash/panic. `EmbeddingModel.isTrainable` / `is_trainable()` is the
  capability-detection helper.

**Swift:**

```swift
public protocol TrainableEmbeddingBasis: AnyObject, Sendable {
    func trainOnCorpus(texts: [String])
    func serializeBasis() -> Data
    func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable
}

// On EmbeddingModel:
public var isTrainable: Bool
public func reconstruct(from basis: Data) throws -> any EmbeddingProvider & Sendable
```

**Rust:** `EmbeddingProvider` is a supertrait (the Rust mirror of Swift's
`as? TrainableEmbeddingBasis` runtime probe), so the trainable
`EmbeddingModelConfig` cases carry `Box<dyn TrainableEmbeddingBasis>` and upcast
to `Box<dyn EmbeddingProvider>` for the embed surface.

```rust
pub trait TrainableEmbeddingBasis: EmbeddingProvider {
    fn train_on_corpus(&mut self, texts: &[&str]);
    fn serialize_basis(&self) -> Vec<u8>;
    fn reconstruct_basis(&self, basis: &[u8])
        -> Result<Box<dyn EmbeddingProvider>, CorpusKitError>;
}

// On EmbeddingModelConfig:
pub fn is_trainable(&self) -> bool;
pub fn reconstruct(&self, basis: &[u8]) -> Result<Box<dyn EmbeddingProvider>, CorpusKitError>;
```

### `CorpusEnsemble.defaultEnsemble()` / `default_ensemble()` — the 1.0 default recall ensemble

The single definition of the canonical 1.0 default recall ensemble: the five
honest signals **RI / PPMI / LSA / NMF / FDC**, in that slot order (slot 0 =
RandomIndexing is the default signal). It lives in **`CorpusKitProviders` /
`corpus-kit-providers`** (layering: providers → core) because it NEWs the
concrete provider types; core's `EmbeddingModel` / `EmbeddingModelConfig` never
names a concrete provider.

It is a **function, not a constant**: the four trainable signals carry mutable
per-estate trained state, and the Rust `EmbeddingModelConfig` is not `Clone`, so
the set is constructed fresh per call. Every production provision/open site
threads this factory (GeniusLocusKit `provision` default, the ARIA_MCP estate
constructors, `moot-mgr` / `aria-mcp-server`). The providers are returned
UNTRAINED; the Corpus lifecycle trains and persists the trainable signals on
first ingest/reindex under their own modelIDs.

**Swift:**

```swift
public enum CorpusEnsemble {
    public static func defaultEnsemble() -> [EmbeddingModel]
}
```

**Rust:**

```rust
pub fn default_ensemble() -> Vec<EmbeddingModelConfig>;
```

### `Chunker`, `HybridRecall`, `CorpusKitSync`

Stateless namespaces (Swift `enum` / Rust free functions or unit
struct). Their members are documented in § 3.

> **Consumed surface (note):** measured against the other packages in
> `packages/{kits,libs}` and `apps/` (excluding `.build/` and
> CorpusKit's own tree), no CorpusKit public type is referenced at the
> source level outside its own test target today. The two apparent
> matches — `Tokenizer` in EideticLib, `HybridRecall` in NeuronKit —
> are both false positives: EideticLib defines its own unrelated
> `Tokenizer` enum, and NeuronKit defines its own `HybridRecallEngine`.
> Runtime consumers
> (GeniusLocusKit composition) reach CorpusKit through the estate
> handle, not by importing these types directly. The full surface is
> therefore documented at one tier.

## § 3 — Public functions

### `Chunker.chunk`

Sentence-aware chunking with overlap (SPEC § 5, B-1). Sentence
segmentation is delegated to `EideticLib.sentences` (Swift) /
`eidetic_lib::segmenter::sentences` (Rust), which centralizes the FDC
encoder mandate's segmentation stage. Time enters
via the supplied HLC generator (Swift) / `now_millis` (Rust).

**Swift:**

```swift
public enum Chunker {
    public static func chunk(text: String, sourceID: String,
        configuration: ChunkerConfiguration = ChunkerConfiguration(),
        hlcGenerator: inout HLCGenerator) -> [Chunk]
}
```

**Rust:**

```rust
pub fn chunk(text: &str, source_id: &str, config: ChunkerConfiguration,
             hlc_generator: &mut HLCGenerator, now_millis: i64) -> Vec<Chunk>;
pub fn chunk_with_default_hlc(text: &str, source_id: &str,
             config: ChunkerConfiguration, now_millis: i64) -> Vec<Chunk>;
```

### `HybridRecall.recall`

RRF fusion of vector kNN and BM25 keyword hits, hydrated from the
bundle store (SPEC § 5, B-4; I-4). The kNN pass is filtered to
`modelID`.

**Swift:**

```swift
public enum HybridRecall {
    public static func recall(
        probe: Engram, query: String, modelID: String, limit: Int,
        vectorStore: VectorStore, bm25: BM25Index, bundleStore: BundleStore,
        configuration: HybridRecallConfiguration = HybridRecallConfiguration()
    ) async throws -> [ScoredChunk]
}
```

**Rust:**

```rust
pub fn recall(probe: &Engram, query: &str, model_id: &str, limit: usize,
              vector_store: &VectorStore, bm25: &BM25Index,
              bundle_store: &BundleStore,
              config: HybridRecallConfiguration) -> CorpusKitResult<Vec<ScoredChunk>>;
```

### `CorpusKitSync.manifest`

Builds the per-estate `SyncManifest` declaring the chunks table
bidirectional with the `.appendOnly` conflict policy (SPEC § 4, I-2;
C-7). The `SyncManifest` type is ConvergenceKit's, not CorpusKit's.

**Swift:**

```swift
public enum CorpusKitSync {
    public static func manifest(zoneIdentifier: String) -> SyncManifest
}
```

**Rust:**

```rust
pub struct CorpusKitSync;
impl CorpusKitSync {
    pub fn manifest(zone_identifier: impl Into<String>) -> SyncManifest;
}
```

## § 4 — Errors

The error categories' behavioral meaning lives in SPEC § 6; this is the
shape. Duplicate-key insert rejections are caught internally as the
idempotent no-op and are not surfaced as errors.

**Swift:**

```swift
public enum CorpusKitError: Error, Sendable, Equatable {
    case encodingFailure(String)
    case decodingFailure(String)
    case tokenizerUnavailable(String)
    case modelUnavailable(String)
    case embeddingFailed(String)
    case storeUnavailable(String)
    case notTrainable(String)  // EmbeddingModel.reconstruct on a non-trainable model
}
```

**Rust:**

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CorpusKitError {
    EncodingFailure(String),
    DecodingFailure(String),
    TokenizerUnavailable(String),
    ModelUnavailable(String),
    EmbeddingFailed(String),
    StoreUnavailable(String),
    NotTrainable(String),  // EmbeddingModelConfig::reconstruct on a non-trainable model
}
pub type CorpusKitResult<T> = Result<T, CorpusKitError>;
// implements std::fmt::Display + std::error::Error
```

## § 5 — Self-report telemetry

CorpusKit emits substrate self-report telemetry via IntellectusLib when
monitoring is enabled. Off by default; off-path cost is one
`AtomicBool` load + branch. See SPEC § 7 for the full contract.

### IntellectusLib dependency

Both ports add IntellectusLib as a dependency (non-breaking addition to
`Package.swift` and `Cargo.toml`, authorized by
`DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28`).

**Swift:** `Package.swift` in `packages/kits/CorpusKit/` adds
`.product(name: "IntellectusLib", package: "IntellectusLib")` to both
the `CorpusKit` target and the `CorpusKitTests` target.

**Rust:** `Cargo.toml` in `packages/kits/CorpusKit/rust/` adds
`intellectus-lib = { path = "../../../libs/IntellectusLib/rust" }`.

### Emit sites

**Swift** (`HybridRecall.swift`, `BundleStore.swift`):
```swift
import IntellectusLib
// Inside BundleStore.insert (after batch completes):
Intellectus.report(.metric(name: "corpuskit.ingest.latency_ms",
    value: (endTime - startTime) * 1000.0,
    tags: ["kit": "CorpusKit"], ts: endTime))
Intellectus.report(.metric(name: "corpuskit.ingest.chunk_count",
    value: Double(chunkCount), tags: ["kit": "CorpusKit"], ts: endTime))

// Inside HybridRecall.recall (after result assembled):
Intellectus.report(.metric(name: "corpuskit.recall.latency_ms", ...))
Intellectus.report(.metric(name: "corpuskit.recall.vector_result_count", ...))
Intellectus.report(.metric(name: "corpuskit.recall.keyword_result_count", ...))
Intellectus.report(.metric(name: "corpuskit.recall.result_count", ...))
```

**Rust** (`bundle_store.rs`, `hybrid_recall.rs`):
```rust
use intellectus_lib::{report, StatSample};
// Inside BundleStore::insert (after loop completes):
report!(StatSample::metric("corpuskit.ingest.latency_ms".to_string(),
    (end_ts - start_ts) * 1000.0,
    [("kit".to_string(), "CorpusKit".to_string())].into_iter().collect(),
    end_ts));
// ... and chunk_count, recall.latency_ms, recall.vector_result_count,
//     recall.keyword_result_count, recall.result_count
```

## § 6 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/CorpusKit
```

(Target: `CorpusKitTests` — covers core + providers; the test target
depends on `PersistenceKitInMemory` for the bundle-store path.
`EmbeddingProviderConformanceTests.swift` loads the shared fixture at
`Tests/SharedVectors/embedding_provider_vectors.json` and verifies
bit-identical tokenizer output, Engram projections, and float-lane
vectors for all three named providers.)

**Rust:**

```
cargo test -p corpus-kit
cargo test -p corpus-kit-providers
```

(The `corpus-kit` integration tests pull `corpus-kit-providers` as a
dev-dependency for the `DeterministicTokenizer` fixture.
`rust-providers/tests/embedding_conformance_tests.rs` loads the same
shared fixture and asserts bit-for-bit parity with the Swift-generated
canonical vectors, covering SPEC C-8b.)

## § 7 — Corpus actor (public entry point)

### `EmbeddingModel` (Swift) / `EmbeddingModelConfig` (Rust)

A CorpusKit-owned type for selecting the embedding model. No VectorKit
type is required at the call site.

**Two-vector architecture:** `.deterministic` is the permanent,
federation-grade vector lane present in every version (v1.0+). It uses
FNV-1a tokenization + FloatSimHash projection, requires no CoreML or model
bundle, and produces byte-identical vectors cross-device and cross-port —
the reproducibility federation requires. It captures surface/lexical
signal, not learned semantic meaning. This is NOT a placeholder; it is
the vector representation that federation synchronizes.

The named model cases (`.miniLM`, `.mpNet`, `.embeddingGemma`) are the
ADDITIVE v1.1 on-device learned semantic lane. They provide richer,
model-dependent similarity for enhanced on-device search but cannot serve
as the federation vector (model-dependent → not reproducible cross-device).
Both lanes coexist; the learned lane does not replace the deterministic lane.

**Swift:**

```swift
public enum EmbeddingModel: Sendable {
    case deterministic
    case miniLM(inference: @Sendable ([Int32]) async throws -> [Float])
    case mpNet(inference: @Sendable ([Int32]) async throws -> [Float])
    case embeddingGemma(inference: @Sendable ([Int32]) async throws -> [Float])
    public static let `default`: EmbeddingModel = .deterministic
}
```

**Rust:**

```rust
/// Selects the embedding model the `Corpus` struct uses internally.
/// Named cases each carry a host-supplied inference closure (`NamedInferenceFn`).
/// The kit owns FNV-1a tokenization and FloatSimHash projection; the host
/// owns the model pass on every platform (CoreML on Apple, host-chosen
/// runtime on Windows/Linux). No model weights are bundled.
pub type NamedInferenceFn = Box<dyn Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static>;

#[derive(Default)]
pub enum EmbeddingModelConfig {
    #[default]
    Deterministic,
    /// MiniLM v6 (384-dim). FNV-1a tokenization, vocab 30522, max 128 tokens,
    /// projection seed 0x4D49_4E4C_4D5F_7631 ("MINLM_v1").
    MiniLM { inference: NamedInferenceFn },
    /// MPNet base v2 (768-dim). FNV-1a tokenization, vocab 30522, max 128 tokens,
    /// projection seed 0x4D50_4E45_545F_7631 ("MPNET_v1").
    MPNet { inference: NamedInferenceFn },
    /// Embedding-Gemma 300M (768-dim). FNV-1a tokenization, vocab 256000, max 2048 tokens,
    /// projection seed 0x454D_4247_4D5F_7631 ("EMBGM_v1").
    EmbeddingGemma { inference: NamedInferenceFn },
}
```

### `Corpus`

The public RAG entry point. No VectorKit type appears in any public
signature (SPEC § 8, B-8).

**Swift:**

```swift
public actor Corpus {
    /// Construct a Corpus. Opens BundleStore + VectorStore + BasisStore schemas
    /// on the supplied storage via migrate(to:). The caller owns the Storage
    /// lifecycle. LOAD-ON-OPEN: when the model is a trainable distributional
    /// provider (RI/PPMI/LSA/NMF) AND a basis was previously persisted for its
    /// (modelID, modelVersion), the trained provider is reconstructed from that
    /// basis blob so the dense lane is trained-ready immediately after restart.
    public init(storage: any Storage, model: EmbeddingModel = .default) async throws

    /// N-PROVIDER construction (mission 6a-iii-core). Builds one ordered provider
    /// slot per model, each keyed by its modelID; models[0] is the DEFAULT signal
    /// the single-signal entry points delegate to. Every fan-out operation
    /// (ingest embed, reindex train, remove, destroy) runs across all slots, each
    /// under its own modelID — the VectorStore/BasisStore (keyed by (modelID,
    /// modelVersion)) hold the N providers' rows side by side with NO schema
    /// change. `init(storage:model:)` is the N=1 special case: it delegates here
    /// with a one-element set, so a single-provider corpus is byte-identical to
    /// the pre-6a-iii behaviour. The production default remains a single provider;
    /// passing all five models is a CAPABILITY the 6b RRF consumer activates.
    /// Precondition: `models` is non-empty. Rust mirror: `Corpus::open_many`.
    public init(storage: any Storage, models: [EmbeddingModel]) async throws

    /// Chunk, store, index, embed, and vector-store a document.
    /// Idempotent on content-addressed chunk ids (SPEC B-9, I-3).
    /// FIRST-INGEST AUTO-TRAIN: when the model is trainable and no basis has been
    /// persisted yet, the first ingest trains a fresh basis on the current corpus
    /// snapshot and persists it; subsequent ingests fold new chunks onto the
    /// frozen basis (no retrain — LSA/NMF cannot incrementally refactor).
    public func ingest(_ text: String, sourceID: String, now: Date) async throws

    /// Embed the query and return fused kNN + BM25 results (SPEC B-10).
    /// Runs on the DEFAULT signal (models[0]).
    public func recall(_ query: String, limit: Int = 10, now: Date) async throws -> [ScoredChunk]

    /// Dense float nearest-neighbour recall (Lane D) on the DEFAULT signal.
    /// Returns an always-observable FloatLaneOutcome (dark lanes carry a typed
    /// reason; store errors are logged + counted, never swallowed; never throws).
    public func floatNearest(query: String, limit: Int) async -> FloatLaneOutcome

    /// PER-SIGNAL dense float nearest (mission 6a-iii-core; the 6b RRF seam).
    /// Runs the dense float lane independently for EVERY held provider slot, each
    /// queried against its own modelID float index, and returns one ranked
    /// FloatLaneOutcome per signal tagged by its modelID, in slot order ([0] is
    /// the default signal). Preserves the per-signal dark-lane observability. NO
    /// fusion happens here — the 6b consumer decides how to combine the lists.
    /// For N=1 returns a single-element array equal to floatNearest's outcome.
    /// Empty query / zero limit returns one .emptyQuery per signal (no store
    /// access). Rust mirror: `Corpus::float_nearest_per_signal`.
    public func floatNearestPerSignal(query: String, limit: Int) async
        -> [(modelID: String, outcome: FloatLaneOutcome)]

    /// Retrain the embedding basis on the full corpus and re-embed every chunk
    /// (mission 6a-ii-β). For a trainable provider: gathers all chunk texts,
    /// trains a FRESH basis from scratch through the TrainableEmbeddingBasis seam,
    /// UPSERTs it into corpus_provider_basis (one row per (modelID, modelVersion)),
    /// and re-embeds every chunk (binary v0 + float v1) replacing stale vectors.
    /// For a non-trainable provider — or a reopened-from-basis corpus — it is a
    /// vector refresh with no basis row written. Deterministic (pass `now`).
    public func reindex(now: Date) async throws

    /// Remove a source from BM25 + VectorStore. BundleStore is
    /// append-only; count() does not decrease (SPEC B-11).
    public func remove(sourceID: String) async throws

    /// Total chunks in BundleStore (does not decrease after remove).
    public func count() async throws -> Int

    // Estate lifecycle primitive:
    /// Destroy the entire recall index. Clears BM25, chunk_source_map, all
    /// vectors, AND all persisted basis rows (no orphans). BundleStore rows
    /// (chunks) are NOT deleted (append-only invariant). Called by
    /// GeniusLocusKit.destroy(storage:corpusStorage:handle:).
    public func destroyRecallIndex() async throws
}

/// Persistence for a trained provider's serialized basis blob (mission 6a-ii-β).
/// One row per (modelID, modelVersion). Lives in CorpusKit core; never imports
/// CorpusKitProviders (the blob bytes are opaque here).
public actor BasisStore {
    /// Additive schema: corpus_provider_basis(model_id TEXT, model_version TEXT,
    /// basis BLOB, trained_at TIMESTAMP/ISO8601, trained_chunk_count INTEGER),
    /// PK (model_id, model_version). NO Bool columns; dates TEXT ISO8601.
    public static let schemaDeclaration: SchemaDeclaration
    public init(storage: any Storage)
    /// UPSERT the basis row (retrain replaces in place — one row per key).
    public func upsert(_ row: PersistedBasis) async throws
    /// Load the persisted basis for a provider key, or nil.
    public func load(modelID: String, modelVersion: String) async throws -> PersistedBasis?
    /// Delete every basis row (used by Corpus.destroyRecallIndex()).
    public func deleteAll() async throws
}
```

**Rust:**

```rust
pub struct Corpus { /* bundle_store, bm25: Mutex<BM25Index>, vector_store,
                       basis_store, model_id, provider: Mutex<ProviderHandle>,
                       fresh_basis_blob: Option<Vec<u8>> */ }
impl Corpus {
    /// Construct via migrate() to apply all schemas (BundleStore + VectorStore +
    /// BasisStore) regardless of version gating. LOAD-ON-OPEN: when the model is
    /// trainable AND a basis was persisted for its (model_id, model_version), the
    /// trained provider is reconstructed from that blob (trained-ready on open).
    pub fn open(storage: Arc<dyn Storage>, model: EmbeddingModelConfig) -> CorpusKitResult<Self>;

    /// now_millis: Unix epoch in milliseconds (caller-supplied for determinism).
    /// FIRST-INGEST AUTO-TRAIN: a trainable provider with no persisted basis
    /// trains a fresh basis on the first ingest; later ingests fold in (no retrain).
    pub fn ingest(&self, text: &str, source_id: &str, now_millis: i64) -> CorpusKitResult<()>;
    pub fn recall(&self, query: &str, limit: usize, now_millis: i64) -> CorpusKitResult<Vec<ScoredChunk>>;

    /// Retrain the embedding basis on the full corpus and re-embed every chunk
    /// (mission 6a-ii-β). Trainable provider: trains a FRESH basis (reconstructed
    /// from the empty-basis blob — train_on_corpus is additive), UPSERTs it into
    /// corpus_provider_basis, re-embeds every chunk replacing stale vectors.
    /// Non-trainable / reopened-from-basis: vector refresh, no basis row.
    /// now_millis is the only clock source (deterministic).
    pub fn reindex(&self, now_millis: i64) -> CorpusKitResult<()>;

    pub fn remove(&self, source_id: &str) -> CorpusKitResult<()>;
    pub fn count(&self) -> CorpusKitResult<usize>;

    // Estate lifecycle primitive:
    /// Clear BM25 + chunk_source_map + all vectors + all basis rows (no orphans).
    /// BundleStore rows preserved (append-only).
    pub fn destroy_recall_index(&self) -> CorpusKitResult<()>;
}

/// Persistence for a trained provider's serialized basis blob (mission 6a-ii-β).
/// One row per (model_id, model_version). Core crate; never depends on
/// corpus-kit-providers (the blob bytes are opaque here).
pub struct BasisStore { /* storage: Arc<dyn Storage> */ }
pub struct PersistedBasis {
    pub model_id: String, pub model_version: String, pub basis: Vec<u8>,
    pub trained_at_secs: i64, pub trained_chunk_count: usize,
}
impl BasisStore {
    /// corpus_provider_basis(model_id TEXT, model_version TEXT, basis BLOB,
    /// trained_at TIMESTAMP/ISO8601, trained_chunk_count INTEGER),
    /// PK (model_id, model_version). No Bool columns; dates TEXT ISO8601.
    pub fn schema_declaration() -> SchemaDeclaration;
    pub fn new(storage: Arc<dyn Storage>) -> Self;
    pub fn upsert(&self, row: &PersistedBasis) -> CorpusKitResult<()>;
    pub fn load(&self, model_id: &str, model_version: &str) -> CorpusKitResult<Option<PersistedBasis>>;
    pub fn delete_all(&self) -> CorpusKitResult<()>;
}
```

The Rust `TrainableEmbeddingBasis` trait gains an additive
`reconstruct_trainable_basis(&self, basis) -> Result<Box<dyn TrainableEmbeddingBasis>>`
sibling of `reconstruct_basis` (the trainable-returning reconstruct the Corpus
needs to rebuild a fresh provider for `reindex`/first-ingest, since Rust has no
runtime trait-object downcast and `train_on_corpus` is additive). Swift gets this
for free via its runtime `as? TrainableEmbeddingBasis` cast on the reconstructed
provider, so no Swift protocol change is required.

---

## § 8 — Examples

```swift
import CorpusKit
import CorpusKitProviders

// 1. Chunk a document.
var hlc = HLCGenerator(nodeID: 1)
let chunks = Chunker.chunk(text: document, sourceID: "doc-42", hlcGenerator: &hlc)

// 2. Persist (idempotent) and index for keyword recall.
let bundle = BundleStore(storage: storage)
try await bundle.insert(chunks)
let bm25 = BM25Index(tokenizer: DeterministicTokenizer())
await bm25.index(chunks)

// 3. Embed the query with a model-tagged provider, then recall.
let provider = MiniLMTextProvider(inference: runMiniLM)
let probe = try await provider.embed("how does overlap work?")
let hits = try await HybridRecall.recall(
    probe: probe, query: "how does overlap work?",
    modelID: provider.modelID, limit: 10,
    vectorStore: vectorStore, bm25: bm25, bundleStore: bundle)
```

---

## § 9 — Swift/Rust Concordance

One row per public concept. Each Swift symbol and Rust symbol is a real
top-level public declaration found in source (file:line cited). The
shape rule states how (if at all) the two ports are allowed to differ.
The test/vector binding names the conformance/parity test that proves
Swift == Rust for that concept.

Status legend: **Confirmed** = both present and test-bound;
**Exempt** = Apple-platform binding, no Rust counterpart by design.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Chunk | `Chunk` (`Chunk.swift:34`) | `Chunk` (`chunk.rs:37`) | public struct / pub struct | identical fields; idiom: Swift `UUID`/`Int`/`[String:String]` ↔ Rust `Uuid`/`usize`/`BTreeMap`; content-addressed v5 id | `ChunkTests.swift` / `chunk_tests.rs` | Confirmed |
| ScoredChunk | `ScoredChunk` (`Chunk.swift:147`) | `ScoredChunk` (`chunk.rs:136`) | public struct / pub struct | identical; Swift `Float`/`Float?` ↔ Rust `f32`/`Option<f32>` | `ChunkTests.swift` / `chunk_tests.rs` | Confirmed |
| ChunkerConfiguration | `ChunkerConfiguration` (`Chunker.swift:29`) | `ChunkerConfiguration` (`chunker.rs:27`) | public struct / pub struct | identical; defaults 800/100/true (Swift default-arg init / Rust `Default`) | `ChunkerTests.swift` / `chunker_tests.rs` | Confirmed |
| Chunker (namespace) | `Chunker` (`Chunker.swift:45`) | `chunk` / `chunk_with_default_hlc` free fns (`chunker.rs`) | public enum (caseless) / pub fn | Swift caseless-enum namespace `Chunker.chunk` / Rust module-level free functions — sanctioned stateless-namespace idiom; Rust adds explicit `now_millis` for determinism | `ChunkerTests.swift` / `chunker_tests.rs` | Confirmed |
| BM25Parameters | `BM25Parameters` (`BM25Index.swift:16`) | `BM25Parameters` (`bm25_index.rs:13`) | public struct / pub struct | identical; defaults k1=1.5, b=0.75; Swift `Double` ↔ Rust `f64` | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| BM25Index | `BM25Index` (`BM25Index.swift:25`) | `BM25Index` (`bm25_index.rs:38`) | public actor / pub struct | Swift `actor` (async isolation) / Rust owned state with `&mut self` mutators, `&self` reads — sanctioned actor↔owned-state seam; verbs `index`↔`index_documents`, `search`/`remove`/`documentCount`↔`document_count` | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| BundleStore | `BundleStore` (`BundleStore.swift:53`) | `BundleStore` (`bundle_store.rs:29`) | public actor / pub struct | Swift `actor` over `Storage` / Rust `Arc<dyn Storage>`; Swift `async throws` ↔ Rust sync `CorpusKitResult`; Rust adds `open()` (schema apply). Append-only, idempotent | `BundleStoreTests.swift` / `bundle_store_tests.rs` | Confirmed |
| HybridRecallConfiguration | `HybridRecallConfiguration` (`HybridRecall.swift:17`) | `HybridRecallConfiguration` (`hybrid_recall.rs:14`) | public struct / pub struct | identical; defaults 0.6/0.4/60/off; Swift `Double`/`Double?` ↔ Rust `f64`/`Option<f64>` | `HybridRecallTests.swift` / `hybrid_recall_tests.rs` | Confirmed |
| HybridRecall (namespace) | `HybridRecall` (`HybridRecall.swift:36`) | `recall` free fn (`hybrid_recall.rs`) | public enum (caseless) / pub fn | Swift caseless-enum namespace `HybridRecall.recall` / Rust free function — sanctioned stateless-namespace idiom; Swift `async throws` ↔ Rust sync `CorpusKitResult` (no async runtime) | `HybridRecallTests.swift` / `hybrid_recall_tests.rs` | Confirmed |
| Tokenizer | `Tokenizer` (`Tokenizer.swift:10`) | `Tokenizer` (`tokenizer.rs:8`) | public protocol / pub trait | identical surface; Swift protocol-extension default `keywordTokens` ↔ Rust trait default delegating to `default_keyword_tokens`; idiom `vocabID`↔`vocab_id`, `Int32`↔`i32` | `TokenizerTests.swift` / `tokenizer_tests.rs` | Confirmed |
| CorpusKitSync | `CorpusKitSync` (`SyncManifest.swift:11`) | `CorpusKitSync` (`sync_manifest.rs:9`) | public enum (caseless) / pub struct | Swift caseless-enum namespace / Rust unit struct — sanctioned stateless-namespace idiom; both expose `manifest(...)→SyncManifest` (ConvergenceKit's type) | `SyncManifestTests.swift` / `hybrid_recall_tests.rs` (manifest exercised) | Confirmed |
| CorpusKitError | `CorpusKitError` (`CorpusKitError.swift:5`) | `CorpusKitError` (`error.rs:4`) | public enum / pub enum | identical six cases; Rust adds `Display`+`Error` impls; case idiom `encodingFailure`↔`EncodingFailure` | `CorpusKitErrorTests.swift` / `chunk_tests.rs` + `error.rs` Display impl | Confirmed |
| CorpusKitResult | (Swift uses `async throws`) | `CorpusKitResult` (`error.rs:28`) | — / pub type alias | Rust `Result<T, CorpusKitError>` alias ↔ Swift typed `throws` — sanctioned error-channel idiom (Swift has no Result-alias surface) | `chunk_tests.rs` / `corpus_tests.rs` (result threaded through) | Confirmed |
| EmbeddingModel selector | `EmbeddingModel` (`CorpusKit.swift:40`) | `EmbeddingModelConfig` (`corpus.rs:56`) | public enum / pub enum | Swift four cases (`deterministic`/`miniLM`/`mpNet`/`embeddingGemma` with async closure); Rust four cases (`Deterministic`/`MiniLM`/`MPNet`/`EmbeddingGemma` with sync `NamedInferenceFn`); async↔sync seam is sanctioned (Rust has no async runtime). Projection seeds byte-identical across ports. | `CorpusTests.swift` / `corpus_tests.rs` + `embedding_conformance_tests.rs` | Confirmed |
| Corpus | `Corpus` (`CorpusKit.swift:99`) | `Corpus` (`corpus.rs:113`) | public actor / pub struct | Swift `actor` (`init async throws`) / Rust `struct` (`open()`, `bm25: Mutex<BM25Index>`); Swift `async throws`+`Date` ↔ Rust sync `CorpusKitResult`+`now_millis` — sanctioned actor↔owned-state + async↔sync seam | `CorpusTests.swift` / `corpus_tests.rs` | Confirmed |
| DeterministicTokenizer | `DeterministicTokenizer` (`DeterministicTokenizer.swift:16`) | `DeterministicTokenizer` (`rust-providers/.../deterministic_tokenizer.rs:34`) | public struct / pub struct | identical FNV-1a fold; Swift default-arg init ↔ Rust `new`/`with_parameters`/`Default`; lives in providers target both ports | `ProvidersTests.swift` / `deterministic_tokenizer_tests.rs` | Confirmed |
| MiniLMTextProvider | `MiniLMTextProvider` (`MiniLMTextProvider.swift:41`) | `MiniLMTextProvider` (`rust-providers/src/text_providers.rs`) | public struct / pub struct | Both ports: model_id "minilm-v6", projectionSeed 0x4D49_4E4C_4D5F_7631, FNV-1a tokenizer (vocab 30522, max 128), host inference closure (Swift `@Sendable ([Int32]) async throws -> [Float]` ↔ Rust sync `InferenceFn`); async↔sync seam is sanctioned. Conforms to VectorKit `EmbeddingProvider`. Bit-identical engram for shared (text → pooled vector) (SPEC C-8b) | `EmbeddingProviderConformanceTests.swift` + `embedding_provider_vectors.json` / `embedding_conformance_tests.rs` | Confirmed |
| MPNetTextProvider | `MPNetTextProvider` (`MPNetTextProvider.swift:31`) | `MPNetTextProvider` (`rust-providers/src/text_providers.rs`) | public struct / pub struct | Both ports: model_id "mpnet-base-v2", projectionSeed 0x4D50_4E45_545F_7631, FNV-1a tokenizer (vocab 30522, max 128), host inference closure (same async↔sync seam). Conforms to VectorKit `EmbeddingProvider`. Bit-identical engram for shared pooled vector (SPEC C-8b) | `EmbeddingProviderConformanceTests.swift` + `embedding_provider_vectors.json` / `embedding_conformance_tests.rs` | Confirmed |
| EmbeddingGemmaProvider | `EmbeddingGemmaProvider` (`EmbeddingGemmaProvider.swift:33`) | `EmbeddingGemmaProvider` (`rust-providers/src/text_providers.rs`) | public struct / pub struct | Both ports: model_id "embedding-gemma-300m", projectionSeed 0x454D_4247_4D5F_7631, FNV-1a tokenizer (vocab 256000, max 2048), host inference closure (same async↔sync seam). Conforms to VectorKit `EmbeddingProvider`. Bit-identical engram for shared pooled vector (SPEC C-8b) | `EmbeddingProviderConformanceTests.swift` + `embedding_provider_vectors.json` / `embedding_conformance_tests.rs` | Confirmed |
| Telemetry — ingest | `Intellectus.report` ×2 in `BundleStore.insert` emitting `corpuskit.ingest.latency_ms` + `corpuskit.ingest.chunk_count` | `report!` ×2 in `BundleStore::insert` | internal emit / internal emit | identical metric names, tags (`kit=CorpusKit`), value semantics; SPEC § 7.2 | `CorpusKitTelemetryTests.swift` §1-§4 / `corpuskit_telemetry_tests.rs` §1-§4 | Confirmed |
| Telemetry — recall | `Intellectus.report` ×4 in `HybridRecall.recall` emitting `corpuskit.recall.*` | `report!` ×4 in `hybrid_recall::recall` | internal emit / internal emit | identical metric names, tags (`kit=CorpusKit`, `model_id`), value semantics; SPEC § 7.2 | `CorpusKitTelemetryTests.swift` §1-§4 / `corpuskit_telemetry_tests.rs` §1-§4 | Confirmed |
| Sparse-lane outcome | `FloatLaneOutcome` (`CorpusKit.swift:45`) | `FloatLaneOutcome` (`corpus.rs:67`) | both public/pub | identical 3-case enum: `hit(ScoredChunk)`/`Hit(ScoredChunk)`, `dark(String)`/`Dark(String)`, `unavailable`/`Unavailable` — float nearest-neighbour lane result; Swift lowerCamel / Rust UpperCamel cases — idiom. `dark` is an EXPECTED degradation (indexed with no corpus, expected miss — not an error). | `CorpusTests.swift` / `corpus_tests.rs` | Confirmed |
| BM25 weighting (Lane D) | `BM25Weighting` (`BM25Weighting.swift:71`) | `BM25Weighting` (`engine/bm25_weighting.rs:69`) | both public/pub | Swift caseless-enum namespace (static methods `weight`, `quantizeImpact`) / Rust unit struct with associated methods — sanctioned stateless-namespace idiom; weight computation and impact quantization are byte-identical | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| Impact posting | `ImpactPosting` (`Engine/SparseTypes.swift:57`) | `ImpactPosting` (`engine/sparse_types.rs:32`) | both public/pub | identical 2-field struct: `termID: UInt32`/`term_id: u32`, `impact: Int32`/`impact: i32` — one (termID, impact) entry in the sorted impact list | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| Sparse search result | `SparseHit` (`Engine/SparseTypes.swift:95`) | `SparseHit` (`engine/sparse_types.rs:53`) | both public/pub | identical 2-field struct: `id: String`, `score: Float`/`f32` — one ranked BM25 result | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| Fused (sparse+dense) hit | `FusedHit` (`Engine/SparseTypes.swift:137`) | `FusedHit` (`engine/sparse_types.rs:76`) | both public/pub | identical 3-field struct: `id: String`, `score: Float`/`f32`, `perLane: [LaneTag: Float]`/`per_lane: HashMap<LaneTag, f32>` — merged result from RRF lane fusion; `perLane`/`per_lane` carries per-lane score contributions | `HybridRecallTests.swift` / `hybrid_recall_tests.rs` | Confirmed |
| Inverted index | `InvertedIndex` (`Engine/InvertedIndex.swift:116`) | `InvertedIndex` (`engine/inverted_index.rs:98`) | both public/pub | identical postings store: Swift `struct` / Rust `struct`; both implement `topK(query:k:)` / `top_k(query, k, algorithm)` against a sorted impact list; Rust adds `Algorithm` enum (WAND / BlockMaxWand) as a query-time parameter (Swift uses WAND implicitly) | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| Inverted index store | `InvertedIndexStore` (`Engine/InvertedIndexStore.swift:47`) | `InvertedIndexStore` (`engine/inverted_index_store.rs:29`) | both public/pub | Swift `actor` (async isolation) / Rust `struct` (owned-state, sync) — sanctioned actor↔owned-state seam; both wrap an `InvertedIndex` with a `BundleStore`-backed build path | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| Lane tag (alias) | `LaneTag` (`Engine/SparseTypes.swift:40`, `public typealias LaneTag = VectorKit.LaneTag`) | re-exported `vectorkit::engine::hit::LaneTag` (`engine/mod.rs`) | both public/pub | CorpusKit re-exports the canonical `VectorKit.LaneTag` in both ports; the type is owned by VectorKit (see VectorKit concordance). In Swift this is an explicit typealias; in Rust it is a re-export at `use vectorkit::engine::hit::LaneTag`. The canonical concordance row lives in VectorKit's concordance table. | (governed by VectorKit parity) | Confirmed (re-export alias; canonical row in VectorKit) |
| Fusion (Lane E) | `Fusion` (`Engine/Fusion.swift:48`) | — (`engine/fusion.rs`: free fns `fuse`, `fuse_scored`) | Swift public caseless-enum namespace / Rust pub free functions | Swift groups lane-fusion under a caseless-enum namespace `Fusion.fuse(sparse:dense:limit:)` / `Fusion.fuseScored(sparse:dense:limit:)`; Rust exposes the identical operations as module-level free functions `fuse(...)` / `fuse_scored(...)` — sanctioned stateless-namespace idiom. Fusion logic (RRF rank combination) is byte-identical. | `HybridRecallTests.swift` / `hybrid_recall_tests.rs` | **Confirmed (Swift namespace / Rust free-fn idiom)** |
| WAND query algorithms (Rust) | — | `Algorithm` (`engine/inverted_index.rs:85`) | Rust-only pub enum | Two query strategies: `Wand` and `BlockMaxWand`. Parametrises `InvertedIndex::top_k` at query time. Swift `InvertedIndex.topK` always uses WAND internally — the enum exposes what the Rust port makes explicit at the call site. This is a Rust-side API ergonomic extension; the WAND algorithm itself is byte-identical both ports. | `bm25_tests.rs` (WAND and BlockMaxWand paths exercised) | **Confirmed (Rust-only parameter enum; WAND logic parity holds)** |
| Term-frequency table (Rust) | — | `TermFreqTable` (`engine/bm25_weighting.rs:64`, `type TermFreqTable = HashMap<String, HashMap<String, usize>>`) | Rust-only pub type alias | Build-time type alias for the BM25 term-frequency accumulator. Swift builds the equivalent structure inline within `BM25Index.index(documents:)`; Rust names it for readability. The underlying `HashMap<String, HashMap<String, usize>>` semantics are identical. | `bm25_tests.rs` | **Confirmed (Rust-only named alias; concept present both ports)** |

**Notes on the three named text providers (Confirmed parity).**
`MiniLMTextProvider`, `MPNetTextProvider`, and `EmbeddingGemmaProvider`
ship in both ports. The inference seam is
host-supplied on every platform: Swift callers wrap a CoreML model; Rust
callers wrap whatever runtime the host chooses (the kit bundles no model
weights and links no ML-runtime crate). The seam payload is identical on
both ports — token IDs in, pooled float vector out — so for any shared
(text → pooled vector) pair the projected Engram is bit-identical
(SPEC C-8b). Conformance is verified by
`EmbeddingProviderConformanceTests.swift` against the shared fixture at
`Tests/SharedVectors/embedding_provider_vectors.json` and by
`rust-providers/tests/embedding_conformance_tests.rs`.

---

*End of CorpusKit Interface.*

## Changelog

### 1.5.0 -- 2026-06-17
Added (6a-iii-wire) the public default-ensemble factory — the single definition
of the 1.0 default recall ensemble (RI/PPMI/LSA/NMF/FDC). Swift
`CorpusEnsemble.defaultEnsemble() -> [EmbeddingModel]` in `CorpusKitProviders`;
Rust `corpus_kit_providers::default_ensemble() -> Vec<EmbeddingModelConfig>`.
Constructed fresh per call (per-estate trained state; Rust config not `Clone`).
Threaded by every production provision/open site so the five honest signals are
the live recall default. ADDITIVE — no existing CorpusKit signature changed.

### 1.4.0 -- 2026-06-17
Added the Corpus N-provider capability + per-signal nearest API (mission
6a-iii-core), ADDITIVE and back-compatible. New public `Corpus.init(storage:
models:)` (Swift) / `Corpus::open_many` (Rust) builds an ordered collection of
provider slots, one per held model keyed by modelID; the existing
`init(storage:model:)` / `Corpus::open` are PRESERVED and delegate to the N path
with a one-element set (N=1 is byte-identical to the prior single-provider
behaviour). Every fan-out operation (ingest embed, reindex train, remove,
destroy) runs across all held slots, each under its own modelID; the
VectorStore/BasisStore — already keyed by (modelID, modelVersion) — hold the N
providers' rows side by side with NO schema change. New public
`Corpus.floatNearestPerSignal(query:limit:)` (Swift) /
`Corpus::float_nearest_per_signal` (Rust) returns one ranked `FloatLaneOutcome`
per held signal tagged by its modelID (the 6b RRF-fusion seam; NO fusion here).
The single-signal entry points (`recall`, `floatNearest`, `embed`, `embedFloat`,
`modelID`, `supportsFloat`) delegate to the default signal (models[0]) — every
existing call site compiles unchanged. The production default remains SINGLE
provider; flipping to all-five is a later mission (6a-iii-wire, sequenced with
6b). Cross-port conformance: an all-five corpus over a fixed corpus yields
per-signal ranked lists with IDENTICAL rank order Swift↔Rust (the float lane is
reproducible-within-config, not four-way bit-identical — raw cosine bits are not
asserted), pinned by `Tests/SharedVectors/n_provider_per_signal.json`
(`NProviderTests.swift` canonical; `rust/tests/corpus_n_provider_tests.rs`
asserts). The 6a-ii-β single-provider fixture passes unchanged (N=1 proof).
VectorKit's float lane (Lane D) was made per-modelID so an N-provider corpus's
float rows of differing dimension are queried in isolation (no shared-stride
corruption) — see VECTORKIT changelog.

### 1.3.0 -- 2026-06-17
Added the basis-persistence table + Corpus training lifecycle (mission 6a-ii-β,
single provider). New `BasisStore` actor (Swift) / `BasisStore` struct (Rust) in
CorpusKit core persisting a trained distributional provider's serialized basis
blob in the additive `corpus_provider_basis` table — columns model_id TEXT,
model_version TEXT, basis BLOB, trained_at TIMESTAMP (TEXT ISO8601, never REAL),
trained_chunk_count INTEGER, PK (model_id, model_version); no Bool columns. New
public `Corpus.reindex(now:)` / `Corpus::reindex(now_millis:)` retrains a FRESH
basis on the full corpus and re-embeds every chunk. `Corpus.init`/`open` now
LOAD-ON-OPEN (reconstructs a trained provider from a persisted basis so the dense
lane is trained-ready after restart); `ingest` FIRST-INGEST auto-trains a fresh
basis when a trainable provider has no basis yet (later ingests fold in, no
retrain); `destroyRecallIndex`/`destroy_recall_index` now also wipe basis rows
(no orphans). The Rust `TrainableEmbeddingBasis` trait gains an additive
`reconstruct_trainable_basis` (trainable-returning reconstruct the Corpus needs
to rebuild a fresh provider — train_on_corpus is additive; Swift gets this via
its runtime `as?` cast). Cross-port conformance: ingest → reindex → reopen →
embed reproduces the α canonical RI basis blob byte-for-byte and the canonical
embedding bit patterns on both ports. Additive; no existing API changed.

### 1.2.0 -- 2026-06-16
Added the `TrainableEmbeddingBasis` seam (mission 6a-ii-α): a new
protocol/trait declared in CorpusKit core that surfaces `trainOnCorpus(texts:)`,
`serializeBasis()`, and a reconstruct path for type-erased providers. The four
distributional providers (`RandomIndexingProvider`, `PpmiProvider`,
`LsaProvider`, `NmfProvider`) conform in `CorpusKitProviders` /
`corpus-kit-providers`; FDC and the deterministic/named-model cases do not.
Added `EmbeddingModel.reconstruct(from:)` + `isTrainable` (Swift) and
`EmbeddingModelConfig::reconstruct` + `is_trainable()` (Rust), and the
`CorpusKitError.notTrainable` / `CorpusKitError::NotTrainable` case for the
non-trainable models. The Rust `TrainableEmbeddingBasis` has `EmbeddingProvider`
as a supertrait, so the trainable `EmbeddingModelConfig` cases now carry
`Box<dyn TrainableEmbeddingBasis>` (upcasting to `Box<dyn EmbeddingProvider>`).
`trainOnCorpus → serializeBasis` reproduces the 6a-i canonical basis blobs
byte-for-byte on both ports — the seam-honesty conformance gate. No persistence,
no Corpus lifecycle change, no runtime behaviour change; additive.

### 1.1.0 -- 2026-06-16
Added the distributional-provider basis serialization API (mission 6a-i):
`serializeBasis()` / `init(deserializing:)` (Swift) and `serialize_basis()` /
`from_serialized_basis()` (Rust) on `RandomIndexingProvider`, `PpmiProvider`,
`LsaProvider`, and `NmfProvider`, plus the shared little-endian `BasisCodec`
(Swift) / `basis_codec` (Rust) and the `BasisCodecError` Rust enum. Documented
the versioned byte format (magic + format version + little-endian payload), the
round-trip law, and the cross-port byte-identity contract. Purely additive; no
existing API changed.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
