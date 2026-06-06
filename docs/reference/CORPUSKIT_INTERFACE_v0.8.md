---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: CorpusKit
languages: [swift, rust]
relates_to:
  - CORPUSKIT_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of CorpusKit in both ports: the Chunk content
  model and its content-addressed identity, the Chunker, the BM25Index
  actor, the BundleStore actor, HybridRecall, the Tokenizer protocol, the three CorpusKitProviders providers, the
  DeterministicTokenizer stand-in, and the CorpusKitSync manifest. The
  companion SPEC carries the behavioral contracts (invariants I-1…I-8,
  conformance C-1…C-7).
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
- providers `src/`: `deterministic_tokenizer.rs`, `lib.rs`
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
conform to **VectorKit's `EmbeddingProvider`** directly (F11,
2026-05-27); each `embed` enforces the empty-input contract
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

**Rust:** the `corpus-kit-providers` crate ships `DeterministicTokenizer`
today (the test-fixture mirror of the Swift type); ONNX/Candle-backed
providers land in a follow-on mission once model bundles are wired in
(SPEC § 9).

```rust
pub struct DeterministicTokenizer { /* vocab_id, vocab_size, max_tokens */ }
impl DeterministicTokenizer {
    pub fn new() -> Self;
    pub fn with_parameters(vocab_id: impl Into<String>,
                           vocab_size: i32, max_tokens: usize) -> Self;
}
impl Default for DeterministicTokenizer { /* "deterministic-v1" / 30522 / 128 */ }
impl Tokenizer for DeterministicTokenizer { /* FNV-1a fold, matches Swift */ }
```

> **F11 consolidation (2026-05-27):** Swift AND Rust providers
> conform to VectorKit's `EmbeddingProvider`. The previous parallel
> `CorpusKit::TextEmbeddingProvider` (both ports) has been deleted.
> Tokenizer stays in CorpusKit as a per-provider implementation
> detail — not part of VectorKit's contract — preserving VectorKit's
> pure-compute isolation for port maintenance.

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
encoder mandate's segmentation stage (F16, 2026-05-27). Time enters
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
}
pub type CorpusKitResult<T> = Result<T, CorpusKitError>;
// implements std::fmt::Display + std::error::Error
```

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/CorpusKit
```

(Target: `CorpusKitTests` — covers core + providers; the test target
depends on `PersistenceKitInMemory` for the bundle-store path.)

**Rust:**

```
cargo test -p corpus-kit
cargo test -p corpus-kit-providers
```

(The `corpus-kit` integration tests pull `corpus-kit-providers` as a
dev-dependency for the `DeterministicTokenizer` fixture.)

## § 6 — Corpus actor (public entry point)

### `EmbeddingModel` (Swift) / `EmbeddingModelConfig` (Rust)

A CorpusKit-owned type for selecting the embedding model. No VectorKit
type is required at the call site. The default is `.deterministic`
(no CoreML required).

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
/// Platform note: named model cases (miniLM/mpNet/embeddingGemma) are
/// Apple-only (CoreML). The Rust port ships Deterministic only.
#[derive(Default)]
pub enum EmbeddingModelConfig {
    #[default]
    Deterministic,
}
```

### `Corpus`

The public RAG entry point. No VectorKit type appears in any public
signature (SPEC § 8, B-8).

**Swift:**

```swift
public actor Corpus {
    /// Construct a Corpus. Opens BundleStore + VectorStore schemas on
    /// the supplied storage via migrate(to:). The caller owns the
    /// Storage lifecycle.
    public init(storage: any Storage, model: EmbeddingModel = .default) async throws

    /// Chunk, store, index, embed, and vector-store a document.
    /// Idempotent on content-addressed chunk ids (SPEC B-9, I-3).
    public func ingest(_ text: String, sourceID: String, now: Date) async throws

    /// Embed the query and return fused kNN + BM25 results (SPEC B-10).
    public func recall(_ query: String, limit: Int = 10, now: Date) async throws -> [ScoredChunk]

    /// Remove a source from BM25 + VectorStore. BundleStore is
    /// append-only; count() does not decrease (SPEC B-11).
    public func remove(sourceID: String) async throws

    /// Total chunks in BundleStore (does not decrease after remove).
    public func count() async throws -> Int
}
```

**Rust:**

```rust
pub struct Corpus { /* bundle_store, bm25: Mutex<BM25Index>, vector_store, provider */ }
impl Corpus {
    /// Construct via migrate() to apply both schemas (BundleStore + VectorStore)
    /// regardless of version gating.
    pub fn open(storage: Arc<dyn Storage>, model: EmbeddingModelConfig) -> CorpusKitResult<Self>;

    /// now_millis: Unix epoch in milliseconds (caller-supplied for determinism).
    pub fn ingest(&self, text: &str, source_id: &str, now_millis: i64) -> CorpusKitResult<()>;
    pub fn recall(&self, query: &str, limit: usize, now_millis: i64) -> CorpusKitResult<Vec<ScoredChunk>>;
    pub fn remove(&self, source_id: &str) -> CorpusKitResult<()>;
    pub fn count(&self) -> CorpusKitResult<usize>;
}
```

---

## § 7 — Examples

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

## § 8 — Swift/Rust Concordance

One row per public concept. Each Swift symbol and Rust symbol is a real
top-level public declaration found in source (file:line cited). The
shape rule states how (if at all) the two ports are allowed to differ.
The test/vector binding names the conformance/parity test that proves
Swift == Rust for that concept. Read-anchored: every row was confirmed
against `Sources/**` and `rust/src/**` (plus `rust-providers/src/**`).

Status legend: **Confirmed** = both present and test-bound;
**Exempt** = Apple-platform binding, no Rust counterpart by design;
**DRIFT** = parity gap that is not a sanctioned platform binding.

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
| EmbeddingModel selector | `EmbeddingModel` (`CorpusKit.swift:40`) | `EmbeddingModelConfig` (`corpus.rs:56`) | public enum / pub enum | Swift four cases (`deterministic`/`miniLM`/`mpNet`/`embeddingGemma`); Rust `Deterministic` only — named cases are CoreML-bound (Apple platform binding); `.deterministic`↔`Deterministic` is the cross-port parity case | `CorpusTests.swift` / `corpus_tests.rs` (deterministic seed parity) | Confirmed |
| Corpus | `Corpus` (`CorpusKit.swift:99`) | `Corpus` (`corpus.rs:113`) | public actor / pub struct | Swift `actor` (`init async throws`) / Rust `struct` (`open()`, `bm25: Mutex<BM25Index>`); Swift `async throws`+`Date` ↔ Rust sync `CorpusKitResult`+`now_millis` — sanctioned actor↔owned-state + async↔sync seam | `CorpusTests.swift` / `corpus_tests.rs` | Confirmed |
| DeterministicTokenizer | `DeterministicTokenizer` (`DeterministicTokenizer.swift:16`) | `DeterministicTokenizer` (`rust-providers/.../deterministic_tokenizer.rs:34`) | public struct / pub struct | identical FNV-1a fold; Swift default-arg init ↔ Rust `new`/`with_parameters`/`Default`; lives in providers target both ports | `ProvidersTests.swift` / `deterministic_tokenizer_tests.rs` | Confirmed |
| MiniLMTextProvider | `MiniLMTextProvider` (`MiniLMTextProvider.swift:41`) | none — Apple platform binding (CoreML) | public struct / — | Rust: none — Apple platform binding (CoreML inference loaded by host app); ONNX/Candle Rust providers deferred (SPEC § 9). Conforms to VectorKit `EmbeddingProvider` | `ProvidersTests.swift` (Swift-only) | Exempt |
| MPNetTextProvider | `MPNetTextProvider` (`MPNetTextProvider.swift:31`) | none — Apple platform binding (CoreML) | public struct / — | Rust: none — Apple platform binding (CoreML); ONNX/Candle Rust provider deferred (SPEC § 9) | `ProvidersTests.swift` (Swift-only) | Exempt |
| EmbeddingGemmaProvider | `EmbeddingGemmaProvider` (`EmbeddingGemmaProvider.swift:33`) | none — Apple platform binding (CoreML) | public struct / — | Rust: none — Apple platform binding (CoreML); ONNX/Candle Rust provider deferred (SPEC § 9) | `ProvidersTests.swift` (Swift-only) | Exempt |

**Notes on the three text providers (Exempt rationale).** `MiniLMTextProvider`,
`MPNetTextProvider`, and `EmbeddingGemmaProvider` each wrap a CoreML-backed
inference closure that the host app supplies; CoreML is an Apple framework with
no Rust counterpart. Per the doc body (§ 2, F11/SPEC § 9), the Rust
`corpus-kit-providers` crate ships `DeterministicTokenizer` today and the
ONNX/Candle-backed providers land in a follow-on mission once model bundles are
wired in. These are sanctioned Apple-platform bindings, not parity drift: the
behavioral parity surface (chunking, BM25, hybrid recall, content-addressed
ids, deterministic embedding) is fully mirrored across both ports. They are
proposed for the audit ignore-list (see `exempt_proposed`) because the
deterministic path is the cross-port contract and these three are the
platform-bound exceptions.

---

*End of CorpusKit Interface v0.8.*
