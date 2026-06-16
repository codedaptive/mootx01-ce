---
title: EideticLib Interface
version: 1.0.0
status: active
date: 2026-06-14
description: Public API surface for EideticLib in both the Swift and Rust ports.
spec_type: kit
authors: MOOTx01 maintainers
package: EideticLib
languages: [swift, rust]
relates_to:
  - EIDETICLIB_SPEC.md  (the contract this interface implements)
  - FDC_ENCODER_CANONICAL.md  (the FDC encoder EideticLib.lookup grounds against)
purpose: |
  Public API surface of EideticLib in both ports. Documents the term→Anchor
  lookup path that other packages consume (the EideticLib namespace and the
  Anchor result), the FDC code-state classifier (classifyLatticeCode /
  LatticeCodeState), and the sentence segmenter consumed by
  CorpusKit.Chunker. lookup is FDC-backed: it delegates
  to LatticeLib's FDC encoder (FDC.encodeAnchor), so EideticLib holds no
  classification data of its own. The companion SPEC carries the
  behavioral contracts.
---

# EideticLib Interface

## § 1 — Package layout

**Swift:** `packages/libs/EideticLib/`

- `Sources/EideticLib/EideticLib.swift` — the `EideticLib` namespace
  (`lookup`, `classifyLatticeCode`, `version`) and the `Anchor` result.
  `lookup` delegates to LatticeLib's `FDC.encodeAnchor`; EideticLib holds
  no classification reference data of its own.
- `Sources/EideticLib/LatticeCodeState.swift` — `LatticeCodeState`,
  `LatticeCodeGrammar` (the FDC code grammar, dependency-free)
- `Sources/EideticLib/Segmenter.swift` — sentence segmentation
  (`sentences`, `sentencesByDelimiter`)
- `Sources/EideticLib/Resources/` — package resources
- `Tests/EideticLibTests/`, `Package.swift`

The FDC reference artifacts (lexicon, frame, signatures) are owned and
cached by **LatticeLib**'s FDC runtime, not by EideticLib. EideticLib
depends on LatticeLib for the lookup path.

**Rust:** `packages/libs/EideticLib/rust/` (crate `eidetic-lib`,
lib name `eidetic_lib`)

- `src/lib.rs` — `lookup`, `VERSION`, re-exports
- `src/anchor.rs` — `Anchor`
- `src/segmenter.rs` — the segmentation reference
- `tests/segmenter_tests.rs`, `examples/benchmark.rs`, `Cargo.toml`

Both versions expose the consumed surface: the term→Anchor lookup path,
the FDC code-state classifier, and the deterministic sentence segmenter.
The two ports produce byte-identical results for every shared input on
the segmenter reference path; Swift is the authoritative design surface
for the FDC-backed lookup.

## § 2 — Public types

The consumed surface is the term→Anchor lookup path (NeuronKit, via
`EideticLib.lookup` → `Anchor`), the code-state classifier, and the
sentence segmenter (CorpusKit.Chunker).

#### `Anchor`

The result of a lookup — the Eidetic. Pure data; byte-identical shape
across ports (SPEC § 4, I-4).

**Swift:**

```swift
public struct Anchor: Equatable, Sendable, Codable {
    public let code: String            // "" means the FDC encoder matched nothing
    public let wikidataQID: String?    // the concept bag's dominant CC0 Q-ID, or nil
    public let confidence: UInt8       // provenance value set: 0/16/32/48/56
    public let dataVersion: String     // the FDC signatures version that produced this

    public init(code: String, wikidataQID: String?, confidence: UInt8, dataVersion: String)
    // No sentinel member: a failed FDC-artifact load crashes loud
    // (fatalError), it does not return a placeholder Anchor (I-3).
}
```

**Rust:**

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Anchor {
    pub code: String,
    pub wikidata_qid: Option<String>,
    pub confidence: u8,
    pub data_version: String,
}
// No sentinel constructor: a failed FDC-artifact load panics, it does
// not return a placeholder Anchor (I-3).
```

#### `EideticLib` (namespace)

The module surface. Stateless from the caller's perspective; the FDC
reference data is parsed once by LatticeLib and cached for the process
lifetime (SPEC § 4, I-1, I-2). Functions are in § 3.

**Swift:**

```swift
public enum EideticLib {
    public static let version: String   // "0.1.0"
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
pipeline. `sentencesByDelimiter` is the deterministic reference (always
available, identical across platforms and ports); `sentences` is the
platform-routed entry that may invoke `NLTokenizer(unit: .sentence)` on
Apple. Consumed by CorpusKit's Chunker.

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

**Rust:** the Rust version implements the canonical reference
(byte-for-byte parity with Swift's `sentencesByDelimiter`); on non-Apple
hosts `sentences` and `sentencesByDelimiter` are the same deterministic path.

```rust
pub fn sentences(text: &str) -> Vec<String>;   // in module eidetic_lib::segmenter
```

#### Code-state types

| Type | One-line | Source (Swift) |
|---|---|---|
| `LatticeCodeState` | `.malformed` / `.known` / `.pending` code state (SPEC § 5, B-5; I-7) | `LatticeCodeState.swift` |
| `LatticeCodeGrammar` | dependency-free FDC code grammar; `maxExtensionDigits == 8` (I-8) | `LatticeCodeState.swift` |

## § 3 — Public functions

The lookup path. Behavioral contracts: SPEC § 5 (B-1…B-5).

### `lookup`

Resolves a term to an `Anchor` deterministically and offline (SPEC § 4,
I-1/I-2; pipeline B-1). `lookup` delegates to LatticeLib's
`FDC.encodeAnchor`: the term is canonicalized to a concept bag and matched
against the pinned FDC signatures, producing an FDC code and the bag's
dominant CC0 Wikidata Q-ID. The network is never consulted.

**Swift:**

```swift
extension EideticLib {
    public static func lookup(_ term: String) -> Anchor
}
```

**Rust:**

```rust
pub fn lookup(term: &str) -> Anchor;
```

### `classifyLatticeCode`

Classifies a candidate FDC code string against the grammar and a supplied
known-code set, without loading the FDC reference data (SPEC § 5, B-5;
I-7).

**Swift:**

```swift
extension EideticLib {
    public static func classifyLatticeCode(
        _ code: String,
        knownCodes: Set<String> = []
    ) -> LatticeCodeState
}
```

**Rust:**

```rust
pub fn classify_lattice_code(code: &str, known_codes: &HashSet<String>) -> LatticeCodeState;
```

### `sentences` / `sentencesByDelimiter`

Sentence segmentation for the deterministic linguistic pipeline.
Behavioral contracts: SPEC § 5 (B-10); cross-port parity: SPEC § 7
(C-11). Full signatures live in § 2 under `EideticLib.Segmenter`.

## § 4 — Errors

The lookup and code-state surfaces are non-failable on valid input (SPEC
§ 6): no thrown errors, no error enum. Absence of a match is the empty
`Anchor` (SPEC § 4, I-3). A failed FDC-artifact load is a
build/configuration error that crashes loud (`fatalError` / `panic!`) — it
never returns a sentinel `Anchor`. There is no `EideticLibError` type and
the package does not use the `MOOTx01Error` umbrella.

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/libs/EideticLib
```

Target `EideticLibTests`. Suites: `LatticeLookupTests` and `EideticLibTests`
(lookup determinism, empty anchor — C-1/C-2), `LatticeCodeStateTests`
(grammar parity, pending round-trip — C-4/C-5), `SegmenterTests`
(canonical reference + routed-entry round-trip — C-11), `StemmerTests`.

**Rust:**

```
cargo test -p eidetic-lib
```

`tests/segmenter_tests.rs` (C-11 against the delimiter reference), plus
the in-crate `#[cfg(test)]` modules (`anchor` round-trip — C-10; `lib`
lookup determinism and the crash-loud-on-missing-artifacts posture).

## § 6 — Examples

```swift
import EideticLib

// The consumed path (NeuronKit's LatticeAnchorInference does exactly this):
let anchor = EideticLib.lookup("organic chemistry research")
// anchor.code        — resolved FDC code, or "" if the encoder matched nothing
// anchor.wikidataQID — the concept bag's dominant CC0 Q-ID, or nil
// anchor.confidence  — 32 (medium) for a resolved code, 0 for a miss
// anchor.dataVersion — the FDC signatures version that produced the answer

// Classify a stored code against a known-code set (pending round-trips):
switch EideticLib.classifyLatticeCode("547.1", knownCodes: known) {
case .malformed(let raw): // grammar rejected raw
case .known(let code):    // resolvable now
case .pending(let code):  // valid, resolves once the code is learned
}
```

```rust
use eidetic_lib::lookup;

let anchor = lookup("organic chemistry research");
// anchor.code        — resolved FDC code, or "" if the encoder matched nothing
// anchor.wikidata_qid — the concept bag's dominant CC0 Q-ID, or None
// anchor.confidence  — 32 (medium) for a resolved code, 0 for a miss
```

## § 7 — Swift/Rust Concordance

Swift is the reference of record.

### `LatticeCodeState` enum

| Aspect | Swift | Rust | Status |
|---|---|---|---|
| Type | `enum LatticeCodeState` (Sendable, Hashable, Codable) | `enum LatticeCodeState` (Serialize, Deserialize) | Parity |
| Cases | `.malformed(String)`, `.known(String)`, `.pending(String)` | `Malformed(String)`, `Known(String)`, `Pending(String)` | Parity |
| `rawCode` / `raw_code()` | computed var returning the associated value | method returning `&str` | Parity |
| `isWellFormed` / `is_well_formed()` | computed Bool | method returning bool | Parity |
| JSON round-trip | Codable (`enum`-keyed encoding) | Serde tagged enum (`#[serde(tag="state", content="code")]`) | Parity — round-trip tested |
| Source | `Sources/EideticLib/LatticeCodeState.swift` | `rust/src/lattice_code_state.rs` | |

### `LatticeCodeGrammar`

| Aspect | Swift | Rust | Status |
|---|---|---|---|
| Type | `enum LatticeCodeGrammar` (caseless namespace) | `struct LatticeCodeGrammar` (unit struct) | Equivalent |
| `maxExtensionDigits` / `MAX_EXTENSION_DIGITS` | `public static let maxExtensionDigits: Int = 8` | `pub const MAX_EXTENSION_DIGITS: usize = 8` | Parity — locked |
| `isWellFormed(_:)` / `is_well_formed(_:)` | grammar: 3 ASCII digits, optional `.` + 1–8 ASCII digits | Same grammar | Parity — shared test vectors |
| Source | `Sources/EideticLib/LatticeCodeState.swift` | `rust/src/lattice_code_state.rs` | |

### `classifyLatticeCode` / `classify_lattice_code`

| Aspect | Swift | Rust | Status |
|---|---|---|---|
| Signature | `EideticLib.classifyLatticeCode(_ code: String, knownCodes: Set<String>) -> LatticeCodeState` | `classify_lattice_code(code: &str, known_codes: &HashSet<String>) -> LatticeCodeState` | Parity |
| Behavior | malformed → `.malformed`; in knownCodes → `.known`; else → `.pending` | Same logic | Parity |
| FDC data loaded | No — grammar check only | No — grammar check only | Parity |
| Source | `Sources/EideticLib/EideticLib.swift` | `rust/src/lattice_code_state.rs` (fn) + `rust/src/lib.rs` (re-export as `classify`) | |

### `lookup` / `lookup`

| Aspect | Swift | Rust | Status |
|---|---|---|---|
| Signature | `EideticLib.lookup(_ term: String) -> Anchor` | `pub fn lookup(term: &str) -> Anchor` | Parity |
| Delegation | `FDC.encodeAnchor(term)` in LatticeLib | `Fdc::encode_anchor(term)` in lattice-lib | Parity |
| Confidence for resolved code | 32 (medium) | 32 (medium) | Parity |
| Confidence for unresolved | 0 | 0 | Parity |
| Missing FDC artifacts | `fatalError` if `FDC.isAvailable == false` | `panic!` if `Fdc::is_available() == false` | Parity — crash loud, no sentinel |
| Behavioral tests | Pass | Pass | Parity |
| Exact-code conformance (SharedVectors/lookup_vectors.json) | Pass | Pass | Parity |
| Source | `Sources/EideticLib/EideticLib.swift` | `rust/src/lib.rs` | |

### `Anchor` struct

| Aspect | Swift | Rust | Status |
|---|---|---|---|
| Fields | `code: String`, `wikidataQID: String?`, `confidence: UInt8`, `dataVersion: String` | `code: String`, `wikidata_qid: Option<String>`, `confidence: u8`, `data_version: String` | Parity |
| Sentinel constructor | none — failed load crashes loud (I-3) | none — failed load panics (I-3) | Parity |
| JSON | Codable (camelCase keys) | Serde `rename_all = "camelCase"` | Parity |
| Source | `Sources/EideticLib/EideticLib.swift` | `rust/src/anchor.rs` | |

### Conformance gate — lookup_vectors.json

Cross-language lookup conformance is gated by `SharedVectors/lookup_vectors.json`,
whose `expected_code` field carries the FDC code each term must resolve to.
These codes are FDC codes (not UDC/Universal Decimal Classification codes);
the Swift and Rust engines produce identical results for every shared input.
Conformance is exercised by `LookupConformanceTests` (Swift) and
`rust/tests/lookup_conformance_test.rs` (Rust).

---

*End of EideticLib Interface.*

## Changelog

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
