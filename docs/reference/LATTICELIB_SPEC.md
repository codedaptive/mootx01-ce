---
title: LatticeLib Specification
version: v0.1
status: active
date: 2026-07-16
description: "Behavioral specification for LatticeLib: the FDC encoder, QID closure, and novel-token learning loop."
spec_type: lib
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/LATTICELIB_INTERFACE.md
  - docs/reference/FDC_ENCODER_CANONICAL.md
  - docs/engineering/FDC_ENCODER_COOKBOOK.md
purpose: |
  LatticeLib is the FDC (Frame-Directed Classification) encoder library.
  It turns a block of text or source code into an FDC decimal code via a
  pure string/bag pipeline, exposes the Q-ID taxonomic closure used by
  DrawerFingerprint, and drives a novel-token learning loop that improves
  the word-class table across the life of an estate process. This document
  defines the behavioral invariants, pipeline semantics, privacy boundary,
  and conformance contract the two ports (Swift and Rust) must uphold. API
  signatures are in LATTICELIB_INTERFACE.md.
---

# LatticeLib Specification

## § 1 — What this package is

LatticeLib is the classification engine at the base of the MOOTx01
substrate. Its primary output is an FDC (Frame-Directed Classification)
decimal code: a hierarchical UDC-based address that places a block of
text — or source code — into a named subject region of the bundled FDC
frame. Classification is a **pure local computation**: the library reads
pinned artifact files checked into the package bundle at build time and
never contacts any external service at runtime.

LatticeLib also ships:

- **QID closure** — the transitive P31/P279 (instance-of / subclass-of)
  ancestor closure of any Wikidata Q-ID, computed over a pinned offline
  snapshot of direct edges. Used by LocusKit's `DrawerFingerprint` to fill
  the `qidClosureHash` lattice-block slot.
- **Novel-token learning** — a fire-and-forget pool/reduce loop that
  accumulates tokens the static word-class table does not know, merges
  them into a writable artifact, and **live-swaps** the running tagger
  in-session without a process restart.
- **Code-language detection** — a rule-based detector that identifies the
  programming language of a fenced-code block or source snippet, returning
  a pinned Wikidata Q-ID to refine the FDC `005` anchor.

LatticeLib is a **Lib** (not a Kit): it owns no persistent connections,
no database state, and no lifecycle management. Its only durable output is
the writable word-class artifact it shares with the novel-token pool
reducer.

**Depends on:** `SubstrateKernel` (for the `FDCSemanticRanker`'s integer
inference; no dependency on storage or network layers). Build-time seed
tooling (`LexRank`) also depends on `SubstrateML` and `NaturalLanguage`
— those are Apple-only, build-time-only dependencies that the Rust port
does not carry.

**Consumed by:** EideticLib (FDC anchor encode), CorpusKitProviders (FDC
provider and ancestor chain), GeniusLocusKit (DrawerFingerprint, novel-token
learning governor, capture seam), AriaMcpKit (pool reduction governance).

## § 2 — Scope

This specification defines:

- The five-step FDC encode pipeline and its properties (determinism,
  purity, artifact pinning).
- The content-aware classification path (FDC `005` anchor rule for code
  input; code-language refinement).
- The no-record privacy boundary for user-memory content.
- The novel-token learning loop: pool accumulation, pool file wire format,
  pool reduction semantics, live-swap contract.
- The writable-artifact lifecycle (lazy seed, merge rules, version pinning).
- The QID closure contract (BFS, numeric sort, exclusion, memoization).
- The code-language detector contract (threshold, tie-break, pinned Q-IDs).
- Error behavior (nil returns, no throwing on the runtime path).
- The cross-port conformance contract (Swift == Rust scalar).

This specification does NOT define:

- API signatures — those live in `LATTICELIB_INTERFACE.md`.
- The FDC frame structure or UDC hierarchy — the bundled `FDCFrame.json`
  artifact is the authoritative frame; its editorial rules live in
  `FDC_ENCODER_CANONICAL.md`.
- The FDC signatures build process (how `FDCSignatures.json` is assembled)
  — `FDC_ENCODER_COOKBOOK.md` covers it.
- The Autonomic Governor that drives pool reduction — AriaMcpKit's spec
  owns that scheduling surface.
- Any storage or network layer — LatticeLib is stateless except for the
  pool-directory / writable-artifact filesystem pair.

## § 3 — Position in the substrate

```
(Wikidata / WordNet / MASC corpus — build-time ETL only)
   ↓
 Bundled pinned artifacts (Lexicon.json, FDCFrame.json,
 FDCSignatures.json, WordClassTable.json, QIDClosureEdges.json,
 FDCSemanticRanker.json/.bin, HMMTaggerModel.json)
   ↓
LatticeLib                 ← this package
   ↑
   ├── EideticLib           (FDC.encode / encodeAnchor — FDC code + Q-ID anchor)
   ├── CorpusKitProviders   (FDCProvider — ancestor chain via FDC.ancestors)
   ├── GeniusLocusKit       (DrawerFingerprint qidClosureHash, capture seam,
   │                         novel-token governor)
   └── AriaMcpKit           (pool-reduce governance via Autonomic Governor)
```

## § 4 — Invariants

**I-1 (pure local classification):** every call to `FDC.encode`,
`FDC.encodeAnchor`, `QIDClosure.ancestors`, and `FDCCodeLanguageDetector.detect`
is a pure local computation over the bundled pinned artifacts. No network
call, no database I/O, no filesystem read beyond the writable word-class
artifact (and only then on the novel-token fast path). Classification is
synchronous, deterministic, and safe to call from any thread.

**I-2 (artifact pinning):** the bundled JSON and binary resources
(`Lexicon.json`, `FDCFrame.json`, `FDCSignatures.json`, `WordClassTable.json`,
`QIDClosureEdges.json`, `FDCSemanticRanker.json/.bin`, `HMMTaggerModel.json`)
are checked in alongside the source and embedded at build time (Swift:
`Bundle.module`; Rust: `include_bytes!`). The runtime never fetches or
updates these artifacts; they change only when a new version of LatticeLib
ships. This ensures classification is reproducible across any machine with
the same build.

**I-3 (conformance contract — scalar equality):** the two ports are
conformance-bound: for every input in the shared fixture
`rust/tests/fixtures/fdc_conformance.json`, Swift-scalar and Rust-scalar
produce identical codes, ancestor chains, frame labels, and semantic
decisions. Conformance is enforced by both test suites reading the SAME
fixture file. The four-way Metal/BLAS/NEON matrix does not apply — FDC is
a pure string/bag computation with no vector dimension.

**I-4 (HMM is the cross-port baseline for novel tokens):** the
parameterless `LatticeLib.wordClass(_:)` and all Rust `word_class`
functions always use the deterministic HMM/Viterbi tagger for tokens absent
from the static table, on ALL platforms including Apple. Apple's
`NLTagger` is opt-in only, activated exclusively by the
`wordClass(_:tagger: .nlTagger)` overload when the estate is explicitly
configured for it. Only the HMM novel-token path is cross-port bound;
the NLTagger path is Apple-only and is explicitly excluded from the
conformance contract (cookbook §2.2/§8).

**I-5 (no-record privacy boundary):** any code path that classifies
user-supplied memory content for storage (the GLK capture seam,
`EideticLib.lookup`, and equivalent Rust paths) MUST use the no-record
variants (`encodeAnchor(_:recordNovel: false)` in Swift;
`Fdc::encode_anchor_no_record` in Rust, or their bag/word-class
equivalents). The tag result is byte-identical to the recording path; only
the pool accumulation side effect is suppressed. This ensures plaintext
tokens from private user-memory content never reach the pool pipeline or
the writable artifact.

**I-6 (word-class table version is pinned):** the `table_version` field
in `WordClassTable.json` is the bundled table's version. Pool submissions
carrying a different version are quarantined by the pool reducer. The
merged (writable) artifact carries the SAME `table_version` as the bundled
table — learning extends the noun/verb sets, it does not bump the version.
The in-process `WordClassTableCache.version` / `table_version()` swap
counter is a separate monotonic per-process counter, not `table_version`.

**I-7 (no data corruption on empty pool):** `PoolReducer.reduce` /
`pool_reduce` is idempotent. An empty pool directory → zero files
consumed → no artifact write → `isNoop == true`. Safe to call on every
governor tick.

## § 5 — The FDC encode pipeline

Classification proceeds in five deterministic steps for text input. Code
input is short-circuited before Step 1 (§ 5.6).

### Step 1 — Word-class tagging

Each token produced by the tokenizer is classified as `.noun`, `.verb`, or
`.other`. Two paths:

1. **Fast path (table-resident tokens):** the LIVE process-global
   `WordClassTableCache` snapshot is checked, verb set first then noun set.
   Constant time, no tagger invoked. A token in both sets resolves to
   `.verb` (the ordering guarantee).

2. **Novel-token path (table miss):** the deterministic HMM/Viterbi tagger
   (`HMMTagger.tag` / `hmm_tag`) classifies the lowercased token. Weights
   are trained on hapax legomena from the MASC 3.0.0 Penn Treebank
   (cookbook §2.2, §8). Unless `recordNovel: false` is in effect, the
   result is accumulated into `NovelTokenCache` toward eventual pool
   submission.

The word-class table is LIVE-SWAPPABLE in-process (§ 7 Novel-token
learning). A post-reduce live swap makes previously-novel tokens table-
resident without a process restart.

### Step 2 — Normalization and stemming

Each token is Unicode-case-folded (`Normalizer.normalize`) and then
Porter2/Snowball-stemmed (`Stemmer.stem`). The stemmed form is the lookup
key for the canonicalization lexicon.

### Step 3 — Lexicon canonicalization

The stemmed key is looked up in the `CanonicalizationLexicon`
(`stem(normalize(token)) -> conceptID`). A **hit** returns the concept's
Wikidata Q-ID or WordNet identifier (the bag key). A **miss** keeps the
stemmed surface form as the bag key. Concept keys are Q-ID strings
(starting with `"Q"`); surface keys are bare stemmed tokens.

**Q-ID relaxation (cookbook §3.2):** tokens that resolve to a Q-ID concept
are retained in the bag even if the word-class tagger returns `.other`.
This recovers named entities the POS tagger mislabels or drops, using only
the pinned lexicon — deterministic across platforms.

### Step 4 — Bag scoring

The concept bag (`conceptID | surfaceForm -> count`) is scored against each
FDC code's signature (`FDCSignatures.json`). Scoring mode is IDF at
runtime (`FDCMatcher` initialized with `.idf`): IDF-weighted overlap
penalizes terms common across many signatures and rewards distinctive ones.
The `stopThreshold` (1) gates frame descent — any code with at least one
matching term is a candidate.

### Step 5 — Frame descent

Starting from the highest-scoring region, the matcher descends the decimal
frame to the most specific code with supported evidence (score ≥
`stopThreshold`). The decimal hierarchy is purely structural — ancestry is
derived from the decimal string, not stored. `FDCFrame.ancestors(of:)` /
`FdcFrame::ancestors` walk the prefix chain. Descent terminates at the
most-specific code whose score meets the threshold.

The semantic micro-ranker (`FDCSemanticRanker`) provides confidence-gated
hierarchy evidence (`FDCSemanticDecision`) that classifier v4.2 uses
together with the bag score to resolve ambiguous within-region placements.

### 5.6 — Code-content anchor rule

When `contentKind == .code` (or when the bag encoder produces `005` from
text and the code-language detector recognizes the input), classification
short-circuits: the FDC code is always `"005"` and the conceptQID is the
pinned Wikidata Q-ID of the detected programming language (or `nil` if the
language is unrecognized). The bag/signature pipeline is not invoked for
code content.

## § 6 — Code-language detection

`FDCCodeLanguageDetector.detect(in:)` / `detect_code_language(text)` is a
two-phase local detector:

1. **Fenced-hint phase:** the first fenced-code-block marker in `text`
   (opening `` ``` `` or `~~~` line) is parsed. If the fence token matches
   a known alias (e.g. `"rust"`, `"python"`, `"swift"`), the associated
   language is returned immediately. If the token is a known operational
   alias (`"bash"`, `"sh"`, `"console"`, etc.) `nil` is returned without
   proceeding to the signal phase. Unknown or absent fence → proceed.

2. **Signal-phrase phase:** each of 13 language definitions is scored by
   counting how many of its signal phrases appear (case-insensitively) in
   `text`, weighted by phrase weight. A language is returned only when:
   (a) the maximum score is ≥ 3, AND (b) exactly one language achieves the
   maximum (no tie). Otherwise `nil` is returned.

The 13 recognized languages and their pinned Q-IDs are: Objective-C
(Q188531), TypeScript (Q978185), JavaScript (Q2005), Swift (Q17118377),
Rust (Q575650), Python (Q28865), Kotlin (Q3816639), Go (Q37227), Ruby
(Q161053), C# (Q2370), C++ (Q2407), C (Q15777), Java (Q251).

The detector is byte-identical across both ports. It is a pure function —
no state, no caching, deterministic given the same input.

## § 7 — Novel-token learning loop

The novel-token learning loop is designed for **near-realtime, in-session**
learning: a token first seen at runtime can become table-resident in the
running process without a restart.

### 7.1 — Pool accumulation

When the HMM classifies a novel token (and `recordNovel` is not suppressed),
`NovelTokenCache.record(token:wordClass:)` / `SHARED_NOVEL_CACHE.record` is
called. The cache accumulates up to `POOL_SUBMIT_THRESHOLD` (50) entries.
When the threshold is reached the cache drains via the injected `Submitter`
closure (fire-and-forget): a `PoolSubmission` is serialized to a dated JSON
file in the pool directory using the wire format (cookbook §2.3):

- File name: `pool_<epoch-ms>_<uuid>.json` (lexicographic order =
  chronological order).
- Fields: `table_version`, `platform`, `tagger_version`,
  `entries: [{token, tag}]`. Tag values are uppercase Penn form:
  `"NOUN"`, `"VERB"`, `"OTHER"`.

The production submitter (`NovelPoolSubmitter.makeDefault()` /
`default_submitter()`) writes to the pool directory resolved from
`LATTICE_POOL_DIR` env var, or the platform default
(`Application Support/com.mootx01.lattice/pool/` on Apple;
`$XDG_DATA_HOME/mootx01/lattice/pool/` on non-Apple).

### 7.2 — Pool reduction

`PoolReducer.reduce(poolDirectory:tableArtifactURL:now:)` / `pool_reduce`
consumes all `pool_*.json` files in `poolDirectory` and merges qualifying
novel tokens into the writable word-class artifact. The reducer is
**idempotent** and **no-op-safe** (empty pool → no artifact write).

**Lazy seed:** if the writable artifact does not exist (first run), it is
created by copying the bundled pristine `WordClassTable.json` before any
merging occurs. Pre-existing writable artifacts (containing prior merged
tokens) are left untouched.

**Merge rules:**

1. Version gate: pool file `table_version` must equal the bundled table's
   version. Mismatch → quarantined to `poolDirectory/quarantine/`.
2. Dedup / conflict resolution: run-global **first-occurrence-wins** per
   lowercased token. Files are processed in lexicographic (= chronological)
   order by file name; entries within a file are processed in declaration
   order. The first occurrence fixes the tag; any later occurrence of the
   same token — even with a different tag — is skipped.
3. Table-resident tokens skipped: a token already in the noun or verb set
   (bundled or previously merged) is never reclassified.
4. Only `NOUN` and `VERB` tags extend the table; `OTHER` entries are
   skipped.
5. Frequency threshold: 1 — any single qualified observation merges.
6. Consumed files are archived to `poolDirectory/archive/`. Invalid files
   (malformed JSON or version mismatch) are quarantined.

### 7.3 — Live swap

After a non-noop reduce, the process **live-swaps** the running word-class
table holder. The swap is a single locked publish of a new immutable
`WordClassTableCache` snapshot plus a monotonic version-counter bump.
Readers copy the whole snapshot out under the lock and test membership
outside it — no torn reads. The previously-novel token is table-resident
in the RUNNING process on the very next `wordClass` call, without a restart.

**Lifecycle on process start:** `seed_global_table` / `loadWithPrecedence`
checks the writable artifact path first. If a writable artifact exists from
a prior process run (cross-reload learning), it is loaded in place of the
bundled table. The `table_version` value is taken from the bundled table and
used to gate future pool submissions regardless of which artifact was loaded.

## § 8 — QID closure

`QIDClosure.ancestors(of:)` / `qid_closure::ancestors` returns the **full
transitive** P31/P279 ancestor closure of a Wikidata Q-ID, over the pinned
`QIDClosureEdges.json` direct-edge graph (38,761 nodes, built offline by
the Q-ID closure ETL). The runtime never re-queries Wikidata.

**Properties:**
- The queried Q-ID itself is EXCLUDED from the result.
- Results are sorted numerically by the integer part of the Q-ID
  (`"Q146" < "Q1084" < "Q25265"`).
- Results are memoized per distinct Q-ID for the life of the process.
- An empty, unknown, or unavailable Q-ID returns `[]`/`vec![]`.
- BFS over direct edges; the closure is computed locally on load.

Both ports produce byte-identical results for every Q-ID. Consumed by
LocusKit's `DrawerFingerprint` to fill the `qidClosureHash` slot (the
`FNV.hash16` of the sorted, `"|"`-joined closure string).

## § 9 — Error behavior

The FDC runtime surface does not throw. Instead:

- `FDC.encode` returns `nil` for empty input or unavailable artifacts.
  Nonempty text without defensible subject evidence returns `"000"`.
- `FDC.encodeAnchor` returns `(nil, nil)` if artifacts are unavailable.
- `FDC.ancestors(of:)` / `QIDClosure.ancestors(of:)` return `[]`/`vec![]`
  for unknown input or unavailable artifacts.
- `FDC.label(for:)` returns `nil` for unknown codes, empty input, or
  unavailable artifacts.
- `FDCCodeLanguageDetector.detect` returns `nil` when the language is
  unrecognized, ambiguous, or the input is an operational fence
  (`bash`, `sh`, etc.).

The pool reducer (`PoolReducer.reduce` / `pool_reduce`) throws /
returns `Result<_, PoolReducerError>` on filesystem errors
(`tableReadFailed`, `tableWriteFailed`, `poolDirectoryUnreadable`).
Build-time tooling (`LexiconBuilder.build`) throws on missing/unreadable
input — build-time-only.

## § 10 — Conformance

Both ports (Swift and Rust) read the same shared fixture file:
`packages/libs/LatticeLib/rust/tests/fixtures/fdc_conformance.json`
(65 vectors). For every vector, the two ports must produce:

- Identical FDC code from `FDC.encode` / `Fdc::encode`.
- Identical `(code, conceptQID)` pair from `FDC.encodeAnchor` /
  `Fdc::encode_anchor`.
- Identical ancestor chain from `FDC.ancestors(of:)` / `Fdc::ancestors`.
- Identical semantic candidates and decisions.

Three vectors in `fdc_conformance.json` contain novel tokens where the
Apple `NLTagger` path diverges from HMM. The Swift test skips those three
vectors on Apple builds (via `#if canImport(NaturalLanguage)` guard); the
Rust test uses the HMM-only baseline. The shared `tag_conformance.json`
fixture (28 vectors) gates the cross-port HMM path independently.

The Snowball/Porter2 stemmer conformance is gated by
`rust/tests/fdc_conformance_test.rs::stemmer_conformance_snowball_corpus`.

---

*End of LatticeLib Specification.*
