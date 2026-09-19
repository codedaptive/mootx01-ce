---
title: CrossEncoder Interface
version: 1.0.3
status: accepted-1.1-target
date: 2026-09-08
description: "Public API surface of the retrieval-time cross encoder across CorpusKit, its providers and GeniusLocusKit — the signatures that satisfy CROSSENCODER_SPEC.md."
spec_type: encoder
authors: MOOTx01 maintainers
languages: [swift, rust]
relates_to:
  - docs/reference/CROSSENCODER_SPEC.md
---

# CrossEncoder Interface

## § 1 — Package layout

**Swift:**

- `packages/kits/CorpusKit/Sources/CorpusKit/Encoder/CrossEncoderProfile.swift`, `PairScorer.swift`, `RerankDirective.swift` — contract
- `packages/kits/CorpusKit/Sources/CorpusKitProviders/Encoder/WordPieceTokenizer.swift` (`tokenizePair`), `CoreMLPairInference.swift`, `PairScorerFactory.swift`; `packages/kits/CorpusKit/Sources/CorpusKitProviders/ModelDirectoryResolver.swift` (profile entry) — runtime
- `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/RecallDirector/CrossEncoderStage.swift`, `CrossEncoderActivation.swift`; `GLKRecallRequest.swift`, `GLKRecallResult.swift`, `RecallDirector.swift` (insertion) — stage
- Tests: `CorpusKitTests/PairScorerTests.swift`, `PairTokenizerTests.swift`, `PairScorerFactoryTests.swift`; `GeniusLocusKitTests/CrossEncoderStageTests.swift`

**Rust:**

- `packages/kits/CorpusKit/rust/src/encoder/cross_encoder_profile.rs`, `pair_scorer.rs`, `rerank_directive.rs`
- `packages/kits/CorpusKit/rust-providers/src/pair_scorer_factory.rs`; `candle_pair_scorer.rs` (feature `candle`); `model_directory_resolver.rs` (profile entry)
- `packages/kits/GeniusLocusKit/rust/src/cross_encoder_stage.rs`; `coordinator.rs` (lifecycle, limits, insertion); `recall.rs` (fields)
- Tests: `corpus-kit/tests/pair_scorer_tests.rs`, `corpus-kit-providers/tests/pair_scorer_factory_tests.rs`, `cross_encoder_candle_tests.rs` (feature `candle`); `genius-locus-kit/tests/cross_encoder_stage_tests.rs`

**Shared fixture:** `packages/kits/SynapseKit/Tests/Fixtures/encoder/cross_encoder_parity.json`

**Packaging:** `tools/encoder-models/build-all.sh --profile minilm-cross`, `cross-encoder-models-apple.json`, `cross-encoder-models-linux.json`

## § 2 — Public types

### `CrossEncoderProfile`

One packaged cross encoder and the limits the stage runs it under (SPEC § 5.1).

**Swift:**

```swift
public struct CrossEncoderProfile: Sendable, Equatable, Codable {
    public let modelID: String            // "model_id"
    public let modelVersion: String       // "model_version"
    public let tokenizerHash: String      // "tokenizer_hash"
    public let maxSequence: Int           // "max_sequence"
    public let pool: Int
    public let head: Int
    public let spans: Int
    public let rrfK: Int                  // "rrf_k"
    public init(modelID:modelVersion:tokenizerHash:maxSequence:pool:head:spans:rrfK:)
    public var artifactName: String       // "MsMarcoMinilmL6CrossV1"
    // tokenizerHash: "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3" (sha256(vocab.txt))
    public static let minilmL6: CrossEncoderProfile
}
```

**Rust:**

```rust
pub struct CrossEncoderProfile {
    pub model_id: String, pub model_version: String, pub tokenizer_hash: String,
    pub max_sequence: usize, pub pool: usize, pub head: usize, pub spans: usize, pub rrf_k: usize,
}
impl CrossEncoderProfile { pub fn artifact_name(&self) -> String; pub fn minilm_l6() -> Self; }
```

### `PairScorer`, `PairInference`, `ProviderPairScorer`

The pair-scoring contract (SPEC § 5.2).

**Swift:**

```swift
public protocol PairScorer: Sendable {
    var profile: CrossEncoderProfile { get }
    var backend: String { get }
    func score(query: String, spans: [String]) async throws -> [Float]
}
public protocol PairInference: Sendable {
    var backend: String { get }
    /// The compiled fixed sequence length for this inference runtime, when
    /// the model has a static input shape; nil when the model accepts any length.
    /// `PairScorerFactory.make` reads this to clamp the tokenizer's `maxTokens`.
    var fixedLength: Int? { get }
    func logits(query: String, spans: [String]) async throws -> [Float]
}
public struct ProviderPairScorer: PairScorer {
    public let profile: CrossEncoderProfile
    public let inference: any PairInference
    public let batchSize: Int
    public var backend: String { inference.backend }
    public static let defaultBatchSize = 8
    public init(profile: CrossEncoderProfile, inference: any PairInference, batchSize: Int = 8)
}
```

**Rust:**

```rust
pub trait PairScorer: Send + Sync {
    fn profile(&self) -> &CrossEncoderProfile;
    fn backend(&self) -> &str;
    fn score(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError>;
}
pub trait PairInference: Send + Sync {
    fn backend(&self) -> &str;
    fn logits(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError>;
}
pub struct ProviderPairScorer;   // new(profile, Box<dyn PairInference>, batch_size), batch_size()
pub const DEFAULT_PAIR_BATCH_SIZE: usize = 8;
```

### `RerankDirective`

The cross-encoder portion of a recall strategy decision (SPEC § 5.8).

**Swift:**

```swift
public struct RerankDirective: Sendable, Equatable, Codable {
    public enum Action: String, Sendable, Codable { case bypass, apply }
    public let action: Action
    public let profileID: String          // "profile_id"
    public let reason: String?
    public init(action: Action, profileID: String, reason: String? = nil)
    public static func apply(reason: String? = nil) -> RerankDirective    // minilmL6
    public static func bypass(reason: String? = nil) -> RerankDirective
}
```

**Rust:**

```rust
pub enum RerankAction { Bypass, Apply }                    // serde "bypass" | "apply"
pub struct RerankDirective { pub action: RerankAction, pub profile_id: String, pub reason: Option<String> }
impl RerankDirective { pub fn apply(reason: Option<&str>) -> Self; pub fn bypass(reason: Option<&str>) -> Self; }
```

### `PairTokens` (Swift providers)

```swift
public struct PairTokens: Sendable, Equatable { public let ids: [Int32]; public let tokenTypeIDs: [Int32] }
extension WordPieceTokenizer { public func tokenizePair(_ query: String, _ span: String) -> PairTokens }
```

### `CrossEncoderLimits`, `CrossEncoderReport` (GeniusLocusKit)

**Swift:**

```swift
public struct CrossEncoderLimits: Sendable, Equatable {
    public let pool: Int, head: Int, spans: Int          // head clamped to pool
    public init(pool: Int, head: Int, spans: Int)
    public init(profile: CrossEncoderProfile)
}
public struct CrossEncoderReport: Sendable, Equatable {
    public enum Status: String, Sendable { case applied, bypassed, degraded }
    public let status: Status, requested: Bool, reason: String?, profileID: String
    public let modelVersion: String?, backend: String?
    public let pool: Int, head: Int, spans: Int, scored: Int
    public let coldLoad: Bool, stageMillis: Int?
    public var summaryLine: String
    public init(status: Status, requested: Bool, reason: String?, profileID: String,
                modelVersion: String?, backend: String?,
                pool: Int, head: Int, spans: Int, scored: Int,
                coldLoad: Bool, stageMillis: Int?)
}
```

**Rust:**

```rust
pub struct CrossEncoderLimits { pub pool: usize, pub head: usize, pub spans: usize }
impl CrossEncoderLimits { pub fn new(pool, head, spans) -> Self; pub fn from_profile(&CrossEncoderProfile) -> Self; }
pub enum CrossEncoderStatus { Applied, Bypassed, Degraded }      // raw_value()
pub struct CrossEncoderReport { /* same fields, snake_case */ }
impl CrossEncoderReport { pub fn bypassed(&RerankDirective) -> Self; pub fn degraded(&RerankDirective, &str, Option<CrossEncoderLimits>) -> Self; pub fn summary_line(&self) -> String; }
```

## § 3 — Public functions

### Stage (pure), GeniusLocusKit

**Swift:**

```swift
public enum CrossEncoderStage {
    public enum Reason { capabilityOff, profileUnknown, modelUnavailable, noQueryText, scorerFailed }   // String constants
    public static let degradedStage = "recall.cross_encoder_degraded"
    public static func fuse(incoming: [String], head: Int, logits: [String: [Float]], rrfK: Int) -> [String]
    public static func selectSpans(content: String, rows: [SpanRerankVector]?, queryVector: [Float]?,
                                   limit: Int, windowWords: Int, overlapDivisor: Int) -> [String]
}
```

**Rust:**

```rust
pub mod cross_encoder_stage {
    pub mod reason { CAPABILITY_OFF, PROFILE_UNKNOWN, MODEL_UNAVAILABLE, NO_QUERY_TEXT, SCORER_FAILED }
    pub const DEGRADED_STAGE: &str = "recall.cross_encoder_degraded";
    pub fn fuse(incoming: &[String], head: usize, logits: &HashMap<String, Vec<f32>>, rrf_k: usize) -> Vec<String>;
    pub fn select_spans(content: &str, rows: Option<&[SpanRerankVector]>, query_vector: Option<&[f32]>,
                        limit: usize, window_words: usize, overlap_divisor: usize) -> Vec<String>;
    pub fn reorder(hits: Vec<RecallHit>, pool: usize, order: &[String]) -> Vec<RecallHit>;
}
```

### Request and result fields, GeniusLocusKit

**Swift:** `GLKRecallRequest.rerankDirective: RerankDirective?` (trailing defaulted init parameter `rerankDirective: RerankDirective? = nil`); `GLKRecallResult.degradedStages: [String]` (the stage appends `CrossEncoderStage.degradedStage` on degrade; `replacing(request:hits:degradedStages:crossEncoder:)`); `GLKRecallResult.crossEncoder: CrossEncoderReport?` (defaulted init parameter).

**Rust:** `GLKRecallRequest.rerank_directive: Option<RerankDirective>` (`new()` sets `None`; builder `with_rerank_directive(RerankDirective) -> Self`); `GLKRecallResult.degraded_stages: Vec<String>`; `GLKRecallResult.cross_encoder: Option<CrossEncoderReport>`.

### Lifecycle and limits, GeniusLocusKit

**Swift:**

```swift
extension GeniusLocusKit {
    static var crossEncoderPoolMetaKey: String      // "cross_encoder_pool"
    static var crossEncoderHeadMetaKey: String      // "cross_encoder_head"
    static var crossEncoderSpansMetaKey: String     // "cross_encoder_spans"
    static var crossEncoderProfileMetaKey: String   // "cross_encoder_profile"
    static var packagedCrossEncoderProfiles: [String: CrossEncoderProfile]
    func registerPairScorer(_ scorer: any PairScorer, for handle: EstateHandle)
    func isPairScorerRegistered(for handle: EstateHandle) -> Bool
    func provisionCrossEncoderLimits(pool: Int, head: Int, spans: Int, for handle: EstateHandle) async throws
    func provisionedCrossEncoderLimits(profile: CrossEncoderProfile, for handle: EstateHandle) async -> CrossEncoderLimits
}
```

**Rust:**

```rust
impl EstateCoordinator {
    pub const CROSS_ENCODER_POOL_META_KEY / HEAD_META_KEY / SPANS_META_KEY / PROFILE_META_KEY: &str;
    pub fn packaged_cross_encoder_profile(profile_id: &str) -> Option<CrossEncoderProfile>;
    pub fn register_pair_scorer(&mut self, handle: &EstateHandle, scorer: Arc<dyn PairScorer>);
    pub fn is_pair_scorer_registered(&self, handle: &EstateHandle) -> bool;
    pub fn provision_cross_encoder_limits(&self, handle: &EstateHandle, pool: usize, head: usize, spans: usize) -> Result<(), VerbDispatchError>;
    pub fn provisioned_cross_encoder_limits(&self, handle: &EstateHandle, profile: &CrossEncoderProfile) -> CrossEncoderLimits;
    pub fn pair_scorer_for(&self, handle: &EstateHandle, profile: &CrossEncoderProfile) -> Result<(Arc<dyn PairScorer>, bool), String>;
}
```

### Runtime factories, providers

**Swift:**

```swift
public enum PairScorerFactory {
    /// Production API. No seam parameter; see `#if DEBUG` overload below.
    public static func make(
        profile: CrossEncoderProfile,
        modelDirectory: URL,
        batchSize: Int = 8
    ) throws -> any PairScorer
}

// Test seam — `#if DEBUG` only, not product API.
// Matches the Rust port: the Rust factory carries no unconditional public seam.
// An injected inference brings its own tokenizer; the directory and vocabulary
// guards are bypassed. The seam takes precedence over the CoreML resolver.
#if DEBUG
extension PairScorerFactory {
    public static func make(
        profile: CrossEncoderProfile,
        modelDirectory: URL,
        batchSize: Int = 8,
        makeInference: @escaping (URL, WordPieceTokenizer) throws -> any PairInference
    ) throws -> any PairScorer
}
#endif
#if canImport(CoreML)
public struct CoreMLPairInference: PairInference {
    public static func make(modelDirectory: URL, tokenizer: WordPieceTokenizer) throws -> CoreMLPairInference
    public let tokenizer: WordPieceTokenizer
    // fixedLength: reads the compiled `input_ids` sequence ceiling from the
    // CoreML model shape constraint. nil when the model has no shape constraint.
    // The Rust factory derives the same ceiling from max_position_embeddings in
    // config.json — same model, different derivation source.
    public var fixedLength: Int? { get }
    func rebuilding(tokenizer: WordPieceTokenizer) -> CoreMLPairInference
}
#endif
```

**Rust:**

```rust
pub struct PairScorerFactory;
impl PairScorerFactory {
    pub fn make(profile: &CrossEncoderProfile, model_dir: &Path) -> Result<Box<dyn PairScorer>, EncoderError>;
    pub fn make_with_batch(profile: &CrossEncoderProfile, model_dir: &Path, batch_size: usize) -> Result<Box<dyn PairScorer>, EncoderError>;
}
// feature "candle":
pub struct CandlePairScorer;   // load(model_dir, max_sequence), assets_present(model_dir), encode_pair(query, span)
pub fn pair_tokenizer(model_dir: &Path, max_sequence: usize) -> Result<Tokenizer, String>;
pub fn encode_pair(tokenizer: &Tokenizer, query: &str, span: &str) -> Result<(Vec<u32>, Vec<u32>), String>;
pub const REQUIRED_FILES: [&str; 3];
pub const CROSS_ENCODER_MODEL_ID: &str;   // model_directory_resolver
```

## § 4 — Errors

`EncoderError` (CorpusKit) for factory and scorer failures; the stage never
raises — see SPEC § 6 for the degrade vocabulary.

## § 5 — Conformance test entry points

- Fuse parity: `CrossEncoderFuseParityTests` (Swift), `every_fixture_case_reproduces_the_lab_order` (Rust) over the shared fixture.
- Pair ids: `PairTokenizerTests` (Swift, shared fixture), `pair_tokens_match_the_shared_fixture` (Rust, feature `candle`, `MOOT_CROSS_ENCODER_ASSETS`).
- Native logits: `PackagedCrossEncoderTests` (Swift), `loaded_classifier_reproduces_the_reference_logits` (Rust); both read `MOOT_CROSS_ENCODER_ASSETS` and skip when unset.
- Stage in recall: `CrossEncoderStageDirectorTests` (Swift; the packaged case needs `--traits CrossEncoder`), `cross_encoder_stage_tests.rs` (Rust; the packaged case needs `--features cross-encoder`).

## § 6 — Examples (optional)

```swift
let request = GLKRecallRequest(frame: frame, mode: .unionBest, scoring: .matrixAware, limit: 20,
                               fallback: .failClosed, queryText: query, origin: .internal,
                               rerankDirective: .apply(reason: "explicit"))
let result = try await kit.recall(handle, request)
print(result.crossEncoder?.summaryLine ?? "")
// cross_encoder: applied profile=ms-marco-minilm-l6-cross-v1 reason=explicit backend=coreml pool=50 head=30 scored=30 cold_load ms=412
```

## Changelog

### 1.0.3 -- 2026-09-08

- `PairScorerFactory.make(makeInference:)`: gated behind `#if DEBUG` (test seam,
  not product API). The Rust factory carries no unconditional public seam; Swift
  now matches. The production overload `make(profile:modelDirectory:batchSize:)`
  is unchanged.
- `PairScorerFactory` (Swift): injected-constructor branch now runs before the
  directory and vocabulary guards. An injected inference brings its own tokenizer;
  the guards apply only to the CoreML production path. Fixes the clamp-branch
  test which was failing with `modelUnavailable` because `temporaryDirectory`
  lacks `vocab.txt`.
- `CrossEncoderActivation.setTestPairScorerMaker` (GeniusLocusKit): doc comment
  now states the seam takes precedence over the resolver.

### 1.0.2 -- 2026-09-08

- `PairInference` protocol: added `fixedLength: Int? { get }` requirement.
  `CoreMLPairInference` satisfies it via the CoreML `input_ids` shape constraint
  (was documented only under `CoreMLPairInference` in 1.0.1; it is now a
  protocol requirement because the clamp-branch test injects a fake via the
  `makeInference` seam and reads `fixedLength` through the protocol).
- `PairScorerFactory.make`: added `makeInference` parameter (default nil).
  Injectable inference constructor for testing; bypasses CoreML loading.

### 1.0.1 -- 2026-09-08

- §3 `CoreMLPairInference`: added `fixedLength: Int?` (reads CoreML `input_ids` shape
  constraint) and `rebuilding(tokenizer:)` (shares the model binary).
- §5: corrected Rust pair-id test name to `pair_tokens_match_the_shared_fixture`.
- W9-2: `ModelDirectoryResolver.swift` path corrected to `CorpusKitProviders/ModelDirectoryResolver.swift` (not in the `Encoder/` subdirectory).
- I9-1: `ProviderPairScorer` block now lists `profile`, `inference`, `batchSize` stored properties and computed `backend`.
- I9-2: `CrossEncoderReport` memberwise init added.
- I9-5: `minilmL6.tokenizerHash` value pinned (`07eced375…`) in the `CrossEncoderProfile` block.
- I9-6: `GLKRecallResult.degradedStages`/`degraded_stages` row added to §3 request/result fields; Swift and Rust both documented.
- I9-8: Rust providers block reordered: `pair_scorer_factory.rs` (non-gated) before `candle_pair_scorer.rs` (feature `candle`).

### 1.0.0 -- 2026-09-08

Initial surface, both ports.

*End of CrossEncoderInterface*
