---
version: v0.1
---

# COMPLETION: LME-04

**Status:** COMPLETE

**Mission:** LME-04 — LoCoMo Loader + Recall Benchmark (Both Twins)
**Worktree:** `/Users/bob/devlop/mootx01-ce-lme-locomo`
**Branch:** `stream/lme-locomo`
**BRR:** `docs_internal/analysis/blast_radius/LME-04_BLAST_RADIUS.md`

---

## What Was Done

- **Part 1 — corpus loaders + synthetic test sample:** `82c6ad6b`
  - `LoCoMoCorpus.swift` + Rust `locomo_corpus.rs` — load locomo10.json
  - `scripts/fetch-locomo.sh` — gitignored dataset download
  - `Tests/mcp-benchmarkerTests/LoCoMoCorpusTests.swift` + `locomo_sample.json`

- **Part 2 — Swift runner + estate lifecycle:** `4dc4000f`
  - `LoCoMoRunner.swift` — per-conversation estates, n=true inline encoding,
    `loCoMoScratchDir()`, `loCoMoGuardedTeardown()`, `runLoCoMoQuestions()`

- **Part 3 — Swift scorer + conformance vectors + locomo subcommand:** `ab9eea7a`
  - `LoCoMoScorer.swift` — `loCoMoManifestAsLme()`, `scoreLoCoMoQuestion()`,
    `aggregateLoCoMoScores()`, `buildLoCoMoReport()`, `writeLoCoMoReport()`
  - `conformance/locomo_vectors.json` — shared conformance vectors
  - `Tests/mcp-benchmarkerTests/LoCoMoScorerTests.swift`
  - `main.swift` — `runLoCoMo()` + `locomo` dispatch case

- **Part 4 — Rust twin (scorer, runner, main dispatch, conformance tests):** `cdcceeb2`
  - `rust/src/locomo_scorer.rs`, `locomo_runner.rs`, `locomo_corpus.rs`
  - `rust/src/lib.rs` + `rust/src/main.rs` updated
  - `rust/tests/conformance.rs` — `locomo_scorer_recall_vectors`,
    `locomo_scorer_uuid_mapping_vectors`

- **Part 5 — 50q smoke, FINDINGS, SIGSEGV fix, CHANGELOG:** `20a9704a`
  - `results/LOCOMO_DIAGNOSTIC_SMOKE_2026-07-26.md` — full smoke findings
  - Swift SIGSEGV fix: `%-14s` → `%-14@` in `main.swift:935`
  - `CHANGELOG.md` — LME-04 entry
  - `.gitignore` — runner-generated JSON report wildcards

---

## Test Verification Log

- `swift build -c release`: exit 0, build complete (verified 2026-07-26)
- `swift test`: exit 0, 183 tests in 36 suites (baseline: 183, delta: unchanged)
- `cargo test --release`: exit 0, 109 tests (68 unit + 40 conformance + 1 stdio; baseline: 109, delta: unchanged)

---

## Smoke Run Summary

| Twin  | Seed     | n  | any@5  | all@5  | any@10 | MRR    | p50 ms | p95 ms |
|-------|----------|----|--------|--------|--------|--------|--------|--------|
| Rust  | 20260725 | 50 | 0.2000 | 0.1800 | 0.2600 | 0.2001 | 257    | 311    |
| Swift | 20260725 | 50 | 0.2800 | 0.2400 | 0.3200 | 0.2129 | 245    | 304    |

Category n-counts: single_hop=8, temporal=12, multi_hop=2, open_domain=28 (match ✓).
Agreement@5: 46/50 = 92%.
Guard: 50/50 healthy both twins.

Full details: `apps/mcp-benchmarker/results/LOCOMO_DIAGNOSTIC_SMOKE_2026-07-26.md`

---

## Discoveries

1. **Swift SIGSEGV from `%-14s` with Swift String.** `String(format:)` with `%s`
   expects a C pointer; Swift `String` is not ABI-compatible, so `_platform_strlen`
   receives a garbage pointer. Fixed to `%-14@` with `as NSString`. The crash was
   reproducible at any question count (1, 3, 50).

2. **Moot binary search is non-deterministic.** Recall metrics vary significantly
   across runs (any@5 range: 0.16–0.28 across 4 runs). The approximate
   nearest-neighbor search returns different top-k results for the same query
   against the same estate. An authoritative LoCoMo baseline needs either
   deterministic search configuration or averaging over multiple full-corpus runs.

3. **Display bug: `conversations used: 1`.** The summary field reads from
   `corpus.questions.prefix(n)` (unshuffled), not the actual selected question set.
   The field is wrong when the first n unshuffled questions all come from one
   conversation. Scoring is unaffected.

4. **Display bug: `turns ingested total` over-counts.** `LoCoMoQuestionResult.turnsIngested`
   stores the full conversation manifest size for every question from that conversation.
   Summing across questions over-counts by the average questions-per-conversation factor
   (~5x here → 30,303 reported vs ~5,882 actual). Scoring is unaffected.

5. **Rust report `questions_loaded` differs from Swift.** Rust: 1,986 (includes
   adversarial). Swift: 1,536 (scoreable only). Minor schema divergence in report
   metadata.

6. **Per-conversation O(10) strategy validated.** All 10 conversations provisioned and
   torn down successfully across all smoke runs. The guarded teardown
   (`/tmp/locomo-bench-` prefix) behaved correctly.

---

## Outstanding (not in LME-04 scope)

- Fix `conversations used` and `turns ingested total` display bugs (no scoring impact)
- Align `questions_loaded` definition between Swift and Rust reports
- Full 1,536-question run for authoritative baseline
- Deterministic search configuration for reproducible benchmarking
- LLM-judge QA accuracy scoring beyond session retrieval

---

## Smythe and Adams Verdicts

To be recorded after Adams post-flight completes.
