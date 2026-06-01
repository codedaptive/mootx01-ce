# COMPLETION: CVK-TEST-01 — ConvergenceKit library test leg → swift-testing

**Status: COMPLETE**
Stream: cv · Branch: `stream/cv-convergencekit-test-leg`
Baseline: `16c0579` · Head: `10b408a`
Mission: `docs/missions/inflight/MISSION_CVK_TEST_01.md`
Date: 2026-05-31

---

## Summary

The ConvergenceKit Swift test leg now runs under swift-testing. Previously its
5 test files used `import XCTest`, which registered as **"Test run with 0 tests
in 0 suites passed"** under the project-standard swift-testing runner — the 12
assertions were invisible to that runner for the suite's entire life (the XCTest
runner still executed them via legacy interop, which is why the gap went
unnoticed). They are now `import Testing` suites the swift-testing runner
discovers and executes.

- **Part 1** converted all 5 XCTest files (12 methods) to swift-testing,
  preserving every assertion.
- **Part 2** added 3 new peer suites (14 `@Test`) covering the 3 source files
  that had no test coverage: `FederationIdentity.swift`,
  `HyperplaneFamilyExchange.swift`, `CKRecordMapping.swift` — deterministic
  paths only.

Final: **26 tests in 8 suites, exit 0, zero warnings, zero `import XCTest`.**
No production source modified. No Rust step (out of scope). `Package.swift`
untouched (swift-testing is bundled in the Swift 6.3.2 toolchain — the mission's
conditional dependency resolves to a no-op, third consecutive test-leg mission
to confirm this).

## What Was Done

- **Pre-implementation** — `c5cd836`
  (`docs(convergencekit-test): mission + Smythe pre-flight (GREEN) + Blast Radius Report`)
  carries the mission file, Smythe pre-flight, and the Blast Radius Report.
- **Part 1 — convert XCTest → swift-testing** — `45a110b`
  (`test(convergencekit): convert XCTest suites to swift-testing (assertions preserved)`)
  - `ConvergenceKitCoreTypeTests.swift` (5 methods), `NoSyncEngineTests.swift`
    (4), `CloudKitStubTests.swift` (1), `FederationStubTests.swift` (1),
    `FederationPairingTests.swift` (1).
  - `import XCTest` → `import Testing`; `XCTestCase` class → `@Suite struct`;
    each `func testX()` → `@Test` func; `XCTAssertEqual(a,b)` → `#expect(a == b)`,
    `XCTAssertNotEqual` → `#expect(a != b)`, `XCTAssertGreaterThan(a,b,msg)` →
    `#expect(a > b, "msg")`, `XCTFail("m")` → `Issue.record("m")`, the
    `do { try …; XCTFail } catch SyncError.x` pattern →
    `await #expect(throws: SyncError.x) { try await … }`.
- **Part 2 — per-type coverage gaps filled** — `10b408a`
  (`test(convergencekit): per-type coverage gaps filled (Swift)`)
  - `FederationIdentityTests.swift` (new, 6 `@Test`): Ed25519 sign→verify
    roundtrip; verify rejects tampered payload, wrong key, malformed key;
    `init(privateKeyBytes:)` reproduces the same public key (and a signature
    from the restored key verifies under the original public key); PeerIdentity
    Equatable/Hashable.
  - `HyperplaneFamilyExchangeTests.swift` (new, 5 `@Test`): default
    `dimension == 256`; Codable roundtrip for HyperplaneFamilySpec,
    PairingProposal, PairingAcceptance; HyperplaneFamilySpec Hashable.
  - `CKRecordMappingTests.swift` (new, 3 `@Test`): `recordType` format;
    `recordID` carries the row key; `record()`→`decode()` roundtrip preserves
    table/rowKey/kitID/schemaVersion/values/HLC via an in-memory CKRecord (no
    network). Per Smythe, integer values assert `.int` (the `.bitmap`
    discriminator is not carried through CKRecord's NSNumber bridge).

## Test Verification Log

### Baseline (mission start, commit `16c0579`)
- `cd packages/kits/ConvergenceKit && swift test`: exit **0**. XCTest runner:
  "Executed 12 tests, with 0 failures". **swift-testing runner: "Test run with
  0 tests in 0 suites passed after 0.001 seconds"** — the bug. 5 files imported
  `XCTest`.
- Rust: `rust/tests/` contains **32** `#[test]` functions (none_engine 8 +
  wire_format 14 + federation 10). Out of scope (no Rust parity step).

### Final (commit `10b408a`)
- Command: `cd packages/kits/ConvergenceKit && swift test`
  - Exit code: **0**
  - swift-testing registration: **26 tests in 8 suites** (12 converted +
    14 new). Suites: "ConvergenceKit core types" (5), "NoSyncEngine" (4),
    "CloudKitSyncEngine stub" (1), "FederationSyncEngine stub" (1), "Federation
    in-process pairing" (1), "Federation identity" (6), "Hyperplane family
    exchange" (5), "CKRecord mapping" (3).
  - Tail (verbatim): `Test run with 26 tests in 8 suites passed after 0.106 seconds.`
  - `import XCTest` remaining in `Tests/`: **0**
  - warnings: **0**

Test count delta: swift-testing runner **0 → 26** registered (≥ 12 required;
12 assertions preserved + 14 new coverage tests).

## Smythe Pre-flight

Verdict: **GREEN — proceed**, zero blockers
(`docs/blast_radius/CVK_TEST_01_PREFLIGHT.md`).
- Blast radius confirmed exact: 5 XCTest files / 12 methods / "0 tests in 0
  suites" baseline bug all real.
- Confirmed the 3 Part-2 target source files have zero peer coverage today and
  their deterministic surfaces are public (no `@testable` needed).
- Confirmed CKRecord types instantiate in-process on macOS without network.
- Confirmed `Package.swift` no-op (swift-testing bundled in Swift 6.3.2).
- **Carry-forward (honored):** `CKRecordMapping.decode()` loses the `.bitmap`
  discriminator — NSNumber integers decode as `.int`. The CKRecord roundtrip
  test asserts `.int(42)`, documented in the test header.
- **Documentation inaccuracy surfaced (non-blocking):** mission Context says the
  Rust leg "has 0 `#[test]` functions"; reality is 32. Does not change the work
  (Rust out of scope, no parity step regardless). Recorded for Skippy.

## Adams Post-flight

Verdict: **PASS — CLEAN. Ship it.** Zero findings at any severity.
(`docs/blast_radius/CVK_TEST_01_POSTFLIGHT.md`)
- **Blast Radius Verification: PASS** — diff matches the BRR file set exactly
  (11 files: 5 converted + 3 created + 3 docs). Zero `Sources/**`, zero
  `rust/**`, zero `docs/validation/**`, zero other package.
  `git diff 16c0579..HEAD -- Package.swift` empty — genuinely unchanged. No
  prohibited patterns (bridge/shim/`@available` deprecated/TODO/FIXME).
- **Test Execution Verification: PASS** — Adams independently re-ran (Method B):
  exit 0, "26 tests in 8 suites passed", zero failures, zero warnings, zero
  `import XCTest`. Baseline "0 tests in 0 suites" bug confirmed fixed.
- **Assertion preservation: 12/12** methods → 12 `@Test`, every assertion
  accounted for; the `do/catch/XCTFail` → `#expect(throws:)` conversions noted
  as semantically equal-or-stronger (swift-testing fails automatically on
  non-throw). None dropped or weakened.
- **Part-2 suites:** all 3 cover deterministic paths only; Smythe `.bitmap`/
  `.int` carry-forward honored exactly.

### Adams findings resolution

No CRITICAL, no WARNING, no INFO findings. Hard gate (Adams PASS) satisfied
before signal. (Adams noted the additive `verifyRejectsMalformedKey` test as
in-purpose extra coverage — not a finding.)

## Self-review

- Diff (11 files, +597 / −71) matches the BRR MUST_UPDATE list exactly: 5
  converted test files + 3 new test files + 3 docs (mission, pre-flight, BRR).
  The 71 deletions are the replaced XCTest bodies.
- No production source touched (`packages/kits/ConvergenceKit/Sources/**`), no
  Rust (`rust/**`), no `docs/validation/**`, no other package, `Package.swift`
  unchanged.
- No bridges, shims, TODOs, deprecations, or silenced warnings in the diff.
- All 12 prior assertions preserved; 14 new deterministic coverage tests added.
- Worktree clean before signal.
- Blast Radius Report: `docs/blast_radius/CVK_TEST_01_BLAST_RADIUS.md`.

## Conditional lifecycle agents — evaluated

- **Simms / Friedlander / Nert — N/A.** Test-only mission; no app, view, or
  user-facing behavior change.
- **Perkins — N/A for this change.** Although ConvergenceKit touches CloudKit
  sync and Federation Ed25519 surfaces (a sensitive area), this mission modifies
  **test code only** — no schema, no CloudKit boundary, no key-handling, no
  prompt construction was changed. The new tests exercise existing public
  crypto/mapping APIs without altering them. No security surface moved.
- **Kong — N/A.** No architectural decision, no primitive touched, no two-viable-
  approaches fork. Straight conversion + additive deterministic coverage.
- **Nagatha docs-repo sync — deferred to post-merge** (standard). This
  completion report is written directly to `docs/status/` per the operative
  goal directive; the signal file follows immediately.

## Discoveries

- **The bug was real and long-lived.** All 5 test files imported XCTest, so the
  swift-testing runner reported "0 tests in 0 suites" for every run since the
  files were written. The XCTest runner still executed the 12 assertions (legacy
  interop), masking the gap. Conversion makes all 26 visible to the standard
  runner.
- **swift-testing needs no package wiring on Swift 6.3.2.** `import Testing`
  resolves from the bundled toolchain; the conditional `Package.swift`
  dependency is unnecessary (matches ENGRAM-TEST-01 / ST-TEST-01 and the
  LatticeKit/SubstrateTypes precedents).
- **`TypedValue` lives in PersistenceKit, not SubstrateTypes.** Naming the type
  explicitly in `CKRecordMappingTests` required `import PersistenceKit`
  (reachable transitively via PersistenceKitInMemory in that test target). The
  other suites only reference it via leaf syntax (`.text(…)`), so they never
  needed the explicit import.
- **CKRecord round-trips lose the `.bitmap` discriminator.** `decode()` reads
  NSNumber integers back as `.int`. Not a bug — CKRecord's NS-bridged value
  model has no bitmap concept. Documented in the test and asserted as `.int`.

## Outstanding (out of scope — not addressed)

- **Mission-prose count fix.** The mission's "Rust leg has 0 `#[test]`
  functions" should read 32 (`rust/tests/{none_engine,wire_format,federation}_tests.rs`).
  Documentation-only; belongs to Skippy on the next mission-authoring pass. The
  work was unaffected — Rust is out of scope and the mission correctly has no
  parity step regardless of the count.
