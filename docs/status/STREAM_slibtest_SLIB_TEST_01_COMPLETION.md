# COMPLETION: SLIB-TEST-01 — SubstrateLib library test leg (swift-testing, both legs)

**Status: COMPLETE**
Stream: slibtest · Branch: `stream/sl-substratelib-test-leg`
Baseline: `b42db96` · Head: `6d11790` (+ this report commit)
Mission: `docs/missions/inflight/MISSION_SLIB_TEST_01.md`
Date: 2026-05-31

---

## Summary

SubstrateLib's Swift test leg is now swift-testing. All 10 pre-existing XCTest
files (7 in `SubstrateLibTests`, 3 in `SubstrateLibConformanceTests`) were
converted to `import Testing` / `@Suite` / `@Test` / `#expect` / `#require`,
preserving every assertion. The conversion was load-bearing, not cosmetic:
under the swift-testing runner these suites previously registered **"0 tests in
0 suites"** (XCTest is invisible to the swift-testing harness), providing no
effective coverage. They now register **101 tests**.

Per-type peer coverage was then completed for the three source types
(`AuditGate`, `RowStateAutomaton`, `Verbs`): `AuditGate` already had its peer
suite; two new suites — `RowStateAutomatonTests` (9) and `VerbsTests` (12) —
were authored to mirror the Rust `#[test]` behavior set. Swift/Rust parity is
confirmed across all three types.

Final state: **swift test exit 0, 122 tests in 12 suites, 0 warnings**;
**cargo test exit 0, 35 source-module tests, 0 warnings**. **No production
source modified** (Sources/**, rust/**, docs/validation/**, Package.swift all
untouched).

## What Was Done

- **Part 1 — convert XCTest → swift-testing** — `86b5284`
  (`test(substratelib): convert XCTest suites to swift-testing (assertions preserved)`)
  - 10 files converted, 101 assertions preserved 1:1:
    AuditGateTests (17), BitFieldTests (14), CountVector256Tests (13),
    SubstrateLibTests (10), SHA256Tests (5), SharedFamilyTests (5),
    HammingTopKTieBreakTests (4), WireFormatConformanceTests (28),
    SubstrateLibConformanceTests (2), BitmapFieldConstantsConformanceTests (3).
  - Translation map: `final class … : XCTestCase` → `@Suite struct`;
    `func testX()` → `@Test func testX()`; `XCTAssertEqual(a,b)` → `#expect(a == b)`;
    `XCTAssertTrue/False` → `#expect(x)` / `#expect(!x)`; `XCTAssertNil` →
    `#expect(x == nil)`; `XCTAssertLessThan` → `#expect(a < b)`;
    `XCTAssertEqual(_,_,accuracy:)` → `#expect(abs(a-b) <= tol)`;
    `XCTFail` / `guard case … else { return XCTFail(…) }` →
    `Issue.record(…)` / `… else { Issue.record(…); return }` (early-exit
    semantics preserved). `throws` tests stay `@Test func … throws`.
  - Zero `import XCTest` remains anywhere in the package.
- **Part 2 — per-type coverage** — `e79941e`
  (`test(substratelib): per-type coverage for AuditGate/RowStateAutomaton/Verbs (Swift)`)
  - `RowStateAutomatonTests.swift` (new, 9 tests): transition table
    (pending→active via observe, active stay-active via mutate, decayed revive
    via observe), `validate` rejecting illegal transitions, S-1 (accepted
    requires canonical trust), S-3 (accepted cannot tombstone — absence from
    table), S-5 defused (tombstone preserves bitmaps), I-22 (secret cannot be
    exportable + its legal complement).
  - `VerbsTests.swift` (new, 12 tests): capture→active, propose→pending,
    capture-without-anchor failure, mutate confirm pending→accepted, mutate
    rejects illegal transition, forbidden secret+public combo at capture,
    expunge tombstones + clears content, double-expunge failure, withdraw +
    re-confirm cycle, recall predicate filter, HLC advancement on audit
    emission, row-ID uniqueness.
- **Part 3 — Swift/Rust parity confirmed** — no code added (parity already
  satisfied after Parts 1–2; confirmation recorded in BRR + below).
- **BRR** — `6d11790`
  (`docs(slibtest): blast radius report for SLIB-TEST-01`)

## Test Verification Log

### Baseline (mission start, commit `b42db96`)
- `swift test` (packages/libs/SubstrateLib): exit 0. XCTest bridge ran **101
  passed**; the **swift-testing runner reported 0 tests in 0 suites** (the
  mission's premise).
- `cargo test` (packages/libs/SubstrateLib/rust): exit 0, **35** source-module
  unittests passed (audit_gate 14 + verbs 12 + row_state 9).

### Final (commit `6d11790`, re-verified by Adams)
- Command: `cd packages/libs/SubstrateLib && swift test`
  - Exit code: **0**
  - Pass count: **122** (101 converted/preserved + 21 net-new)
  - Suites: **12**
  - Tail (verbatim): `Test run with 122 tests in 12 suites passed after 0.190 seconds.`
  - `swift build --build-tests` warnings: **0**
- Command: `cd packages/libs/SubstrateLib/rust && cargo test`
  - Exit code: **0**
  - Pass count (source-module unittests): **35**
  - Tail (verbatim): `test result: ok. 35 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s`
  - `cargo` warnings: **0**

### Swift/Rust parity (Part 3 confirmation)
- **audit_gate**: Rust 14 ↔ Swift AuditGateTests 17 — full coverage + superset
  (Swift adds content-ID-changes-with-payload, value-exceeds-width freeze,
  I-22-via-gate). Cross-leg content-ID vector (`testContentIDSharedVector`)
  asserts the exact hex `eba1f4509f84abe2a472d99fb621334b` the Rust
  `content_id_shared_vector` test asserts — byte-parity pinned.
- **row_state**: Rust 9 ↔ Swift RowStateAutomatonTests 9 — 1:1.
- **verbs**: Rust 12 ↔ Swift VerbsTests 12 — 1:1 (with one documented port
  divergence; see Discoveries).
- Rust source-module total 14+12+9 = **35**, matching `cargo test`.

## Smythe Pre-flight

Verdict: **GREEN — proceed**, no RESCOPE. (Agent `ab1e15694552c8762`.)
- Verified the blast-radius reality: confirmed **no production source** needs
  touching for a pure framework conversion.
- Confirmed the conformance target (`Tests/SubstrateLibConformanceTests/`) is
  in scope (mission "Files You Will Modify" lists `*ConformanceTests.swift`);
  distinct from the off-limits EE `docs/validation/` harness.
- Confirmed `RowStateAutomaton` and `Verbs` had **no** peer suites → CREATE
  both in Part 2.
- **Package.swift no-change cleared:** swift-testing ships with the Swift 6.0
  toolchain; LatticeKit (the real style precedent) declares no swift-testing
  dep; the baseline runner already resolved the framework. No dep added.
- Cautions all honored: guard-case early-exit → `Issue.record; return`;
  `throws` tests; `@testable import` preserved; `import Foundation` retained
  only where UUID / JSON types are used.
- **Stale-claim flag (informational):** the mission Context says the Rust
  crate was "re-homed to rust/src/, glref-* dropped, v1.0." Reality: files are
  still `glref-rust-*.rs` at `rust/` top level, no `rust/src/`. The "35" count
  is nonetheless correct. Rust is reference-only/off-limits, so no action.

## Adams Post-flight

Verdict: **PASS — "Clean. Ship it."** (Agent `a08b21645f775b8fe`.)
- **Blast Radius Verification: PASS** — diff touches exactly 12 test files +
  the BRR doc; all MUST_UPDATE files present, none missing; **zero** bytes
  under `Sources/`, `rust/`, `docs/validation/`, `Package.swift`; Package.swift
  no-change justification verified against the diff; no prohibited patterns
  (legacy/compat/bridge/shim/@available-deprecated/TODO/FIXME — none).
- **Test Execution Verification: PASS (Method B re-run)** — independently
  re-ran `swift test` → exit 0, **122 tests in 12 suites** (matches claim,
  non-zero count confirms the conversion took effect); `cargo test` → exit 0,
  **35** (matches). 
- **Conversion fidelity:** zero XCTest residue; guard-case early-exit idiom
  preserved with `return`; float-accuracy converted to tolerance check (not
  dropped); AuditGate 17/17 method names verbatim — no test deleted/renamed.
- **New-suite correctness:** RowStateAutomatonTests 9 ↔ Rust 9, VerbsTests 12
  ↔ Rust 12; no vacuous/tautological tests; port divergence honestly handled.

### Adams findings resolution

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | INFO | BRR uses "assertions preserved" to mean @Test-method count, not #expect call-site count (e.g. WireFormat: 28 methods, 55 #expect lines). | No action — test-method 1:1 parity confirmed; no coverage lost. Vocabulary note for future BRRs. |

**No CRITICAL. No WARNING.** Hard gate (Adams PASS) satisfied before signal.

## Self-review

- Diff (12 test files + 1 BRR doc; 691 insertions, 336 deletions) matches the
  BRR MUST_UPDATE list exactly. Deletions are the XCTest-form lines replaced
  by swift-testing equivalents — expected for a conversion.
- No bridges, shims, TODOs, deprecations, secrets, or silenced warnings.
- No view code (no system-color/localization concerns).
- Blast Radius Report: `docs/blast_radius/SLIB_TEST_01_BLAST_RADIUS.md`.

## Conditional lifecycle agents — evaluated

- **Simms / Friedlander / Nert — N/A.** Test-only mission; ships no
  user-facing views, behavior, visual, or accessibility surface.
- **Perkins — N/A.** No security surface touched: no schema change, no
  CloudKit, no privacy/FNode fields, no API-key/Keychain/URL-scheme/NL-prompt
  handling. Tests exercise existing pure functions only.
- **Kong — not spawned.** No architectural decision, no primitive-semantics
  change, no locked-decision conflict — pure test conversion.
- **Nagatha docs-repo sync — deferred to post-merge.** Per the operative goal
  directive, this completion report is written directly to `docs/status/` and
  the signal follows.

## Discoveries

- **The conversion was the coverage.** The 101 XCTest assertions compiled and
  "passed" via the XCTest bridge at baseline, but the swift-testing runner —
  what the substrate lane's CI actually counts — saw **0 tests in 0 suites**.
  A green `swift test` at baseline masked zero effective swift-testing
  coverage. Worth flagging for the sibling test legs (sktest, smltest): a
  green run does not imply the runner registered the tests.
- **Port divergence — deterministic row IDs (Rust) vs random UUID (Swift).**
  The Rust `verbs::deterministic_row_ids_across_calls` test pins that identical
  call sequences yield identical `RowId(u128)` values (deterministic newtype).
  The Swift `Substrate.capture` (`Verbs.swift:127`) assigns `UUID()` (random),
  so deterministic row IDs is a **Rust-only port property**, not a Swift
  behavior. The Swift counterpart (`testCaptureRowIdsAreUnique`) asserts row-ID
  **uniqueness** instead — the faithful Swift invariant. Forcing determinism
  would require modifying production source (MUST NOT). Surfaced for the record;
  not a bug.
- **Mission Context staleness (rust/src/).** The Rust crate is NOT re-homed to
  `rust/src/` — files remain `glref-rust-*.rs` at `rust/` top level. The "35
  #[test]" figure is accurate against the source modules. No action (Rust
  off-limits); flagged so future missions don't trust the stale path claim.

## Outstanding (out of scope — not addressed)

- **None blocking.** The deterministic-row-ID divergence (above) is the only
  Swift/Rust behavioral difference; it is a deliberate, documented port
  property, not a defect, and resolving it would require touching MUST-NOT
  production source.
