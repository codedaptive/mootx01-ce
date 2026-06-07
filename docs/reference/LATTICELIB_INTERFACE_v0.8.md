---
title: LatticeLib Interface
version: v0.8
status: active
spec_type: kit
authors: Bob Pankratz (via Claude)
date: 2026-06-05
package: LatticeLib
languages: [swift, rust]   # Swift LEADS; Rust port is partial (runtime encode path)
relates_to:
  - docs/reference/FDC_ENCODER_CANONICAL_v1.0.md  (the algorithm this implements)
  - docs/engineering/FDC_ENCODER_COOKBOOK_v1.0.md  (the implementation guide)
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
  Apple NaturalLanguage novel-token fallback has no Rust counterpart —
  platform-divergent by design (cookbook §2.2/§8). See the Concordance section.
---

> **Supersedes** `docs/archive/LATTICEKIT_INTERFACE_v0.8.md`, relocated +
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
editorial surface and the Apple NaturalLanguage novel-token fallback are
deliberately absent (see § 7).

## § 2 — Public types (Tier 1 — runtime contract)

#### `LatticeLib`

The module surface (version) plus the Step-1 word-class entry point
(`wordClass(_:)`, defined as an extension in `WordClassTagger.swift`).

```swift
public enum LatticeLib {
    public static let version: String                 // "0.1.0"
}
public extension LatticeLib {
    static func wordClass(_ token: String) -> WordClass
    static func taggerEnabled(osVersion:minOSVersion:) -> Bool
}
```

The Rust port carries the word-class decision on
`WordClassTableCache::word_class(&str)` (table fast path + `.other` stub);
there is no `LatticeLib`-namespace type in Rust.

#### `FDC` / `Fdc`

The runtime entry point: load the pinned artifacts once and encode text.

```swift
public enum FDC {
    public static let stopThreshold: Int                      // 1
    public static func encode(_ text: String) -> String?
    public static func encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?)
    public static var isAvailable: Bool
    public static var dataVersion: String
}
```
```rust
pub struct Fdc;   // encode / encode_anchor / is_available / data_version
```

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

#### `WordClassTable` / `WordClassTableCache`

The static noun/verb fast-path table and its process-lifetime membership
cache.

```swift
public struct WordClassTable: Sendable, Codable {
    public let tableVersion, minOSVersion, snapshotDate: String
    public let nouns, verbs: [String]
    public static func loadBundled() -> WordClassTable?
}
enum WordClassTableCache { /* internal: table / nounSet / verbSet */ }
```
```rust
pub struct WordClassTable { /* table_version, min_os_version, snapshot_date, nouns, verbs */ }
pub struct WordClassTableCache { /* from_json / word_class */ }
```

#### `PoolEntry` / `PoolSubmission` / `NovelTokenCache` / `Submitter`

The novel-token pool wire-format types and the process-wide accumulation cache
(cookbook §2.2, §2.3, canonical §3 Step 1). When a token is not in the static
word-class table, the word-class path records the result here. The cache drains
to the injected `Submitter` at exactly `POOL_SUBMIT_THRESHOLD` (50) entries
(fire-and-forget). The `SHARED_NOVEL_CACHE` singleton is initialized when the
bundled artifacts are loaded by `fdc_runtime.rs`.

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
```

Idiom: Swift `typealias Submitter` / Rust `type Submitter = Box<dyn Fn...>` — same
fire-and-forget closure concept. Swift `NSLock` / Rust `Mutex` — both protect the
pending list.

#### `ConceptBag` / `BagBuilder`

The weighted concept bag (`conceptID|surface -> count`) and its builder
(Steps 1–3).

```swift
public typealias ConceptBag = [String: Int]
public enum BagBuilder { public static func bag(_:lexicon:keep:) -> ConceptBag }
```
```rust
pub type ConceptBag = HashMap<String, usize>;
pub fn build_bag(...) -> ConceptBag;          // + build_encoder_bag
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
seed tooling — flagged DRIFT below per Bob's force-mirror standard, since
build-time-only is NOT an automatic platform-binding waiver).

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Module surface / version | `LatticeLib` (`LatticeLib.swift:12`) | (no namespace type; free fns in modules) | Swift public / Rust modules | Swift enum-namespace / Rust free-fn modules — idiom | N/A (structural) | Confirmed |
| Word-class Step-1 entry | `LatticeLib.wordClass` (`WordClassTagger.swift:45`) | `WordClassTableCache::word_class` (`word_class_table.rs`) | both public | Swift method on `LatticeLib` ext / Rust method on cache; table fast path identical, novel-token path divergent (see Exempt row) | `FDCConformanceTests.swift::allConformanceVectorsMatch` / `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
| Runtime encoder entry | `FDC` (`FDCRuntime.swift:15`) | `Fdc` (`fdc_runtime.rs:96`) | both public | Swift enum statics / Rust unit struct assoc fns — idiom (FDC/Fdc); `encode`/`encodeAnchor`/`isAvailable`/`dataVersion` identical | `FDCRuntimeTests.swift` / `fdc_conformance_test.rs::fdc_conformance_all_vectors_match` | Confirmed |
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
| Novel-token tagger fallback | `LatticeLib.tagNovelToken` / Apple `NLTagger` branch (`WordClassTagger.swift:144,171`) | (Rust `.other` stub + `SHARED_NOVEL_CACHE.get()?.record` in `WordClassTableCache::word_class`) | Swift internal (platform `#if canImport(NaturalLanguage)`) / Rust stub | Rust: none for the Apple `NLTagger` leg — Apple platform binding (`NaturalLanguage`). Platform-divergent BY DESIGN (cookbook §2.2/§8); the static table is the cross-platform-guaranteed surface; Rust mirrors the non-Apple `.other` stub and records into SHARED_NOVEL_CACHE | conformance vectors exercise table-resident tokens only (`fdc_conformance.json`) | Exempt |

### Drift summary

There are no remaining runtime DRIFT rows. All public Swift runtime concepts now
have a Rust counterpart.

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

Five concepts are correctly recorded as Exempt (build-time editorial tooling,
Swift-only by design): `SourceWeights`, `CodeSignature`, `SignatureAssembler`,
`LexiconBuilder`, and `LexRank`. The Rust server loads the bundled artifacts; it
does not assemble them.

One concept remains Exempt for platform-binding reasons: the Apple
`NaturalLanguage` novel-token fallback (platform-divergent by design,
contract-excluded per cookbook §2.2/§8). The Rust port mirrors the Swift
non-Apple `.other` stub and records into `SHARED_NOVEL_CACHE`.

---

*End of LatticeLib Interface v0.8.*
