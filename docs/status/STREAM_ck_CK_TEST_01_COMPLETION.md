# Stream Completion Report — CK-TEST-01

**Mission:** CorpusKit library test leg (swift-testing) — `docs/missions/inflight/MISSION_CK_TEST_01.md`
**Task:** TASK-MXC-2026-0031 · **Stream:** ck · **Branch:** `stream/ck-corpuskit-test-leg`
**Base commit:** `16c0579` · **Head:** `dc97bd5`
**Priority:** P1 · **Status:** ✅ COMPLETE — Swift leg green, Smythe GREEN, Adams PASS

---

## Summary

Converted CorpusKit's Swift test leg from XCTest to swift-testing and filled the
per-source-type coverage gaps. TEST-ONLY mission — no production source, the Rust
leg, the conformance harness, or `Package.swift` were modified. There is no Rust
parity step (Rust is out of scope per the mission).

- **Swift test leg:** 22 `XCTest` methods registering **0** under the swift-testing
  runner → **47 `@Test` across 9 suites**.
- **All 22 prior test methods and all 38 `XCTAssert` call-sites** preserved verbatim
  in meaning on conversion (Adams confirmed counts: 22 methods / 38 assertions).
- **Zero `import XCTest`** remains in the package test target.
- **Swift leg green, zero warnings.**
- **`Package.swift` untouched** — swift-testing is toolchain-bundled (Swift 6.3.2).

---

## Commits (3)

| Commit | Description |
|---|---|
| `a24fa90` | docs(cktest): mission + Smythe pre-flight (GREEN) + Blast Radius Report — first stream commit (hard gate) |
| `dc2edc7` | test(corpuskit): convert XCTest suites to swift-testing (assertions preserved) — Part 1 |
| `dc97bd5` | test(corpuskit): per-type coverage gaps filled (Swift) — Part 2 |

---

## Test Verification Log

### Baseline (mission start, @ `16c0579`)
- Command: `cd packages/kits/CorpusKit && swift test`
- **XCTest runner:** `Executed 22 tests, with 0 failures` — exit 0
  (BM25 4, BundleStore 9, Chunker 3, Providers 6 = 22 methods; 38 `XCTAssert` call-sites).
- **swift-testing runner:** `Test run with 0 tests in 0 suites passed` — **0 `@Test`**.
- **Rust** (`rust/tests/`): **32 `#[test]`** across 6 files — out of scope (recorded as ground truth).

### Final (@ `dc97bd5`, post-commit, pre-signal)
- Command: `cd packages/kits/CorpusKit && swift test`
- Exit code: **0**
- `@Test` count: **47** · Suites: **9**
- Fail count: **0**
- Warnings: **0** (zero `warning:` lines across build + test)
- Tail (verbatim):

```
􁁛  Suite "BM25Index" passed after 0.001 seconds.
􁁛  Suite "BundleStore" passed after 0.001 seconds.
􁁛  Test chunkerHLCMonotonic() passed after 0.002 seconds.
􁁛  Test chunkerProducesNonEmptyChunks() passed after 0.002 seconds.
􁁛  Test chunkerRespectsTargetSize() passed after 0.002 seconds.
􁁛  Suite "Chunker" passed after 0.003 seconds.
􁁛  Test miniLMProviderProjectsToEngram() passed after 0.015 seconds.
􁁛  Test providersHaveDistinctProjectionSeeds() passed after 0.023 seconds.
􁁛  Suite "Providers" passed after 0.023 seconds.
􁁛  Test run with 47 tests in 9 suites passed after 0.023 seconds.
```

Independently re-run and verified by Adams (Method B, re-run) — output matched verbatim, exit 0.

### Suite map (9 suites)

| Suite | Tests | Source type | Status |
|---|---|---|---|
| BM25Index | 4 | `BM25Index` | converted |
| BundleStore | 9 | `BundleStore` (+ `Chunk.deriveID` ground truth) | converted |
| Chunker | 3 | `Chunker` | converted |
| Providers | 6 | `MiniLM`/`MPNet`/`EmbeddingGemma` + `DeterministicTokenizer` | converted |
| CorpusKitError | 5 | `CorpusKitError` | new (Part 2) |
| SyncManifest | 4 | `CorpusKitSync.manifest` | new (Part 2) |
| Tokenizer.keywordTokens (default) | 6 | `Tokenizer` default extension | new (Part 2) |
| HybridRecallConfiguration | 3 | `HybridRecallConfiguration` | new (Part 2) |
| Chunk / ScoredChunk | 7 | `Chunk`, `ScoredChunk` | new (Part 2) |

Only `CorpusKit.swift` (module-doc file, no public testable surface) has no peer suite — confirmed appropriate by Smythe and Adams.

---

## Files Changed (12 = 9 test files + 3 docs)

**Converted (XCTest → swift-testing):** `BM25Tests.swift`, `BundleStoreTests.swift`,
`ChunkerTests.swift`, `ProvidersTests.swift`.

**Created (swift-testing peer suites):** `CorpusKitErrorTests.swift`,
`SyncManifestTests.swift`, `TokenizerTests.swift`, `HybridRecallTests.swift`,
`ChunkTests.swift`.

**Docs:** `docs/blast_radius/CK_TEST_01_BLAST_RADIUS.md`,
`docs/blast_radius/CK_TEST_01_PREFLIGHT.md`, `docs/missions/inflight/MISSION_CK_TEST_01.md`.

**Not modified (off-limits, confirmed clean):** `Sources/CorpusKit/**`,
`Sources/CorpusKitProviders/**`, `rust/**`,
`docs/validation/substrate_math_performance/**`, `Package.swift`.

---

## Known Ambiguity 1 — Resolved

`Package.swift` test-target wiring: **no edit needed.** Swift 6.3.2 bundles the Testing
framework; LatticeKit (the reference) declares no swift-testing dependency and uses
`import Testing` directly. CorpusKit on `swift-tools-version:6.0` is the same situation.
`Package.swift` was therefore left untouched (the conditional edit was contingent on a
missing dependency that does not exist). Confirmed by Smythe pre-flight.

One necessary import change beyond the framework swap: `import Foundation` was added to
`BM25Tests.swift` and `BundleStoreTests.swift` (and is present in the new `ChunkTests.swift`).
`import XCTest` re-exported Foundation as a side-effect (providing `UUID`, `JSONEncoder`);
`import Testing` does not. Adams confirmed these are necessary, not scope creep.

---

## Smythe Pre-flight (steps 4–5) — verdict GREEN

Full report: `docs/blast_radius/CK_TEST_01_PREFLIGHT.md`.

- Blast-radius reality verified: 13 source files, 4 XCTest files (22 `func test`, each
  `import XCTest`), LatticeKit swift-testing reference present, SubstrateTypes Package.swift
  wiring precedent present — all match mission claims.
- Precision note: the mission's "22" is the test-method count; the actual `XCTAssert`
  call-site count is **38**. All 38 preserved.
- Package.swift: no edit needed (toolchain-bundled).
- Coverage-gap list accepted: `CorpusKitError`, `SyncManifest`, `Tokenizer`,
  `HybridRecall`, `Chunk`/`ScoredChunk`.
- **WARNING / INFO (non-blocking):** mission Context claims "Rust leg has 0 `#[test]`"; reality
  is **32** across 6 files. The mission's *reason* for "no Rust parity step" is stale, but the
  Rust-out scope is stated as an independent explicit decision — Swift-only scope stands.
  Recommend mission-file correction before merge.
- **Blockers: none. Verdict: GREEN, proceed.**

---

## Adams Post-flight (steps 10–13) — verdict PASS

### First pass — CLEAN (0 CRITICAL, 0 WARNING, 1 INFO)

Zero findings on first read. No iteration required.

- **Scope-check:** 9 test files + 3 docs; production / rust / harness / Package.swift all
  empty in diff. Clean.
- **Blast Radius Verification (BLOCKING):** all 9 MUST_UPDATE files present in diff; every
  INTENTIONALLY_LEFT justification (Package.swift no-op; Sources/rust/validation off-limits)
  real and verified; no grep drift; no prohibited patterns (no bridges/shims/deprecations/TODOs).
- **Test Execution Verification (BLOCKING):** re-ran `swift test` (Method B) — matched verbatim,
  exit 0, 47 tests / 9 suites, zero failures, zero warnings.
- **Assertion preservation:** confirmed 22 methods / 38 call-sites; every conversion mapping
  correct; no assertion weakened or dropped.
- **No false-passing tests:** all five new peer suites assert real behavior against live
  source (enum equality, manifest shape, keywordTokens output, config defaults, Codable
  round-trip), not tautologies.
- **`import Foundation` additions:** justified and necessary.
- **INFO (non-blocking):** mission file line 12 stale Rust claim — recommend correction
  before archive.

> "Clean. Ship it."

---

## Self-Review (step 9)

- **Step 0 — Blast Radius Scope Check:** BRR MUST_UPDATE = 9 test files; all 9 present in
  `git diff 16c0579..HEAD`. Diff files not in BRR: the 3 stream docs (BRR, preflight, mission),
  all accounted for as "self". `Package.swift` correctly absent (INTENTIONALLY_LEFT). ✅
- **Files changed:** 12 (9 test + 3 docs). 689 insertions, 80 deletions.
- **Scope:** all within `CorpusKitTests/` reservation + `docs/blast_radius/` — none outside. ✅
- **Anti-patterns:** none. No bridges, shims, deprecation stubs, or silenced warnings. Test
  helpers (`makeIndex`, `makeChunk`, `makeStore`) preserved from the originals. `Issue.record`
  used in `CorpusKitErrorTests.payloadIsPreserved` is the correct swift-testing idiom for a
  guard-else failure path.
- **Secrets:** none.
- **Orphan code:** none — every helper is used by the suite that declares it.
- **No production source modified** — the library was proven, not changed.

---

## Conditional Agents (steps 14–15) — not triggered

- **Simms (user guide):** N/A — test-only mission, no user-facing views or behavior changed.
- **Nagatha (docs sync):** report is placed in-repo at `docs/status/`; no guide delta to sync.
- **Friedlander / Nert (UI/accessibility):** N/A — not a UI mission.
- **Perkins (security):** N/A — touches no CloudKit sync, SQLite schema, privacy fields,
  API-key handling, NL/prompt construction, URL schemes, or Keychain.

---

## Discoveries / Notes for the controller

- **Mission-file correction recommended before archive:** `MISSION_CK_TEST_01.md` line ~13
  states "Its Rust leg has 0 `#[test]` functions." Reality is **32** across 6 files
  (bm25=8, bundle_store=7, chunk=5, chunker=5, hybrid_recall=4, tokenizer=3). The Swift-only
  scope is unaffected (the mission states Rust-out as an independent explicit decision in two
  places), so this did not block — but the stated *reason* is stale. Flagged by Smythe, the
  BRR, and Adams. CorpusKit therefore HAS a Rust test leg; a future Rust-parity mission could
  be warranted but is explicitly out of scope here.

---

## Success Criteria — met

✅ 4 suites converted with all 22 methods / 38 assertions intact and registering.
✅ Every CorpusKit source type with a testable surface has a swift-testing peer suite.
✅ Zero `import XCTest` remains in the package test target.
✅ Swift leg green (47 tests / 9 suites, exit 0), zero warnings.
✅ Production code, Rust leg, conformance harness, and `Package.swift` untouched.
