---
title: LatticeLib Interface
version: 1.2.1
description: Public API surface for LatticeLib in both the Swift and Rust ports.
status: active
spec_type: kit
authors: MOOTx01 maintainers
date: 2026-06-17
package: LatticeLib
languages: [swift, rust]
relates_to:
  - docs/reference/FDC_ENCODER_CANONICAL.md
  - docs/engineering/FDC_ENCODER_COOKBOOK.md
purpose: |
  Public API surface of LatticeLib (Swift + partial Rust). LatticeLib is
  the FDC (Frame-Directed Classification) encoder library: it turns a block
  of text into an FDC decimal code via a pure string/bag pipeline
  (normalize -> tokenize -> stem -> lexicon canonicalize -> concept bag ->
  signature match -> frame descent). The Rust port covers the runtime
  encode path plus the code grammar validator (Code/code module) and the
  novel-token pool cache (NovelTokenCache, PoolEntry, PoolSubmission). The
  build-time editorial tooling (LexRank, CodeSignature, SignatureAssembler,
  SourceWeights, LexiconBuilder) is sanctioned-exempt from parity: the Rust
  server loads the bundled canon artifacts; it does not assemble them. The
  Apple NaturalLanguage novel-token fallback (`NLTagger`) has no Rust counterpart
  and is Apple-Swift-only by design (cookbook §2.2/§8). The cross-port novel-token
  contract is the integer-Viterbi HMM (`HMMTagger.tag` == `hmm_tag`), which Rust
  uses for all platforms. See the Concordance section.
---

> **Supersedes** `docs/archive/LATTICEKIT_INTERFACE.md`, relocated +
> renamed LatticeKit -> LatticeLib. The MDCC canon/code-grammar machinery
> the archived doc described was removed in the MDCC->FDC migration; the
> shipped library is the FDC encoder. This document describes the current
> `packages/libs/LatticeLib` reality.

# LatticeLib Interface

## § 1 — Package layout

**Swift:** `packages/libs/LatticeLib/`

- `Sources/LatticeLib/` — the FDC runtime (`FDC`, `FDCMatcher`,
  `BagBuilder`), text primitives (`Normalizer`, `Tokenizer`, `Stemmer`,
  `WordClass`, `LatticeLib.wordClass`), pinned-artifact models
  (`CanonicalizationLexicon`, `FDCFrame`/`FDCEntry`, `WordClassTable`),
  the code grammar (`Code`), and the build-time/seed surface
  (`LexiconBuilder`, `SignatureAssembler`/`CodeSignature`/`SourceWeights`,
  `LexRank`, `NovelTokenCache`/`PoolEntry`/`PoolSubmission`).
- `Sources/LatticeLib/Resources/` — bundled pinned artifacts
  (`Lexicon.json`, `FDCFrame.json`, `FDCSignatures.json`,
  `WordClassTable.json`).
- `Tests/LatticeLibTests/`, `Package.swift` (Swift package `LatticeLib`).

**Rust:** `packages/libs/LatticeLib/rust/` (crate `lattice-lib`,
lib `lattice_lib`). Covers the runtime FDC encode path, the code grammar, and
the novel-token pool cache: `normalizer`, `stemmer`, `tokenizer`, `word_class`,
`word_class_table`, `lexicon`, `fdc_frame`, `fdc_signatures`, `concept_bag`,
`fdc_matcher`, `fdc_runtime`, `code`, `novel_token_cache`. The build-time
editorial surface is deliberately absent (see § 7). The Apple NaturalLanguage
novel-token fallback (`NLTagger`) is Apple-Swift-only; Rust uses the integer-Viterbi
HMM (`hmm_tag`) for novel tokens — the non-Apple cross-port contract.

## § 2 — Public types (Tier 1 — runtime contract)

#### `LatticeLib`

The module surface (version) plus the Step-1 word-class entry point
(`wordClass(_:)`, defined as an extension in `WordClassTagger.swift`).

```swift
public enum LatticeLib {
    public static let version: String                 // "0.1.0"
}
public extension LatticeLib {
    // Parameterless overload — uses platform default for novel tokens
    // (Apple: NLTagger; non-Apple: HMM). Legacy / build-time tooling path.
    static func wordClass(_ token: String) -> WordClass

    // Estate-choice overload (Layer-2a) — threads the tagger choice from
    // EstateConfiguration.novelTokenTagger (bridged to LatticeLib.NovelTokenTaggerChoice).
    // .hmm: always uses the deterministic HMM/Viterbi tagger (cross-platform).
    // .nlTagger: uses NLTagger on Apple; falls back to HMM on non-Apple builds.
    static func wordClass(_ token: String, tagger: NovelTokenTaggerChoice) -> WordClass

    static func taggerEnabled(osVersion:minOSVersion:) -> Bool
}
```

**`NovelTokenTaggerChoice` (Layer-2a)** — LatticeLib-scoped enum; mirrors
`PersistenceKit.NovelTokenTaggerChoice` case-for-case. Defined independently
(topology: PersistenceKit is upstream of LatticeLib). Consumers bridge with a
trivial switch at the GLK/NeuronKit boundary.

```swift
public enum NovelTokenTaggerChoice: Sendable, Hashable {
    case hmm        // Deterministic HMM/Viterbi — default and cross-port baseline
    case nlTagger   // Apple NLTagger — Apple-only; not federatable with hmm estates
}
```

**Rust port** carries `WordClassTableCache::word_class(&str)` (table fast path
+ HMM fallback) and the new `WordClassTableCache::word_class_with_tagger(&str, NovelTokenTaggerChoice)`
overload. `NovelTokenTaggerChoice { Hmm, NlTagger }` exists in
`word_class.rs`; on Rust both variants dispatch to HMM (NaturalLanguage is absent).
The `hmm_tag_with_choice` free function is the novel-token-only dispatch primitive.

#### `FDC` / `Fdc`

The runtime entry point: load the pinned artifacts once and encode text.

```swift
public enum FDC {
    public static let stopThreshold: Int                      // 1
    public static func encode(_ text: String) -> String?
    public static func encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?)
    public static func ancestors(of code: String) -> [String]
    public static func label(for code: String) -> String?
    public static var isAvailable: Bool
    public static var dataVersion: String
    public static let classifierVersion: String
    public static var recalculationVersion: String
    public static func semanticCandidates(_ text: String, limit: Int) -> [FDCSemanticCandidate]
    public static func semanticDecision(_ text: String) -> FDCSemanticDecision?
    public static var semanticModelVersion: String
    public static var semanticModelSHA256: String
}
```
```rust
pub struct Fdc;
// encode / encode_anchor / ancestors / is_available / data_version / label
// semantic_candidates / semantic_decision / semantic_model_version / semantic_model_sha256
impl Fdc {
    pub fn ancestors(code: &str) -> Vec<String>;
    pub fn label(code: &str) -> Option<String>;
}
```

`ancestors(of:)` / `ancestors()` returns the ancestor chain for an FDC code
(root first, excluding the code itself) by delegating to the bundled frame's
`FDCFrame.ancestors(of:)` / `FdcFrame::ancestors`. Returns `[]`/`vec![]` when
the artifacts are unavailable or the code is the root `"000"`. This is the
façade accessor that consumers (e.g. `CorpusKitProviders/FDCProvider`) use to
obtain the ancestor chain without reaching into `FDCFrame`/`FdcFrame` directly;
the decimal hierarchy math lives in LatticeLib only.

`label(for:)` / `label()` resolves a UDC/MDCC decimal code to its human-readable
frame label. Every code resolves to its OWN frame label — never an ancestor's —
so sibling codes listed together (651, 652, 657 …) stay distinguishable; the
frame ships a distinct label per code. Returns `nil`/`None` for unknown codes
or empty input.

#### `QIDClosure` / `qid_closure`

The pinned Q-ID taxonomic-closure surface: a process-global static lookup over
the bundled `QIDClosureEdges.json` direct-edge graph. Loads the edge graph once
per process (Swift `Bundle.module` resource; Rust `include_bytes!` at compile
time, mirroring the FDC runtime's artifact embedding) and exposes the
**transitive** P31/P279 (instance-of / subclass-of) ancestor closure of any
Wikidata Q-ID.

```swift
public enum QIDClosure {
    public static func ancestors(of qid: String) -> [String]
    public static var isAvailable: Bool
    public static var dataVersion: String
}
```
```rust
pub mod qid_closure {
    pub fn ancestors(qid: &str) -> Vec<String>;
    pub fn is_available() -> bool;
    pub fn data_version() -> &'static str;
}
// re-exported as qid_ancestors / qid_closure_is_available / qid_closure_data_version
```

`ancestors(of:)` / `qid_closure::ancestors` returns the full transitive closure —
every ancestor reachable by a BFS walk over the pinned direct edges to the roots
— **excluding the queried qid itself**, sorted **numerically** by the integer
part of the Q-ID (`"Q146" < "Q1084" < "Q25265"`). An empty or unknown qid (or an
unavailable artifact) → `[]`/`vec![]`. Results are memoized per distinct qid for
the life of the process. The two ports are byte-identical: same edges, same BFS,
same numeric sort, same exclusion.

The bundled `QIDClosureEdges.json` is a **pinned Wikidata snapshot** of direct
P31/P279 edges, built offline by the Q-ID closure ETL (EE build tooling) and checked in
alongside the FDC artifacts. **The runtime never re-queries Wikidata** — the
transitive closure is computed locally in the loader. This keeps `ancestors`
pure, deterministic, and conformance-stable. Consumed by LocusKit's
`DrawerFingerprint` to fill the lattice-block `qidClosureHash` slot (the
`FNV.hash16` of the sorted, `"|"`-joined closure).

#### `FDCMatcher` / `FdcMatcher`

Steps 4–5: score the concept bag against code signatures, then descend the
decimal frame to the most specific well-supported code.

```swift
public struct FDCMatcher: Sendable {
    public enum ScoreMode: Sendable { case raw, idf, cosine, idfCosine }
    public let stopThreshold: Int
    public let scoreMode: ScoreMode
    public init(lexicon:frame:signatures:stopThreshold:scoreMode:)
    public func encode(_ text: String) -> String?
    public func encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?)
}
```
```rust
pub enum ScoreMode { Raw, Idf, Cosine, IdfCosine }
pub struct FdcMatcher { /* new / new_with_mode / encode / encode_anchor */ }
```

#### `CanonicalizationLexicon`

The pinned `stem(normalize(token)) -> conceptID` map (Step 2).

```swift
public struct CanonicalizationLexicon: Sendable, Codable, Equatable {
    public let version: String
    public let language: String
    public let entries: [String: String]
    public init(version:language:entries:)
}
```
```rust
pub struct CanonicalizationLexicon { /* from_json / lookup */ }
```

#### `FDCFrame` / `FDCEntry`

The decimal classification frame and its rows; ancestry derived from the
decimal string (not stored).

```swift
public struct FDCEntry: Codable, Equatable, Sendable { public let code: String; public let label: String }
public struct FDCFrame: Codable, Equatable, Sendable {
    public let frameVersion: String
    public let codes: [FDCEntry]
    public func children(of node: String) -> [FDCEntry]
    public func ancestors(of code: String) -> [String]
}
```
```rust
pub struct FdcEntry { pub code: String, pub label: String }
pub struct FdcFrame { /* from_json / decimal_parent / children / ancestors */ }
```

#### `WordClass`

The Step-1 word-class label.

```swift
public enum WordClass: String, Equatable, Sendable, Codable { case noun, verb, other }
```
```rust
pub enum WordClass { Noun, Verb, Other }
```

#### `WordClassTable` / `WordClassTableCache` — LIVE-SWAPPABLE

The noun/verb fast-path table and its process-wide, **live-swappable**
membership holder. On process start the holder is seeded via
`WordClassTable.loadWithPrecedence()` (Swift) / `seed_global_table()` (Rust),
writable-first (see **Writable-artifact lifecycle** below). After a reduce
merges novel tokens, the running tagger adopts the new table **in-session** via
an atomic swap — no process restart, version-tracked, no torn reads (a reader
copies the whole immutable snapshot out under the lock, then tests membership
outside it). Tagging is deterministic given **(input, table-version)**.

```swift
public struct WordClassTable: Sendable, Codable {
    public let tableVersion, minOSVersion, snapshotDate: String
    public let nouns, verbs: [String]
    public init(tableVersion:minOSVersion:snapshotDate:nouns:verbs:)  // public memberwise
    public static func loadBundled() -> WordClassTable?    // bundled pristine resource only
    public static func loadWritable() -> WordClassTable?   // writable artifact only (nil if absent)
    public static func loadWithPrecedence() -> WordClassTable?  // writable first, bundled fallback
}
// Process-wide LIVE-SWAPPABLE holder (lock-guarded immutable snapshot + version):
public enum WordClassTableCache {
    public static var version: UInt64 { get }              // 0 = seed; bumped per swap
    public static func swap(_ newTable: WordClassTable?)    // atomic publish + version bump
    public static func reloadFromPrecedence() -> UInt64     // swap from default artifact path
    public static func reload(fromArtifact: URL) -> UInt64  // swap from a specific artifact path
    // internal live accessors: current / table / nounSet / verbSet
}
```
```rust
pub struct WordClassTable { /* table_version, min_os_version, snapshot_date, nouns, verbs */ }
pub struct WordClassTableCache { pub noun_set, verb_set: HashSet<String>; /* from_json / word_class */ }  // Clone
// Writable-artifact helpers:
pub const BUNDLED_TABLE_JSON: &[u8];                      // compile-time bundled bytes
pub fn load_writable_table(artifact_path: &Path) -> Option<WordClassTable>;  // writable only
pub fn load_with_precedence(artifact_path: &Path) -> Option<WordClassTableCache>;  // writable first, bundled fallback
// Process-wide LIVE-SWAPPABLE holder (RwLock<Arc<WordClassTableCache>> + AtomicU64 version):
pub fn global_table() -> Arc<WordClassTableCache>;        // brief read-lock, Arc clone, no torn read
pub fn table_version() -> u64;                            // 0 = seed; bumped per swap
pub fn word_class(token: &str) -> WordClass;              // table-first, reads the live holder
pub fn seed_global_table(artifact_path: &Path);           // startup seed (no version bump)
pub fn swap_global_table(new_cache: WordClassTableCache); // atomic publish + version bump
pub fn swap_global_table_from_precedence(artifact_path: &Path) -> Option<u64>;  // post-reduce swap
// Re-exported from lib.rs:
pub use word_class_table::{load_with_precedence as table_load_with_precedence,
    load_writable_table, BUNDLED_TABLE_JSON, global_table, table_version, word_class,
    swap_global_table, swap_global_table_from_precedence, seed_global_table, WordClassTableCache};
```

#### `PoolEntry` / `PoolSubmission` / `NovelTokenCache` / `Submitter`

The novel-token pool wire-format types and the process-wide accumulation cache
(cookbook §2.2, §2.3, canonical §3 Step 1). When a token is not in the static
word-class table, the word-class path records the result here. The cache drains
to the injected `Submitter` at exactly `POOL_SUBMIT_THRESHOLD` (50) entries
(fire-and-forget). The `SHARED_NOVEL_CACHE` singleton is initialized when the
bundled artifacts are loaded by `fdc_runtime.rs`.

The production path uses the real local-file submitter (`NovelPoolSubmitter.makeDefault()`
/ `novel_pool_submitter::default_submitter()`). Each drained batch is written as a
dated JSON file in the pool directory (cookbook §2.3 wire format). The pool directory
is resolved from `LATTICE_POOL_DIR` env var, or the platform default
(`Application Support/com.mootx01.lattice/pool/` on Apple; `$XDG_DATA_HOME/mootx01/lattice/pool/`
on non-Apple). The no-op `submitter: { _ in }` / `Box::new(|_| {})` is an explicit
test / embedded-host fallback only.

```swift
public struct PoolEntry: Equatable, Sendable, Codable {
    public let token: String
    public let tag: String         // uppercase Penn form: "NOUN"/"VERB"/"OTHER"
    public init(token:tag:)
}
public struct PoolSubmission: Equatable, Sendable, Codable {
    public let tableVersion: String    // JSON key: table_version
    public let platform: String
    public let taggerVersion: String   // JSON key: tagger_version
    public let entries: [PoolEntry]
    public init(tableVersion:platform:taggerVersion:entries:)
}
public final class NovelTokenCache: @unchecked Sendable {
    public static let poolSubmitThreshold: Int    // 50
    public typealias Submitter = @Sendable (PoolSubmission) -> Void
    public init(tableVersion:platform:taggerVersion:submitter:)
    public func record(token:wordClass:)
    public var count: Int
}
// Extension on WordClass (NovelTokenCache.swift):
extension WordClass {
    var poolTag: String           // "NOUN" / "VERB" / "OTHER"
}

// Pool submitter factory + path resolution (NovelPoolSubmitter.swift):
public enum NovelPoolSubmitter {
    public static func make(poolDirectory: URL) -> NovelTokenCache.Submitter
    public static func makeDefault() -> NovelTokenCache.Submitter
    // LATTICE_POOL_DIR env var → Application Support/com.mootx01.lattice/pool/ (Apple)
    //                         → XDG_DATA_HOME/mootx01/lattice/pool/ (non-Apple)
    public static func poolDirectory() -> URL        // the resolved pool dir (read side)
    public static func tableArtifactURL() -> URL     // writable WordClassTable.json sibling
}
```

```rust
pub struct PoolEntry { pub token: String, pub tag: String }
pub struct PoolSubmission {
    pub table_version: String, pub platform: String,
    pub tagger_version: String, pub entries: Vec<PoolEntry>
}
pub type Submitter = Box<dyn Fn(PoolSubmission) + Send + Sync>;
pub struct NovelTokenCache { /* new / new_noop / record / count */ }
pub const POOL_SUBMIT_THRESHOLD: usize = 50;
pub static SHARED_NOVEL_CACHE: OnceLock<NovelTokenCache>;
pub fn pool_tag(wc: WordClass) -> &'static str;  // "NOUN"/"VERB"/"OTHER"

// Pool submitter factory (novel_pool_submitter.rs):
pub fn local_dir_submitter(dir: PathBuf) -> Submitter;
pub fn default_submitter() -> Submitter;
pub fn default_pool_dir() -> PathBuf;
// LATTICE_POOL_DIR env var → XDG_DATA_HOME/mootx01/lattice/pool/ (non-Apple)
pub fn default_table_artifact() -> PathBuf;  // writable WordClassTable.json sibling of pool dir
```

Idiom: Swift `typealias Submitter` / Rust `type Submitter = Box<dyn Fn...>` — same
fire-and-forget closure concept. Swift `NSLock` / Rust `Mutex` — both protect the
pending list. The reducer that consumes pool files and merges novel tokens into the
WordClassTable artifact (`PoolReducer.reduce` / `pool_reduce`) is driven
**near-realtime** by the resident Autonomic Governor (packages/kits/AriaMcpKit,
ARIA_MCP_SPEC §17.1): considered every governor tick, gated by the reducer's own
no-op-safe scan. `poolDirectory()`/`default_pool_dir()` (read side) and
`tableArtifactURL()`/`default_table_artifact()` give the governor the same paths
the submitter writes to. After a non-noop reduce the governor **live-swaps** the
running table (`WordClassTableCache.reload(fromArtifact:)` /
`swap_global_table_from_precedence`) so the running tagger learns the merged
tokens **in-session** — no process restart (cookbook §1.3/§2.2).

#### `PoolReducer` / `PoolReduceResult` / `PoolReducerError`

The pool reducer: batch consumer that merges pooled novel-token observations into
the `WordClassTable` artifact (cookbook §10). Includes **lazy-seed** behavior that
ensures the writable artifact exists before merging (see **Writable-artifact
lifecycle** below).

```swift
public enum PoolReducer {
    /// Reduces the pool directory into the table artifact.
    ///
    /// LAZY SEED: if `tableArtifactURL` does not exist (first run), it is
    /// created by copying the bundled pristine WordClassTable resource before
    /// loading. Pre-existing files (containing merged novel tokens from prior
    /// runs) are left untouched so accumulated learning is preserved.
    ///
    /// Then: reads all `pool_*.json` files, validates each (version gate, JSON
    /// well-formedness), deduplicates across submissions (first-occurrence wins,
    /// sorted by file name), merges NOUN/VERB tokens not already in the table,
    /// archives consumed files to `poolDirectory/archive/`, quarantines
    /// invalid files to `poolDirectory/quarantine/`. Writes the updated artifact
    /// (sorted nouns/verbs, advanced snapshot_date = now) only when at least one
    /// file was consumed. Idempotent: empty pool → no-op, no artifact write.
    public static func reduce(
        poolDirectory: URL,
        tableArtifactURL: URL,
        now: Date
    ) throws -> PoolReduceResult
}

public struct PoolReduceResult: Equatable, Sendable {
    public let consumed: Int        // files consumed and archived
    public let quarantined: Int     // files quarantined (malformed or version mismatch)
    public let nounsAdded: Int      // novel tokens merged into noun set
    public let verbsAdded: Int      // novel tokens merged into verb set
    public let skipped: Int         // entries skipped (resident, OTHER tag, or dedup)
    public var isNoop: Bool         // true when consumed == 0 && quarantined == 0
    public init(consumed:quarantined:nounsAdded:verbsAdded:skipped:)
}

public enum PoolReducerError: Error, Equatable, Sendable {
    case tableReadFailed(String)
    case tableWriteFailed(String)
    case poolDirectoryUnreadable(String)
}
```

```rust
// pool_reducer.rs
// LAZY SEED: if `table_artifact` does not exist, it is seeded from
// `BUNDLED_TABLE_JSON` before loading. Same idempotent contract as Swift.
pub fn reduce(
    pool_dir: &Path,
    table_artifact: &Path,
    now: &str,           // ISO 8601 date string "YYYY-MM-DD", injected for determinism
) -> Result<PoolReduceResult, PoolReducerError>;

pub struct PoolReduceResult {
    pub consumed: usize,
    pub quarantined: usize,
    pub nouns_added: usize,
    pub verbs_added: usize,
    pub skipped: usize,
}
impl PoolReduceResult {
    pub fn is_noop(&self) -> bool;
}

pub enum PoolReducerError {
    TableReadFailed(String),
    TableWriteFailed(String),
    PoolDirectoryUnreadable(String),
}
```

**Trigger host recommendation:** the autonomic governor (GeniusLocusKit scheduling
layer) or an operator CLI in `aria-mcp` / `Mootx01-App`. Do not invoke from the
hot `wordClass` path — reduction is a batch operation, not a per-token side effect.
The governor or operator command owns the invocation.

**Merge rules (derived; cookbook §2.3 and §1.3):**
1. Seed-if-absent: create the writable artifact from the bundled table on first run.
2. Version gate: `table_version` mismatch → quarantined.
3. Dedup / conflict resolution: run-global **first-occurrence-wins** per
   lowercased token. Files are processed in **filename-chronological order**
   (lexicographic by file name, which is chronological by the submitter's
   epoch-ms/ISO8601 prefix); within a file, entry order decides. The first
   occurrence fixes the token's tag; any later occurrence — even one carrying a
   *different* tag (e.g. the same token tagged NOUN in an earlier file and VERB
   in a later file, or twice within one file) — is a skipped duplicate. The
   token is never double-counted and never re-tagged.
4. Table-resident tokens skipped (already classified; no-op). A token already in
   the bundled/seed noun or verb set is **never reclassified** by a submission
   carrying a different tag.
5. Only NOUN and VERB tags expand the table; OTHER does not.
6. Frequency threshold: 1 (any single qualified observation merges).

#### `ConceptBag` / `BagBuilder`

The weighted concept bag (`conceptID|surface -> count`) and its builder
(Steps 1–3).

```swift
public typealias ConceptBag = [String: Int]
public enum BagBuilder {
    // Legacy / build-time overload — uses platform default for novel tokens.
    public static func bag(_ text: String, lexicon: CanonicalizationLexicon,
                           keep: Set<WordClass> = [.noun, .verb]) -> ConceptBag

    // Estate-choice overload (Layer-2a): threads tagger choice from EstateConfiguration.
    // Thread `PersistenceKit.EstateConfiguration.novelTokenTagger` (bridged to
    // `LatticeLib.NovelTokenTaggerChoice`) to classify novel tokens consistently
    // with the estate's indexed content.
    public static func bag(_ text: String, lexicon: CanonicalizationLexicon,
                           keep: Set<WordClass> = [.noun, .verb],
                           taggerChoice: NovelTokenTaggerChoice) -> ConceptBag
}
```
```rust
pub type ConceptBag = HashMap<String, usize>;
pub fn build_bag(text, lexicon, table, keep_classes) -> ConceptBag;
pub fn build_encoder_bag(text, lexicon, table) -> ConceptBag;
// Layer-2a tagger-choice overloads:
pub fn build_bag_with_tagger(text, lexicon, table, keep_classes, choice: NovelTokenTaggerChoice) -> ConceptBag;
pub fn build_encoder_bag_with_tagger(text, lexicon, table, choice) -> ConceptBag;
// On Rust, both Hmm and NlTagger dispatch to HMM (no NaturalLanguage available).
```

#### `Code` / `code`

The FDC code grammar (pure functions).

```swift
public enum Code {
    public static let maxExtensionDigits: Int                 // 8
    public static func isWellFormed(_ code: String) -> Bool
    public static func integerBase(of code: String) -> Int?
}
```
```rust
pub const MAX_EXTENSION_DIGITS: usize = 8;
pub fn is_well_formed(code: &str) -> bool;
pub fn integer_base(code: &str) -> Option<u32>;  // code module, not a type
```
Conformance: same result for every input (`code_test.rs::*`). Swift `Int?`
maps to Rust `Option<u32>` (idiom — both are 32-bit non-negative under the
three-digit 000..999 range).

#### Text primitives — `Normalizer`, `Tokenizer`, `Stemmer`

```swift
public enum Normalizer { public static func normalize(_ token: String) -> String }
public enum Tokenizer  { public static func tokenize(_ text: String) -> [String] }
public enum Stemmer    { public static func stem(_ token: String) -> String }
```
```rust
pub fn normalize(token: &str) -> String;
pub fn tokenize(text: &str) -> Vec<String>;
pub fn stem(token: &str) -> String;
```

## § 3 — Build-time / seed surface (Swift-only — NOT in the Rust runtime port)

Present in the Swift package but invoked only at seed/build time, never on
the runtime encode path. The Rust port deliberately excludes them
(`rust/src/lib.rs` DEFERRED note). See § 7 Concordance for per-type status.

- **Lexicon build:** `LexiconBuilder` (with nested `Inputs`) — `Lexicon.swift`.
- **Signature assembly:** `SignatureAssembler`, `CodeSignature`,
  `SourceWeights` — `CodeSignature.swift`.
- **Article reduction:** `LexRank` (uses `SubstrateML` + `NaturalLanguage`) —
  `LexRank.swift`.

**Note:** `NovelTokenCache`, `PoolEntry`, `PoolSubmission`, and `Submitter`
(`NovelTokenCache.swift`) are runtime types used in the `wordClass` path
(`WordClassTagger.swift::sharedNovelCache`). They accumulate novel-token pool
entries at runtime, not at build time. They are runtime types, not build-time
tooling, and are now ported to Rust (`novel_token_cache.rs`). See § 2 and § 7
Concordance.

#### `FdcSignatures` (Rust-only helper)

The Rust port carries a `pub struct FdcSignatures` (`fdc_signatures.rs`)
that parses the compact `FDCSignatures.json` into `code -> term-set`. The
Swift equivalent is a *private* inner struct of `FDC`
(`FDC.SignaturesFile`), not a public type. The two perform the identical
parse; the Rust visibility is broader for crate-internal wiring.

## § 3.5 — Writable-artifact lifecycle (novel-token learning)

Novel-token learning is **near-realtime and IN-SESSION** (it also survives a
reload). The loop is:

```
tag / submit content with novel tokens
  → NovelTokenCache accumulates to POOL_SUBMIT_THRESHOLD (50)
  → drain → pool_*.json file written to poolDirectory / default_pool_dir()
  → PoolReducer.reduce / pool_reduce runs NEAR-REALTIME (autonomic governor,
    every tick, no-op-safe scan gate):
      1. LAZY SEED: if tableArtifactURL / table_artifact absent, seed it from
         the bundled pristine table (Bundle.module resource / BUNDLED_TABLE_JSON)
      2. Load seeded or pre-existing artifact
      3. Merge qualifying novel tokens (NOUN / VERB, not already table-resident)
      4. Write updated artifact (sorted nouns+verbs, advanced snapshot_date)
      5. Archive / quarantine pool files
  → LIVE SWAP (same process, post-reduce safe point):
      WordClassTableCache.reload(fromArtifact:) (Swift) /
      swap_global_table_from_precedence(&artifact_path) (Rust):
        re-resolve writable-first from the just-written artifact and atomically
        publish it into the live holder (version bump, no torn reads)
      → previously-novel token is now table-resident in the RUNNING process
      → the SAME live tagger's wordClass / word_class fast path returns its
        class directly (learned in-session — NO process restart)
  → ALSO on a future PROCESS LOAD: seed_global_table / loadWithPrecedence picks
    up the same writable artifact (cross-reload learning still holds).
```

**Key constraints:**
- Learning is LIVE (in-session): a `PoolReducer.reduce` run writes the artifact,
  and the governor immediately live-swaps the running holder so the tagger learns
  the merged tokens without a restart. The same artifact is also picked up on any
  future process start (cross-reload).
- The swap is a single locked publish of a new immutable snapshot + a monotonic
  version bump; readers copy the whole snapshot out under the lock and test
  membership outside it — no torn reads. Tagging is deterministic given
  **(input, table-version)**.
- The bundled resource (`Resources/WordClassTable.json` / `BUNDLED_TABLE_JSON`) is
  read-only and is never written. The writable artifact lives at
  `NovelPoolSubmitter.tableArtifactURL()` / `default_table_artifact()`.
- `table_version` is pinned from the bundled table. The merged artifact carries the
  same `table_version` — pool submissions with a different version are quarantined.
  Learning does NOT bump `table_version`; it extends the noun/verb sets within the
  same version. (The live-swap *holder* version — `WordClassTableCache.version` /
  `table_version()` — is a separate in-process swap counter, not the table_version.)

**Paths (both ports agree on these paths — single source of truth in
`NovelPoolSubmitter`):**

| Name | Swift | Rust |
|---|---|---|
| Pool dir | `NovelPoolSubmitter.poolDirectory()` | `default_pool_dir()` |
| Writable artifact | `NovelPoolSubmitter.tableArtifactURL()` | `default_table_artifact()` |

Override both with `LATTICE_POOL_DIR` env var (artifact sits beside that dir).

## § 4 — Errors

LatticeLib's runtime surface does not throw. `FDC.encode` returns `nil` for
UNRESOLVED or unavailable artifacts. `LexiconBuilder.build(_:)` throws on a
missing/unreadable input file (build-time only); there is no module-owned
`MOOTx01Error` in the current library (the archived `edgeFetchFailed` case
belonged to the removed MDCC Wikidata-fetch path).

## § 5 — Conformance test entry points

The two ports agree byte-for-byte over the **same** shared fixture,
`rust/tests/fixtures/fdc_conformance.json`.

**Swift:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/libs/LatticeLib
```
Target `LatticeLibTests` — `FDCConformanceTests.swift::allConformanceVectorsMatch`
reads the shared fixture; `FDCMatcherTests`, `FDCRuntimeTests`, `CodeTests`,
`ConceptBagTests`, `FDCSignaturesArtifactTests`, `LexiconBuilderTests`,
`LexRankTests`, `CodeSignatureTests`, `NovelTokenCacheTests` (pool cache and wire
format, 16 tests).

**Rust:**
```
cargo test --manifest-path packages/libs/LatticeLib/rust/Cargo.toml
```
`rust/tests/fdc_conformance_test.rs::fdc_conformance_all_vectors_match`
(same shared fixture) and `::stemmer_conformance_snowball_corpus`;
`rust/tests/fdc_artifact_test.rs` (artifact-shape checks).

## § 6 — Example

```swift
import LatticeLib

guard FDC.isAvailable else { /* artifacts missing */ return }
let code = FDC.encode("computer graphics rendering")     // String? (FDC code or nil)
let (c, qid) = FDC.encodeAnchor("computer graphics")     // (code, dominant Q-ID)
let evidence = FDC.semanticDecision("stars and galaxy")  // hierarchy evidence
let ok = Code.isWellFormed("006.6")                      // true
let base = Code.integerBase(of: "006.6")                 // 6
```

## § 7 — Swift/Rust Concordance

LatticeLib LEADS in Swift; the Rust port covers the **runtime FDC encode
path** only. Conformance is two-way scalar (`Swift-scalar == Rust-scalar`)
over the shared fixture — there is no vector/matrix dimension, so the
four-way matrix (Metal/BLAS/NEON) does not apply (`rust/src/lib.rs`
CONFORMANCE SCOPE note). Missing-Rust concepts are marked **DRIFT** (not
fabricated), with two sanctioned exceptions called out as **Exempt**: the
Apple `NaturalLanguage` novel-token fallback (platform binding), and the
build-time-only seed surface (Swift LEADS; Rust runtime port does not carry
seed tooling). Build-time-only status is not on its own a platform-binding
waiver: such concepts are recorded explicitly as Exempt with the reason
stated, not silently dropped.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Module surface / version | `LatticeLib` (`LatticeLib.swift:12`) | (no namespace type; free fns in modules) | Swift public / Rust modules | Swift enum-namespace / Rust free-fn modules — idiom | N/A (structural) | Confirmed |
| Word-class Step-1 entry | `LatticeLib.wordClass` (`WordClassTagger.swift:45`) | `WordClassTableCache::word_class` (`word_class_table.rs`) | both public | Swift method on `LatticeLib` ext / Rust method on cache; table fast path identical, novel-token path divergent (see Exempt row) | `FDCConformanceTests.swift::allConformanceVectorsMatch` / `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Runtime encoder entry | `FDC` (`FDCRuntime.swift:15`) | `Fdc` (`fdc_runtime.rs:96`) | both public | Swift enum statics / Rust unit struct assoc fns — idiom (FDC/Fdc); `encode`/`encodeAnchor`/`ancestors`/`isAvailable`/`dataVersion` identical | `FDCRuntimeTests.swift` / `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Semantic micro-ranker | `FDCSemanticRanker` / `FDC.semanticCandidates` / `semanticDecision` | `FdcSemanticRanker` / `Fdc::semantic_candidates` / `semantic_decision` | both public | Same binary parser, ASCII/FNV features, integer scores, hierarchy thresholds, and tie-breaks | `FDCSemanticRankerTests.swift` / `fdc_semantic_conformance_test.rs` shared 12-vector fixture | **Confirmed** |
| FDC ancestor façade | `FDC.ancestors(of:)` (`FDCRuntime.swift`) | `Fdc::ancestors` (`fdc_runtime.rs`) | both public | Swift static func / Rust associated fn on `Fdc` — idiom; delegates to `FDCFrame.ancestors(of:)` / `FdcFrame::ancestors`; returns `[]`/`vec![]` when artifacts unavailable; consumers use this façade — decimal hierarchy math lives only in `FDCFrame`/`FdcFrame` | `FdcProviderTests.swift::FdcAncestorsTests` (7 tests via `FDC.ancestors`) / `fdc_runtime.rs` (delegation to `FdcFrame::ancestors` already tested in `fdc_frame.rs::tests`) | **Confirmed** |
| Frame label lookup | `FDC.label(for:)` (`FDCRuntime.swift`) | `Fdc::label` (`fdc_runtime.rs`) | both public | Swift static func / Rust associated fn on `Fdc` — idiom; returns the human-readable label for a UDC/MDCC code; integer codes walk to 3-digit parent before frame lookup; `nil`/`None` for empty or unknown input | `FDCRuntimeTests.swift::label*` / `fdc_runtime.rs::tests::label_*` (4 tests) | **Confirmed** |
| Signature matcher | `FDCMatcher` (`FDCMatcher.swift:20`) | `FdcMatcher` (`fdc_matcher.rs:67`) | both public | Swift `init` / Rust `new`+`new_with_mode` — idiom; encode/encodeAnchor identical | `FDCMatcherTests.swift` / `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Score mode | `FDCMatcher.ScoreMode` (`FDCMatcher.swift:39`) | `ScoreMode` (`fdc_matcher.rs:53`) | both public | Swift nested `FDCMatcher.ScoreMode` / Rust flat `ScoreMode`; cases raw/idf/cosine/idfCosine identical | `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Canonicalization lexicon | `CanonicalizationLexicon` (`Lexicon.swift:30`) | `CanonicalizationLexicon` (`lexicon.rs:16`) | both public | identical (Codable JSON / `from_json`+`lookup`) | `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Frame entry | `FDCEntry` (`FDCFrame.swift:17`) | `FdcEntry` (`fdc_frame.rs:14`) | both public | identical shape; idiom FDCEntry/FdcEntry | `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Classification frame | `FDCFrame` (`FDCFrame.swift:34`) | `FdcFrame` (`fdc_frame.rs:24`) | both public | identical; ancestry derived (`children`/`ancestors`/`decimalParent` ⇔ `decimal_parent`); idiom FDCFrame/FdcFrame | `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Word class | `WordClass` (`WordClass.swift:23`) | `WordClass` (`word_class.rs:13`) | both public | identical 3-case enum (noun/verb/other) | `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Word-class table model | `WordClassTable` (`WordClassTable.swift:19`) | `WordClassTable` (`word_class_table.rs:37`) | both public | identical JSON schema (table_version/min_os_version/snapshot_date/nouns/verbs) | `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Word-class membership cache | `WordClassTableCache` (`WordClassTable.swift:82`, internal) | `WordClassTableCache` (`word_class_table.rs:50`) | Swift internal / Rust public | Swift internal cache / Rust pub — caching shim, not a cross-port wire contract; concept present both sides | `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Concept bag type | `ConceptBag` (`ConceptBag.swift:25`) | `ConceptBag` (`concept_bag.rs:30`) | both public | Swift `[String:Int]` typealias / Rust `HashMap<String,usize>` type alias — identical (Int/usize idiom) | `ConceptBagTests.swift` / `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Bag builder | `BagBuilder` (`ConceptBag.swift:27`) | `build_bag` / `build_encoder_bag` (`concept_bag.rs:35,71`) | both public | Swift enum-namespace `BagBuilder.bag` / Rust free fns — idiom | `ConceptBagTests.swift` / `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Normalizer | `Normalizer` (`Normalizer.swift:11`) | `normalize` (`normalizer.rs:15`) | both public | Swift enum-namespace static / Rust free fn — idiom | `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Tokenizer | `Tokenizer` (`Tokenizer.swift:17`) | `tokenize` (`tokenizer.rs:19`) | both public | Swift enum-namespace static / Rust free fn — idiom | `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Stemmer (Porter2/Snowball) | `Stemmer` (`Stemmer.swift:49`) | `stem` (`stemmer.rs:34`) | both public | Swift enum-namespace static / Rust free fn — idiom | `fdc_conformance_test.rs::stemmer_conformance_snowball_corpus` | Confirmed |
| Compact signatures parse | `FDC.SignaturesFile` (private inner, `FDCRuntime.swift:45`) | `FdcSignatures` (`fdc_signatures.rs:28`) | Swift private / Rust public | Swift private inner struct of `FDC` / Rust pub helper struct; identical parse (compact membership form), visibility differs for crate wiring | `fdc_artifact_test.rs::artifact_is_membership_only_with_provenance_header` | Confirmed |
| Code grammar | `Code` (`Code.swift:28`) | `code` module: `is_well_formed`, `integer_base`, `MAX_EXTENSION_DIGITS` (`code.rs`) | Swift public enum / Rust free-fn module — idiom; `isWellFormed`/`integerBase`/`maxExtensionDigits` ↔ `is_well_formed`/`integer_base`/`MAX_EXTENSION_DIGITS`; Swift `Int?` ↔ Rust `Option<u32>` (idiom) | `CodeTests.swift` / `code_test.rs::*` (9 tests) | **Confirmed** |
| Source weights (seed) | `SourceWeights` (`CodeSignature.swift:13`) | — none — | Swift public / Rust absent | Build-time editorial tooling: §7.1 signature assembly; invoked only when building the pinned `FDCSignatures.json` artifact, never on the runtime encode path. The Rust server loads the bundled artifact; it does not assemble signatures. | `CodeSignatureTests.swift` (Swift only) | **Exempt (build-time editorial tooling — Swift-only by design; Rust server loads bundled canon, does not assemble it)** |
| Code signature (seed) | `CodeSignature` (`CodeSignature.swift:24`) | — none — | Swift public / Rust absent | Build-time editorial tooling: §7.1 signature assembly output type; never on the runtime encode path. | `CodeSignatureTests.swift` (Swift only) | **Exempt (build-time editorial tooling — Swift-only by design; Rust server loads bundled canon, does not assemble it)** |
| Signature assembler (seed) | `SignatureAssembler` (`CodeSignature.swift:33`) | — none — | Swift public / Rust absent | Build-time editorial tooling: §7.1 merge-and-accumulate pass; never on the runtime encode path. | `CodeSignatureTests.swift` (Swift only) | **Exempt (build-time editorial tooling — Swift-only by design; Rust server loads bundled canon, does not assemble it)** |
| Lexicon builder (seed) | `LexiconBuilder` (`Lexicon.swift:51`) | — none — | Swift public / Rust absent | Build-time editorial tooling: constructs `Lexicon.json` from WordNet + Wikidata inputs; never on the runtime encode path. | `LexiconBuilderTests.swift` (Swift only) | **Exempt (build-time editorial tooling — Swift-only by design; Rust server loads bundled canon, does not assemble it)** |
| Article reduction (seed) | `LexRank` (`LexRank.swift:18`) | — none — | Swift public / Rust absent | Build-time editorial tooling: §7.2 LexRank article reduction used when building corpus inputs for signature assembly; uses `SubstrateML`+`NaturalLanguage`; never on the runtime encode path. | `LexRankTests.swift` (Swift only) | **Exempt (build-time editorial tooling — Swift-only by design; Rust server loads bundled canon, does not assemble it)** |
| Novel-token cache | `NovelTokenCache` (`NovelTokenCache.swift:86`) | `NovelTokenCache` (`novel_token_cache.rs:112`) | both public | Swift `final class` with `NSLock` / Rust struct with `Mutex` — idiom; `record`/`count`/`poolSubmitThreshold` identical; process-wide singleton `sharedNovelCache` ↔ `SHARED_NOVEL_CACHE` (OnceLock); initialized when bundled artifacts load | `NovelTokenCacheTests.swift` / `novel_token_cache.rs::tests::*` (16 tests each) | **Confirmed (ported + test-bound)** |
| Pool entry | `PoolEntry` (`NovelTokenCache.swift:29`) | `PoolEntry` (`novel_token_cache.rs:45`) | both public | identical shape (token/tag); JSON serialization identical (field names match) | `NovelTokenCacheTests.swift` / `novel_token_cache.rs::tests::*` | **Confirmed (ported + test-bound)** |
| Pool submission | `PoolSubmission` (`NovelTokenCache.swift:42`) | `PoolSubmission` (`novel_token_cache.rs:61`) | both public | identical shape; snake_case CodingKeys (`table_version`/`tagger_version`) verified in both ports | `NovelTokenCacheTests.swift` / `novel_token_cache.rs::tests::pool_submission_json_round_trip_uses_snake_case_keys` | **Confirmed (ported + test-bound)** |
| Pool submitter type | `NovelTokenCache.Submitter` (`NovelTokenCache.swift:94`) | `Submitter` (`novel_token_cache.rs:101`) | both public | Swift `public typealias Submitter = @Sendable (PoolSubmission) -> Void` / Rust `type Submitter = Box<dyn Fn(PoolSubmission) + Send + Sync>` — idiom (fire-and-forget closure) | (structural — covered by `NovelTokenCache` tests) | Confirmed |
| Pool tag accessor | `WordClass.poolTag` (`NovelTokenCache.swift:72`) | `pool_tag(WordClass)` (`novel_token_cache.rs:89`) | Swift internal computed var / Rust pub fn | Swift extension var / Rust free fn — idiom; same mapping Noun→"NOUN", Verb→"VERB", Other→"OTHER" | `NovelTokenCacheTests.swift::WordClassPoolTagTests` / `novel_token_cache.rs::tests::pool_tag_*` | Confirmed |
| Novel-token tagger fallback | Swift Apple: `LatticeLib.tagNovelToken` / Apple `NLTagger` branch (`WordClassTagger.swift:144,171`). Swift non-Apple: `HMMTagger.tag` (integer Viterbi, `HMMTagger.swift`). | Rust: `word_class::hmm_tag` called from `WordClassTableCache::word_class` (`word_class_table.rs`) for table-miss tokens; result recorded into `SHARED_NOVEL_CACHE`. | Swift Apple: internal `#if canImport(NaturalLanguage)` platform guard. Swift non-Apple + Rust: `HMMTagger.tag` / `hmm_tag` — shared integer-Viterbi tables. | Non-Apple cross-port contract: Swift-non-Apple-HMM == Rust-HMM (byte-identical, integer scoring). Apple `NLTagger` is a different engine — legitimately diverges from HMM for some novel tokens, Apple-only by design (cookbook §2.2/§8). | `tag_conformance.json` (28 vectors incl. real English novel tokens — cross-port HMM gate). `fdc_conformance.json` (65 vectors, 3 Apple-divergent ones use Rust-HMM baseline; Swift test skips those 3 on Apple via `#if canImport(NaturalLanguage)` guard). | **Confirmed (HMM wired, fixtures split)** |
| Pool reducer | `PoolReducer` (`PoolReducer.swift`) | `pool_reducer::reduce` (`pool_reducer.rs`) | both public | Swift enum namespace static / Rust free fn — idiom; identical merge semantics (lazy seed, version gate, dedup, noun/verb-only expansion, archive/quarantine); `now` injected for determinism | `PoolReducerTests.swift` / `pool_reducer.rs::tests::*` + `NovelTokenEffectivenessTests.swift` / `novel_token_effectiveness_test.rs` (9+6 Swift + 10+6 Rust tests) | **Confirmed** |
| Pool reduce result | `PoolReduceResult` (`PoolReducer.swift`) | `pool_reducer::PoolReduceResult` (`pool_reducer.rs`) | both public | identical fields: consumed/quarantined/nouns_added(nounsAdded)/verbs_added(verbsAdded)/skipped + is_noop/isNoop; Swift camelCase / Rust snake_case — idiom | `PoolReducerTests.swift` / `pool_reducer.rs::tests::*` | **Confirmed** |
| Pool reducer error | `PoolReducerError` (`PoolReducer.swift`) | `pool_reducer::PoolReducerError` (`pool_reducer.rs`) | both public | identical 3-case error enum: tableReadFailed/TableReadFailed, tableWriteFailed/TableWriteFailed, poolDirectoryUnreadable/PoolDirectoryUnreadable; Swift associated String / Rust tuple variant — idiom | (structural, covered by error-path tests) | **Confirmed** |
| Writable-table load precedence | `WordClassTable.loadWithPrecedence()`, `loadWritable()` (`WordClassTable.swift`) | `load_with_precedence(&Path)`, `load_writable_table(&Path)`, `BUNDLED_TABLE_JSON` (`word_class_table.rs`) | both public | writable artifact first, bundled fallback — cross-reload learning contract (§3.5); `WordClassTableCache` init uses `loadWithPrecedence` / `load_with_precedence`; `BUNDLED_TABLE_JSON` is compile-time bytes (Rust), `Bundle.module` resource (Swift) | `NovelTokenEffectivenessTests.swift` / `novel_token_effectiveness_test.rs` | **Confirmed** |
| Reduce seed-if-absent | `PoolReducer.seedWritableArtifactIfAbsent` (private, `PoolReducer.swift`) | `seed_writable_artifact_if_absent` (private, `pool_reducer.rs`) | both internal | seeds writable artifact from bundled table when absent on first run; idempotent (pre-existing file left untouched) | `NovelTokenEffectivenessTests.swift::seedIfAbsentCreatesArtifact` / `novel_token_effectiveness_test.rs::seed_if_absent_creates_artifact` | **Confirmed** |
| Novel-token tagger selector | `NovelTokenTaggerChoice` (`NovelTokenTaggerChoice.swift:23`) | `NovelTokenTaggerChoice` (`word_class.rs:166`) | both public / pub | identical 2-case enum (`hmm`/`Hmm`, `nlTagger`/`NlTagger`); Swift lowerCamel / Rust UpperCamel — idiom. `Default` = `hmm`/`Hmm` on both ports. `NlTagger` case is a no-op in Rust (routes to HMM; Apple NaturalLanguage absent on server) — behaviour parity: non-Apple path is identical. PersistenceKit carries an independent mirrored copy (`persistence_kit::NovelTokenTaggerChoice`); consumers bridge via a trivial switch. | `tag_conformance.json` (28 vectors — cross-port HMM gate includes table-miss novel tokens); `fdc_conformance.json` (65 vectors) | **Confirmed** |
| Production pool submitter | `NovelPoolSubmitter` (`NovelPoolSubmitter.swift:43`) | — (`novel_pool_submitter.rs`: free functions `local_dir_submitter`, `default_submitter`, `default_pool_dir`, `default_table_artifact`) | Swift public enum-namespace / Rust pub free functions | Swift wraps the operations as a caseless-enum namespace (`make(poolDirectory:)`, `makeDefault()`, `poolDirectory()`, `tableArtifactURL()`); Rust exposes identical functionality as module-level free functions (no namespace type) — sanctioned stateless-namespace idiom. Pool-dir resolution logic is identical on both ports (env-var → XDG/AppSupport → default), as is the fire-and-forget write-and-log contract. | `NovelTokenEffectivenessTests.swift` (pool write path exercised) / `novel_pool_submitter.rs #[cfg(test)]` | **Confirmed (Swift namespace / Rust free-fn idiom)** |

### Drift summary

There are no remaining runtime DRIFT rows. All public Swift runtime concepts now
have a Rust counterpart.

`FDC.ancestors(of:)` / `Fdc::ancestors` (ancestor chain façade delegating to
`FDCFrame.ancestors` / `FdcFrame::ancestors`) is present in both ports and
confirmed. Added as part of the ADR-010 Decision B FDC provider migration:
consumers use the `FDC`/`Fdc` runtime façade rather than reaching into
`FDCFrame`/`FdcFrame` directly, and the decimal hierarchy math lives only in
LatticeLib (Gate 2).

`FDC.label(for:)` / `Fdc::label` (frame label lookup by code — every code
resolves to its own frame label) is present in both ports and test-bound.

Three rows that were previously marked DRIFT are now Confirmed:
`NovelTokenCache`, `PoolEntry`, and `PoolSubmission`. The Rust port
(`novel_token_cache.rs`) implements all three types with identical behavior —
accumulate-and-submit at exactly 50 entries, snake_case JSON wire format,
process-wide singleton initialized on artifact load. Both ports are test-bound
(`NovelTokenCacheTests.swift` / `novel_token_cache.rs::tests`).

Two new rows were added for concepts surfaced during the port:
`NovelTokenCache.Submitter` / `Submitter` (the fire-and-forget closure type
alias, Confirmed) and `WordClass.poolTag` / `pool_tag` (the Penn-tag accessor,
Confirmed).

The pool reducer is present in both ports: `PoolReducer` / `pool_reducer::reduce`,
`PoolReduceResult` / `pool_reducer::PoolReduceResult`, and `PoolReducerError` /
`pool_reducer::PoolReducerError`. This completes the novel-token learning loop —
the cookbook "Pool reducer" surface is shipped in both ports. Both ports are
test-bound (9 Swift + 10 Rust tests).

Five concepts are correctly recorded as Exempt (build-time editorial tooling,
Swift-only by design): `SourceWeights`, `CodeSignature`, `SignatureAssembler`,
`LexiconBuilder`, and `LexRank`. The Rust server loads the bundled artifacts; it
does not assemble them.

One concept remains Exempt for platform-binding reasons: the Apple
`NaturalLanguage` novel-token fallback (platform-divergent by design,
contract-excluded per cookbook §2.2/§8). The Rust port mirrors the Swift
non-Apple `.other` stub and records into `SHARED_NOVEL_CACHE`.

---

*End of LatticeLib Interface.*

## Changelog

### 1.2.1 -- 2026-06-17
Replaced the hand-specified HMM priors in `HMMTagger` / `hmm_tag` with weights
trained on the MASC 3.0.0 Penn Treebank constituency corpus (CC BY 3.0 US, ANC).
Because the HMM only ever tags NOVEL (out-of-vocabulary) tokens at runtime —
known/closed-class words are served by the fast-path `WordClassTable` — the
model is estimated only from the corpus's RARE words (hapax legomena, ~5,230
tokens), the standard unknown-word proxy. This yields the correct content-noun-
dominant prior (a no-suffix unknown such as "religion" tags as noun); estimating
from the full corpus instead lets frequent function words wrongly dominate the
no-suffix bucket. The weights are frozen as a checked-in resource
`Resources/HMMTaggerModel.json`, produced by the HMM-training ETL (EE build
tooling; Laplace add-1 smoothing, integer log-weight scale 1000). Both ports read
the SAME JSON artifact — Swift via `Bundle.module`, Rust via `include_bytes!` —
ensuring byte-identity. `HMM_VITERBI_VERSION` / `currentTaggerVersion` bumped to
`hmm-viterbi-3`. The shared conformance fixtures `tag_conformance.json` and
`fdc_conformance.json` regenerated to the trained-model output. Attribution:
`Resources/HMMTaggerModel.NOTICE.md`. API shape unchanged; the public
`HMMTagger.tag` / `hmm_tag` signatures are identical. No new public symbols added.

### 1.2.0 -- 2026-06-17
Added the `QIDClosure` / `qid_closure` surface (mission #7b): a process-global
static lookup over the pinned `QIDClosureEdges.json` direct-edge graph exposing
`ancestors(of:)` — the transitive P31/P279 ancestor closure of a Wikidata Q-ID
(BFS over the pinned edges, excluding the queried qid, sorted numerically),
plus `isAvailable` / `dataVersion`. The artifact is a pinned offline Wikidata
snapshot (38,761 nodes) built by the Q-ID closure ETL (EE build tooling); the runtime
never re-queries Wikidata — the closure is computed locally. Byte-identical
across the Swift and Rust ports (same edges, BFS, numeric sort). Consumed by
LocusKit's `DrawerFingerprint` to fill the lattice-block `qidClosureHash` slot.
Additive; no existing surface changed.

### 1.1.0 -- 2026-06-16
Added `FDC.ancestors(of:)` (Swift) and `Fdc::ancestors` (Rust) to the public
FDC/Fdc runtime façade. Both delegate to the already-public
`FDCFrame.ancestors(of:)` / `FdcFrame::ancestors`; the decimal hierarchy math
lives in LatticeLib only. Added to support ADR-010 Decision B: the FDC provider
in CorpusKitProviders now calls `FDC.ancestors(of:)` / `Fdc::ancestors` rather
than reimplementing the ancestor walk inline (Gate 2 compliance). Added the new
façade row to the concordance table. Drift summary updated.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
