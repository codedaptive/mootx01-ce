# Blast Radius Report — TASK-MXC-2026-0031 (CK-TEST-01)

**Mission:** CorpusKit library test leg (swift-testing) — `docs/missions/inflight/MISSION_CK_TEST_01.md`
**Stream:** ck · **Branch:** `stream/ck-corpuskit-test-leg`
**Base commit:** `16c0579` (HEAD of main at branch point) · **Head:** (this report = first stream commit)
**Tier:** **test-only** — no production source is modified. Four legacy XCTest files
are rewritten to swift-testing; new per-type peer suites are authored. No exported
symbol changes meaning. No public API is touched.

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **GREEN** (zero CRITICAL, zero blockers). Full report:
`docs/blast_radius/CK_TEST_01_PREFLIGHT.md`.

## Step 0 — Baseline (verified at `16c0579`)

```
cd packages/kits/CorpusKit && swift test
```
- **XCTest runner:** `Executed 22 tests, with 0 failures` — exit 0.
  - BM25Tests 4, BundleStoreTests 9, ChunkerTests 3, ProvidersTests 6 = **22 test methods**.
  - Actual `XCTAssert*` call-site count: **38** (the "22" in the mission is the method
    count; all 38 assertion call-sites are preserved on conversion).
- **swift-testing runner:** `Test run with 0 tests in 0 suites passed` — **0 `@Test`**.
- **Rust** (`packages/kits/CorpusKit/rust/tests/`): **32 `#[test]`** across 6 files
  (bm25=8, bundle_store=7, chunk=5, chunker=5, hybrid_recall=4, tokenizer=3).
  Out of scope per mission; recorded here as ground-truth (see Notes).

Gate value: at mission end `swift test` must exit 0, the swift-testing runner must
register **≥ 22** `@Test`, and the 38 assertion call-sites must be preserved.

## Symbols modified / removed / renamed / deprecated

The only symbols whose form changes are the four **test entry-point types**, converted
from `XCTestCase` subclasses to swift-testing `@Suite` structs:

| Symbol | Change class | Scope | External consumers |
|---|---|---|---|
| `BM25Tests` | semantic (XCTest → swift-testing) + class→struct | test target only | **none** |
| `BundleStoreTests` | semantic + class→struct | test target only | **none** |
| `ChunkerTests` | semantic + class→struct | test target only | **none** |
| `ProvidersTests` | semantic + class→struct | test target only | **none** |

Grep across `packages/**` and `apps/**` (`\b<name>\b`, `*.swift`) finds **zero**
references to any of the four names outside their own files. The package manifest
references only the test **target** name `CorpusKitTests` (`Package.swift:63,69`), which
does **not** change. Test code exports no symbols consumed by any other target — there
is no cross-package blast radius.

## MUST_UPDATE list (reality vs mission "Files You Will Modify")

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `Tests/CorpusKitTests/BM25Tests.swift` | yes | rewrite XCTest → swift-testing (4 methods, all assertions) | MUST_UPDATE |
| `Tests/CorpusKitTests/BundleStoreTests.swift` | yes | rewrite XCTest → swift-testing (9 methods, all assertions) | MUST_UPDATE |
| `Tests/CorpusKitTests/ChunkerTests.swift` | yes | rewrite XCTest → swift-testing (3 methods, all assertions) | MUST_UPDATE |
| `Tests/CorpusKitTests/ProvidersTests.swift` | yes | rewrite XCTest → swift-testing (6 methods, all assertions) | MUST_UPDATE |
| `Tests/CorpusKitTests/CorpusKitErrorTests.swift` | yes (CREATE) | new peer suite — `CorpusKitError` enum | MUST_UPDATE (new) |
| `Tests/CorpusKitTests/SyncManifestTests.swift` | yes (CREATE) | new peer suite — `CorpusKitSync.manifest` | MUST_UPDATE (new) |
| `Tests/CorpusKitTests/TokenizerTests.swift` | yes (CREATE) | new peer suite — `Tokenizer.keywordTokens` default ext | MUST_UPDATE (new) |
| `Tests/CorpusKitTests/HybridRecallTests.swift` | yes (CREATE) | new peer suite — `HybridRecallConfiguration` | MUST_UPDATE (new) |
| `Tests/CorpusKitTests/ChunkTests.swift` | yes (CREATE) | new peer suite — `Chunk` / `ScoredChunk` | MUST_UPDATE (new) |
| `Package.swift` | yes (conditional) | **NO EDIT** — swift-testing is toolchain-bundled (Swift 6.3.2); LatticeKit declares no dependency and uses `import Testing` directly | INTENTIONALLY_LEFT — the conditional edit was contingent on a missing dependency that does not exist |
| `docs/blast_radius/CK_TEST_01_BLAST_RADIUS.md` | n/a | this report (first stream commit, hard gate) | self |
| `docs/blast_radius/CK_TEST_01_PREFLIGHT.md` | n/a | Smythe pre-flight | self |

## INTENTIONALLY_LEFT (with justification)

- `Sources/CorpusKit/**`, `Sources/CorpusKitProviders/**` — released production code,
  correct and shipped. Tests prove it; they do not change it. If a test reveals a real
  bug, the mission STOPS and reports (no source edit). Off-limits per mission.
- `rust/**` — out of scope per mission. The 32 `#[test]` are read as behavior reference
  only, never modified. NO Rust parity step in this mission.
- `docs/validation/substrate_math_performance/**` — conformance harness (EE-only); tests
  algorithm validity, not the library; off-limits per mission and per the substrate-lane rule.
- `Package.swift` — see table; no dependency line required in Swift 6.3.2.
- `CorpusKit.swift` — module-doc file with no public testable surface beyond imports; no
  peer suite warranted (confirmed by Smythe).

## RESCOPE_REQUIRED

**None.** Blast radius is contained entirely within the `CorpusKitTests` target. No item
classifies as RESCOPE.

## Notes for implementation

- **Mission-context inaccuracy (non-blocking):** the mission Context states "Its Rust leg
  has 0 `#[test]` functions". Reality is **32** `#[test]` across 6 files. The mission's
  *reason* for "no Rust parity step" is therefore stale, but the mission ALSO states the
  Rust-out scope as an independent, explicit decision ("rust/** — out of scope", "There is
  NO Rust parity step"). The Swift-only scope stands on its own; the inaccuracy does not
  change scope and does not block execution. Recommend the mission file be corrected before
  merge. Flagged to Smythe (GREEN) and carried into the completion report.
- **Coverage map (Part 2):** source types lacking a peer suite at baseline →
  `CorpusKitError`, `SyncManifest` (`CorpusKitSync`), `Tokenizer` (default `keywordTokens`),
  `HybridRecall` (`HybridRecallConfiguration` — `recall(...)` needs a live `VectorStore`,
  out of unit scope; config struct is the viable surface), `Chunk`/`ScoredChunk`. Types
  already covered: `BM25Index`, `BundleStore`, `Chunker`, providers + `DeterministicTokenizer`.
- `Chunk.deriveID` cross-language ground-truth is already asserted in `BundleStoreTests`;
  it is left there (preserved on conversion). `ChunkTests` covers `Chunk`/`ScoredChunk`
  construction and equality without duplicating those assertions.
