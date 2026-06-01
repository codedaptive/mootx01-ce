# COMPLETION REPORT — VK-TEST-01

**Mission:** VectorKit library test leg — convert XCTest → swift-testing, fill per-type gaps
**Stream:** stream/vk-vectorkit-test-leg
**Worktree:** /Users/bob/devlop/mootx01-ce-vk-vectorkit-test-leg
**Date:** 2026-05-31
**Author:** Bilby
**Toolchain:** Apple Swift 6.3.2 / arm64-apple-macosx26

---

## Status: COMPLETE

The conversion is complete and verified (Smythe GREEN, Adams PASS ×2). `swift test` is
now **reliably green** — 43 tests / 7 suites, exit 0, zero warnings, across 6 consecutive
runs (Bilby ×5 + Adams ×1).

**Resolution of the one blocker:** the mission initially went `.stuck` on a single
pre-existing flaky perf assertion — `testFindNearestP99...<50ms` (~44 ms typical, ~12%
headroom, P99 wall-clock noise crossed 50 ms on ~1 run in 3; flaky even under
`--no-parallel`, so not a swift-testing-parallelism artifact). The mission forbade Bilby
from changing the assertion, so the decision was escalated to Bob. **Bob (2026-05-31)
approved raising the find-nearest P99 ceiling 50 ms → 75 ms** (commit `09e8c48`) — ~1.7×
the ~44 ms typical, preserving a meaningful budget while removing the flake. Only that one
threshold changed; end-to-end (100 ms / 50 ms) and storage-only (5 ms) budgets are
untouched. Adams re-verified the delta: **PASS**.

This was the correct sequence: Bilby did not silently retune an assertion the mission told
him to preserve — he surfaced the conflict (`.stuck`), Bob decided, Bilby implemented the
decision and re-verified.

---

## What Was Done

- **Part 1 — convert 4 XCTest files → swift-testing** — commit `1bfc2c1`
  All 4 files (`EmbeddingProviderTests`, `FloatSimHashEmbeddingProviderTests`,
  `VectorStoreTests`, `CapturePathBenchmarkTests`) converted: `import Testing`, `@Suite`,
  `@Test`, `#expect` / `#expect(throws:)`. **All 30 test methods and all 61
  `XCTAssert*`/`XCTFail` calls preserved 1:1.** Zero `import XCTest` remains. Method names
  kept verbatim for audit traceability.
- **Part 2 — per-type coverage gaps filled** — commit `b61d8e2`
  3 net-new swift-testing peer suites for the 3 public source types lacking direct
  coverage: `VectorKitErrorTests` (5), `VectorMatchTests` (5), `StoredVectorTests` (3) =
  13 tests. `VectorKit.swift` is module-doc-only (no type), needs no suite.
- **Step 6.5 — Blast Radius Report** — commit `12582c5` (first stream commit).

**Total: 43 tests across 7 suites. Production source untouched (git diff of Sources/,
rust/, Package.swift, docs/validation/ is empty).**

---

## Smythe Pre-flight: GREEN

`docs/analysis/blast_radius/VK_TEST_01_SMYTHE_PREFLIGHT.md`

- Blast radius verified: 4 test files, 30 methods, Tests/ clean.
- No swift-testing imports pre-existing; no Package.swift change needed (Testing ships with
  the Swift 6.3.2 toolchain — `no-op-pkg-confirmed`, matching SK-TEST-01 / ENGRAM-TEST-01).
- Premise corrections raised (see below). No blockers.

## Adams Post-flight: PASS — Clean

- §9 Blast Radius Verification (BLOCKING): **PASS** — diff matches BRR; zero production
  touch confirmed; no prohibited patterns (bridges/shims/orphan deprecations).
- §10 Test Execution Verification (BLOCKING): **PASS** — Adams independently re-ran
  `swift test`: 43 tests / 7 suites, exit 0, zero warnings (his run measured find-nearest
  P99 = 43.9 ms). Adams's run happened to land in the passing band (see flakiness data).
- Assertion preservation: 61 `#expect` calls confirmed (EmbeddingProvider 5, FloatSimHash
  14, VectorStore 34, CapturePathBenchmark 8 = 61). `.serialized` trait, `import Foundation`
  additions, and the one converted inline comment all judged clean/in-scope.
- 1 INFO (pre-existing stale comment, leave-as-is — see Outstanding). 0 WARNING, 0 CRITICAL.

> Note: Adams's post-flight ran before the flakiness was characterized; his §10 re-run
> passed (43.9 ms). The flakiness below was found by repeated runs after his review. His
> correctness verdict (assertions preserved, scope clean) stands and is unaffected.

---

## Test Verification Log

### Baseline (mission start, on the un-converted XCTest suite)
`swift test`: **exit 0**, 30 XCTest methods, all passing under the XCTest runner; the
swift-testing runner reported "0 tests in 0 suites" — exactly the condition the mission
targets. (find-nearest P99 that run: 44.782 ms.)

### Final (converted suite) — counts
- **43 `@Test` functions in 7 `@Suite`s** registered under the swift-testing runner
  (30 converted + 13 new). Was 0 under swift-testing at baseline. ✅ registers non-zero ≥ 30.
- **Zero `import XCTest`** remaining. ✅
- **Zero warnings.** ✅
- 42 of 43 tests pass on **every** run.

### Final — the (now resolved) marginal benchmark
`testFindNearestP99Under10MillisecondsOver10000VectorCorpus` asserts
`#expect(stats.p99Ms < 75.0)` (raised from 50 ms by Bob's decision). **After the raise,
6/6 runs green** — find-nearest P99: 45.0 / 51.6 / 53.3 / 47.2 / 45.6 (Bilby ×5) + 46.1
(Adams) ms, all comfortably under 75 ms (worst case 53.3 ms = ~21 ms headroom).

The history below is the 9-run data that justified the decision. Under the original 50 ms
ceiling, measured find-nearest P99:

| Execution mode | P99 (ms) | Result |
|---|---|---|
| XCTest baseline (serial) | 44.782 | pass |
| swift-testing, parallel (pre-fix) | 55.498 | FAIL |
| swift-testing, `.serialized` | 45.287 / 43.9 / 46.184 | pass ×3 |
| swift-testing, `.serialized` | 53.125 / 52.606 | FAIL ×2 |
| `swift test --no-parallel` | 54.188 | FAIL |
| `swift test --no-parallel` | 44.827 / 44.365 | pass ×2 |

Verbatim failing line (representative):
```
✘ Test testFindNearestP99Under10MillisecondsOver10000VectorCorpus() recorded an issue at
  CapturePathBenchmarkTests.swift:231:9: Expectation failed: (stats.p99Ms → 53.124958) < 50.0
  [VEC-05 retrieval P99 budget exceeded: 53.124958 ms]
✘ Test run with 43 tests in 7 suites failed after 16.742 seconds with 1 issue.
```
Verbatim passing line (representative):
```
✓ Test run with 43 tests in 7 suites passed after 16.509 seconds.
  [VEC-05 find-nearest (k=10, corpus=10000, q=100)] min=42.000  median=43.658  p99=46.184
```

**The other three benchmarks are not marginal** and pass every run with wide headroom:
end-to-end P99 ≈ 7.5 ms (budget 100), end-to-end median ≈ 6.7 ms (budget 50), storage-only
P99 ≈ 0.23 ms (budget 5). The find-nearest **median (~43 ms) and min (~42 ms) are
rock-stable**; only the P99 (the single slowest of 100 queries) crosses the 50 ms line,
~1 run in 3, due to ordinary OS-scheduler / thermal wall-clock noise.

---

## Root-cause analysis (why this is pre-existing, not a conversion defect)

1. **The conversion introduced one real regression, which I fixed.** swift-testing runs
   `@Test`s in parallel by default; XCTest ran them serially. Under parallel execution the
   four heavy benchmarks contended for CPU and find-nearest P99 hit 55.5 ms. I added the
   `.serialized` trait to the benchmark suite (scheduling-only; no assertion changed),
   restoring the serial execution model the budgets were calibrated under. Typical P99
   returned to ~44 ms, matching the XCTest baseline.

2. **The residual flake is NOT execution-contention and NOT caused by the conversion.**
   - `--no-parallel` (full serial, the faithful XCTest model) **still flakes** (54.2 ms on
     1 of 3 runs). So no execution-model change removes it.
   - The timing code is **byte-identical** to the original: corpus build, query loop,
     `ContinuousClock` sampling, percentile math, and the `< 50.0` threshold are unchanged
     — only `XCTAssertLessThan(x, 50)` became `#expect(x < 50)`. Since serial execution of
     identical timing code reproduces the flake, the **original XCTest suite would flake
     identically on repeated runs on this host.**
   - The benchmark's own doc comment states the 50 ms ceiling "reflects measured pipeline
     reality with ~2× headroom" — calibrated on `apple-m5-max`. This host delivers ~44 ms
     typical, i.e. only ~12 % headroom, which P99 sample noise (±~10 ms) routinely
     overruns.

**Conclusion:** a pre-existing, environment-sensitive perf budget with insufficient margin
on this hardware. The conversion is faithful; it merely surfaced the latent fragility by
being run repeatedly.

---

## Self-review

- Diff matches BRR scope exactly: 4 converted + 3 new test files; Sources/, rust/,
  Package.swift, docs/validation/ untouched (verified empty diff). ✅
- All 30 methods + 61 assertion calls preserved; zero `import XCTest`; zero warnings. ✅
- No bridges / shims / TODOs / orphan deprecations. ✅
- No production code touched; no `@available` deprecations; no scope creep. ✅
- The only judgment calls (`.serialized` trait, `import Foundation`, one comment-fidelity
  edit) are documented and Adams-cleared.

---

## Premise corrections (confirmed by Smythe; recorded in BRR)

- **PC-1** — Mission says "Rust leg has 0 `#[test]`"; reality is **23** (8
  `simhash_provider_tests.rs` + 15 `vector_store_tests.rs`). Non-blocking: Rust out of
  scope; preserving Swift assertions keeps Swift↔Rust parity intact. (`mission-prose-
  wrong-on-rust` recurrence, cf. ENGRAM-TEST-01.)
- **PC-2** — "Read First" source descriptions are stale (pre-2026-05-19 kit-graph
  refactor). Count (7) correct; no execution impact.
- **PC-3** — "30 assertions" = 30 test *methods*; actual assertion-call count is **61**.
  Both preserved.

---

## Outstanding

- **[RESOLVED]** find-nearest P99 flakiness — Bob approved raising the ceiling 50 → 75 ms
  (option 1 of the 3 presented). Implemented in `09e8c48`, Adams-re-verified, 6/6 runs
  green. No longer blocking.
- **[FOLLOW-ON, optional]** The other three options remain available if a future
  deterministic-gate policy is wanted: (2) move the 4 wall-clock benchmarks out of the
  default `swift test` gate; (3) assert on stable median instead of P99. Not needed for
  this mission; noted for the perf-test-policy backlog.
- **[INFO, pre-existing]** `CapturePathBenchmarkTests` doc comment says
  "Package.swift … declares only EngramLib as a dependency" — actual manifest declares four
  (EngramLib, SubstrateTypes, SubstrateML, PersistenceKit). The functional point (kernel
  types unreachable from the test target) still holds. Left verbatim — out of scope for a
  framework conversion. Adams concurs (INFO, leave-as-is). Candidate for a future
  comment-cleanup mission.

---

## Commits (on stream/vk-vectorkit-test-leg, base 16c0579)

| SHA | Description |
|---|---|
| `12582c5` | docs: mission + Smythe pre-flight (GREEN) + Blast Radius Report |
| `1bfc2c1` | test(vectorkit): convert XCTest suites to swift-testing (assertions preserved) |
| `b61d8e2` | test(vectorkit): per-type coverage gaps filled (Swift) |
| `f2f0d40` | docs: completion report (initial — BLOCKED on flaky benchmark) |
| `09e8c48` | test(vectorkit): raise find-nearest P99 ceiling 50→75ms (Bob-approved, de-flake) |
