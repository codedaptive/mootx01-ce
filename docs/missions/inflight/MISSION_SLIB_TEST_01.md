# Mission SLIB-TEST-01 — SubstrateLib library test leg (swift-testing, both legs)

## Priority: P1
## Stream: slibtest
## Branch from: main
## Depends on: None
## Parallel safe with: sktest, smltest (disjoint packages)

---

## Context

SubstrateLib ships 3 Swift source files (`AuditGate.swift`, `RowStateAutomaton.swift`,
`Verbs.swift`) and a Rust crate (recently re-homed: modules now in `rust/src/`, glref-*
names dropped, v1.0). The Rust leg has 35 `#[test]` functions. Unlike the other substrate
packages, SubstrateLib already has SUBSTANTIAL Swift test CONTENT — 7 test files,
68 XCTest methods (AuditGateTests 17, BitFieldTests 14, CountVector256Tests 13,
SubstrateLibTests 10, SHA256Tests 5, SharedFamilyTests 5, HammingTopKTieBreakTests 4) —
but they all use `import XCTest`, so they register as "0 tests in 0 suites" under the
swift-testing runner and provide NO effective coverage.

This mission is primarily a CONVERSION, not authoring-from-scratch: convert the 7 existing
XCTest files to swift-testing (`import Testing`/`@Test`/`#expect`), preserving every
assertion. Then verify the converted suites cover the 3 source types + the behaviors the
Rust leg asserts; add any missing per-type coverage. TEST-ONLY — no production source
modified. Follows the ST-TEST-01 pattern.

NOTE on test scope: several existing test files (BitFieldTests, SHA256Tests,
CountVector256Tests) appear to test types that live in sibling crates (SubstrateKernel,
SubstrateTypes) — they may be conformance/integration tests exercised through SubstrateLib.
Preserve them as-is in intent during conversion; do NOT delete coverage. If a test targets
a type now owned by another package, keep it (it is integration coverage), just convert the
framework.

The conformance harness at `docs/validation/substrate_math_performance/` (EE-only) is
off-limits and is not coverage.

## Read First

- Source: `packages/libs/SubstrateLib/Sources/SubstrateLib/{AuditGate,RowStateAutomaton,Verbs}.swift`.
- Existing tests to CONVERT (read each fully; preserve all assertions): `packages/libs/SubstrateLib/Tests/SubstrateLibTests/*.swift` — AuditGateTests, BitFieldTests, CountVector256Tests, HammingTopKTieBreakTests, SHA256Tests, SharedFamilyTests, SubstrateLibTests, plus any conformance files (WireFormatConformanceTests, SubstrateLibConformanceTests, BitmapFieldConstantsConformanceTests if present).
- swift-testing reference style: `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
- Rust behavior to mirror: `packages/libs/SubstrateLib/rust/src/*.rs` inline `#[test]` (35 tests).
- swift-testing wiring precedent: `packages/libs/SubstrateTypes/Package.swift`.

## Known Ambiguities

1. Cross-crate test ownership. Some existing test files name types from sibling crates
   (BitField, SHA256, CountVector256). Treat these as integration/conformance coverage
   reached through SubstrateLib — convert framework, preserve intent, do not relocate or
   delete. Confirm by reading each file before converting.

## Files You Will Modify

| File | Change |
|---|---|
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/AuditGateTests.swift` | convert XCTest -> swift-testing (preserve 17 assertions) |
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/BitFieldTests.swift` | convert (preserve 14) |
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/CountVector256Tests.swift` | convert (preserve 13) |
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/SubstrateLibTests.swift` | convert (preserve 10) |
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/SHA256Tests.swift` | convert (preserve 5) |
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/SharedFamilyTests.swift` | convert (preserve 5) |
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/HammingTopKTieBreakTests.swift` | convert (preserve 4) |
| any `*ConformanceTests.swift` present | convert framework, preserve assertions |
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/RowStateAutomatonTests.swift` | CREATE if no peer suite exists for RowStateAutomaton |
| `packages/libs/SubstrateLib/Tests/SubstrateLibTests/VerbsTests.swift` | CREATE if no peer suite exists for Verbs |
| `packages/libs/SubstrateLib/Package.swift` | conditional: additive swift-testing dep only if absent |

## Files You MUST NOT Modify

- `packages/libs/SubstrateLib/Sources/**` — released production code. If a test reveals a real bug, STOP and report.
- `packages/libs/SubstrateLib/rust/**` — complete; behavior reference only.
- `docs/validation/**` — off-limits.
- Any other package.

## Implementation Parts

### Part 1 — Convert existing XCTest -> swift-testing
Read each existing test file fully. Convert framework, preserving every assertion exactly
(XCTAssertEqual -> #expect(==), XCTAssertTrue -> #expect, XCTUnwrap -> #require, etc.).
No behavior change — pure framework conversion.
**Commit:** `test(substratelib): convert XCTest suites to swift-testing (assertions preserved)`
→ verify: `cd packages/libs/SubstrateLib && swift test` green and the converted suites now REGISTER (non-zero @Test count); no `import XCTest` remains.

### Part 2 — Fill per-source-type gaps
Ensure AuditGate, RowStateAutomaton, and Verbs each have peer coverage asserting their Rust
counterpart's behavior set. Add suites/assertions where missing.
**Commit:** `test(substratelib): per-type coverage for AuditGate/RowStateAutomaton/Verbs (Swift)`
→ verify: `swift test` green; the 3 source types covered.

### Part 3 — Parity, both legs
Confirm Swift suites assert the behavior set the Rust `#[test]` modules assert; add missing.
Run both legs.
**Commit:** `test(substratelib): Swift/Rust library-test parity confirmed`
→ verify: `swift test` green and `cd rust && cargo test` green (35 expected); zero warnings both legs.

## Test Requirements

- swift-testing only; zero `import XCTest` in the package.
- All previously-existing assertions preserved (no coverage lost in conversion).
- AuditGate, RowStateAutomaton, Verbs each have peer coverage.
- `swift test` green and registers non-zero tests; `cargo test` green (35); zero warnings both legs.
- No production source modified.

## Test Verification Log
### Baseline: 7 XCTest files, 68 methods, registering 0 under swift-testing runner; Rust #[test] = 35 (verify).
### Final: `cd packages/libs/SubstrateLib && swift test 2>&1 | tail -20` exit 0, @Test count recorded (must be >= 68), verbatim tail; `cd rust && cargo test` exit 0, 35 passed.

## Verification

SubstrateLib's Swift test leg is swift-testing, all prior assertions preserved and now
running, the 3 source types covered, parity with Rust confirmed. No production source
changed. Both legs green. Harness untouched.

## Success Criteria

All 7 existing suites converted with assertions intact and registering; the 3 source types
covered; Swift/Rust parity; both legs green; production untouched.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-slibtest
