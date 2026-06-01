# Smythe Pre-flight: GLK-TEST-01

## Status

YELLOW — terrain substantially clear. No execution blockers. Two mission-prose
inaccuracies documented (doc nits, non-blocking). Rust parity scope is
significantly larger than the mission states: 99 total `#[test]` functions across
12 files, not 13. True Swift @Test-eligible method count is 148, not 146.
Proceed with corrections noted.

---

## Status details

- **Blast radius:** 20 test files + Package.swift declared. Reality: exactly 20
  test files, all XCTest. Package.swift has no swift-testing dep (confirmed
  no-op). No undeclared call sites. No cross-package entanglement — only branch
  `stream/gl-geniuslocuskit-test-leg` touches GeniusLocusKit. Blast radius
  matches claim.
- **Prior art:** No conflicting prior art. No parallel branch touches
  GeniusLocusKit files. One branch: `stream/gl-geniuslocuskit-test-leg` (this
  branch). Clean.
- **Environment:** Branch `stream/gl-geniuslocuskit-test-leg` active. Baseline
  confirmed: `swift test` exit 0, 148 XCTest methods pass, swift-testing runner
  reports 0 tests in 0 suites (the bug). `cargo test` exit 0 — 99 total passed
  across 12 test binaries, 0 failed. Both legs green.
  Toolchain: Swift 6.3.2 / swiftlang-6.3.2.1.108. swift-testing bundled.
- **Dependencies:** None listed. Mission declares parallel-safe with all other
  test-leg streams (disjoint packages). Confirmed.

---

## Blockers

None. Mission may proceed.

---

## Mission-prose inaccuracies (non-blocking — reconcile before committing)

### 1. Swift method count: mission says 146, reality is 148

**Mission states:** "20 files, 146 XCTest methods" and "preserve all 146
assertions."

**Reality:** `grep -c "func test"` across all 20 files sums to exactly 148.
XCTest runner confirms: "Executed 148 tests, with 0 failures." Both methods in
`PerformanceGateTests.swift` (`testTheorem5_CaptureP99UnderIPhoneBudget` and
`testTheorem5_EnrichmentThroughputClearsMacFloor`) are genuine `@Test`-eligible
methods — not helpers, not lifecycle overrides.

**Per-file breakdown:**

| File | func test count |
|---|---|
| `VerbSurfaceTests.swift` | 16 |
| `UnifiedAuditLogTests.swift` | 16 |
| `StandingSignalSchedulerTests.swift` | 13 |
| `TrainingDaemonTests.swift` | 11 |
| `MatrixTierTests.swift` | 11 |
| `GLK_COW_01_BranchTests.swift` | 10 |
| `GLK_MIG_02_MigrationTests.swift` | 9 |
| `StandingSignalsTests.swift` | 8 |
| `GRT01_GrantTests.swift` | 8 |
| `GLK03_AuditIntegrationTests.swift` | 7 |
| `ENC02_DecayDerivedKeyTests.swift` | 7 |
| `CrossEstateFederationTests.swift` | 6 |
| `TheoremsTests.swift` | 4 |
| `PromotionTargetTests.swift` | 4 |
| `CrossEstateOverlapTests.swift` | 4 |
| `CoordinatorLifecycleTests.swift` | 4 |
| `CompositionConformanceTests.swift` | 4 |
| `GRT_AuditEmissionTests.swift` | 3 |
| `PerformanceGateTests.swift` | 2 |
| `EstateIsolationTests.swift` | 1 |
| **TOTAL** | **148** |

Bilby must preserve all 148 assertions. No test is a helper or excluded.

---

### 2. Rust test count: mission says 13, reality is 99

**Mission states:** "The Rust leg has 13 `#[test]` functions."

**Reality:** 99 `#[test]` functions across 12 files (2 inline unit-test modules
in `src/`, 10 integration test files in `tests/`). `cargo test` confirms:
99 passed, 0 failed, across 12 binaries.

The 13 the mission references is the *unit test binary* only: 7 inline tests in
`src/coordinator.rs` + 6 inline tests in `src/branches.rs` = 13. The integration
suite in `tests/` adds 86 more across 10 files.

**Rust test inventory by file:**

| File | `#[test]` count | Cargo result |
|---|---|---|
| `src/coordinator.rs` (inline) | 7 | 13 unit ok (combined w/ branches) |
| `src/branches.rs` (inline) | 6 | — |
| `tests/audit_parity.rs` | 15 | 15 ok |
| `tests/scheduler_parity.rs` | 12 | 12 ok |
| `tests/training_parity.rs` | 11 | 11 ok |
| `tests/matrix_parity.rs` | 11 | 11 ok |
| `tests/standing_signals_parity.rs` | 10 | 10 ok |
| `tests/verb_parity.rs` | 10 | 10 ok |
| `tests/parity.rs` | 8 | 8 ok |
| `tests/theorems_tests.rs` | 4 | 4 ok |
| `tests/composition_conformance_tests.rs` | 3 | 3 ok |
| `tests/performance_gate_tests.rs` | 2 | 2 ok |
| **TOTAL** | **99** | **99 ok** |

Implication for Part 3 (parity): Bilby must confirm Swift suites assert the
behaviors from **all 99** Rust tests — not just 13. The 20 existing Swift test
files already substantially mirror the integration test suite (same domains:
audit, scheduler, training, matrix, standing signals, verb, branches, theorems,
composition, performance). Parity mapping goes in the Blast Radius Report.

---

## Verified findings

### 3. swift-testing wiring — Package.swift change is a no-op

Swift 6.3.2 bundles swift-testing. `import Testing` resolves without a package
dependency.

Confirmed by precedent: `packages/kits/LatticeKit/Package.swift` — no
swift-testing entry in `dependencies:` or `testTarget` dependencies. Test files
use `import Testing` and pass. `packages/libs/SubstrateTypes/Package.swift` —
same pattern.

`GeniusLocusKit/Package.swift`: no swift-testing dep in `dependencies:` or in
the `GeniusLocusKitTests` target. Mission clause "conditional: additive
swift-testing dep only if absent" → absent AND not needed. **No-op.** Bilby
reads Package.swift, confirms, makes no change.

---

### 4. swift-testing reference style — CodeTests.swift pattern

`packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`:

```swift
import Testing
@testable import LatticeKit

@Suite("Code grammar")
struct CodeTests {
    @Test("three-digit integer is well-formed")
    func threeDigit() {
        #expect(Code.isWellFormed("000"))
    }
}
```

This is the conversion pattern. Each XCTest class → `@Suite` struct; each
`func test*` method → `@Test func` (camelCase, drop the `test` prefix); each
`XCTAssertEqual(a, b)` → `#expect(a == b)`; each `XCTAssertTrue(x)` →
`#expect(x)`; each `XCTAssertNil(x)` → `#expect(x == nil)`; each
`try XCTUnwrap(x)` → `try #require(x)`. Async throws methods stay async throws.

---

### 5. Source-type coverage — gaps and peer map

46 source files in 9 source groups. 20 test files cover the below. No test file
is missing for an entire domain — but several source types within domains have
no dedicated peer suite:

**Covered (peer test file exists):**

| Source group | Source files | Peer test file |
|---|---|---|
| `Audit/` (6 files) | AuditBridge, AuditChainReport, AuditChainVerifier, AuditProjection, AuditRecovery, UnifiedAuditLog | `UnifiedAuditLogTests.swift`, `GLK03_AuditIntegrationTests.swift`, `GRT_AuditEmissionTests.swift` |
| `Brain/` (3 direct) | ProposalKind, SignalAPI, SignalSchedule, StandingSignalScheduler | `StandingSignalSchedulerTests.swift`, `StandingSignalsTests.swift` |
| `Brain/Signals/` (5 files) | ByReferenceValiditySignal, DecaySweepSignal, DefaultStandingSignals, DreamingSignal, EndOfDayTournamentSignal, MaintenanceSignal, VectorSimilaritySignal | `StandingSignalsTests.swift` |
| `Branches/` (3 files) | BranchHandle, BranchTypes, EstateBranch | `GLK_COW_01_BranchTests.swift` |
| `Federation/` (2 files) | CrossEstateFederation, FederatedRecallResult | `CrossEstateFederationTests.swift`, `CrossEstateOverlapTests.swift` |
| `Grants/` (4 files) | Grant, GrantStore, LagrangeDecayKey, ScopeKeyVault | `GRT01_GrantTests.swift`, `ENC02_DecayDerivedKeyTests.swift` |
| `Matrix/` (4 files) | Calibration, LatentFactors, MatrixPersistence, MatrixTier | `MatrixTierTests.swift` |
| `Migration/` (4 files) | ExternalCorpus, MigrationAPI, MigrationTypes, ParallelRunHandle | `GLK_MIG_02_MigrationTests.swift` |
| `Training/` (3 files) | EnrichmentPipeline, ThresholdGate, TrainingDaemon | `TrainingDaemonTests.swift` |
| `Verbs/` (4 files) | AriaLexiconConformance, Frames, VerbError, VerbSurface | `VerbSurfaceTests.swift` |
| Root (4 files) | CrossEstateRead, EstateCoordinator, EstateHandle, GeniusLocusKit, GeniusLocusKitError | `CoordinatorLifecycleTests.swift`, `EstateIsolationTests.swift`, `CompositionConformanceTests.swift` |
| Theorems | (cross-cutting) | `TheoremsTests.swift` |
| Performance | (cross-cutting) | `PerformanceGateTests.swift` |
| Promotion | PromotionTargetTests | `PromotionTargetTests.swift` |

**Potential Part 2 gap candidates (source types with no dedicated peer):**

- `AuditBridge`, `AuditChainReport`, `AuditChainVerifier`, `AuditRecovery` — folded into audit integration tests; Rust `audit_parity.rs` covers projection/recovery directly. Gap suite candidate: `AuditChainTests.swift`.
- `Calibration`, `LatentFactors`, `MatrixPersistence` — covered partially by `MatrixTierTests`; Rust `matrix_parity.rs` has 11 dedicated tests including persistence modes. Gap candidate: `MatrixCalibrationTests.swift`.
- `ScopeKeyVault` — no dedicated peer (grant tests focus on Grant/GrantStore/decay). Gap candidate: folding into `GRT01_GrantTests`.
- `FederatedRecallResult` — covered through federation tests but no dedicated type test.
- `ProposalKind`, `SignalSchedule`, `SignalAPI` — partially in `StandingSignalSchedulerTests`; Rust `scheduler_parity.rs` has `proposal_kind_raw_value_round_trip` and `proposal_kind_unknown_label_maps_to_other` (2 tests). Gap candidate: `ProposalKindTests.swift`.
- `GeniusLocusKitError` — no dedicated error-type test visible in existing suite.

Bilby will do the definitive gap triage by reading each test file fully (Part 2).

---

### 6. Prior-art conflicts — none

No parallel stream touches GeniusLocusKit. One branch:
`stream/gl-geniuslocuskit-test-leg`. No undeclared test files beyond the 20
already in `Tests/GeniusLocusKitTests/`.

---

## Baseline test counts (verbatim tails)

### Swift `swift test` (tail -25)

```
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testMutateStateAxisKindSurfacesNotSupported]' passed (0.001 seconds).
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testProposeOnStaleHandleRaisesEstateNotOpen]' started.
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testProposeOnStaleHandleRaisesEstateNotOpen]' passed (0.001 seconds).
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testProposeRaisesNotSupported]' started.
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testProposeRaisesNotSupported]' passed (0.001 seconds).
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testReanchorEmptyRaisesGuard]' started.
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testReanchorEmptyRaisesGuard]' passed (0.001 seconds).
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testReanchorRoundTrip]' started.
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testReanchorRoundTrip]' passed (0.001 seconds).
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testSurfaceTargetsAreAcceptedByLexicon]' started.
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testSurfaceTargetsAreAcceptedByLexicon]' passed (0.000 seconds).
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testWithdrawRoundTrip]' started.
Test Case '-[GeniusLocusKitTests.VerbSurfaceTests testWithdrawRoundTrip]' passed (0.001 seconds).
Test Suite 'VerbSurfaceTests' passed at 2026-05-31 20:55:04.947.
	 Executed 16 tests, with 0 failures (0 unexpected) in 0.015 (0.015) seconds
Test Suite 'GeniusLocusKitPackageTests.xctest' passed at 2026-05-31 20:55:04.947.
	 Executed 148 tests, with 0 failures (0 unexpected) in 0.366 (0.373) seconds
Test Suite 'All tests' passed at 2026-05-31 20:55:04.947.
	 Executed 148 tests, with 0 failures (0 unexpected) in 0.366 (0.373) seconds
[GLK-08 perf] capture-latency p50=0.321 ms p95=0.431 ms p99=0.519 ms max=0.575 ms (n=200 Mac profile; iPhone budget 100.0 ms)
[GLK-08 perf] enrichment-rate elapsed=0.003 s drawers=500 rate=614107481.774 drawers/hour (Mac profile; floor 60.0 drawers/hour)
  Test run started.
  Testing Library Version: 1902
  Target Platform: arm64e-apple-macos14.0
  Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

XCTest: 148 executed, 0 failures. swift-testing: 0 tests in 0 suites — the bug.

### Rust `cargo test` (result lines)

```
test result: ok. 13 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s   [unit: branches + coordinator inline]
test result: ok. 15 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s   [audit_parity]
test result: ok.  3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s   [composition_conformance_tests]
test result: ok. 11 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.02s   [training_parity]
test result: ok.  8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s   [parity]
test result: ok.  2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s   [performance_gate_tests]
test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s   [scheduler_parity]
test result: ok. 10 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s   [verb_parity]
test result: ok.  4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s   [theorems_tests]
test result: ok. 11 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s   [matrix_parity]
test result: ok. 10 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s   [standing_signals_parity]
test result: ok.  0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s   [doc-tests]
```

99 passed, 0 failed. Both legs green.

---

## Bilby's stated approach

*[To be written by Bilby before proceeding. 2-4 sentences: which files first,
which pattern, what is NOT being done.]*

**Assessment:** Pending Bilby's statement.

---

## Actions (proceeding)

1. Read all 20 XCTest files fully before touching any.
2. Convert file-by-file: `import XCTest` → `import Testing`; `XCTestCase`
   subclass → `@Suite` struct; each `func test*` → `@Test func` (drop `test`
   prefix, camelCase); `XCTAssertEqual(a, b)` → `#expect(a == b)`;
   `XCTAssertTrue(x)` → `#expect(x)`; `XCTAssertNil(x)` → `#expect(x == nil)`;
   `try XCTUnwrap(x)` → `try #require(x)`. Async throws signatures unchanged.
   Pattern: `LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
3. After Part 1 commit: `swift test` must exit 0, register >= 148 @Test
   functions, zero `import XCTest` remaining.
4. Part 2: read each test file and source group; identify source types with no
   peer assertion; add per-type suites for the confirmed gaps listed above.
5. Part 3: read all 12 Rust test files (99 tests); confirm Swift suites assert
   each behavior; add missing @Test functions where parity is absent.
6. `Package.swift`: read, confirm no swift-testing dep, make no change. Non-event.
7. Final: `swift test` exit 0 (>= 148 @Test), `cargo test` exit 0 (99 passed),
   zero warnings both legs, zero `import XCTest`. Record verbatim tails in
   mission Test Verification Log.

---

## Decision needed

None. Path is clear.

---

## Baseline test counts

| Suite | Count | Status |
|---|---|---|
| Swift `swift test` | **148** XCTest methods pass; 0 swift-testing (the bug) | GREEN baseline |
| Rust `cargo test` | **99** passed (13 unit + 86 integration), 0 failed | GREEN |
