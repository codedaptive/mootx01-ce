# COMPLETION: GLK-TEST-01 — GeniusLocusKit library test leg → swift-testing (both legs)

**Status: COMPLETE**
Stream: gl · Branch: `stream/gl-geniuslocuskit-test-leg`
Baseline: `16c0579` · Head: `3df6107`
Mission: `docs/missions/inflight/MISSION_GLK_TEST_01.md`
Date: 2026-05-31

---

## Summary

The GeniusLocusKit Swift library test leg now runs under swift-testing.
Previously all 20 files in `Tests/GeniusLocusKitTests/` used `import XCTest`,
which registered as **"0 tests in 0 suites"** under the project-standard
swift-testing runner — 148 assertions invisible to CI for the suite's entire
life. The XCTest runner still executed them (legacy interop), which is why the
gap went unnoticed. The files are now `import Testing` suites the swift-testing
runner discovers and executes.

All 20 files converted, **all 148 prior assertions preserved 1:1**. One new
per-type gap suite added (`GeniusLocusKitErrorTests`, 14 tests) for the single
source type Smythe's blast-radius map flagged with no dedicated peer. Parity
with the Rust behavior set confirmed. No production source modified. Both legs
green, zero warnings.

**Package.swift was not modified** (mission's conditional change). swift-testing
is bundled in the Swift toolchain; `import Testing` resolves with no package
dependency — confirmed by Smythe against the LatticeKit / SubstrateTypes
precedents and by the clean build. The conditional "add dep only if absent"
resolves to a no-op (matches the EngramLib / ST-TEST-01 precedent).

## What Was Done

- **Part 1 — convert 20 XCTest files** — `dd04301`
  (`test(geniuslocuskit): convert XCTest suites to swift-testing (assertions preserved)`)
  - Each of the 20 files: `import XCTest`→`import Testing`;
    `final class FooTests: XCTestCase`→`@Suite("…") struct FooTests`; each
    `func testBar()`→`@Test func bar()` (drop `test` prefix, lowercase first
    char; `async`/`throws` preserved). Assertion macros translated 1:1:
    `XCTAssertEqual(a,b)`→`#expect(a == b)`, `XCTAssertNotEqual`→`!=`,
    `XCTAssertTrue(x)`→`#expect(x)`, `XCTAssertFalse(x)`→`#expect(!x)`,
    `XCTAssertNil(x)`→`#expect(x == nil)`, `XCTAssertNotNil(x)`→`#expect(x != nil)`,
    `XCTAssertGreaterThan/LessThan[OrEqual]`→`> / < / >= / <=`,
    `XCTAssertEqual(a,b,accuracy:acc)`→`#expect(abs(a-b) <= acc)`,
    `try XCTUnwrap(x)`→`try #require(x)`, `XCTFail(m)`→`Issue.record(m)`.
  - The custom `XCTAssertThrowsErrorAsync` free helper (defined in
    `CoordinatorLifecycleTests`, used across 4 files) was replaced everywhere
    with native `await #expect(throws: E.self) { … }`, capturing the returned
    error and matching the same enum case + associated values via
    `if case .case(let x)? = thrown { #expect(x == …) } else { Issue.record(…) }`.
    The helper definition was removed. `do/catch` and `switch` blocks that used
    `XCTFail` (GLK_MIG_02, GRT01, ENC02, scheduler, training) had `XCTFail`→
    `Issue.record` with their message strings verbatim; structure preserved.
  - Scoped imports preserved (`import enum GeniusLocusKit.ProposalKind` in the
    scheduler suite; plain `import GeniusLocusKit` in GLK_MIG_02; `CryptoKit`,
    `AriaLexiconLib`, `SubstrateTypes` imports as-is).
- **Part 2 — per-type coverage gaps filled** — `fe37310`
  (`test(geniuslocuskit): per-type coverage gaps filled (Swift)`)
  - `GeniusLocusKitErrorTests.swift` (new, 14 `@Test`): the one source type
    with no dedicated peer. Existing suites throw and match individual error
    cases; none assert the type's own surface. New suite pins all 10 cases'
    `CustomStringConvertible.description` and the `Equatable` conformance
    (equal iff case+payload; differs by payload; differs by case), plus
    throwable/catchable as a typed error.
  - ProposalKind, ScopeKeyVault, FederatedRecallResult, AuditChain* confirmed
    already covered by existing peer suites (Known Ambiguity 1/2) — no
    synthetic tests added.
- **Part 3 — Swift/Rust parity confirmed** — `3df6107` (empty commit)
  (`test(geniuslocuskit): Swift/Rust library-test parity confirmed`)
  - Parity held after Parts 1-2: nothing was missing, so no test was added.
    Empty commit marks the milestone honestly rather than fabricating a delta.

## Test Verification Log

### Baseline (mission start, commit `16c0579`)
- `cd packages/kits/GeniusLocusKit && swift test`: exit **0**. XCTest runner
  executed 148; **swift-testing runner: "0 tests in 0 suites"** — the bug.
  20 files, all `import XCTest`, zero `import Testing`.
- `cd packages/kits/GeniusLocusKit/rust && cargo test`: exit **0**, **99 passed**
  (13 unit inline in `src/coordinator.rs`+`src/branches.rs`, 86 integration in
  `tests/`). (The mission prose says "13 Rust `#[test]`" — that is the unit
  binary only; Smythe reconciled the true total to 99. Recorded for Skippy.)

### Final (commit `3df6107`)
- Command: `cd packages/kits/GeniusLocusKit && swift test`
  - Exit code: **0**
  - swift-testing registration: **162 tests in 21 suites** (20 converted suites
    = 148 `@Test` + `GeniusLocusKitError surface` = 14)
  - Tail (verbatim): `Test run with 162 tests in 21 suites passed after 0.117 seconds.`
  - `import XCTest` remaining in `Tests/`: **0**;
    `XCTAssert*`/`XCTFail`/`XCTUnwrap`/`XCTestCase` remaining: **0**
  - warnings: **0**
- Command: `cd packages/kits/GeniusLocusKit/rust && cargo test`
  - Exit code: **0**
  - Pass count: **99** (unchanged — Rust leg not touched):
    13 + 15 + 3 + 11 + 8 + 2 + 12 + 10 + 4 + 11 + 10 + 0 doc-tests
  - warnings: **0**

Test count delta: swift-testing runner **0 → 162** registered (≥ 148 required;
148 preserved + 14 new).

Method-count note: the mission states "146 XCTest methods"; the true
`@Test`-eligible count is **148** (Smythe + XCTest runner + per-file grep
agree). All 148 preserved. Mission-prose inaccuracy recorded for Skippy.

## Parity (Rust `#[test]` ↔ Swift `@Test`)

Mission-scoped target — the 13 inline `src/` `#[test]` — all have named Swift
peers:
- `co1…co6` (7 coordinator tests, `src/coordinator.rs`) → `VerbSurfaceTests`
  (captureThenRecall, withdrawRoundTrip, expungeWithoutConfirmationRaisesGuard,
  reanchorEmptyRaisesGuard, mutateConfirmRoundTripTransitionsConfirmation,
  mutateStateAxisKindSurfacesNotSupported, proposeOnStaleHandleRaisesEstateNotOpen).
- `br1…br6` (6 branch tests, `src/branches.rs`) → `GLK_COW_01_BranchTests`.

The broader 86 integration `#[test]` (`tests/*_parity.rs`, 99 total) each have
a peer suite by name: `verb_parity`↔VerbSurfaceTests,
`audit_parity`↔UnifiedAuditLogTests, `scheduler_parity`↔StandingSignalSchedulerTests,
`training_parity`↔TrainingDaemonTests, `matrix_parity`↔MatrixTierTests,
`standing_signals_parity`↔StandingSignalsTests, `parity`↔Coordinator/CrossEstate*,
`theorems_tests`↔TheoremsTests, `composition_conformance_tests`↔CompositionConformanceTests,
`performance_gate_tests`↔PerformanceGateTests. Full table in the BRR. Result:
**parity holds, asymmetry respected** (only 13 inline src tests; Rust does not
implement most of the 46 source types, so Swift asserts Swift behavior where
Rust has no peer).

## Smythe Pre-flight

Verdict: **YELLOW — proceed**, zero blockers.
(`docs/blast_radius/GLK_TEST_01_PREFLIGHT.md` + `…_BLAST_RADIUS.md`)
- Blast radius confirmed: 20 test files + Package.swift conditional. No
  undeclared call sites, no cross-package entanglement.
- Confirmed the swift-testing runner registers 0 at baseline (bug real) and
  both legs green at baseline.
- Reconciled two mission-prose inaccuracies (non-blocking):
  1. method count is **148**, not 146;
  2. Rust `#[test]` total is **99** (13 unit + 86 integration), not 13 — the
     mission's "13" is the unit binary only.
- Produced the source-type→test-file map (the GeniusLocusKitError gap) and the
  full 99-test parity table. Confirmed `import Testing` needs no package dep.

## Adams Post-flight

Verdict: **PASS — CLEAN. Ship it.**
(`docs/blast_radius/GLK_TEST_01_POSTFLIGHT.md`)
- Blast Radius Verification: **PASS** — committed diff (`16c0579..3df6107`)
  touches exactly 21 files, all under `Tests/GeniusLocusKitTests/`. Zero
  `Sources/**`, zero `rust/**` (incl. Cargo.lock), zero `docs/validation/**`,
  zero other package. Package.swift not in diff (no-op confirmed). The 3 mission
  docs correctly untracked.
- Test Execution Verification: **PASS** — Adams independently re-ran both legs
  (Method B): swift exit 0 / "162 tests in 21 suites", cargo exit 0 / 99 passed.
  Both MATCH the claims. Baseline "0 tests in 0 suites" bug confirmed fixed.
  Zero `import XCTest`/`XCTAssert*`. Zero warnings both legs. Cargo's Cargo.lock
  re-resolution reverted; rust tree left pristine.
- Assertion preservation: **148/148** + 14 new survive; all macro translations
  semantically exact — incl. the `accuracy:`→`abs(a-b) <= acc` conversions, the
  15-site `XCTAssertThrowsErrorAsync`→native `#expect(throws:)` with
  associated-value extraction preserved, `XCTUnwrap`→`#require`, and
  `XCTFail`→`Issue.record` with verbatim messages.
- `_ = branchRow` / `_ = skippedRow` in GLK_COW_01: behavior-neutral
  unused-binding suppression; baseline confirms those bindings were never used
  in assertions.

### Adams findings resolution

No CRITICAL, no WARNING, no INFO findings. Hard gate (Adams PASS) satisfied
before signal.

## Self-review

- Committed diff (`16c0579..3df6107`, 21 files) matches the BRR MUST_UPDATE list
  exactly: 20 converted test files + 1 new per-type suite. The 3 docs
  (mission, pre-flight, BRR, post-flight) are written directly to the worktree
  and are intentionally untracked per the operative goal directive.
- No production source touched (`Sources/**`), no Rust (`rust/**`, incl.
  Cargo.lock — reverted twice after Smythe's and the Part-3 cargo runs
  re-resolved substrate-lib 0.36.0→1.0.0; that resolution is environmental,
  not a mission edit), no `docs/validation/**`, no other package.
- No bridges, shims, TODOs, deprecations, or silenced warnings introduced.
- All 148 prior assertions preserved; zero `import XCTest` and zero `XCTAssert*`
  tokens remain in `Tests/`.
- Blast Radius Report: `docs/blast_radius/GLK_TEST_01_BLAST_RADIUS.md`.

## Conditional lifecycle agents — evaluated

- **Simms / Friedlander / Nert — N/A.** Test-only mission; no app, view, or
  user-facing behavior change.
- **Perkins — N/A.** No production security surface modified. The federation/
  grant/custody/CryptoKit test code (GRT01, ENC02, CrossEstateFederation) only
  *asserts existing behavior* of released code; it adds no new schema,
  CloudKit, privacy/FNode, API-key/Keychain, URL-scheme, or NL-prompt surface.
- **Nagatha docs-repo sync — deferred to post-merge** (standard). This
  completion report is written directly to `docs/status/` per the operative
  goal directive; the signal file follows.

## Discoveries

- **The bug was real and long-lived.** Every file in `Tests/GeniusLocusKitTests/`
  imported XCTest, so the swift-testing runner reported "0 tests in 0 suites"
  for the suite's entire life — 148 assertions invisible to the project-standard
  runner. The XCTest runner still ran them (legacy interop), masking the gap.
  Conversion makes all 148 visible (now 162 with the gap suite).
- **swift-testing's `Comment` rejects `String` concatenation.** Two
  `#expect(cond, "…" + "…")` comment args (PerformanceGateTests) failed to
  compile — `Comment` is `ExpressibleByStringInterpolation` but a `+`-built
  `String` is a value, not a literal. Fixed by merging each into one
  interpolated literal. (Watch-item for future XCTest→swift-testing conversions.)
- **swift-testing runs suites in parallel by default.** The converted suites use
  per-test isolated in-memory storage and value-type `@Suite struct`s (fresh
  instance per `@Test`), so the parallel runner found no races — both the
  implementer's and Adams's independent runs were clean at 162/21. (Cross-ref
  the PK-TEST-01 observation that parallel-by-default can surface latent
  fire-and-forget `Task` races; none surfaced here.)

## Outstanding (out of scope — not addressed)

- **Mission-prose fixes (documentation-only, for Skippy):** "146 XCTest methods"
  should read **148**; "The Rust leg has 13 `#[test]` functions" should read
  **99** (13 unit + 86 integration; the 13 is the `src/` inline binary only).
  Behavior unaffected; surfaced by Smythe, recorded here.
