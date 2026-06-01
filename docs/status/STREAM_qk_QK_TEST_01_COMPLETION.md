# COMPLETION: QK-TEST-01 — QueueKit library test leg → swift-testing (conversion)

**Status: COMPLETE**
Stream: qk · Branch: `stream/qk-queuekit-test-leg`
Baseline: `16c0579` · Head: `39b56cc`
Mission: `docs/missions/inflight/MISSION_QK_TEST_01.md`
Date: 2026-05-31

---

## Summary

The QueueKit Swift library test leg now runs under swift-testing. Previously all
5 test files used `import XCTest`, so the project-standard swift-testing runner
reported **"Test run with 0 tests in 0 suites passed"** — the entire 33-method
suite was invisible to that runner for its whole life. (The legacy XCTest runner
still executed the 33 methods, which is why the gap went unnoticed.) The suites
are now `import Testing` / `@Test` / `#expect`, discovered and executed by the
swift-testing runner: **0 → 41 registered**.

Work in two parts:
- **Part 1 — convert** the 5 XCTest files. Every one of the 33 methods and every
  assertion preserved 1:1. No behavior change.
- **Part 2 — fill per-type gaps**. A new `IdentifierTypeTests.swift` adds peer
  coverage (8 `@Test`) for the four public source types in `Job.swift` that had
  no dedicated suite: `StreamID`, `SessionID`, `ToolName`, `MissionContext`.

This is a CONVERSION mission with NO Rust parity step (per mission framing). No
production source modified. Swift leg green, zero warnings. Follows the
ST-TEST-01 / ENGRAM-TEST-01 precedent.

**Package.swift was not modified** (mission's conditional change). swift-testing
is bundled in the toolchain; `import Testing` resolves with no package dependency
— confirmed by the LatticeKit and SubstrateTypes precedents and by Smythe. The
conditional "add dep only if absent" resolves to a no-op.

## What Was Done

- **Part 1 — convert XCTest → swift-testing** — `9b0e919`
  (`test(queuekit): convert XCTest suites to swift-testing (assertions preserved)`)
  - All 5 files: `import XCTest` → `import Testing` (+ explicit `import Foundation`,
    which `import XCTest` previously provided transitively).
  - `final class X: XCTestCase` → suite types. The two filesystem suites
    (`ConformanceTests`, `FilesystemBackendTests`) and the fixture producer
    (`FixtureGenerator`) keep a `final class` form: `setUp` → `init() throws`,
    `tearDown` → `deinit` (synchronous `try? removeItem`, deinit-safe). swift-testing
    instantiates the suite once per test, so per-test setup/teardown semantics are
    preserved. `PersistenceKitBackendTests` and `SupportingTypeTests` became
    `struct` (no teardown needed).
  - `func testX()` → `@Test func x()`, `async throws` preserved where present.
  - Assertions: `XCTAssertEqual(a,b)` → `#expect(a == b)`; `XCTAssertTrue(x)` →
    `#expect(x)`; `XCTAssertFalse(x)` → `#expect(!x)`. The four
    `do { … XCTFail("expected throw") } catch QueueError.case {}` patterns kept the
    `do/catch` (preserving the **specific** error-case assertion — `QueueError` is
    not `Equatable`, so `#expect(throws:)` with a value would not compile) with
    `XCTFail` → `Issue.record`. The Area 4 TaskGroup `XCTFail` → `Issue.record`.
  - `.serialized` applied to the three filesystem-touching suites to honor the
    mission's ordering-sensitivity caution. Correctness does not depend on it
    (each test isolates via a UUID temp dir / fresh in-memory storage); it is a
    harmless match to XCTest's in-class serial execution.
- **Part 2 — per-type coverage gaps filled** — `c100322`
  (`test(queuekit): per-type coverage gaps filled (Swift)`)
  - `IdentifierTypeTests.swift` (new): `StreamID` (RawRepresentable + single-value
    Codable, incl. bare-string wire shape), `SessionID` (`.mint()` lowercase-UUID
    shape + uniqueness + Codable), `ToolName` (RawRepresentable + Codable),
    `MissionContext` (full Codable round-trip + optional/`[String]` defaults). All
    deterministic — no IO, no timing.
- **BRR finalization** — `39b56cc` (`docs(qktest): finalize Blast Radius Report
  test-verification section`).

## Test Verification Log

### Baseline (mission start, commit `16c0579`)
- `cd packages/kits/QueueKit && swift test`: exit **0**. XCTest runner: "Executed
  33 tests, with 0 failures". **swift-testing runner: "Test run with 0 tests in 0
  suites passed"** — the bug. All 5 files imported `XCTest`.
- `cd packages/kits/QueueKit/rust && cargo test`: exit **0**, **4 passed** (all in
  `rust/tests/conformance.rs`; lib 0, doc-tests 0).

### Final (commit `39b56cc`)
- Command: `cd packages/kits/QueueKit && swift test`
  - Exit code: **0**
  - swift-testing registration: **41 tests in 6 suites**
    (Conformance 6, FilesystemBackend 9, PersistenceKit 7, SupportingType 9,
    FixtureGenerator 2, IdentifierType 8 = 41 `@Test`)
  - Tail (verbatim): `Test run with 41 tests in 6 suites passed after 0.062 seconds.`
  - `import XCTest` remaining in Tests/: **0**
  - warnings (clean rebuild): **0**
- Command: `cd packages/kits/QueueKit/rust && cargo test`
  - Exit code: **0**
  - Pass count: **4** (unchanged — Rust leg not touched)
  - Tail (verbatim): `test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.83s`

Test count delta: swift-testing runner **0 → 41** registered (≥ 33 required).
Adams independently re-ran (Method B): "Test run with 41 tests in 6 suites passed
after 0.071 seconds.", exit 0.

## Mission-claim inaccuracy surfaced (non-blocking)

Mission Context says "Its Rust leg has 0 `#[test]` functions." Reality:
`rust/tests/conformance.rs` has **4** `#[test]` (byte-conformance against the
committed `Tests/QueueKitTests/Fixtures/`). This does NOT change the mission: those
are cross-language byte-conformance tests, not behavioral unit tests to mirror, and
`rust/**` is on the MUST-NOT list. The operative intent ("no Rust parity step")
stands. Caught by Smythe and recorded in the BRR + Smythe pre-flight. Recorded for
Skippy; not a blocker.

## Smythe Pre-flight

Verdict: **GREEN — proceed**, zero blockers.
(`docs/blast_radius/QK_TEST_01_PREFLIGHT.md`)
- Blast radius exact: 5 files / 33 methods (6/9/7/9/2), all `import XCTest`, zero
  `import Testing` at baseline.
- Baseline bug confirmed live: swift-testing runner "0 tests in 0 suites".
- Rust `#[test]` = 4 (mission says 0) — non-blocking prose inaccuracy.
- `import Testing` resolves with no Package.swift dep (LatticeKit / SubstrateTypes
  precedents) → Package.swift change is a no-op.
- Part 2 gap types verified present and uncovered (StreamID, SessionID, ToolName,
  MissionContext). Watcher exclusion accepted (internal; `watchKQueue` parks on
  `await box.wait()` until DispatchSource cancel; no unit-test-reachable
  cancellation path on Darwin; timing-sensitive).
- Conversion hazards reviewed sound: `deinit` teardown legal (synchronous
  `try? removeItem`); `do/catch + Issue.record` is the correct mapping (QueueError
  not Equatable).

## Adams Post-flight

Verdict: **PASS — CLEAN. Ship it.**
(`docs/blast_radius/QK_TEST_01_POSTFLIGHT.md`)
- Blast Radius Verification: **PASS** — diff is exactly the 6 test-target files
  (5 converted + 1 new) + 3 docs. `Package.swift` diff empty (confirmed no-op);
  `Sources/**`, `rust/**`, `docs/validation/**`, other packages all untouched.
  No prohibited patterns (no bridge/shim/`@available` deprecated/TODO/FIXME/
  `.disabled`/skip).
- Test Execution Verification: **PASS** — Adams re-ran (Method B): exit 0, "41
  tests in 6 suites passed", 0 failures. Zero `import XCTest`. @Test count 41.
- Assertion preservation: **33/33** methods survive 1:1; the four
  `do/catch + Issue.record` error-case patterns and the Area 4 TaskGroup
  `Issue.record` correctly preserve the original assertions; all `XCTAssertFalse`
  → `#expect(!x)`. None dropped or weakened.
- Part 2: 8 genuine tests over 4 confirmed-public types; none tautological.
  Watcher exclusion technically sound and correctly documented.

### Adams findings resolution

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | INFO | `FixtureGenerator.swift:8` header comment updated `--filter FixtureGenerator.testGenerate` → `--filter FixtureGenerator`; the suite-level filter is the natural swift-testing equivalent and also runs `fixturesByteIdenticalToCommitted`. No behavior impact. | No action — accurate as written. |

No CRITICAL, no WARNING. Hard gate (Adams PASS) satisfied before signal.

## Self-review

- Diff (9 files, +674 / −137) matches the BRR MUST_UPDATE list exactly: 5 converted
  test files + 1 new (`IdentifierTypeTests.swift`) + 3 docs (mission, pre-flight,
  BRR). The 137 deletions are replaced XCTest bodies.
- No production source touched (`Sources/**`), no Rust (`rust/**`), no
  `docs/validation/**`, no other package. `Package.swift` unchanged.
- No bridges, shims, TODOs, deprecations, or silenced warnings.
- Worktree clean before signal.
- Blast Radius Report: `docs/blast_radius/QK_TEST_01_BLAST_RADIUS.md`.

## Conditional lifecycle agents — evaluated

- **Simms / Friedlander / Nert — N/A.** Test-only mission; no app, view, or
  user-facing behavior change.
- **Perkins — N/A.** No security surface touched: no schema change, no CloudKit,
  no privacy/FNode fields, no API-key/Keychain/URL-scheme/NL-prompt handling. Test
  code only. (The PersistenceKit schema is *read* in assertions, not modified.)
- **Kong / Scorandum / Kinsta — N/A.** No architectural decision, no perf-sensitive
  surface, no stuck investigation.
- **Nagatha docs-repo sync — deferred to post-merge** (standard). This completion
  report is written directly to `docs/status/` per the operative goal directive;
  the signal file follows.

## Discoveries

- **The bug was real and long-lived.** Because all 5 files imported XCTest, the
  swift-testing runner reported "0 tests in 0 suites" on every run since the files
  were written — the 33 methods were invisible to the project-standard runner.
  Conversion makes them visible (now 41 with the gap-fill suite).
- **swift-testing needs no package wiring on this toolchain.** `import Testing`
  resolves from the bundled toolchain; the mission's conditional Package.swift
  dependency is unnecessary (matches ST-TEST-01 / ENGRAM-TEST-01 and the
  LatticeKit / SubstrateTypes test targets).
- **Structs can't carry teardown.** swift-testing suites are commonly structs, but
  struct suites have no `deinit`. The two temp-dir suites use `final class` +
  `init`/`deinit` to preserve XCTest's setUp/tearDown lifecycle faithfully.

## Outstanding (out of scope — not addressed)

- **Mission-prose fix.** Mission Context "Rust leg has 0 `#[test]`" should read
  "4 `#[test]` in `rust/tests/conformance.rs` (byte-conformance, not parity)".
  Documentation-only; belongs to Skippy on the next mission-authoring pass.
  Behavior unaffected; mission intent unchanged.
- **Watcher direct unit coverage.** Intentionally deferred — a deterministic test
  of the kqueue/inotify wake source needs a cancellation/timeout harness that
  doesn't risk a hang. Tracked as a conscious decision, not a regression.
