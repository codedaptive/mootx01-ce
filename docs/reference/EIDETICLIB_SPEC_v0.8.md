---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: EideticLib
kind: Lib
relates_to:
  - EIDETICLIB_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - LATTICEKIT_SPEC_v0.8.md  (the MDCC canon + Code grammar this package resolves against)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (the mdccCode rung and provenance invariant I-4)
  - COGNITIONKIT_SPEC_v0.1.md  (a downstream consumer of deterministic grounding)
purpose: |
  EideticLib is the deterministic term→Anchor resolver. Pass a term to
  EideticLib.lookup and get back an Eidetic — an Anchor carrying an MDCC
  code, the canon entry's CC0 Wikidata Q-ID, a confidence packed into the
  substrate provenance value set, and the canon version that produced the
  answer. Resolution is offline, pure, and reproducible against the
  pinned canon LatticeKit bundles; the network is never consulted on the
  lookup path. The package also carries the FDC encoder Step-1 word-class
  surface and the opt-in, consent-gated foreign-source assembly pipeline.
  The companion INTERFACE document carries the signatures.
---

# EideticLib Specification

## § 1 — What this package is

EideticLib is the deterministic text-to-anchor utility at the base of the
reasoning layer. A caller hands it a term — a word, a phrase — and it
returns an `Anchor`: an MDCC classification code, the resolved canon
entry's CC0 Wikidata Q-ID, a confidence value, and the canon version that
produced the answer. NeuronKit's `LatticeAnchorInference` is the primary
consumer; it calls `EideticLib.lookup` to ground content before the
reasoning layer records the resulting `mdccCode` rung (architecture spec
§ I-4, the model-provenance invariant — though EideticLib's own resolution
is deterministic, not model-generated, and records the canon version
rather than a model id).

The grounding pipeline is fixed and offline: tokenize (UAX #29), normalize
(case-fold), stem (Porter2 / English Snowball), then resolve the
normalized/stemmed tokens against the bundled MDCC canon LatticeKit
publishes, and finally carry the resolved entry's CC0 Wikidata Q-ID,
confirmed against the bundled CC0 subset. No step consults a network.
Determinism is guaranteed against the pinned canon version.

Alongside the lookup path, EideticLib carries two further surfaces that
are present in the package but not yet consumed by other packages: the
FDC encoder **Step-1 word-class** surface (`wordClass`, the static
fast-path table, the platform-tagger fallback, and the novel-token pool
cache), and the **consent-gated foreign-source** machinery
(`ActivationConsent`, `ConsentLedger`, `ForeignSourcePipeline`) that lets a
user opt in to fetching and assembling share-alike/attribution-licensed
schemes on their own machine. Foreign-licensed data never ships in the
binary.

This package is a **Lib**: pure resolution functions over bundled,
build-time-constant reference data, with no managed estate or lifecycle.
The one stateful corner is deliberate and isolated — `ConsentLedger` /
`ActivationConsent` are actors guarding the consent record set, and
`NovelTokenCache` is a lock-guarded accumulator; neither is on the
deterministic `lookup` path.

## § 2 — Scope

This specification defines:

- The `Anchor` (Eidetic) result and the meaning of each field, including
  the empty-anchor vs. sentinel distinction.
- The deterministic `lookup` pipeline: tokenize → normalize → stem →
  resolve against the MDCC canon → carry the entry's CC0 Wikidata Q-ID.
- The MDCC-canon resolution contract: label-only matching, the
  deterministic ranking vector, and the confidence mapping.
- The MDCC code-state classification (`malformed` / `known` / `pending`)
  and the round-trip guarantee for pending codes.
- The classification-scheme model: the bundled offline MDCC default vs.
  consent-gated foreign schemes.
- The FDC encoder Step-1 word-class contract: the fast-path table, the
  platform-tagger fallback boundary, and the novel-token pool cache.
- Sentence segmentation: the deterministic delimiter reference and the
  optional Apple acceleration path.
- The consent gate and foreign-source assembly contract: unskippable,
  logged, per-scheme consent; clean-failure atomic assembly.

This specification does NOT define:

- API signatures — those live in `EIDETICLIB_INTERFACE_v0.8.md`.
- The MDCC canon contents, the `Code` grammar's authoritative form, or
  the canon-versioning scheme — those are LatticeKit's
  (`LATTICEKIT_SPEC_v0.8.md`). EideticLib resolves against the canon;
  it does not own it.
- The `mdccCode` rung's place in the memory ladder or the provenance
  fields it feeds — see `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md`.
- How an estate stores or indexes anchors — see `LOCUSKIT_SPEC_v0.8.md`
  and `VECTORKIT_SPEC_v0.8.md`.

## § 3 — Position in the kit family

```
LatticeKit            (MDCC canon + Code grammar)
   ▲
EideticLib            ← depends on LatticeKit
   ▲
NeuronKit             (LatticeAnchorInference calls EideticLib.lookup)
   ▲
GeniusLocusKit / CognitionKit  (reasoning + behaviour recipes)
```

**Depends on:** LatticeKit (the bundled MDCC canon and its canon version;
`LatticeCanon`, `LatticeEntry`). Foundation. No other Swift package; the
Rust version depends only on `serde`, `serde_json`, `unicode-segmentation`,
`rust-stemmers`, and `aho-corasick`.

**Consumed by:** NeuronKit (via `EideticLib.lookup` returning `Anchor`)
and CorpusKit (via `EideticLib.sentences` / `EideticLib.sentencesByDelimiter`,
called by `CorpusKit.Chunker`; F16, 2026-05-27). The FDC word-class
surface and the foreign-source pipeline are part of the public API but
are exercised only by EideticLib's own tests and the FDC runtime
missions pending downstream.

## § 4 — Invariants

**I-1 (offline lookup):** `EideticLib.lookup` never performs network I/O.
Every byte it reads is from the build-time-bundled MDCC canon (LatticeKit)
and the bundled CC0 Wikidata subset. The only network-touching surface in
the package is the consent-gated `ForeignSourcePipeline`, which is not on
the lookup path.

**I-2 (determinism):** for a fixed bundled canon version and a fixed input
term, `lookup` returns a byte-identical `Anchor` on every call and across
both ports for table-/canon-resident inputs. No clock and no randomness
enters the lookup path; any time a sub-surface needs a timestamp
(consent acceptance) it is passed in as a `now` parameter per the
determinism rule.

**I-3 (no fallback code):** when no canon entry matches the term, `lookup`
returns an **empty anchor** (`mdccCode == ""`, `wikidataQID == nil`,
`confidence == 0`, the live canon version) — never a guessed or default
code. The empty anchor is distinct from the `notImplemented` sentinel,
which is returned only when the bundled canon fails to load (a build/
configuration error, carrying `dataVersion == "0.1.0-stub"`).

**I-4 (Anchor shape parity):** `Anchor` is pure data with a byte-identical
shape across the Swift and Rust ports — `mdccCode: String`,
`wikidataQID: String?`, `confidence: UInt8`, `dataVersion: String`. Its
JSON encoding is camelCase in both ports.

**I-5 (confidence value set):** `Anchor.confidence` only ever holds a value
from the substrate provenance confidence value set — `0` (null), `16`
(low), `32` (medium), `48` (high), `56` (verified). EideticLib emits `48`,
`32`, `16`, or `0`; it never emits an arbitrary integer.

**I-6 (label-only resolution):** MDCC resolution matches input tokens
against canon-entry **labels only** (`LatticeEntry` carries no aliases
field). A position matches a candidate when its normalized form is in the
label's normalized token set OR its stemmed form is in the label's stemmed
token set.

**I-7 (pending-code round-trip):** a well-formed MDCC code absent from the
caller's bound canon classifies as `.pending` and round-trips intact
through `Codable` storage. A pending code is queryable as pending until a
later canon resolves it; it is never silently dropped or rewritten.

**I-8 (grammar parity):** `LatticeCodeGrammar.isWellFormed` is a
dependency-free reimplementation of LatticeKit's `Code.isWellFormed` and
agrees with it bit-for-bit on the shared conformance vectors. The
`maxExtensionDigits` constant (8) is locked across both implementations.

**I-9 (consent unskippable):** there is no path from the public API to a
foreign-source fetch that does not first pass `verifyConsent(forScheme:)`.
`ForeignSourcePipeline.assemble` performs the consent check before any
network or filesystem I/O, and aborts with `consentMissing` if it fails.

**I-10 (consent logged, per-scheme):** every acceptance produces a
`ConsentRecord` (scheme id, license-text digest, caller-supplied
timestamp) in the ledger, keyed by scheme id. Consent is granted per
foreign scheme; granting one scheme grants no other.

**I-11 (clean-failure assembly):** on any pipeline failure — missing
consent, unreachable source, digest mismatch, write error — the staging
directory is removed and the live destination is left in its exact prior
state (including non-existence). No half-assembled state is ever promoted.

**I-12 (no foreign data in the binary):** the MDCC default scheme is the
only scheme shipped complete in the bundle. Foreign-licensed schemes are
assembled on the user's machine via the opt-in pipeline; their data never
ships inside the binary.

**I-13 (sentence segmentation parity):** `EideticLib.sentencesByDelimiter`
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

**B-1 (lookup pipeline order):** `lookup(term)` runs tokenize →
normalize → stem → `LatticeResolver.resolve` → Q-ID confirmation, in that
order. The normalized and stemmed token arrays are positionally aligned
and the same length as the token array.

**B-2 (resolution ranking):** among candidate entries (those matching at
least one input position) the resolver maximizes the lexicographic vector
`(exactLabel, matchedInputCount, −extraLabelTokens, −codeOrder)`:
exact-label match wins first; then the count of matched input positions;
then fewer extra (input-absent) label tokens; the final deterministic
tiebreak is the lowest (most canonical) code string ascending.

**B-3 (confidence mapping):** an exact label match → `48` (high); a label
that fully covers the input but is not an exact set match → `32` (medium);
a partial hit → `16` (low); no candidate → empty anchor at `0` (I-3).

**B-4 (Q-ID confirmation):** the resolved entry's `sourceIdentity` is its
CC0 Wikidata Q-ID. `WikidataResolver.resolve` surfaces that Q-ID and
confirms it against the bundled CC0 subset, recording label/alias evidence.
A canon Q-ID the subset does not carry is surfaced anyway, with zero
evidence; a missing `sourceIdentity` yields `nil`.

**B-5 (code-state classification):** `classifyLatticeCode(code,
knownCodes:)` returns `.malformed` if the grammar rejects the code,
`.known` if it is well-formed and in `knownCodes`, else `.pending`. The
grammar is three ASCII digits, optionally a dot and 1…8 ASCII digits.

**B-6 (word-class fast path then fallback):** `wordClass(token)` lowercases
the token, returns `.other` for an empty token, then tests the static verb
set **before** the noun set (a token in both resolves to `.verb`); a token
in neither falls to the platform tagger. Table-resident results are
cross-platform identical; novel-token results are platform-specific.

**B-7 (tagger OS gate, fail-closed):** the platform tagger runs only when
the running OS meets the table's pinned `min_os_version`; below it the
table-only path returns `.other` for novel tokens and records nothing. An
unparseable `min_os_version` disables the tagger (fail closed).

**B-8 (pool submission at threshold):** `NovelTokenCache.record` accumulates
tagged novel tokens and, exactly at `poolSubmitThreshold` (50), builds the
wire payload, drains, and hands it to the injected submitter — fire-and-
forget, outside the lock, never altering the returned `WordClass`. The
default submitter is a no-op until the pool endpoint is wired.

**B-9 (assembly promotion):** on success `assemble` fetches the payload,
verifies its SHA-256 against the pinned `expectedDigest`, writes it to a
per-run staging directory atomically, then promotes it to the live
destination (direct move when no prior file exists, atomic replace
otherwise), and removes staging. The returned URL is the live destination.

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
a failed canon load is the `notImplemented` sentinel, not a throw. The
word-class surface is likewise non-failable.

The failable surface is the consent-gated foreign-source pipeline. Its
errors form one category — **clean-failure** — meaning every variant
leaves the live destination untouched (I-11). The concrete enum cases and
their per-language shapes live in INTERFACE § 4.

| Category | Trigger | Recovery posture |
|---|---|---|
| consent missing | no `ConsentRecord` for the requested scheme id (I-9) | abort before any I/O; prompt for activation, then retry |
| source unreachable | fetcher cannot reach or read the source | abort; retry later; live state untouched |
| digest mismatch | downloaded payload's SHA-256 ≠ pinned `expectedDigest` | abort; do not assemble; re-pin or re-fetch |
| assembly write failed | staging/destination directory or move failed | abort; staging removed; surface to caller |

## § 7 — Conformance requirements

**C-1 (lookup determinism):** `lookup(term)` returns the same `Anchor` for
the same term and bundled canon version on repeated calls (I-2). Verified
in `MDCCLookupTests` / `EideticLibTests` against `lookup_vectors.json`.

**C-2 (no fallback code):** a term with no canon match yields the empty
anchor (`mdccCode == ""`, `confidence == 0`), distinct from the
`notImplemented` sentinel (I-3).

**C-3 (ranking + confidence):** for the shared lookup vectors the resolver
selects the entry that maximizes the B-2 vector and assigns the B-3
confidence; ties resolve to the lowest code string.

**C-4 (grammar parity):** `LatticeCodeGrammar.isWellFormed` agrees with
LatticeKit's `Code.isWellFormed` on the shared conformance vectors, and
`maxExtensionDigits == 8` in both (I-8). Verified in `LatticeCodeStateTests`
and LatticeKit's `CodeTests`.

**C-5 (pending round-trip):** a well-formed unknown code classifies as
`.pending` and survives a `Codable` encode/decode round-trip unchanged
(I-7).

**C-6 (word-class ordering + cross-platform):** `wordClass` checks verbs
before nouns and is cross-platform identical for table-resident tokens
(B-6); verified against `word_class_vectors.json` in both ports
(`WordClassTaggerTests`, Rust `word_class_conformance`).

**C-7 (pool threshold):** `NovelTokenCache` drains exactly at 50 entries,
not before, and the drained payload carries the table version, platform,
and tagger version (B-8).

**C-8 (consent gate):** `assemble` throws `consentMissing` and performs no
I/O when no consent record exists for the scheme (I-9); a recorded consent
admits the run (`ConsentGateTests`).

**C-9 (clean failure):** for each pipeline failure variant the live
destination is byte-unchanged and the staging directory is removed (I-11);
verified in `ForeignSourcePipelineTests`, including the SHA-256
implementation against FIPS 180-4 vectors.

**C-10 (Anchor shape parity):** the Swift `Anchor` and Rust `Anchor`
encode to identical camelCase JSON for the same field values (I-4);
verified by the Rust `anchor_roundtrips_through_json` test against the
Swift Codable shape.

**C-11 (sentence segmentation parity):** for every input in the shared
segmenter vectors, Swift `EideticLib.sentencesByDelimiter` and Rust
`eidetic_lib::segmenter::sentences` produce identical segment counts and
identical segment contents (B-10, I-13). The Swift routed entry
`EideticLib.sentences` round-trips back to the original input on inputs
that don't exercise language-specific edge cases. Verified in Swift
`SegmenterTests` and Rust `tests/segmenter_tests.rs`.
