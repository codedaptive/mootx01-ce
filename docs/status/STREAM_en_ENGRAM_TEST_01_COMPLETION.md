# COMPLETION: ENGRAM-TEST-01 — EngramLib library test leg → swift-testing (both legs)

**Status: COMPLETE**
Stream: engramtest · Branch: `stream/en-engramlib-test-leg`
Baseline: `b42db96` · Head: `324bcf2`
Mission: `docs/missions/inflight/MISSION_ENGRAM_TEST_01.md`
Date: 2026-05-31

---

## Summary

The EngramLib Swift library test leg now runs under swift-testing. Previously
`EngramLibTests.swift` used `import XCTest`, which registered as **"0 tests in
0 suites"** under the project-standard swift-testing runner — the suite was
invisible to CI for its entire life. It is now an `import Testing` suite that
the swift-testing runner discovers and executes.

The single 20-method XCTest file was converted and split per source type:
- **`EngramLibTests.swift`** — 19 `@Test` methods covering the EngramLib-type
  API (distance, distances, findNearest, findWithin, union, Session).
- **`MatchTests.swift`** (new) — 1 `@Test` method covering the Match type
  (`Comparable`/sort: distance ascending, ties by index ascending).

All 20 original assertions preserved. Parity with the 19 Rust `#[test]`
behaviors confirmed. No production source modified. Both legs green, zero
warnings.

**Package.swift was not modified** (mission's conditional change). swift-testing
is bundled in the Swift 6.3.2 toolchain; `import Testing` resolves with no
package dependency — confirmed by the LatticeKit and SubstrateTypes precedents.
The conditional "add dep only if absent" resolves to a no-op because the
dependency is the toolchain's, not a package's.

## What Was Done

- **Part 1 — convert + per-type split (Swift)** — `c3dddb3`
  (`test(engramlib): swift-testing conversion + per-type split (Swift)`)
  - `EngramLibTests.swift`: `import XCTest` → `import Testing`; `XCTestCase`
    class → `@Suite("EngramLib API") struct`; each `func testX()` → `@Test`
    func; `XCTAssertEqual(a,b)` → `#expect(a == b)`, `XCTAssertNil(x)` →
    `#expect(x == nil)`. `testMatchOrdering` removed (moved to the peer suite).
  - `MatchTests.swift` (new): `@Suite("Match ordering") struct` holding
    `matchOrdering`. Pattern mirrors `LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
- **Part 2 — Swift/Rust library-test parity confirmed** — `324bcf2`
  (`test(engramlib): Swift/Rust library-test parity confirmed`, empty commit)
  - Parity already held after Part 1: all 19 Rust behaviors have Swift peers.
    Nothing was missing, so no test was added. Empty commit marks the milestone
    honestly rather than fabricating a delta.

(Pre-implementation commit `a72ef86` carried the mission file, Smythe
pre-flight, and the Blast Radius Report.)

## Test Verification Log

### Baseline (mission start, commit `b42db96`)
- `cd packages/libs/EngramLib && swift test`: exit **0**. XCTest runner:
  "Executed 20 tests, with 0 failures". **swift-testing runner: "Test run with
  0 tests in 0 suites passed"** — the bug. 1 file imported `XCTest`.
- `cd packages/libs/EngramLib/rust && cargo test`: exit **0**, **19 passed**
  (+1 ignored doc-test, expected).

### Final (commit `324bcf2`)
- Command: `cd packages/libs/EngramLib && swift test`
  - Exit code: **0**
  - swift-testing registration: **20 tests in 2 suites** (Suite "EngramLib API"
    = 19, Suite "Match ordering" = 1)
  - Tail (verbatim): `Test run with 20 tests in 2 suites passed after 0.001 seconds.`
  - `import XCTest` remaining in Tests/: **0**
  - warnings: **0**
- Command: `cd packages/libs/EngramLib/rust && cargo test`
  - Exit code: **0**
  - Pass count: **19** (unchanged — Rust leg not touched)
  - Tail (verbatim): `test result: ok. 19 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s`
  - warnings: **0** (the 1 ignored doc-test is the `///` example marked `ignore`)

Test count delta: swift-testing runner **0 → 20** registered (≥ 20 required).

## Parity (19 Rust `#[test]` ↔ Swift `@Test`)

All 19 behaviors in `rust/tests/engram_lib_tests.rs` have a named Swift peer
(full table in the BRR). The one Swift method with no Rust peer —
`findWithinNegativeMax` — is legitimate Swift-only extra coverage: Rust
`find_within` takes `u32`, so a negative `maxDistance` is structurally
impossible there. Not a parity gap. Result: **19/19 mirrored + 1 Swift-only
extra**.

## Smythe Pre-flight

Verdict: **GREEN — proceed**, zero blockers.
(`docs/blast_radius/ENGRAM_TEST_01_PREFLIGHT.md`)
- Blast radius confirmed exact: mission claims 3 files, reality is 3 (2 written
  + Package.swift no-op). No undeclared call sites, no cross-package entanglement.
- Confirmed the swift-testing runner registers 0 at baseline (bug real) and
  that the per-type split is clean (19 EngramLib-type + exactly 1 Match-type).
- Confirmed `import Testing` works with no package dep on this toolchain
  (LatticeKit/SubstrateTypes precedents) → Package.swift change is a no-op.
- Confirmed `testFindWithinNegativeMax` is Swift-only extra coverage.
- **Documentation inaccuracy surfaced (non-blocking):** mission Context +
  Read First say the 19 Rust tests live "in lib.rs + matchx.rs inline." They
  do not — all 19 live in `rust/tests/engram_lib_tests.rs`. Tests exist and
  `cargo test` runs them; only the pointer is off. Recorded for Skippy.

## Adams Post-flight

Verdict: **PASS — CLEAN. Ship it.**
(`docs/blast_radius/ENGRAM_TEST_01_POSTFLIGHT.md`)
- Blast Radius Verification: **PASS** — diff matches the BRR file set exactly
  (5 files: 2 test files + 3 docs). Zero `Sources/**`, zero `rust/**`, zero
  `docs/validation/**`, zero other package touched. `git diff -- Package.swift`
  empty — genuinely unchanged, confirmed correct. No prohibited patterns
  (bridge/shim/`@available` deprecated/TODO/FIXME).
- Test Execution Verification: **PASS** — Adams independently re-ran both legs
  (Method B): swift exit 0 / "20 tests in 2 suites", cargo exit 0 / 19 passed.
  Both MATCH the claims. Baseline "0 tests in 0 suites" bug confirmed fixed.
  Zero `import XCTest`. Zero warnings both legs.
- Assertion preservation: **20/20** survive; all XCTAssert* → #expect
  translations semantically exact (incl. `XCTAssertNil` → `#expect(x == nil)`).
  No assertion dropped or weakened.
- Parity: **19/19 mirrored + 1 Swift-only extra** confirmed.

### Adams findings resolution

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | INFO | Mission prose locates the 19 Rust tests "in lib.rs + matchx.rs inline"; they actually live in `rust/tests/engram_lib_tests.rs`. Already caught by Smythe and recorded in the BRR. | No code action — Skippy corrects mission prose on next pass. Non-blocking. |

No CRITICAL, no WARNING findings. Hard gate (Adams PASS) satisfied before signal.

## Self-review

- Diff (5 files, +484 / −58) matches the BRR MUST_UPDATE list exactly: 2 test
  files (`EngramLibTests.swift` converted, `MatchTests.swift` created) + 3 docs
  (mission, pre-flight, BRR). The 58 deletions are the replaced XCTest bodies.
- No production source touched (`packages/libs/EngramLib/Sources/**`), no Rust
  (`rust/**`), no `docs/validation/**`, no other package.
- No bridges, shims, TODOs, deprecations, or silenced warnings in the diff.
- Worktree clean before signal.
- Blast Radius Report: `docs/blast_radius/ENGRAM_TEST_01_BLAST_RADIUS.md`.

## Conditional lifecycle agents — evaluated

- **Simms / Friedlander / Nert — N/A.** Test-only mission; no app, view, or
  user-facing behavior change.
- **Perkins — N/A.** No security surface touched: no schema, no CloudKit, no
  privacy/FNode fields, no API-key/Keychain/URL-scheme/NL-prompt handling. Test
  code only.
- **Nagatha docs-repo sync — deferred to post-merge** (standard; Nagatha syncs
  stream output after merge). This completion report is written directly to
  `docs/status/` per the operative goal directive; the signal file follows.

## Discoveries

- **The bug was real and long-lived.** Because `EngramLibTests.swift` imported
  XCTest, the swift-testing runner reported "0 tests in 0 suites" for every run
  since the file was written — the 20 assertions were invisible to the
  project-standard runner. The XCTest runner still executed them (legacy
  interop), which is why the gap went unnoticed. Conversion makes them visible.
- **swift-testing needs no package wiring on Swift 6.3.2.** `import Testing`
  resolves from the bundled toolchain; the mission's conditional Package.swift
  dependency is unnecessary (matches the ST-TEST-01 precedent and the
  LatticeKit/SubstrateTypes test targets).

## Outstanding (out of scope — not addressed)

- **Mission-prose pointer fix.** The mission's "Rust tests in lib.rs + matchx.rs
  inline" should read `rust/tests/engram_lib_tests.rs`. Documentation-only;
  belongs to Skippy on the next mission-authoring pass. Behavior unaffected.
