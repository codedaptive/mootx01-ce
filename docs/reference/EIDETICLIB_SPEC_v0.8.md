---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: EideticLib
kind: Lib
relates_to:
  - EIDETICLIB_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - FDC_ENCODER_CANONICAL_v1.0.md  (the FDC encoder + signatures lookup grounds against)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (the anchor-code rung and provenance invariant I-4)
  - COGNITIONKIT_SPEC_v0.85.md  (a downstream consumer of deterministic grounding)
purpose: |
  EideticLib is the deterministic term→Anchor resolver. Pass a term to
  EideticLib.lookup and get back an Anchor carrying an FDC code, the
  concept bag's dominant CC0 Wikidata Q-ID, a confidence packed into the
  substrate provenance value set, and the FDC signatures version that
  produced the answer. lookup delegates to LatticeLib's FDC encoder
  (FDC.encodeAnchor); resolution is offline, pure, and reproducible
  against LatticeLib's pinned FDC artifacts. The network is never
  consulted. EideticLib also carries the FDC code-state classifier and the
  sentence segmenter consumed by CorpusKit. The companion INTERFACE
  document carries the signatures.
---

# EideticLib Specification

## § 1 — What this package is

EideticLib is the deterministic text-to-anchor utility at the base of the
reasoning layer. A caller hands it a term — a word, a phrase — and it
returns an `Anchor`: an FDC classification code, the resolved concept
bag's dominant CC0 Wikidata Q-ID, a confidence value, and the FDC
signatures version that produced the answer. NeuronKit's
`LatticeAnchorInference` is the primary consumer; it calls
`EideticLib.lookup` to ground content before the reasoning layer records
the resulting anchor code rung (architecture spec § I-4, the
model-provenance invariant — though EideticLib's own resolution is
deterministic, not model-generated, and records the FDC signatures
version rather than a model id).

The grounding path is fixed and offline. `lookup` delegates to
LatticeLib's FDC encoder (`FDC.encodeAnchor`): the term is canonicalized
to a concept bag and matched against the pinned FDC signatures, producing
an FDC code; the bag's dominant CC0 Wikidata Q-ID is carried as the anchor
concept. No step consults a network. Determinism is guaranteed against
LatticeLib's pinned FDC artifacts (lexicon, frame, signatures), which are
parsed once per process and cached.

This package is a **Lib**: pure resolution functions over LatticeLib's
build-time-constant FDC reference data, with no managed estate or
lifecycle. It holds no classification data of its own — the FDC lexicon,
frame, and signatures are owned and cached by LatticeLib's FDC runtime.

## § 2 — Scope

This specification defines:

- The `Anchor` (Eidetic) result and the meaning of each field, including
  the empty-anchor vs. sentinel distinction.
- The deterministic `lookup` path: delegate to LatticeLib's FDC encoder
  (concept-bag canonicalization → FDC code) and carry the bag's dominant
  CC0 Wikidata Q-ID.
- The confidence mapping for a resolved code.
- The FDC code-state classification (`malformed` / `known` / `pending`)
  and the round-trip guarantee for pending codes.
- Sentence segmentation: the deterministic delimiter reference and the
  optional Apple acceleration path.

This specification does NOT define:

- API signatures — those live in `EIDETICLIB_INTERFACE_v0.8.md`.
- The FDC encoder internals, the FDC signatures, the frame, or the
  signatures-versioning scheme — those are LatticeLib's
  (`FDC_ENCODER_CANONICAL_v1.0.md`). EideticLib resolves through the FDC
  encoder; it does not own it.
- The anchor code rung's place in the memory ladder or the provenance
  fields it feeds — see `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md`.
- How an estate stores or indexes anchors — see `LOCUSKIT_SPEC_v0.8.md`
  and `VECTORKIT_SPEC_v0.8.md`.

## § 3 — Position in the kit family

```
LatticeLib            (FDC encoder + signatures + Code grammar)
   ▲
EideticLib            ← depends on LatticeLib
   ▲
NeuronKit             (LatticeAnchorInference calls EideticLib.lookup)
   ▲
GeniusLocusKit / CognitionKit  (reasoning + behaviour recipes)
```

**Depends on:** LatticeLib (the FDC encoder `FDC.encodeAnchor`, the pinned
FDC artifacts, the signatures version). Foundation. No other Swift
package; the Rust version depends only on `serde`, `serde_json`, and
`unicode-segmentation`.

**Consumed by:** NeuronKit (via `EideticLib.lookup` returning `Anchor`)
and CorpusKit (via `EideticLib.sentences` / `EideticLib.sentencesByDelimiter`,
called by `CorpusKit.Chunker`; F16, 2026-05-27).

## § 4 — Invariants

**I-1 (offline lookup):** `EideticLib.lookup` never performs network I/O.
Every byte it reads is from LatticeLib's build-time-bundled FDC artifacts
(lexicon, frame, signatures). There is no network-touching surface in the
package.

**I-2 (determinism):** for a fixed bundled FDC signatures version and a
fixed input term, `lookup` returns a byte-identical `Anchor` on every call
and across both legs for artifact-resident inputs. No clock and no
randomness enters the lookup path.

**I-3 (no fallback code):** when the FDC encoder matches nothing, `lookup`
returns an **empty anchor** (`code == ""`, `wikidataQID == nil`,
`confidence == 0`, the live FDC signatures version) — never a guessed or
default code. The empty anchor is distinct from the `notImplemented`
sentinel, which is returned only when LatticeLib's FDC artifacts fail to
load (a build/configuration error, carrying `dataVersion == "0.1.0-stub"`).

**I-4 (Anchor shape parity):** `Anchor` is pure data with a byte-identical
shape across the Swift and Rust versions — `code: String`,
`wikidataQID: String?`, `confidence: UInt8`, `dataVersion: String`. Its
JSON encoding is camelCase in both legs.

**I-5 (confidence value set):** `Anchor.confidence` only ever holds a value
from the substrate provenance confidence value set — `0` (null), `16`
(low), `32` (medium), `48` (high), `56` (verified). The FDC encoder
carries no calibrated confidence score, so EideticLib reports a resolved
code at `32` (medium) and a miss at `0`; it never emits an arbitrary
integer.

**I-6 (no hidden state):** EideticLib holds no mutable state on the lookup
path. The FDC reference data is owned and cached by LatticeLib's FDC
runtime; EideticLib reads through `FDC.encodeAnchor` and adds no cache of
its own.

**I-7 (pending-code round-trip):** a well-formed FDC code absent from the
caller's bound known-code set classifies as `.pending` and round-trips
intact through `Codable` storage. A pending code is queryable as pending
until a caller learns it as known; it is never silently dropped or
rewritten.

**I-8 (grammar parity):** `LatticeCodeGrammar.isWellFormed` is a
dependency-free reimplementation of LatticeLib's `Code.isWellFormed` and
agrees with it bit-for-bit on the shared conformance vectors. The
`maxExtensionDigits` constant (8) is locked across both implementations.

**I-9 (sentence segmentation parity):** `EideticLib.sentencesByDelimiter`
(Swift) and `eidetic_lib::segmenter::sentences` (Rust) implement the same
delimiter-based algorithm and produce byte-identical segmentation for
every shared input. The Apple-platform `EideticLib.sentences` is a platform-
routed entry that may invoke `NLTokenizer(unit: .sentence)` on Apple
when available; on Apple it MAY diverge from the canonical reference for
language-specific edge cases (abbreviations, quotation handling), and
that divergence is federation-safe because downstream consumers (e.g.
`CorpusKit.Chunker`) content-address by `(sourceID, startOffset, text)`
under an append-only conflict policy — divergent segmentation yields a
superset of independently-addressed chunks across devices, never a
conflicting write.

## § 5 — Behavioral contracts

**B-1 (lookup delegation):** `lookup(term)` delegates to
`FDC.encodeAnchor(term)`, which canonicalizes the term to a concept bag
and matches it against the pinned FDC signatures, returning an FDC code
(or none) and the bag's dominant CC0 Wikidata Q-ID (or none).

**B-2 (resolved result):** when the FDC encoder returns a code, `lookup`
builds an `Anchor` carrying that code, the dominant concept Q-ID, the
medium confidence (B-3), and the live FDC signatures version.

**B-3 (confidence mapping):** a resolved FDC code → `32` (medium); no
match → empty anchor at `0` (I-3). The FDC encoder does not produce a
calibrated per-result confidence, so resolved codes are reported uniformly
at medium.

**B-4 (Q-ID carry):** the concept bag's dominant Wikidata Q-ID is carried
as `Anchor.wikidataQID`. When the encoder surfaces no dominant Q-ID, the
field is `nil`.

**B-5 (code-state classification):** `classifyLatticeCode(code,
knownCodes:)` returns `.malformed` if the grammar rejects the code,
`.known` if it is well-formed and in `knownCodes`, else `.pending`. The
grammar is three ASCII digits, optionally a dot and 1…8 ASCII digits.

**B-10 (sentence segmentation: reference and routed entry):**
`sentencesByDelimiter(text)` splits on `.`, `!`, `?`, and newline,
preserving the terminator at the end of each segment; empty input
yields an empty result; non-empty input yields at least one substring
covering the entire input. `sentences(text)` returns
`sentencesByDelimiter(text)` on non-Apple platforms; on Apple
platforms it invokes `NLTokenizer(unit: .sentence)` and may yield a
different segmentation for language-specific edge cases. Both
functions are pure and total over their inputs.

## § 6 — Error model (conceptual)

The deterministic `lookup` path is non-failable: there are no thrown
errors. Absence of a match is data, not an error (the empty anchor, I-3);
a failed FDC-artifact load is the `notImplemented` sentinel, not a throw.
The code-state and segmentation surfaces are likewise non-failable. The
package has no error enum and does not use the `MOOTx01Error` umbrella.

## § 7 — Conformance requirements

**C-1 (lookup determinism):** `lookup(term)` returns the same `Anchor` for
the same term and bundled FDC signatures version on repeated calls (I-2).
Verified in `LatticeLookupTests` / `EideticLibTests`.

**C-2 (no fallback code):** a term the FDC encoder does not match yields
the empty anchor (`code == ""`, `confidence == 0`), distinct from the
`notImplemented` sentinel (I-3).

**C-4 (grammar parity):** `LatticeCodeGrammar.isWellFormed` agrees with
LatticeLib's `Code.isWellFormed` on the shared conformance vectors, and
`maxExtensionDigits == 8` in both (I-8). Verified in `LatticeCodeStateTests`
and LatticeLib's `CodeTests`.

**C-5 (pending round-trip):** a well-formed unknown code classifies as
`.pending` and survives a `Codable` encode/decode round-trip unchanged
(I-7).

**C-10 (Anchor shape parity):** the Swift `Anchor` and Rust `Anchor`
encode to identical camelCase JSON for the same field values (I-4);
verified by the Rust `anchor_roundtrips_through_json` test against the
Swift Codable shape.

**C-11 (sentence segmentation parity):** for every input in the shared
segmenter vectors, Swift `EideticLib.sentencesByDelimiter` and Rust
`eidetic_lib::segmenter::sentences` produce identical segment counts and
identical segment contents (B-10, I-9). The Swift routed entry
`EideticLib.sentences` round-trips back to the original input on inputs
that don't exercise language-specific edge cases. Verified in Swift
`SegmenterTests` and Rust `tests/segmenter_tests.rs`.
