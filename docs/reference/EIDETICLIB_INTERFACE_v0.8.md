---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: EideticLib
languages: [swift, rust]
relates_to:
  - EIDETICLIB_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of EideticLib in both ports. Tier 1 fully documents
  the term→Anchor lookup path that other packages consume (the EideticLib
  namespace and the Anchor result) AND the sentence segmenter consumed by
  CorpusKit.Chunker (F16, 2026-05-27). Tier 2 lists the present-but-not-
  yet-externally-consumed surfaces — the FDC encoder Step-1 word-class API
  and the consent-gated foreign-source pipeline — as a table of contents.
  The companion SPEC carries the behavioral contracts (invariants I-1…I-13,
  conformance C-1…C-11).
---

# EideticLib Interface

## § 1 — Package layout

**Swift:** `packages/libs/EideticLib/`

- `Sources/EideticLib/EideticLib.swift` — the `EideticLib` namespace
  (`lookup`, `classifyLatticeCode`, `version`, `defaultScheme`,
  `activationConsent`) and the `Anchor` result
- `Sources/EideticLib/LatticeResolver.swift` — `LatticeResolver`,
  `MDCCResolution` (the MDCC-canon grounding step)
- `Sources/EideticLib/LatticeCodeState.swift` — `LatticeCodeState`,
  `LatticeCodeGrammar`
- `Sources/EideticLib/Scheme.swift` — `ClassificationScheme`,
  `LatticeSchemeManifest`
- `Sources/EideticLib/WikidataResolver.swift` /
  `WikidataSubset.swift` — `WikidataResolver`, `ResolverDecision`,
  `WikidataEntry`, `WikidataSubset` (Q-ID confirmation)
- `Sources/EideticLib/Tokenizer.swift`, `Normalizer.swift`,
  `Stemmer.swift`, `Segmenter.swift` — the deterministic linguistic
  pipeline stages (tokens / normalization / stems / sentences)
- `Sources/EideticLib/WordClass.swift`, `WordClassTable.swift`,
  `WordClassTagger.swift`, `NovelTokenCache.swift` — FDC encoder Step 1
- `Sources/EideticLib/ConsentGate.swift`,
  `ForeignSourcePipeline.swift` — opt-in foreign-source assembly
- `Sources/EideticLib/Resources/` — bundled MDCC/Wikidata JSON, the
  word-class table, the Snowball corpus
- `Tests/EideticLibTests/`, `Tests/SharedVectors/`, `Package.swift`

**Rust:** `packages/libs/EideticLib/rust/` (crate `eidetic-lib`,
lib name `eidetic_lib`)

- `src/lib.rs` — `lookup`, `VERSION`, re-exports
- `src/anchor.rs` — `Anchor`
- `src/tokenizer.rs`, `src/normalizer.rs`, `src/stemmer.rs`, `src/segmenter.rs` — pipeline
- `src/wikidata_resolver.rs`, `src/wikidata_subset.rs` — `ResolverDecision`,
  `WikidataEntry`, `WikidataSubset`
- `src/word_class.rs` — `WordClass`, `WordClassTable`, `CachedTable`,
  `NovelTokenCache`, `PoolEntry`, `PoolSubmission`
- `tests/word_class_conformance.rs`, `examples/benchmark.rs`, `Cargo.toml`

The Rust version covers the building blocks (anchor, pipeline, wikidata,
word-class); the lattice-resolution, scheme, and consent/foreign-source
surfaces are present in the Swift version and not yet in the Rust version.

## § 2 — Public types

This package has a large public surface; only the term→Anchor lookup path
is consumed by other packages (NeuronKit, via `EideticLib.lookup` →
`Anchor`). That path is documented in full as **Tier 1**. The remaining
public surfaces — present and tested, but not yet consumed outside
EideticLib's own tests — are listed in the **Tier 2** table of contents at
the end of this section.

### Tier 1 — consumed surface

#### `Anchor`

The result of a lookup — the Eidetic. Pure data; byte-identical shape
across ports (SPEC § 4, I-4).

**Swift:**

```swift
public struct Anchor: Equatable, Sendable, Codable {
    public let mdccCode: String        // "" means no canon entry matched
    public let wikidataQID: String?    // resolved entry's CC0 Q-ID, or nil
    public let confidence: UInt8       // provenance value set: 0/16/32/48/56
    public let dataVersion: String     // MDCC canon version that produced this

    public init(mdccCode: String, wikidataQID: String?, confidence: UInt8, dataVersion: String)

    /// Sentinel returned only when the bundled canon fails to load.
    public static let notImplemented: Anchor   // dataVersion == "0.1.0-stub"
}
```

**Rust:**

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Anchor {
    pub mdcc_code: String,
    pub wikidata_qid: Option<String>,
    pub confidence: u8,
    pub data_version: String,
}

impl Anchor {
    pub fn not_implemented() -> Self;   // data_version == "0.1.0-stub"
}
```

#### `EideticLib` (namespace)

The module surface. Stateless from the caller's perspective; the bundled
reference data is parsed once and cached for the process lifetime (SPEC
§ 4, I-1, I-2). Functions are in § 3.

**Swift:**

```swift
public enum EideticLib {
    public static let version: String                       // "0.1.0"
    public static let defaultScheme: ClassificationScheme   // .mdcc
    public static let activationConsent: ActivationConsent

    public static func defaultSchemeManifest() -> LatticeSchemeManifest?
    // lookup(_:) and classifyLatticeCode(_:knownCodes:) — see § 3
}
```

**Rust:**

```rust
pub const VERSION: &str = "0.1.0";
// pub fn lookup(term: &str) -> Anchor;  // see § 3
```

#### `EideticLib.Segmenter` (sentence segmentation)

Centralizes sentence segmentation for the deterministic linguistic
pipeline. The two-method shape mirrors the apple-nlp-accel pattern
used by WordClassTagger (B-6/B-7): `sentencesByDelimiter` is the
deterministic reference (always available, identical across
platforms and ports); `sentences` is the platform-routed entry
that may invoke `NLTokenizer(unit: .sentence)` on Apple. Consumed
by CorpusKit's Chunker (F16, 2026-05-27).

**Swift:**

```swift
public extension EideticLib {
    /// Platform-routed sentence segmentation. Uses NLTokenizer on
    /// Apple platforms when available; falls back to
    /// `sentencesByDelimiter` elsewhere. Empty input → []; non-empty
    /// input always yields at least one covering substring.
    static func sentences(_ text: String) -> [Substring]

    /// Deterministic delimiter-based segmentation: splits on `.`,
    /// `!`, `?`, and newline while preserving the terminator at the
    /// end of each segment. The canonical reference, identical
    /// across platforms and ports. Always callable directly when
    /// strict cross-platform identity is required.
    static func sentencesByDelimiter(_ text: String) -> [Substring]
}
```

**Rust:** the Rust version has no platform-acceleration today, so a
single function suffices; it implements the canonical reference
(byte-for-byte parity with Swift's `sentencesByDelimiter`).

```rust
pub fn sentences(text: &str) -> Vec<String>;   // in module eidetic_lib::segmenter
```

### Tier 2 — additional public surface

Fully public, exercised by EideticLib's own tests and the pending FDC
runtime missions, but not (yet) referenced by any other package. Listed
here by name + one-line + source file; signatures live at the cited file.

| Type / function | One-line | Source (Swift / Rust) |
|---|---|---|
| `MDCCResolution` | resolved code + CC0 source identity + confidence (SPEC § 5, B-2/B-3) | `LatticeResolver.swift` |
| `LatticeResolver.resolve` | label-only MDCC-canon grounding step (SPEC § 4, I-6) | `LatticeResolver.swift` |
| `LatticeCodeState` | `.malformed` / `.known` / `.pending` code state (SPEC § 5, B-5; I-7) | `LatticeCodeState.swift` |
| `LatticeCodeGrammar` | dependency-free MDCC grammar; `maxExtensionDigits == 8` (I-8) | `LatticeCodeState.swift` |
| `ClassificationScheme` | `.mdcc` default vs `.foreign(String)` (SPEC § 4, I-12) | `Scheme.swift` |
| `LatticeSchemeManifest` | canon version + license note + offline flag | `Scheme.swift` |
| `WikidataResolver.resolve` | confirms a canon entry's CC0 Q-ID (SPEC § 5, B-4) | `WikidataResolver.swift` / `wikidata_resolver.rs` |
| `ResolverDecision` | Q-ID + label/alias evidence | `WikidataResolver.swift` / `wikidata_resolver.rs` |
| `WikidataEntry`, `WikidataSubset` | bundled CC0 subset rows + loader | `WikidataSubset.swift` / `wikidata_subset.rs` |
| `Tokenizer.tokenize` | UAX #29 word tokenization | `Tokenizer.swift` / `tokenizer.rs` |
| `Normalizer.normalize` | ASCII case-fold normalize | `Normalizer.swift` / `normalizer.rs` |
| `Stemmer.stem` | Porter2 / English Snowball stem | `Stemmer.swift` / `stemmer.rs` |
| `WordClass` | `.noun` / `.verb` / `.other` (FDC Step 1) | `WordClass.swift` / `word_class.rs` |
| `EideticLib.wordClass` | classify a token; verb-set before noun-set (SPEC § 5, B-6) | `WordClassTagger.swift` / `word_class.rs` |
| `EideticLib.taggerEnabled` | OS-version gate for the platform tagger (B-7) | `WordClassTagger.swift` |
| `WordClassTable` | bundled noun/verb fast-path table + loader | `WordClassTable.swift` / `word_class.rs` |
| `NovelTokenCache` | novel-token pool accumulator; drains at 50 (B-8) | `NovelTokenCache.swift` / `word_class.rs` |
| `PoolEntry`, `PoolSubmission` | pool wire format (cookbook § 2.3) | `NovelTokenCache.swift` / `word_class.rs` |
| `ConsentRecord` | one logged acceptance (scheme id, digest, time) (I-10) | `ConsentGate.swift` |
| `ConsentLedger` | actor holding the per-scheme consent records | `ConsentGate.swift` |
| `ActivationConsent` | the unskippable consent gate (I-9) | `ConsentGate.swift` |
| `PinnedSource` | a pinned, versioned, digest-checked foreign source | `ForeignSourcePipeline.swift` |
| `ForeignSourceFetcher` | injected fetch closure (testability seam) | `ForeignSourcePipeline.swift` |
| `ForeignSourcePipeline` | consent → fetch → verify → atomic assemble (B-9; I-11) | `ForeignSourcePipeline.swift` |
| `PipelineError` | clean-failure error enum — see § 4 | `ForeignSourcePipeline.swift` |

## § 3 — Public functions

The lookup path. Behavioral contracts: SPEC § 5 (B-1…B-5).

### `lookup`

Resolves a term to an `Anchor` deterministically and offline (SPEC § 4,
I-1/I-2; pipeline B-1). The Swift version resolves real MDCC codes today; the
Rust version returns the `not_implemented` sentinel pending the FDC runtime
(SPEC § 9).

**Swift:**

```swift
extension EideticLib {
    public static func lookup(_ term: String) -> Anchor
}
```

**Rust:**

```rust
pub fn lookup(term: &str) -> Anchor;   // currently Anchor::not_implemented()
```

### `classifyLatticeCode`

Classifies a candidate MDCC code string against the grammar and a supplied
known-code set, without loading the canon (SPEC § 5, B-5; I-7).

**Swift:**

```swift
extension EideticLib {
    public static func classifyLatticeCode(
        _ code: String,
        knownCodes: Set<String> = []
    ) -> LatticeCodeState
}
```

**Rust:** present in the Swift version and not yet in the Rust version.

### `defaultSchemeManifest`

Returns the bundled MDCC default scheme's manifest, derived from
LatticeKit's canon version; always present.

**Swift:**

```swift
extension EideticLib {
    public static func defaultSchemeManifest() -> LatticeSchemeManifest?
}
```

**Rust:** not ported.

### `sentences` / `sentencesByDelimiter`

Sentence segmentation for the deterministic linguistic pipeline.
Behavioral contracts: SPEC § 5 (B-10); cross-port parity: SPEC § 7
(C-11). Full signatures live in § 2 Tier 1 under
`EideticLib.Segmenter`.

Tier-2 function signatures (the word-class API, the resolver/pipeline
methods) live at the source files cited in the § 2 Tier-2 table.

## § 4 — Errors

The lookup and word-class surfaces are non-failable (SPEC § 6): no thrown
errors, no error enum. Absence of a match is the empty `Anchor` (SPEC § 4,
I-3); a failed canon load is `Anchor.notImplemented`.

The one error type is `PipelineError`, raised by `ForeignSourcePipeline`
(Tier 2). Every variant leaves the live destination untouched — the
clean-failure category (SPEC § 6, I-11). There is no `EideticLibError`
type; the package does not use the `MOOTx01Error` umbrella because its
only failable surface is the foreign-source pipeline, whose errors are
domain-specific to assembly.

**Swift:**

```swift
public enum PipelineError: Error, Sendable, Hashable {
    case consentMissing(schemeID: String)
    case sourceUnreachable(url: URL, reason: String)
    case digestMismatch(url: URL, expected: String, actual: String)
    case assemblyWriteFailed(reason: String)
}
```

**Rust:** the foreign-source pipeline is present in the Swift version and not yet in the Rust version; the Rust version exposes
no error enum (its `lookup` is infallible and returns the sentinel).

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/libs/EideticLib
```

Target `EideticLibTests`. Suites: `MDCCLookupTests` and `EideticLibTests`
(lookup determinism, empty anchor — C-1/C-2/C-3), `LatticeCodeStateTests`
(grammar parity, pending round-trip — C-4/C-5), `WordClassTaggerTests`
(verb-before-noun, pool threshold — C-6/C-7), `SegmenterTests`
(canonical reference + routed-entry round-trip — C-11), `ConsentGateTests`
(consent gate — C-8), `ForeignSourcePipelineTests` (clean failure +
SHA-256 FIPS 180-4 vectors — C-9), `WikidataResolverTests`,
`WikidataSubsetTests`, `SchemeTests`, `StemmerTests`. Shared vectors:
`Tests/SharedVectors/lookup_vectors.json`,
`Tests/SharedVectors/word_class_vectors.json`.

**Rust:**

```
cargo test -p eidetic-lib
```

`tests/word_class_conformance.rs` (C-6 against the shared word-class
vectors), `tests/segmenter_tests.rs` (C-11 against the delimiter
reference), plus the in-crate `#[cfg(test)]` modules (`anchor`
round-trip — C-10; `lib` lookup sentinel and determinism).

## § 6 — Examples

```swift
import EideticLib

// The consumed path (NeuronKit's LatticeAnchorInference does exactly this):
let anchor = EideticLib.lookup("organic chemistry research")
// anchor.mdccCode   — resolved MDCC code, or "" if nothing matched
// anchor.wikidataQID — the entry's CC0 Q-ID, or nil
// anchor.confidence — 48 high / 32 medium / 16 low / 0 none
// anchor.dataVersion — the canon version that produced the answer

// Classify a stored code against a known-code set (pending round-trips):
switch EideticLib.classifyLatticeCode("547.1", knownCodes: known) {
case .malformed(let raw): // grammar rejected raw
case .known(let code):    // resolvable now
case .pending(let code):  // valid, resolves on the next canon pull
}
```

```rust
use eidetic_lib::lookup;

// Rust lookup returns the not_implemented sentinel until the FDC runtime
// lands (GNO-FDC-06/07); the API surface is stable for integration.
let anchor = lookup("organic chemistry research");
assert_eq!(anchor.confidence, 0);
```

---

*End of EideticLib Interface v0.8.*
