---
title: CorpusKit Interface
status: accepted-1.1-target
authors: MOOTx01 maintainers
date: 2026-07-22
spec_type: kit
version: 1.18.0
description: Public API surface for CorpusKit in both the Swift and Rust ports.
package: CorpusKit
languages: [swift, rust]
relates_to:
  - CORPUSKIT_SPEC.md  (the contract this interface implements)
  - the package-dependency rule  (authorizes the IntellectusLib dependency)
purpose: |
  Accepted 1.1 public API target for CorpusKit in both ports: the
  content-source contract, standalone content store, operating modes,
  canonical CorpusHit result, whole-content and optional standalone
  passage policies, BM25/vector retrieval, provider surfaces, and
  synchronization/migration seams. Chunk, Chunker, ScoredChunk, and
  BundleStore remain a standalone 1.0 compatibility surface and are not
  used by GeniusLocusKit.
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
  - `BasisStore.swift` — `BasisStore` (actor), `PersistedBasis`
  - `CorpusProviderCountsStore.swift` — `CorpusProviderCountsStore` (actor),
    `PersistedCounts`, `PersistedCountsReference`, `CountsGrowthAnchor`
  - `RemovedSourceStore.swift` — `RemovedSourceStore` (actor)
  - `HybridRecall.swift` — `HybridRecall`, `HybridRecallConfiguration`
  - `Tokenizer.swift` — `Tokenizer` protocol + default `keywordTokens`
  - `TrainableEmbeddingBasis.swift` — `TrainableEmbeddingBasis` protocol
  - `SyncManifest.swift` — `CorpusKitSync`
  - `CorpusKitError.swift` — `CorpusKitError`
  - `CorpusKit.swift` — `EmbeddingModel`, `EncodeSpeed`, `FloatLaneOutcome`, `Corpus`
  - `CorpusIngestQueue.swift` — ingest pipeline extension on `Corpus`
  - `Engine/` — inverted-index engine types (`BM25Weighting`, `ImpactPosting`,
    `SparseHit`, `FusedHit`, `Fusion`, `InvertedIndex`, `InvertedIndexStore`, `LaneTag`)
- `Sources/CorpusKitProviders/` — providers (imply a model bundle):
  - `DeterministicTokenizer.swift` — `DeterministicTokenizer`
  - `FdcProvider.swift` — `FDCProvider`, `fdcDimension`, `fdcProjectionSeed`,
    `fdcNodeVector`
  - `MiniLMTextProvider.swift`, `MPNetTextProvider.swift`,
    `EmbeddingGemmaProvider.swift`
  - `RandomIndexingProvider.swift` — `RandomIndexingProvider`
  - `PpmiProvider.swift` — `PpmiProvider`
  - `LsaProvider.swift` — `LsaProvider`
  - `NmfProvider.swift` — `NmfProvider`
  - `BasisCodec.swift` — `BasisWriter`, `BasisReader`, `basisFormatVersion`
  - `DefaultEnsemble.swift` — `CorpusEnsemble`
  - `NLEmbeddingProvider.swift`, `NLContextualEmbeddingProvider.swift`
    (Swift-only, `#if canImport(NaturalLanguage)` — see the Apple embedding-provider contract)
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

## § 1.1 — Shared-content operating surface (accepted 1.1 target)

The types in this section are the common engine boundary for standalone
CorpusKit and GeniusLocusKit composition. Swift and Rust ship the same value
semantics and conformance traces.

### Canonical content values

```swift
public typealias CorpusContentID = String

public struct CorpusContentRecord: Sendable, Equatable {
    public let id: CorpusContentID
    public let revision: String
    public let digest: ContentHash
    public let text: String
}

public struct CorpusChangeCursor: Sendable, Equatable, Codable {
    public let rawValue: String
}

public enum CorpusContentChange: Sendable, Equatable {
    case upsert(id: CorpusContentID, revision: String, digest: ContentHash)
    case remove(id: CorpusContentID, revision: String)
}

public struct CorpusContentChangeBatch: Sendable, Equatable {
    public let changes: [CorpusContentChange]
    public let nextCursor: CorpusChangeCursor
}
```

```rust
pub type CorpusContentId = String;

pub struct CorpusContentRecord {
    pub id: CorpusContentId,
    pub revision: String,
    pub digest: ContentHash,
    pub text: String,
}

pub struct CorpusChangeCursor(pub String);

pub enum CorpusContentChange {
    Upsert { id: CorpusContentId, revision: String, digest: ContentHash },
    Remove { id: CorpusContentId, revision: String },
}

pub struct CorpusContentChangeBatch {
    pub changes: Vec<CorpusContentChange>,
    pub next_cursor: CorpusChangeCursor,
}
```

### Content-source and standalone-store contracts

```swift
public protocol CorpusContentSource: Sendable {
    func content(id: CorpusContentID) async throws -> CorpusContentRecord?
    func changes(since cursor: CorpusChangeCursor?) async throws
        -> CorpusContentChangeBatch
}

public protocol CorpusContentStore: CorpusContentSource {
    @discardableResult
    func put(_ text: String, id: CorpusContentID?, now: Date) async throws
        -> CorpusContentID
    func removeContent(id: CorpusContentID, now: Date) async throws
}
```

```rust
pub trait CorpusContentSource: Send + Sync {
    fn content(&self, id: &CorpusContentId) -> CorpusKitResult<Option<CorpusContentRecord>>;
    fn changes(&self, cursor: Option<&CorpusChangeCursor>)
        -> CorpusKitResult<CorpusContentChangeBatch>;
}

pub trait CorpusContentStore: CorpusContentSource {
    fn put(&self, text: &str, id: Option<CorpusContentId>, now_millis: i64)
        -> CorpusKitResult<CorpusContentId>;
    fn remove_content(&self, id: &CorpusContentId, now_millis: i64)
        -> CorpusKitResult<()>;
}
```

`CorpusContentSource` is declared in CorpusKit core. LocusKit does not conform
directly and does not import CorpusKit; GeniusLocusKit owns the adapter that
projects active Drawers into these values.

### Index-unit policy and results

```swift
public enum CorpusIndexUnitPolicy: Sendable, Equatable {
    case wholeContent
#if CORPUSKIT_STANDALONE_PASSAGES
    case tokenWindows(windowTokens: Int, overlapTokens: Int)
#endif
}

public struct CorpusEvidence: Sendable, Equatable {
    public let passageID: String
    public let utf8Start: Int
    public let utf8Length: Int
}

public struct CorpusContentHit: Sendable, Equatable {
    public let id: CorpusContentID
    public let score: Float
    public let vectorScore: Float?
    public let keywordScore: Float?
    public let evidence: CorpusEvidence?
}
```

Rust exposes the equivalent `CorpusIndexUnitPolicy::TokenWindows`,
`CorpusEvidence`, and `CorpusContentHit` values with snake-case fields when the
`standalone-passages` feature is enabled.

`.wholeContent` is the standalone default and the only policy accepted by the
GeniusLocusKit adapter. `.tokenWindows` is compiled only with the Swift
`StandalonePassages` trait and is standalone-only. Its persisted rows carry
`content_id`, `revision`, `digest`, `policy_fingerprint`, and UTF-8 range
coordinates; they carry no text. The database also stores one
`corpus_index_configuration` authority row containing tokenizer identity,
window, overlap, and version. Every recall result is aggregated to its canonical
content ID.

### Operating modes and construction

```swift
public enum CorpusOperatingMode: Sendable {
    case standalone
    case attached
}

public actor CorpusContentEngine {
    public init(
        storage: any Storage,
        vectorStorage: any Storage,
        mode: CorpusOperatingMode,
        indexUnitPolicy: CorpusIndexUnitPolicy = .wholeContent,
        embeddingModels: [EmbeddingModel]
    ) async throws

    public func applySourceChanges(now: Date) async throws
    public func rebuildFromSource(now: Date) async throws
    public func recall(_ query: String, limit: Int = 10, now: Date) async throws
        -> [CorpusHit]
}
```

Rust exposes the equivalent `CorpusOperatingMode` and `CorpusContentEngine::open`,
`apply_source_changes`, `rebuild_from_source`, and `recall` surface.

Standalone convenience methods delegate content mutation to the configured
`CorpusContentStore` and then apply the resulting source change. Attached mode
has no content mutation surface. GLK capture, mutation, withdrawal, and expunge
remain LocusKit/GLK operations.

### Storage profiles

- **Standalone:** canonical `corpus_documents`; optional
  `corpus_index_configuration` plus range-only `corpus_passages` when the
  standalone passage build option is selected; derived BM25, vector,
  provider-basis/counts, and `corpus_index_state` tables.
- **GLK attached:** canonical `drawers` supplied by LocusKit; derived BM25,
  vector, provider-basis/counts, and `corpus_index_state` tables only. No
  `corpus_documents`, `corpus_passages`, `chunks`, or `corpus_metadata` table is
  part of the GLK composite schema.
- `corpus_index_state` is keyed by canonical content ID and records only source
  revision/digest, applied cursor, and index version. It contains no verbatim
  content.

## § 2 — Public types

### `Chunk`

A standalone 1.0 compatibility type for an optional passage index unit. It is
never a GLK content object or public GLK result identity. The id is a
deterministic RFC 4122 v5 UUID over `(sourceID, startOffset, text)`.

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

A standalone 1.0 compatibility result: a chunk plus its retrieval score,
returned only by the legacy passage-hydration hybrid recall (SPEC § 5, B-4).
Absent sub-scores are `nil` / `None`.

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

Standalone-only passage parameters. New 1.1 callers use
`CorpusIndexUnitPolicy.tokenWindows(windowTokens:overlapTokens:)`, whose limits
are expressed in tokens under the versioned CorpusKit passage tokenizer. These
character-based defaults remain
only for 1.0 compatibility (target 800 chars, overlap 100). Overlap is clamped to
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

Standalone 1.0 compatibility storage for copied chunk content. It is excluded
from the GeniusLocusKit composite schema under the 1.1 shared-content contract.
The chunks table joins to VectorKit by
`chunk.id.uuidString == storedVector.drawerID` (I-5). An `actor` in
Swift over a PersistenceKit `Storage`.

**Swift:**

```swift
public actor BundleStore {
    public static let schemaDeclaration: SchemaDeclaration   // chunks + corpus_metadata tables (kit-ID "CorpusKit", v3), appendOnly; chunks carries content_hash BLOB nullable (hash-on-write, the node-integrity contract §19) and ext JSON nullable (the forward-compatible ext-slot contract, inert in 1.0)
    public init(storage: any Storage)
    public func insert(_ chunks: [Chunk]) async throws        // idempotent (B-5); hash-on-write + Merkle rollup (I-11, I-13)
    public func get(id: UUID, asOf: AsOfCoordinate? = nil) async throws -> Chunk?
    public func getMany(ids: [UUID], asOf: AsOfCoordinate? = nil) async throws -> [Chunk]
    public func chunksForSource(_ sourceID: String, asOf: AsOfCoordinate? = nil) async throws -> [Chunk]
    public func count(asOf: AsOfCoordinate? = nil) async throws -> Int   // asOf accepted but not forwarded (I-12)
    public func allChunks(asOf: AsOfCoordinate? = nil) async throws -> [Chunk]           // HLC-ordered
    public func corpusMerkleRoot(for sourceID: String) async throws -> MerkleRoot   // I-13; .empty if no chunks
    public func globalCorpusMerkleRoot() async throws -> MerkleRoot   // I-13; interior hash over all per-corpus roots
}
```

**Rust:**

```rust
pub struct BundleStore { /* Arc<dyn Storage>, HashingRowStore, ParentChainCache */ }
impl BundleStore {
    pub fn schema_declaration() -> SchemaDeclaration;   // chunks + corpus_metadata (kit-ID "CorpusKit", v3)
    pub fn new(storage: Arc<dyn Storage>) -> Self;
    pub fn open(storage: Arc<dyn Storage>) -> CorpusKitResult<Self>;  // applies schema, wires HashingRowStore
    pub fn insert(&self, chunks: &[Chunk]) -> CorpusKitResult<()>;   // hash-on-write + Merkle rollup (I-11, I-13)
    pub fn get(&self, id: Uuid, as_of: Option<AsOfCoordinate>) -> CorpusKitResult<Option<Chunk>>;
    pub fn get_many(&self, ids: &[Uuid], as_of: Option<AsOfCoordinate>) -> CorpusKitResult<Vec<Chunk>>;
    pub fn chunks_for_source(&self, source_id: &str, as_of: Option<AsOfCoordinate>) -> CorpusKitResult<Vec<Chunk>>;
    pub fn count(&self, as_of: Option<AsOfCoordinate>) -> CorpusKitResult<usize>;   // as_of accepted but not forwarded (I-12)
    pub fn all_chunks(&self, as_of: Option<AsOfCoordinate>) -> CorpusKitResult<Vec<Chunk>>;
    pub fn corpus_merkle_root(&self, source_id: &str) -> CorpusKitResult<MerkleRoot>;   // I-13; EMPTY if no chunks
    pub fn global_corpus_merkle_root(&self) -> CorpusKitResult<MerkleRoot>;   // I-13; interior hash over all per-corpus roots
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
    // default: lowercase, fold final sigma U+03C2 to U+03C3,
    // then split on Unicode-alphabetic / ASCII-digit boundaries
    func keywordTokens(_ text: String) -> [String]
}
```

The final-sigma fold is part of the cross-port canonical-token contract.
Because it changes training input for RI, PPMI, LSA, and NMF, their production
defaults use model version `1.1.0`; persisted `1.0.0` bases are not reused.
FDC is stateless and remains `1.0.0`.

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

#### `FDCProvider` — Frequency-Discriminating Code (both ports)

The fifth default-ensemble signal. A deterministic, non-trainable provider that
encodes each chunk as a 256-dimensional float vector by hashing its vocabulary
terms through a fixed codebook (`fdcNodeVector`). No inference closure; no
training. Projection seed `fdcProjectionSeed` ("FDCV1P", `0x4644_435F_5631_5F50`).
Cross-port classification also requires the Lattice tokenizer contract: Rust
splits ASCII `:` to match Foundation word enumeration, and macOS Rust resolves
the writable `WordClassTable.json` from the same
`~/Library/Application Support/com.mootx01.lattice` root as Swift. An explicit
environment override still takes precedence.

**Swift:**

```swift
public let fdcDimension: Int                // 256
public let fdcProjectionSeed: UInt64        // 0x4644_435F_5631_5F50 ("FDCV1P")
public func fdcNodeVector(code: String) -> [Float]  // deterministic 256-dim code vector

public final class FDCProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelID: String              // default "fdc-v1"
    public let modelVersion: String         // default "1.0.0"
    public init(modelID: String = "fdc-v1", modelVersion: String = "1.0.0")
    public func embed(_ text: String) async throws -> Engram
    public func embedFloat(_ text: String) async throws -> [Float]
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float])
}
```

**Rust:** `corpus-kit-providers` ships an equivalent `FdcProvider` with the
same modelID default, projectionSeed, and 256-dim codebook. Parity status:
**Confirmed** (covered by `embedding_conformance_tests.rs`).

#### Distributional providers — `CorpusKitProviders` / `corpus-kit-providers`

Four trainable distributional signal providers. All four conform to
`EmbeddingProvider` and `TrainableEmbeddingBasis`. They form the
RI / PPMI / LSA / NMF slots of `CorpusEnsemble.defaultEnsemble()`.
Constants are public for cross-port conformance tests.

**`RandomIndexingProvider`** (slot 0, default signal):

```swift
public let riDimension: Int                 // 2048
public let riNonzeros: Int                  // 10
public let riWindow: Int                    // 4
public let riProjectionSeed: UInt64         // 0x5249_5F56_315F_4D58 ("RI_V1_MX")
public func riIndexVector(term: String) -> [Float]

public final class RandomIndexingProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelID: String              // default "random-indexing-v1"
    public let modelVersion: String         // default "1.1.0"
    public init(modelID: String = "random-indexing-v1", modelVersion: String = "1.1.0",
                dimension: Int = riDimension, nonzeros: Int = riNonzeros,
                window: Int = riWindow, projectionSeed: UInt64 = riProjectionSeed)
    public func train(terms: [String], window: Int = riWindow)
    public var vocabularySize: Int
    public func contextVector(forTerm term: String) -> [Float]?
    public func releaseBasis()  // zero the training data; retains the projection seed
    // TrainableEmbeddingBasis: trainOnCorpus, serializeBasis, init(deserializing:),
    //   reconstructBasis(from:), addToCounts, serializeCounts, restoreCounts(from:),
    //   countsVocabularySize
    public func embed(_ text: String) async throws -> Engram
    public func embedFloat(_ text: String) async throws -> [Float]
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float])
}
```

**`PpmiProvider`** (slot 1):

```swift
public let ppmiDimension: Int               // 2048
public let ppmiNonzeros: Int                // 10
public let ppmiWindow: Int                  // 4
public let ppmiProjectionSeed: UInt64       // 0x5050_4D49_5F56_314D ("PPMI_V1M")

public final class PpmiProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelID: String              // default "ppmi-v1"
    public let modelVersion: String
    public init(modelID: String = "ppmi-v1", modelVersion: String = "1.1.0",
                dimension: Int = ppmiDimension, nonzeros: Int = ppmiNonzeros,
                window: Int = ppmiWindow, projectionSeed: UInt64 = ppmiProjectionSeed)
    public func train(terms: [String], window: Int = ppmiWindow)
    public func finalize()  // apply PMI transform; must be called before embed
    public var vocabularySize: Int
    public var trainingVocabSize: Int
    public func ppmiVector(forTerm term: String) -> [Float]?
    public func releaseBasis()
    // TrainableEmbeddingBasis surface (same as RI)
}
```

**`LsaProvider`** (slot 2):

```swift
public let lsaProjectionSeed: UInt64        // 0x4C53415F56315F4D ("LSA_V1_M")
public let lsaDefaultRank: Int              // 64

public final class LsaProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelID: String              // default "lsa-v1"
    public let modelVersion: String
    public let rank: Int                    // SVD rank (default lsaDefaultRank)
    public let reducedVocabCap: Int         // vocabulary cap before SVD
    public let svdSweeps: Int               // Jacobi sweep count
    public init(modelID: String = "lsa-v1", modelVersion: String = "1.1.0",
                rank: Int = lsaDefaultRank, reducedVocabCap: Int = 8192,
                svdSweeps: Int = 30, projectionSeed: UInt64 = lsaProjectionSeed)
    public func train(document: String)     // accumulate one document's TF
    public func finalize()                  // run SVD; must be called before embed
    public var documentCount: Int
    public var vocabularySize: Int
    public var isFinalized: Bool
    public var effectiveRank: Int
    public func documentEmbedding(at docIdx: Int) -> [Float]?
    public func releaseBasis()
    // TrainableEmbeddingBasis surface (same as RI)
}
```

**`NmfProvider`** (slot 3):

```swift
public let nmfProjectionSeed: UInt64        // 0x4E4D465F56315F4D ("NMF_V1_M")
public let nmfDefaultRank: Int              // 32
public let nmfDefaultIterations: Int        // 100
public let nmfFactorizationSeed: UInt64     // 0xDEAD_BEEF_CAFE_BABE

public final class NmfProvider: EmbeddingProvider, @unchecked Sendable {
    public let modelID: String              // default "nmf-v1"
    public let modelVersion: String
    public let rank: Int                    // NMF rank (default nmfDefaultRank)
    public let reducedVocabCap: Int
    public let maxIterations: Int           // default nmfDefaultIterations
    public let seed: UInt64                 // NMF random init seed (default nmfFactorizationSeed)
    public init(modelID: String = "nmf-v1", modelVersion: String = "1.1.0",
                rank: Int = nmfDefaultRank, reducedVocabCap: Int = 8192,
                maxIterations: Int = nmfDefaultIterations,
                seed: UInt64 = nmfFactorizationSeed,
                projectionSeed: UInt64 = nmfProjectionSeed)
    public func train(document: String)
    public func finalize()
    public var documentCount: Int
    public var vocabularySize: Int
    public var isFinalized: Bool
    public var effectiveRank: Int
    public func documentEmbedding(at docIdx: Int) -> [Float]?
    public func releaseBasis()
    // TrainableEmbeddingBasis surface (same as RI)
}
```

All four distributional providers ship in `corpus-kit-providers` with identical
constants, default parameters, and `TrainableEmbeddingBasis` surface. Both ports
are at parity (Confirmed; the basis round-trip produces byte-identical blobs — see
§ 2 distributional-provider basis serialization and the concordance table).

> **Provider surface (both ports):** Swift and Rust providers conform to
> VectorKit's `EmbeddingProvider`. Tokenizer stays in CorpusKit as a
> per-provider implementation detail — not part of VectorKit's contract —
> preserving VectorKit's pure-compute isolation.
>
> The Rust `corpus-kit-providers` crate ships all six provider types:
> `FDCProvider`, `DeterministicTokenizer`, `MiniLMTextProvider`,
> `MPNetTextProvider`, `EmbeddingGemmaProvider`, and all four distributional
> providers (`RandomIndexingProvider`, `PpmiProvider`, `LsaProvider`,
> `NmfProvider`). The three named CoreML model providers use the same
> host-inference seam model as Swift: `InferenceFn` (synchronous, token
> IDs in / pooled float vector out). No ONNX/Candle dependency is added;
> the kit owns only the tokenizer and projection; model weights remain
> the host's concern on every platform.

#### Distributional-provider support types (both ports)

`TermDocumentCounts` and `ReducedVocabulary` live in
`Sources/CorpusKitProviders/` (Swift) and `rust-providers/src/`
(Rust). They are shared utilities consumed internally by `LsaProvider`
and `NmfProvider`; they are public API so callers who drive training
directly (e.g. conformance tests) can read the accumulated counts.

**`TermDocumentCounts`** — encounter-order vocabulary builder plus raw
TF and DF counts. Both legs agree on vocabulary encounter order and raw
counts; downstream conformance vectors pin the bit-identical contract.

```swift
// Sources/CorpusKitProviders/TermDocumentCounts.swift
public struct TermDocumentCounts {
    /// term → encounter-order index (deterministic for a fixed training sequence)
    public private(set) var vocab: [String: Int]
    /// tfCounts[docIdx][termIdx] = raw count
    public private(set) var tfCounts: [[Int: Int]]
    /// dfCounts[termIdx] = number of documents containing that term
    public private(set) var dfCounts: [Int: Int]

    public init()
    /// Reconstruct from a persisted vocab + document count without re-tokenizing
    /// (deserialization path — raw TF rows are training scratch, not serialized).
    public init(restoredVocab vocab: [String: Int], documentCount: Int)

    /// Tokenize text, assign encounter-order vocab indices, accumulate TF and DF.
    /// No-op for text that tokenizes to nothing. Does NOT call Date().
    public mutating func addDocument(_ text: String)

    /// Lightweight anchor variant: grow vocab and document count without
    /// retaining per-document TF rows or DF counts (incremental counts path P3).
    /// Does NOT call Date().
    public mutating func addDocumentForCountsAnchor(_ text: String)

    public var documentCount: Int    { tfCounts.count }
    public var vocabularySize: Int   { vocab.count }
}
```

**Rust** (`corpus-kit-providers`; re-exported at crate root as
`corpus_kit_providers::TermDocumentCounts`):

```rust
pub struct TermDocumentCounts {
    pub vocab: HashMap<String, usize>,          // term → encounter-order index
    pub tf_counts: Vec<HashMap<usize, usize>>,  // per-document TF counts
    pub df_counts: HashMap<usize, usize>,       // term → document frequency
}
impl TermDocumentCounts {
    pub fn new() -> Self;
    /// Mirror of Swift's `init(restoredVocab:documentCount:)`.
    pub fn from_restored(vocab: HashMap<String, usize>, document_count: usize) -> Self;
    pub fn add_document(&mut self, text: &str);
    pub fn add_document_for_counts_anchor(&mut self, text: &str);
    pub fn document_count(&self) -> usize;
    pub fn vocabulary_size(&self) -> usize;
}
impl Default for TermDocumentCounts { /* new() */ }
```

**`ReducedVocabulary`** — frozen IDF-reduced vocabulary selection for
the dense LSA/NMF factorizations. The selection algorithm is
bit-identical across ports: drop hapax (df < 2), rank remaining terms
by document frequency descending then UTF-8 byte order ascending, keep
the top K. Below the cap the full vocabulary is returned unchanged.

```swift
// Sources/CorpusKitProviders/ReducedVocab.swift

/// Default cap K for the reduced vocabulary (both ports).
public let defaultReducedVocabCap: Int = 512  // K²·numDocs cost keeps large-corpus reindex in seconds range

/// Frozen reduced vocabulary: ordered kept terms plus maps needed
/// to remap full-vocab TF rows at train time and query terms at projection time.
public struct ReducedVocabulary: Sendable {
    public let keptTerms: [String]           // column i == keptTerms[i]
    public let termToColumn: [String: Int]   // term → reduced column
    public let fullIndexToColumn: [Int: Int] // full-vocab index → reduced column
    public var size: Int { keptTerms.count }
}

/// Select the shared reduced vocabulary from maintained term-document counts.
/// No-op when fullVocab.count ≤ cap (small estates, conformance fixtures).
public func selectReducedVocabulary(
    vocab: [String: Int],
    dfCounts: [Int: Int],
    documentCount N: Int,
    cap: Int = defaultReducedVocabCap
) -> ReducedVocabulary
```

**Rust** (`corpus-kit-providers`; reachable as
`corpus_kit_providers::reduced_vocab::{ReducedVocabulary, DEFAULT_REDUCED_VOCAB_CAP, select_reduced_vocabulary}`):

```rust
// rust-providers/src/reduced_vocab.rs; pub mod re-exported from lib.rs

pub const DEFAULT_REDUCED_VOCAB_CAP: usize = 512;  // mirrors Swift defaultReducedVocabCap

pub struct ReducedVocabulary {
    pub kept_terms: Vec<String>,
    pub term_to_column: HashMap<String, usize>,
    pub full_index_to_column: HashMap<usize, usize>,
}
impl ReducedVocabulary {
    pub fn size(&self) -> usize;
}

pub fn select_reduced_vocabulary(
    vocab: &HashMap<String, usize>,
    df_counts: &HashMap<usize, usize>,
    _document_count: usize,
    cap: usize,
) -> ReducedVocabulary;
```

> **Parity note.** Both ports are at parity. The selection is
> deterministic and produces identical column assignments on both legs
> (df descending, then term UTF-8 byte order ascending — Rust `&str` Ord
> matches Swift's `Array(term.utf8)` compare). Covered by
> `reduced_vocab.rs` tests.

#### Apple NL providers — Swift-only (the Apple embedding-provider contract)

Two additional providers exist in `CorpusKitProviders` behind
`#if canImport(NaturalLanguage)`. They are **not** available in the
Rust port (sanctioned divergence — same class as the `.nlTagger`
word-class path; see the Apple embedding-provider contract). They are item-local (stateless,
compute-once-on-write) and **opt-in** (not part of the default ensemble).

**`NLEmbeddingProvider`** — OS-bundled sentence embedding (macOS 12+/iOS 15+):

```swift
#if canImport(NaturalLanguage)
/// model_id "apple-nlembedding-v1", seed nlEmbeddingProjectionSeed ("APNLEMB1",
/// 0x4150_4E4C_454D_4231). Float lane: NLEmbedding.vector(for:) → [Float],
/// L2-normalised. Absent lane (no OS model for language): embedFloat → [].
public struct NLEmbeddingProvider: EmbeddingProvider, Sendable {
    public let modelID: String          // default "apple-nlembedding-v1"
    public let modelVersion: String     // default "1.0.0"
    public init(modelID: String = "apple-nlembedding-v1",
                modelVersion: String = "1.0.0",
                language: NLLanguage = .english,
                projectionSeed: UInt64 = nlEmbeddingProjectionSeed)
    public func embed(_ text: String) async throws -> Engram
    public func embedFloat(_ text: String) async throws -> [Float]
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float])
}

public let nlEmbeddingProjectionSeed: UInt64  // 0x4150_4E4C_454D_4231 ("APNLEMB1")
#endif
```

**`NLContextualEmbeddingProvider`** — on-device transformer embedding (macOS 13+/iOS 16+):

```swift
#if canImport(NaturalLanguage)
/// model_id "apple-nlcontextual-v1", seed nlContextualEmbeddingProjectionSeed
/// ("APNLCTX1", 0x4150_4E4C_4354_5831). Float lane: NLContextualEmbedding
/// per-token vectors, mean-pooled → [Float], L2-normalised. Absent lane
/// (asset not downloaded / language unsupported): embedFloat → [].
/// NEVER downloads proactively; asset management is the host app's responsibility.
public struct NLContextualEmbeddingProvider: EmbeddingProvider, Sendable {
    public let modelID: String          // default "apple-nlcontextual-v1"
    public let modelVersion: String     // default "1.0.0"
    public init(modelID: String = "apple-nlcontextual-v1",
                modelVersion: String = "1.0.0",
                language: NLLanguage = .english,
                projectionSeed: UInt64 = nlContextualEmbeddingProjectionSeed)
    public func embed(_ text: String) async throws -> Engram
    public func embedFloat(_ text: String) async throws -> [Float]
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float])
}

public let nlContextualEmbeddingProjectionSeed: UInt64  // 0x4150_4E4C_4354_5831 ("APNLCTX1")
#endif
```

**`EmbeddingModel` cases (Swift-only, `#if canImport(NaturalLanguage)`):**

```swift
#if canImport(NaturalLanguage)
extension EmbeddingModel {
    /// Opt-in NL sentence embedding (item-local, no training, no basis).
    case nlEmbedding(provider: any EmbeddingProvider & Sendable)
    /// Opt-in NL contextual transformer embedding (item-local, no training).
    case nlContextualEmbedding(provider: any EmbeddingProvider & Sendable)
}
#endif
```

Neither case joins `CorpusEnsemble.defaultEnsemble()`. Neither conforms to
`TrainableEmbeddingBasis`. Rust has no counterpart. Recorded in SPEC I-14 and the Apple embedding-provider contract.

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

The seam also carries the **maintained-counts** operations (the incremental
counts table — see the `CorpusProviderCountsStore` section below). These let the
host maintain each trainable provider's raw additive statistics through the
type-erased provider instead of rebuilding them merely to measure growth:
- `addToCounts(text:)` / `add_to_counts(&mut self, text:)` — fold one canonical
  index unit into the accumulated counts (RI/PPMI fold a term sequence; LSA/NMF
  fold a document into a lightweight vocab+doc-count anchor, O(vocab) not
  O(corpus)). In attached GLK mode that unit is a whole GLK Drawer; standalone
  behavior follows the standalone database's explicit index-unit policy.
- `serializeCounts()` / `serialize_counts()` — snapshot the raw additive state
  (distinct from `serializeBasis`; the counts codec, persisted in
  `corpus_provider_counts`). Byte-identical across ports.
- `restoreCounts(from:)` / `restore_counts(&mut self, bytes:)` — resume the
  snapshot in place; does NOT rebuild the derived basis. Throws/returns
  `decodingFailure` / `DecodingFailure` on a bad blob — never crashes.
- `countsVocabularySize` / `counts_vocabulary_size()` — the cheap vocabulary
  anchor the autonomic governor's vocab-growth retrain trigger reads.

**Swift:**

```swift
public protocol TrainableEmbeddingBasis: AnyObject, Sendable {
    func trainOnCorpus(texts: [String])
    func serializeBasis() -> Data
    func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable
    // Maintained counts (incremental counts table):
    func addToCounts(text: String)
    func serializeCounts() -> Data
    func restoreCounts(from data: Data) throws
    var countsVocabularySize: Int { get }
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
    // reconstruct_trainable_basis — Rust-only sibling that retains trainability
    // (the Swift `as?` cross-cast has no Rust equivalent); used by reindex /
    // first-ingest to rebuild a fresh trainable provider from the empty blob.
    fn reconstruct_trainable_basis(&self, basis: &[u8])
        -> Result<Box<dyn TrainableEmbeddingBasis>, CorpusKitError>;
    // Maintained counts (incremental counts table):
    fn add_to_counts(&mut self, text: &str);
    fn serialize_counts(&self) -> Vec<u8>;
    fn restore_counts(&mut self, bytes: &[u8]) -> Result<(), CorpusKitError>;
    fn counts_vocabulary_size(&self) -> usize;
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

### `CorpusProviderCountsStore` — base counts plus attached reference deltas (both ports)

The persisted **counts table**: each trainable provider's published additive
statistics base (RI context vectors; PPMI co-occurrence; LSA/NMF vocabulary +
document-count anchor). Sibling of
`BasisStore`; CorpusKit-core, depends only on PersistenceKit + SubstrateTypes,
never interprets the bytes (the provider owns the codec via the
`TrainableEmbeddingBasis` counts seam). One row per `(model_id, model_version)`,
keyed identically to the basis and vector rows. The two cheap integer columns
`doc_count` / `vocab_size` are independently maintained, durable growth-trigger
anchors. Between provider publications they intentionally describe the live
maintained state while `counts` remains the frozen published base blob.

Standalone `Corpus` retains the established lifecycle: restore the accumulator,
fold each newly written standalone index unit, and publish the blob at bounded
ingest/reindex boundaries. Attached `CorpusContentEngine` does not rewrite an
estate-scale counts blob for each queue burst. It atomically publishes small rows in
`corpus_provider_count_references`, keyed by provider generation and canonical
content identity, alongside the content checkpoint and the updated anchor
columns. A new identity advances the document anchor once. A changed digest
refreshes the same reference and may advance the nondecreasing vocabulary anchor
without incrementing documents; an identical digest is a no-op. Those rows
contain no text or token payload. Open restores the published base blob, resolves
each pending identity through the canonical content source, rebuilds the working
accumulator, and then restores the transactional anchor columns as the governor's
authority. A provider publication/retrain atomically replaces its base counts
and removes the reference rows that generation subsumed.

`CorpusContentEngine.maintainedVocabAnchor()` /
`CorpusContentEngine::maintained_vocab_anchor()` exposes the maximum durable,
nondecreasing vocabulary anchor across trainable slots — the in-process read the
autonomic governor's vocab-growth retrain trigger consumes (NeuronKit
`CorpusGrowthProbe`). Store-level `growthAnchor` reads the same transactional
anchor columns; it does not infer them from the frozen blob.

**Swift:**

```swift
public struct PersistedCounts: Sendable, Equatable {
    public let modelID: String
    public let modelVersion: String
    public let counts: Data          // opaque provider-serialized counts
    public let documentCount: Int    // growth anchor
    public let vocabSize: Int        // growth anchor
    public let updatedAt: Date
}
public struct CountsGrowthAnchor: Sendable, Equatable {
    public let documentCount: Int
    public let vocabSize: Int
}
public struct PersistedCountsReference: Sendable, Equatable {
    public let modelID: String
    public let modelVersion: String
    public let contentID: String
    public let revision: Int64
    public let digest: String
    public let updatedAt: Date
}
public actor CorpusProviderCountsStore {
    public static let schemaDeclaration: SchemaDeclaration
    public init(storage: any Storage)
    public func upsert(_ row: PersistedCounts) async throws
    public func load(modelID: String, modelVersion: String) async throws -> PersistedCounts?
    public func growthAnchor(modelID: String, modelVersion: String) async throws -> CountsGrowthAnchor?
    public func upsertReference(_ row: PersistedCountsReference, into rowStore: any RowStore) async throws
    public func updateAnchors(modelID: String, modelVersion: String, documentCount: Int, vocabSize: Int, into rowStore: any RowStore) async throws -> Bool
    public func references(modelID: String, modelVersion: String) async throws -> [PersistedCountsReference]
    public func deleteReferences(modelID: String, modelVersion: String, into rowStore: any RowStore) async throws
    public func deleteAll() async throws
}

// On Corpus:
public func maintainedVocabAnchor() -> Int
```

**Rust:**

```rust
pub struct PersistedCounts {
    pub model_id: String,
    pub model_version: String,
    pub counts: Vec<u8>,
    pub document_count: usize,
    pub vocab_size: usize,
    pub updated_at_secs: i64,
}
pub struct CountsGrowthAnchor { pub document_count: usize, pub vocab_size: usize }
pub struct PersistedCountsReference {
    pub model_id: String,
    pub model_version: String,
    pub content_id: String,
    pub revision: i64,
    pub digest: String,
    pub updated_at_secs: i64,
}
impl CorpusProviderCountsStore {
    pub fn schema_declaration() -> SchemaDeclaration;
    pub fn new(storage: Arc<dyn Storage>) -> Self;
    pub fn upsert(&self, row: &PersistedCounts) -> CorpusKitResult<()>;
    pub fn load(&self, model_id: &str, model_version: &str) -> CorpusKitResult<Option<PersistedCounts>>;
    pub fn growth_anchor(&self, model_id: &str, model_version: &str) -> CorpusKitResult<Option<CountsGrowthAnchor>>;
    pub fn upsert_reference_into(&self, row: &PersistedCountsReference, row_store: &Arc<dyn RowStore>) -> CorpusKitResult<()>;
    pub fn update_anchors_into(&self, model_id: &str, model_version: &str, document_count: usize, vocab_size: usize, row_store: &Arc<dyn RowStore>) -> CorpusKitResult<bool>;
    pub fn references(&self, model_id: &str, model_version: &str) -> CorpusKitResult<Vec<PersistedCountsReference>>;
    pub fn delete_references_into(&self, model_id: &str, model_version: &str, row_store: &Arc<dyn RowStore>) -> CorpusKitResult<()>;
    pub fn delete_all(&self) -> CorpusKitResult<()>;
}

// On Corpus:
pub fn maintained_vocab_anchor(&self) -> CorpusKitResult<usize>;
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

Standalone compatibility surface only. Sentence-aware chunking with overlap
(SPEC § 5, B-1). It is not constructed or called by GLK. Sentence
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

Standalone 1.0 compatibility surface. RRF fusion of vector kNN and BM25
keyword hits is hydrated from the bundle store (SPEC § 5, B-4; I-4). The kNN
pass is filtered to `modelID`. GLK uses `Corpus.recall` from § 1.1 and receives
canonical Drawer-keyed `CorpusHit` values; it does not hydrate `ScoredChunk`.

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

In standalone mode this builds the per-corpus `SyncManifest` declaring the chunks table
bidirectional with the `.appendOnly` conflict policy (SPEC § 4, I-2;
C-7). In GLK mode the composition manifest includes only CorpusKit's derived,
rebuildable index state; no `chunks`, `corpus_documents`, or `corpus_passages`
content table is declared. The `SyncManifest` type is ConvergenceKit's, not
CorpusKit's.

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
    case contentUnavailable(String)
    case modeViolation(String)
    case migrationIncomplete(String)
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
    ContentUnavailable(String),
    ModeViolation(String),
    MigrationIncomplete(String),
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
`the package-dependency rule`).

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

> **1.1 authority:** the shared-content constructors and operations in § 1.1
> are the normative target surface. Signatures below that accept verbatim text,
> return `ScoredChunk`, or expose `BundleStore` are retained only as the
> standalone CorpusKit 1.0 compatibility surface. They are not available from a
> GLK-composed `Corpus`.

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

The public RAG entry point. No VectorKit type appears in any public signature
(SPEC § 8, B-8). In standalone mode CorpusKit owns its content store. In GLK
mode it reads canonical Drawers through the injected `CorpusContentSource` and
persists only Drawer-keyed derived index state.

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

    /// Batch ingest with the embedding COMPUTE parallelized across documents
    /// (the CPU-bound cost) and the chunk/BM25/bundle/vector WRITES serial.
    /// Output is byte-identical to calling `ingest` once per item — same chunks,
    /// vectors, content-addressed idempotency — deterministic regardless of task
    /// completion order. Falls back to serial `ingest` per item while any
    /// trainable slot still lacks a persisted basis (first-ingest training cannot
    /// parallelize). The cross-document parallelism the ingest drain drives.
    /// Each item is `(text, sourceID, now)`. Rust: `ingest_batch(&[(String,String,i64)])`.
    public func ingestBatch(_ items: [(text: String, sourceID: String, now: Date)]) async throws

    // MARK: Ingest pipeline (queue + drain + worker pool — § 11 of the SPEC)
    //
    // A Corpus owns its encode pipeline and drains itself with no orchestrator
    // (CorpusKit is a standalone substrate). Relocated from GeniusLocusKit's
    // EncodeIntake. Rust mirrors take `&Arc<Self>` for the mount/enqueue paths
    // (the drain worker holds a cloned Arc<Corpus>); the job payload is the
    // CorpusKit-internal `IngestJob`, not a public type.

    /// Mount the per-corpus QueueKit-backed ingest queue (transient in-memory
    /// PersistenceKit backend) and start its foreground poll drain worker.
    /// Idempotent. Rust: `mount_ingest_queue(self: &Arc<Self>)`.
    public func mountIngestQueue() async throws

    /// Tear down the ingest queue: cancel the drain workers, await their
    /// exit (a cancelled pass can be mid-SQLite-transaction; a successor
    /// mounting the same estate file must not race it), then release the
    /// leases. Idempotent. Rust: `drop_ingest_queue(&self)`.
    public func dropIngestQueue() async

    /// STANDALONE ONLY: enqueue text for asynchronous ingest (lazily mounts the
    /// queue). Empty text is skipped. `sourceID` is the canonical standalone
    /// document id; `now` is the capture instant. Rust:
    /// `enqueue_ingest(self: &Arc<Self>, text, source_id, now_millis)`.
    public func enqueueIngest(_ text: String, sourceID: String, now: Date) async throws

    /// GLK/attached mode: enqueue a source change without copying Drawer text
    /// into QueueKit. The job contains canonical id, revision/digest, and source
    /// cursor; the worker resolves current content through CorpusContentSource.
    /// Rust: `enqueue_source_change(self: &Arc<Self>, change)`.
    public func enqueueSourceChange(_ change: CorpusContentChange) async throws

    /// Block until the ingest queue has fully drained (every enqueued item
    /// ingested + replied). Returns promptly when empty; no-op when no queue is
    /// mounted. Rust: `await_ingest_drain(&self)`.
    public func awaitIngestDrain(timeout: Duration = .seconds(30)) async throws

    /// Drain the ingest queue once (drivable by tests): ingest every available
    /// job via the parallel `ingestBatch` (with per-job at-least-once retry
    /// fallback), reply terminal, then fire `onEncoded`. Returns the job count.
    /// Rust: `drain_ingest_queue_once(&self)`.
    @discardableResult
    public func drainIngestQueueOnce() async throws -> Int

    /// Read-only depth probe of the ingest drain's outstanding work:
    /// `(pending, inFlight)`. Their sum is the encode work left; both zero means
    /// idle. OBSERVES the queue frontiers — never claims or drains — so it is
    /// safe to poll from any task while the drain runs. Returns `(0, 0)` when no
    /// queue is mounted. Rust: `ingest_queue_depth(&self) -> (usize, usize)`.
    public func ingestQueueDepth() async throws -> (pending: Int, inFlight: Int)

    /// Set the encode drain's SPEED (the import `mode`). `.foreground` (default)
    /// embeds across all logical cores; `.background` caps embed concurrency to
    /// ~`cores / 4` (x=4) so a large import leaves the machine headroom. SPEED
    /// axis only — write strategy is size-gated, not set here. Rust:
    /// `set_encode_speed(&self, speed: EncodeSpeed)`.
    public func setEncodeSpeed(_ speed: EncodeSpeed)

    /// The encode-speed knob. Swift `enum EncodeSpeed { case foreground, background }`;
    /// Rust `enum EncodeSpeed { Foreground, Background }`. Selects the embed
    /// fan-out concurrency (all cores vs ~a quarter) via `available cores`
    /// (`ProcessInfo.activeProcessorCount` / `std::thread::available_parallelism`),
    /// uniform across platforms and identical Swift↔Rust.

    /// Coordination callback fired after each drained batch with the encoded
    /// sourceIDs. `nil` when standalone; the orchestrator (GeniusLocusKit) sets
    /// it to roll up the touched LocusKit rooms. CorpusKit never reaches into
    /// LocusKit itself. Rust mirror: `set_on_encoded<F>(&self, callback: F)`
    /// (a method, not a var, because Rust has no stored-closure-as-property idiom).
    public var onEncoded: (@Sendable ([String]) async -> Void)?

    /// STANDALONE 1.0 COMPATIBILITY: embed the query and return fused kNN + BM25
    /// ScoredChunk results. The § 1.1 recall overload returns [CorpusHit] in both
    /// modes and is the only overload GLK calls. Runs on models[0].
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

    /// PER-SIGNAL dense float FARTHEST — the anti-similarity sibling of
    /// floatNearestPerSignal (mission 6b-modifiers-antisim). Runs the dense lane
    /// in the FARTHEST direction for EVERY held provider slot: each signal
    /// surfaces the most DISSIMILAR sources ("find things UNLIKE this"), ranked
    /// least-similar first. Same outcome shape, dark-lane observability,
    /// telemetry, and slot ordering as floatNearestPerSignal; only the objective
    /// differs (the store returns farthest index units via VectorStore.findFarthestFloat,
    /// and a source's score is its WORST unit cosine — the min-cosine inversion
    /// of nearest's best-chunk rule). This is the seam GLK's RecallShape
    /// antiSimilarLanes consumes. Empty query / zero limit → one .emptyQuery per
    /// signal. Rust mirror: `Corpus::float_farthest_per_signal`.
    public func floatFarthestPerSignal(query: String, limit: Int) async
        -> [(modelID: String, outcome: FloatLaneOutcome)]

    /// Retrain the embedding basis on the full corpus and re-embed every active
    /// index unit. In GLK an index unit is exactly one canonical Drawer; in
    /// standalone mode it may be a document or configured passage
    /// (mission 6a-ii-β). For a trainable provider: gathers all chunk texts,
    /// trains a FRESH basis from scratch through the TrainableEmbeddingBasis seam,
    /// UPSERTs it into corpus_provider_basis (one row per (modelID, modelVersion)),
    /// and re-embeds every chunk (binary v0 + float v1) replacing stale vectors.
    /// For a non-trainable provider — or a reopened-from-basis corpus — it is a
    /// vector refresh with no basis row written. Deterministic (pass `now`).
    public func reindex(now: Date) async throws

    /// Remove a canonical content id from BM25 + the Corpus-owned vector scope.
    /// In GLK this removes derived rows only; LocusKit Drawer content is untouched.
    public func remove(sourceID: String) async throws

    /// STANDALONE 1.0 COMPATIBILITY: total chunks in BundleStore.
    public func count() async throws -> Int

    /// STANDALONE 1.0 COMPATIBILITY: resolve chunk IDs to document IDs, from the
    /// warm in-memory chunkSourceMap (no table scan; unmapped IDs absent
    /// from the result). Retired from GLK in 1.1 because every Corpus result is
    /// already keyed by Drawer id; retained only for standalone 1.0 callers.
    /// Rust: `source_ids_for_chunks(&[Uuid])`.
    public func sourceIDs(forChunkIDs ids: [UUID]) -> [UUID: String]

    // Estate lifecycle primitive:
    /// Destroy CorpusKit's derived recall index. Clears BM25, CorpusKit-owned
    /// id maps, CorpusKit-scoped vectors, provider basis/count rows, and
    /// checkpoints. It MUST NOT delete canonical documents/Drawers or vectors
    /// owned by other GLK lanes, and MUST NOT call an unqualified
    /// `destroyAllVectors`. Standalone BundleStore rows are preserved. Called by
    /// GeniusLocusKit.destroy(storage:corpusStorage:handle:).
    public func destroyRecallIndex() async throws

    /// STANDALONE ONLY: scrub verbatim content owned by CorpusKit, then remove
    /// its derived recall state. In GLK, erasure begins in LocusKit and GLK calls
    /// `remove` for the Drawer id; CorpusKit never scrubs or owns Drawer text.
    /// Rust: `expunge(&self, source_id)`.
    public func expunge(sourceID: String) async throws

    /// Canonical-content-aggregated BM25 recall. GLK rows are Drawer-keyed
    /// directly; standalone passage scores fold to their document id. Used by
    /// the Hunter BM25 prefilter path (corpus lane).
    /// Empty query or limit ≤ 0 returns []. Rust: `bm25_top_k_by_source`.
    public func bm25TopKBySource(query: String, limit: Int) async throws -> [(sourceID: String, score: Float)]

    /// All canonical content IDs represented in the derived Corpus index. In
    /// GLK this is read from index/checkpoint state, not BundleStore, and is used
    /// only for reconciliation with the injected content source.
    /// Rust: `indexed_source_ids() -> HashSet<String>`.
    public func indexedSourceIDs() async throws -> Set<String>

    /// STANDALONE compatibility roots over CorpusKit-owned content. GLK uses the
    /// LocusKit/GLK content and composition roots; it does not create a second
    /// Corpus content Merkle identity.
    public func corpusMerkleRoot(for sourceID: String) async throws -> MerkleRoot
    public func globalCorpusMerkleRoot() async throws -> MerkleRoot

    // Composition seam (GLK/NeuronKit reach these through the Corpus, not around it):

    /// The estate's shared VectorStore, owned by this Corpus. The composition
    /// layer (GeniusLocusKit) registers this instance as the estate's shared
    /// vector lane instead of constructing a second VectorStore over the same
    /// table. One store, one resident array, one on-disk sidecar.
    /// Rust: `shared_vector_store(&self) -> Arc<VectorStore>`.
    public var sharedVectorStore: VectorStore

    /// Embed the query text via the default provider (models[0]) and return the
    /// binary Engram. Used by GLK composition; not part of the sealed-Corpus
    /// four-verb SDK surface (SPEC B-8 applies to `recall`, not to this seam).
    /// Rust: `embed(&self, text) -> CorpusKitResult<Engram>`.
    public func embed(_ text: String) async throws -> Engram

    /// Float-lane embed via the default provider. Returns the pooled float
    /// vector before SimHash projection. Rust: `embed_float`.
    public func embedFloat(_ text: String) async throws -> [Float]

    /// `true` when the default provider supports the float lane (the on-device
    /// CoreML / host-inference lane). `false` for `.deterministic`.
    /// Rust: `supports_float(&self) -> bool`.
    public var supportsFloat: Bool

    /// The modelID of the default provider (models[0]). Rust: `model_id() -> &str`.
    public var modelID: String
}

/// Persistence for a trained provider's serialized basis blob (mission 6a-ii-β).
/// One row per (modelID, modelVersion). Lives in CorpusKit core; never imports
/// CorpusKitProviders (the blob bytes are opaque here).
public actor BasisStore {
    /// Additive schema (kit-ID "CorpusKitBasis", version 2): corpus_provider_basis(
    /// model_id TEXT, model_version TEXT, basis BLOB, trained_at TIMESTAMP/ISO8601,
    /// trained_chunk_count INTEGER, ext JSON nullable — the forward-compatible ext-slot contract forward-compat slot,
    /// inert in 1.0), PK (model_id, model_version). NO Bool columns; dates TEXT ISO8601.
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
    /// STANDALONE 1.0 compatibility constructor. Construct via migrate() to apply
    /// CorpusKit-owned content plus derived schemas. The § 1.1 attached constructor
    /// accepts Arc<dyn CorpusContentSource> and omits content/chunk schemas.
    /// LOAD-ON-OPEN: when the model is
    /// trainable AND a basis was persisted for its (model_id, model_version), the
    /// trained provider is reconstructed from that blob (trained-ready on open).
    pub fn open(storage: Arc<dyn Storage>, model: EmbeddingModelConfig) -> CorpusKitResult<Self>;

    /// now_millis: Unix epoch in milliseconds (caller-supplied for determinism).
    /// FIRST-INGEST AUTO-TRAIN: a trainable provider with no persisted basis
    /// trains a fresh basis on the first ingest; later ingests fold in (no retrain).
    /// STANDALONE 1.0 compatibility; unavailable in attached GLK mode.
    pub fn ingest(&self, text: &str, source_id: &str, now_millis: i64) -> CorpusKitResult<()>;
    /// STANDALONE 1.0 compatibility. The § 1.1 recall returns Vec<CorpusHit>.
    pub fn recall(&self, query: &str, limit: usize, now_millis: i64) -> CorpusKitResult<Vec<ScoredChunk>>;

    /// Attached/GLK queue payload contains identity and revision metadata only.
    pub fn enqueue_source_change(&self, change: CorpusContentChange) -> CorpusKitResult<()>;

    /// Retrain the embedding basis on the full corpus and re-embed every index
    /// unit (one Drawer per unit in GLK; document or passage in standalone mode)
    /// (mission 6a-ii-β). Trainable provider: trains a FRESH basis (reconstructed
    /// from the empty-basis blob — train_on_corpus is additive), UPSERTs it into
    /// corpus_provider_basis, re-embeds every chunk replacing stale vectors.
    /// Non-trainable / reopened-from-basis: vector refresh, no basis row.
    /// now_millis is the only clock source (deterministic).
    pub fn reindex(&self, now_millis: i64) -> CorpusKitResult<()>;

    pub fn remove(&self, source_id: &str) -> CorpusKitResult<()>;
    pub fn count(&self) -> CorpusKitResult<usize>;

    /// STANDALONE ONLY: scrub CorpusKit-owned text then remove from recall.
    /// GLK erasure is owned by LocusKit/GLK. Swift: `expunge(sourceID:)`.
    pub fn expunge(&self, source_id: &str) -> CorpusKitResult<()>;

    /// Source-aggregated BM25 recall. Swift: `bm25TopKBySource(query:limit:)`.
    pub fn bm25_top_k_by_source(&self, query: &str, limit: usize) -> Vec<(String, f32)>;

    /// Canonical IDs represented by the derived index; GLK does not read a
    /// BundleStore. Swift: `indexedSourceIDs()`.
    pub fn indexed_source_ids(&self) -> CorpusKitResult<std::collections::HashSet<String>>;

    /// STANDALONE content roots. GLK uses LocusKit/GLK content roots.
    pub fn corpus_merkle_root(&self, source_id: &str) -> CorpusKitResult<MerkleRoot>;
    pub fn global_corpus_merkle_root(&self) -> CorpusKitResult<MerkleRoot>;

    // Composition seam:
    pub fn shared_vector_store(&self) -> Arc<VectorStore>;
    pub fn embed(&self, text: &str) -> CorpusKitResult<engram_lib::Engram>;
    pub fn embed_float(&self, text: &str) -> CorpusKitResult<Vec<f32>>;
    pub fn supports_float(&self) -> bool;
    pub fn model_id(&self) -> &str;

    // Estate lifecycle primitive:
    /// Clear BM25 + CorpusKit id maps + CorpusKit-scoped vectors + basis/count
    /// rows and checkpoints. Preserve canonical content and unrelated GLK vectors;
    /// an unqualified destroy-all-vectors operation is forbidden.
    pub fn destroy_recall_index(&self) -> CorpusKitResult<()>;

    // Rust-only bulk-import path (no Swift counterpart):
    // `ingest_batch_import` uses a sharded phase-P/phase-S pipeline that
    // parallelizes BM25 shard writes and embeds in private shard SQLite files
    // before merging — distinct from `ingest_batch`'s serial-write bounded pool.
    // The queue variants mirror it: `enqueue_ingest_batch_import` /
    // `import_queue_depth`. Swift handles large imports through `ingestBatch`
    // directly; these Rust extensions exist for the Rust MCP server import path.
    pub fn ingest_batch_import(&self, items: &[(String, String, i64)]) -> CorpusKitResult<()>;
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
    /// trained_at TIMESTAMP/ISO8601, trained_chunk_count INTEGER, ext JSON nullable
    /// — the forward-compatible ext-slot contract forward-compat slot, inert in 1.0), PK (model_id, model_version).
    /// kit-ID "CorpusKitBasis", version 2. No Bool columns; dates TEXT ISO8601.
    pub fn schema_declaration() -> SchemaDeclaration;
    pub fn new(storage: Arc<dyn Storage>) -> Self;
    pub fn upsert(&self, row: &PersistedBasis) -> CorpusKitResult<()>;
    pub fn load(&self, model_id: &str, model_version: &str) -> CorpusKitResult<Option<PersistedBasis>>;
    pub fn delete_all(&self) -> CorpusKitResult<()>;
}
```

### `RemovedSourceStore` (standalone 1.0 compatibility)

Standalone persistence for source IDs whose recall has been suppressed by
`Corpus.remove`. Because `BundleStore.chunks` is append-only (I-2), a reindex
would re-embed and re-index a removed source's chunks, resurrecting it in
recall. `RemovedSourceStore` records which sources are removed so every rebuild
path (reindex, InvertedIndexStore reload) can exclude them. A source is
reactivated when it is re-ingested: `Corpus.ingest` calls `clearRemoved` before
inserting new chunks, so a later reindex includes the source again.

Schema: `removed_sources(source_id TEXT PK, removed_at TEXT ISO8601)`.
Kit-ID "CorpusKitRemovedSources", version 1. No Bool columns; dates TEXT
ISO8601. `appendOnly` is false — a reactivation deletes the row.

**Swift:**

```swift
public actor RemovedSourceStore {
    public static let schemaDeclaration: SchemaDeclaration  // kit-ID "CorpusKitRemovedSources", v1
    public init(storage: any Storage)
    /// Record a removal (UPSERT on source_id PK). `now` is caller-supplied (determinism).
    public func markRemoved(_ sourceID: String, now: Date) async throws
    /// Reactivate: delete the removed row so future rebuilds include the source.
    public func clearRemoved(_ sourceID: String) async throws
    /// The full set of removed source IDs (the active-chunk filter reads this).
    public func removedIDs() async throws -> Set<String>
    /// Delete every removed-source row (used by Corpus.destroyRecallIndex()).
    public func deleteAll() async throws
}
```

**Rust:**

```rust
pub struct RemovedSourceStore { /* storage: Arc<dyn Storage> */ }
impl RemovedSourceStore {
    pub fn schema_declaration() -> SchemaDeclaration;  // kit-ID "CorpusKitRemovedSources", v1
    pub fn new(storage: Arc<dyn Storage>) -> Self;
    pub fn mark_removed(&self, source_id: &str, now_secs: i64) -> CorpusKitResult<()>;
    pub fn clear_removed(&self, source_id: &str) -> CorpusKitResult<()>;
    pub fn removed_ids(&self) -> CorpusKitResult<HashSet<String>>;
    pub fn delete_all(&self) -> CorpusKitResult<()>;
}
```

Both ports are at parity for standalone compatibility. A GLK-composed Corpus
does not open this content-lifecycle table; it derives active membership from
LocusKit changes and its own Drawer-keyed checkpoint/index state. A standalone
`Corpus` owns the `RemovedSourceStore` instance
internally and drives it through `remove` / `expunge` / `ingest` / `reindex` /
`destroyRecallIndex`; external callers do not hold a reference to it directly.

---

The Rust `TrainableEmbeddingBasis` trait gains an additive
`reconstruct_trainable_basis(&self, basis) -> Result<Box<dyn TrainableEmbeddingBasis>>`
sibling of `reconstruct_basis` (the trainable-returning reconstruct the Corpus
needs to rebuild a fresh provider for `reindex`/first-ingest, since Rust has no
runtime trait-object downcast and `train_on_corpus` is additive). Swift gets this
for free via its runtime `as? TrainableEmbeddingBasis` cast on the reconstructed
provider, so no Swift protocol change is required.

---

## § 8 — Examples

The example below exercises standalone CorpusKit's 1.0 compatibility surface.
GLK composition uses the § 1.1 attached-content surface and does not call
`Chunker`, `BundleStore`, or `HybridRecall.recall` directly.

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
**Accepted target** = normative 1.1 surface awaiting implementation;
**Exempt** = Apple-platform binding, no Rust counterpart by design.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Canonical content identity | `CorpusContentID` | `CorpusContentId` | public alias / pub alias | String identity; GLK value is exactly `Drawer.id` | shared content-source fixture | Accepted target |
| Content source | `CorpusContentSource` | `CorpusContentSource` | public protocol / pub trait | read-by-id plus cursor-based changes; same values and error semantics | source-adapter conformance suite | Accepted target |
| Standalone content store | `CorpusContentStore` | `CorpusContentStore` | public protocol / pub trait | extends source with put/remove; unavailable in attached mode | standalone content conformance suite | Accepted target |
| Index-unit policy | `CorpusIndexUnitPolicy` | `CorpusIndexUnitPolicy` | public enum / pub enum | whole content in GLK; optional token-budgeted range-only passages in standalone | policy conformance suite | Accepted target |
| Canonical recall result | `CorpusHit` | `CorpusHit` | public struct / pub struct | identical canonical content id, fused scores, range evidence | recall conformance suite | Accepted target |
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
| CorpusKitError | `CorpusKitError` (`CorpusKitError.swift:5`) | `CorpusKitError` (`error.rs:4`) | public enum / pub enum | 1.1 target adds matching content-unavailable, mode-violation, and migration-incomplete cases to the existing six; Rust adds `Display`+`Error` impls | target error parity suite | Accepted target |
| CorpusKitResult | (Swift uses `async throws`) | `CorpusKitResult` (`error.rs:28`) | — / pub type alias | Rust `Result<T, CorpusKitError>` alias ↔ Swift typed `throws` — sanctioned error-channel idiom (Swift has no Result-alias surface) | `chunk_tests.rs` / `corpus_tests.rs` (result threaded through) | Confirmed |
| EmbeddingModel selector | `EmbeddingModel` (`CorpusKit.swift:40`) | `EmbeddingModelConfig` (`corpus.rs:56`) | public enum / pub enum | Swift four cases (`deterministic`/`miniLM`/`mpNet`/`embeddingGemma` with async closure); Rust four cases (`Deterministic`/`MiniLM`/`MPNet`/`EmbeddingGemma` with sync `NamedInferenceFn`); async↔sync seam is sanctioned (Rust has no async runtime). Projection seeds byte-identical across ports. | `CorpusTests.swift` / `corpus_tests.rs` + `embedding_conformance_tests.rs` | Confirmed |
| Corpus | `Corpus` (`CorpusKit.swift:99`) | `Corpus` (`corpus.rs:113`) | public actor / pub struct | Swift `actor` (`init async throws`) / Rust `struct` (`open()`, `bm25: Mutex<BM25Index>`); Swift `async throws`+`Date` ↔ Rust sync `CorpusKitResult`+`now_millis` — sanctioned actor↔owned-state + async↔sync seam | `CorpusTests.swift` / `corpus_tests.rs` | Confirmed |
| DeterministicTokenizer | `DeterministicTokenizer` (`DeterministicTokenizer.swift:16`) | `DeterministicTokenizer` (`rust-providers/.../deterministic_tokenizer.rs:34`) | public struct / pub struct | identical FNV-1a fold; Swift default-arg init ↔ Rust `new`/`with_parameters`/`Default`; lives in providers target both ports | `ProvidersTests.swift` / `deterministic_tokenizer_tests.rs` | Confirmed |
| MiniLMTextProvider | `MiniLMTextProvider` (`MiniLMTextProvider.swift:41`) | `MiniLMTextProvider` (`rust-providers/src/text_providers.rs`) | public struct / pub struct | Both ports: model_id "minilm-v6", projectionSeed 0x4D49_4E4C_4D5F_7631, FNV-1a tokenizer (vocab 30522, max 128), host inference closure (Swift `@Sendable ([Int32]) async throws -> [Float]` ↔ Rust sync `InferenceFn`); async↔sync seam is sanctioned. Conforms to VectorKit `EmbeddingProvider`. Bit-identical engram for shared (text → pooled vector) (SPEC C-8b) | `EmbeddingProviderConformanceTests.swift` + `embedding_provider_vectors.json` / `embedding_conformance_tests.rs` | Confirmed |
| MPNetTextProvider | `MPNetTextProvider` (`MPNetTextProvider.swift:31`) | `MPNetTextProvider` (`rust-providers/src/text_providers.rs`) | public struct / pub struct | Both ports: model_id "mpnet-base-v2", projectionSeed 0x4D50_4E45_545F_7631, FNV-1a tokenizer (vocab 30522, max 128), host inference closure (same async↔sync seam). Conforms to VectorKit `EmbeddingProvider`. Bit-identical engram for shared pooled vector (SPEC C-8b) | `EmbeddingProviderConformanceTests.swift` + `embedding_provider_vectors.json` / `embedding_conformance_tests.rs` | Confirmed |
| EmbeddingGemmaProvider | `EmbeddingGemmaProvider` (`EmbeddingGemmaProvider.swift:33`) | `EmbeddingGemmaProvider` (`rust-providers/src/text_providers.rs`) | public struct / pub struct | Both ports: model_id "embedding-gemma-300m", projectionSeed 0x454D_4247_4D5F_7631, FNV-1a tokenizer (vocab 256000, max 2048), host inference closure (same async↔sync seam). Conforms to VectorKit `EmbeddingProvider`. Bit-identical engram for shared pooled vector (SPEC C-8b) | `EmbeddingProviderConformanceTests.swift` + `embedding_provider_vectors.json` / `embedding_conformance_tests.rs` | Confirmed |
| Telemetry — ingest | `Intellectus.report` ×2 in `BundleStore.insert` emitting `corpuskit.ingest.latency_ms` + `corpuskit.ingest.chunk_count` | `report!` ×2 in `BundleStore::insert` | internal emit / internal emit | identical metric names, tags (`kit=CorpusKit`), value semantics; SPEC § 7.2 | `CorpusKitTelemetryTests.swift` §1-§4 / `corpuskit_telemetry_tests.rs` §1-§4 | Confirmed |
| Telemetry — recall | `Intellectus.report` ×4 in `HybridRecall.recall` emitting `corpuskit.recall.*` | `report!` ×4 in `hybrid_recall::recall` | internal emit / internal emit | identical metric names, tags (`kit=CorpusKit`, `model_id`), value semantics; SPEC § 7.2 | `CorpusKitTelemetryTests.swift` §1-§4 / `corpuskit_telemetry_tests.rs` §1-§4 | Confirmed |
| Sparse-lane outcome | `FloatLaneOutcome` (`CorpusKit.swift:45`) | `FloatLaneOutcome` (`corpus.rs:67`) | both public/pub | standalone 1.0 compatibility shape carries `ScoredChunk`; the 1.1 attached Corpus surface exposes canonical `CorpusHit` outcomes instead | legacy corpus tests + target recall suite | Confirmed legacy / Accepted target |
| BM25 weighting (Lane D) | `BM25Weighting` (`BM25Weighting.swift:71`) | `BM25Weighting` (`engine/bm25_weighting.rs:69`) | both public/pub | Swift caseless-enum namespace (static methods `weight`, `quantizeImpact`) / Rust unit struct with associated methods — sanctioned stateless-namespace idiom; weight computation and impact quantization are byte-identical | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| Impact posting | `ImpactPosting` (`Engine/SparseTypes.swift:57`) | `ImpactPosting` (`engine/sparse_types.rs:32`) | both public/pub | identical 2-field struct: `termID: UInt32`/`term_id: u32`, `impact: Int32`/`impact: i32` — one (termID, impact) entry in the sorted impact list | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| Sparse search result | `SparseHit` (`Engine/SparseTypes.swift:95`) | `SparseHit` (`engine/sparse_types.rs:53`) | both public/pub | identical 2-field struct: `id: String`, `score: Float`/`f32` — one ranked BM25 result | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| Fused (sparse+dense) hit | `FusedHit` (`Engine/SparseTypes.swift:137`) | `FusedHit` (`engine/sparse_types.rs:76`) | both public/pub | identical 3-field struct: `id: String`, `score: Float`/`f32`, `perLane: [LaneTag: Float]`/`per_lane: HashMap<LaneTag, f32>` — merged result from RRF lane fusion; `perLane`/`per_lane` carries per-lane score contributions | `HybridRecallTests.swift` / `hybrid_recall_tests.rs` | Confirmed |
| Inverted index | `InvertedIndex` (`Engine/InvertedIndex.swift:116`) | `InvertedIndex` (`engine/inverted_index.rs:98`) | both public/pub | identical postings store: Swift `struct` / Rust `struct`; both implement `topK(query:k:)` / `top_k(query, k, algorithm)` against a sorted impact list; Rust adds `Algorithm` enum (WAND / BlockMaxWand) as a query-time parameter (Swift uses WAND implicitly) | `BM25Tests.swift` / `bm25_tests.rs` | Confirmed |
| Inverted index store | `InvertedIndexStore` (`Engine/InvertedIndexStore.swift:47`) | `InvertedIndexStore` (`engine/inverted_index_store.rs:29`) | both public/pub | Swift `actor` / Rust owned-state struct; 1.1 build path enumerates `CorpusContentSource`, while the `BundleStore` path remains standalone 1.0 compatibility only | legacy BM25 tests + target source rebuild suite | Confirmed legacy / Accepted target |
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

### 1.18.0 -- 2026-07-22

- Attached maintained counts now use a published provider base plus
  reference-only canonical-content deltas. Queue commits no longer serialize
  the complete RI/PPMI counts blobs; provider publication compacts deltas
  atomically. The delta table stores no Drawer text. Document and vocabulary
  anchors commit transactionally with each admitted reference, remain
  nondecreasing across revision/reopen cycles, and drive identical governor
  decisions before and after restart.
- Full `CorpusContentEngine.reindex` operations defer resident-index
  publication across the corpus rewrite and publish once at completion.
- Recorded the FDC cross-port tokenizer and macOS writable-artifact contract.
- Historical shared basis fixtures remain pinned to their 1.0 envelope while
  production trainable-provider defaults remain 1.1.

### 1.17.0 -- 2026-07-20

- Added the shared `CorpusContentSource`/`CorpusContentStore` engine boundary,
  operating modes, canonical `CorpusHit`, and whole-content/range-only passage
  policies for the accepted 1.1 target.
- Limited `Chunk`, `ScoredChunk`, `Chunker`, and `BundleStore` to standalone
  1.0 compatibility; GLK uses no passage content table or chunk identity.
- Added source-change queue payloads, attached/standalone schema profiles, and
  Corpus-owned selective teardown/migration contracts.

### 1.15.0 -- 2026-07-16
Surface audit: documented the full public API of both ports.

**Factual correction:** `Corpus.setOnEncoded(_:)` (method) corrected to
`Corpus.onEncoded` (Swift `var`) — the property form is what the Swift source
ships. Rust retains `set_on_encoded<F>(&self, callback: F)` (a method), which is
noted alongside the Swift var.

**Added § 1 layout entries** for source files missing from the layout table:
`BasisStore.swift`, `CorpusProviderCountsStore.swift`, `RemovedSourceStore.swift`,
`CorpusIngestQueue.swift`, `TrainableEmbeddingBasis.swift`, `Engine/`, and all
distributional-provider source files.

**Added `RemovedSourceStore`** — the public actor (Swift) / struct (Rust) that
persists the set of recall-suppressed source IDs. Schema kit-ID
"CorpusKitRemovedSources" v1 (`removed_sources(source_id TEXT PK, removed_at TEXT
ISO8601)`). Four operations: `markRemoved`, `clearRemoved`, `removedIDs`,
`deleteAll`. Both ports at parity.

**Added `FDCProvider`** — the fifth default-ensemble signal, a deterministic
256-dim provider conforming to `EmbeddingProvider` (no training, no inference
closure). Public constants `fdcDimension`, `fdcProjectionSeed`, `fdcNodeVector`.

**Added distributional providers** (`RandomIndexingProvider`, `PpmiProvider`,
`LsaProvider`, `NmfProvider`) — individually documented with init params, train /
finalize, diagnostics, `releaseBasis`, and `TrainableEmbeddingBasis` surface
references. Public constants per provider (dimension, nonzeros, window, seed, rank).

**Added missing `Corpus` methods to § 7 (both ports):**
- `expunge(sourceID:)` / `expunge(source_id)` — scrub chunk text then remove from recall (SPEC B-15)
- `bm25TopKBySource(query:limit:)` / `bm25_top_k_by_source` — source-aggregated BM25 recall (Hunter BM25 prefilter lane)
- `indexedSourceIDs()` / `indexed_source_ids()` — all source IDs in BundleStore
- `corpusMerkleRoot(for:)` / `corpus_merkle_root` — delegation to BundleStore (Swift doc previously only listed this on BundleStore)
- `globalCorpusMerkleRoot()` / `global_corpus_merkle_root` — same
- `sharedVectorStore` / `shared_vector_store()` — the shared VectorStore accessor for GLK composition
- `embed(_:)` / `embed` — query embed via default provider
- `embedFloat(_:)` / `embed_float` — float-lane embed
- `supportsFloat` / `supports_float()` — float-lane capability flag
- `modelID` / `model_id()` — default provider model ID

**Added Rust-only bulk-import note:** `Corpus::ingest_batch_import` (sharded
phase-P/phase-S pipeline) and associated queue variants (`enqueue_ingest_batch_import`,
`import_queue_depth`). No Swift counterpart.

### 1.14.0 -- 2026-07-12
Additive (contradiction hunter corpus lane): `Corpus.sourceIDs(forChunkIDs:)`
(Swift) / `Corpus::source_ids_for_chunks(&[Uuid])` (Rust) — resolve chunk IDs
to their owning source (drawer) IDs from the warm in-memory chunkSourceMap.
No table scan; unmapped IDs are absent from the result. Consumer:
`GeniusLocusKit.huntContradictions` / `EstateCoordinator::hunt_contradictions`
maps the encode pipeline's chunk-keyed vector rows back to drawer pairs so the
hunter's kNN mining works on production estates (which register
`corpus.sharedVectorStore` and hold no drawer-keyed vectors). Both ports at
parity.

### 1.13.0 -- 2026-06-25
T1 (encode mode + QoS throttle): new `EncodeSpeed` enum (`foreground` /
`background`) + `Corpus.setEncodeSpeed(_:)` (Rust `set_encode_speed`). The embed
fan-out in `ingest` / `ingestBatch` is now CONCURRENCY-THROTTLED by the speed:
foreground uses all logical cores, background caps to `cores / 4` (x=4, floor 1)
so a large background import leaves ~75% of the machine free. Uniform across
platforms (`activeProcessorCount` / `available_parallelism`) and identical
Swift↔Rust (a chunked-batch fan-out replaces the prior unbounded task-per-item
spawn). Output is byte-identical regardless of speed — only scheduling changes.

### 1.12.0 -- 2026-06-25
Additive (T6 — drain status): `Corpus.ingestQueueDepth() -> (pending, inFlight)`
(Swift) / `ingest_queue_depth(&self) -> (usize, usize)` (Rust) — a read-only
probe of the ingest drain's outstanding work. OBSERVES the queue's `new/` +
`cur/` frontiers (via the new `QueueKit.pendingCount` + existing `inFlight`),
never claiming or draining; returns `(0, 0)` when no queue is mounted. Feeds the
GLK `drainStatuses` aggregation and the `moot_drain_status` MCP tool. No change
to the drain pipeline or byte-identity.

### 1.11.0 -- 2026-06-24
Documented the incremental provider-counts table (both ports). New
`CorpusProviderCountsStore` (sibling of `BasisStore`, `corpus_provider_counts`
table, one row per `(model_id, model_version)`, `PersistedCounts` /
`CountsGrowthAnchor`, `upsert` / `load` / `growthAnchor` / `deleteAll`).
`TrainableEmbeddingBasis` gains the maintained-counts seam (`addToCounts`,
`serializeCounts`, `restoreCounts`, `countsVocabularySize`); the Rust trait also
documents `reconstruct_trainable_basis`. `Corpus.maintainedVocabAnchor()` exposes
the vocab-growth anchor the autonomic governor's retrain trigger reads. The
governor's auto-reindex gate moved from a +25-chunk delta to a vocabulary-growth
trigger (NeuronKit). ADDITIVE — no existing surface changed; the counts table is
maintained on write, restored on open, persisted at batch boundaries.

### 1.10.0 -- 2026-06-24
Added two Apple NaturalLanguage embedding providers (the Apple embedding-provider contract), Swift-only
(`#if canImport(NaturalLanguage)`), no Rust counterpart (sanctioned divergence):
`NLEmbeddingProvider` (model_id "apple-nlembedding-v1", seed "APNLEMB1"
`0x4150_4E4C_454D_4231`) and `NLContextualEmbeddingProvider` (model_id
"apple-nlcontextual-v1", seed "APNLCTX1" `0x4150_4E4C_4354_5831`). Both are
item-local (stateless, no TrainableEmbeddingBasis), opt-in (not in the default
ensemble), and gracefully absent when the OS model/asset is unavailable
(embedFloat → [], never throw/crash). Added two EmbeddingModel cases
`.nlEmbedding(provider:)` / `.nlContextualEmbedding(provider:)` behind the same
`#if canImport(NaturalLanguage)` gate. Updated § 1 package layout. ADDITIVE —
no existing provider, EmbeddingModel case, or default changed.

### 1.9.0 -- 2026-06-23
Added the Corpus-owned **ingest pipeline** to § 7: `ingestBatch`,
`mountIngestQueue`, `dropIngestQueue`, `enqueueIngest`, `awaitIngestDrain`,
`drainIngestQueueOnce`, `setOnEncoded` (+ the `onEncoded` callback). A Corpus
now owns its encode queue + drain worker pool and drains itself with no
orchestrator — relocated from GeniusLocusKit's `EncodeIntake`. Rust mount/enqueue
take `&Arc<Self>`; the job payload is the internal `IngestJob` (not public).
Behaviorally specified in CORPUSKIT_SPEC § 11. Additive; no existing signature
removed.

### 1.8.0 -- 2026-06-21
BundleStore schema v2 → v3 (NT-C1, the node-integrity contract §19): all six query methods (`get`, `getMany`, `chunksForSource`, `count`, `allChunks`) now accept an `AsOfCoordinate` parameter for temporal reads (I-12); `count` accepts it for API parity but does not forward it. New `content_hash` BLOB nullable column on `chunks` (hash-on-write via HashingRowStore, I-11). New `corpus_metadata` table (source_id TEXT PK, merkle_root BLOB nullable). New public methods: `corpusMerkleRoot(for:)` / `corpus_merkle_root` returns per-corpus Merkle root (I-13), `globalCorpusMerkleRoot()` / `global_corpus_merkle_root` returns interior hash over all per-corpus roots. Updated schemaDeclaration comment from v2 to v3. Additive; no existing signature removed.

### 1.7.0 -- 2026-06-17
Schema bumps (the forward-compatible ext-slot contract): `chunks` (BundleStore, kit-ID "CorpusKit") v1 → v2 and `corpus_provider_basis` (BasisStore, kit-ID "CorpusKitBasis") v1 → v2, each gaining a nullable `.json` `ext` forward-compat slot. Both ports; inert in 1.0 (NULL / omitted on insert, never read). `chunks.ext` is distinct from the existing per-chunk `metadata` column. Updated the BundleStore / BasisStore schema concordance.

### 1.6.0 -- 2026-06-17
Added `Corpus.floatFarthestPerSignal` / `Corpus::float_farthest_per_signal`
(mission 6b-modifiers-antisim) — the per-signal dense float FARTHEST
(anti-similarity) recall. Each held signal surfaces the most DISSIMILAR sources
("find things UNLIKE this"), via `VectorStore.findFarthestFloat`, inverting the
per-source aggregation (max→min cosine) and ranking least-similar first.
floatNearestPerSignal is byte-identical and unchanged. ADDITIVE (MINOR).

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
