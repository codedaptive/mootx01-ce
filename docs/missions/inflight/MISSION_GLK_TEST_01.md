# Mission GLK-TEST-01 — GeniusLocusKit library test leg (swift-testing, both legs)

## Priority: P1
## Stream: gl
## Branch from: main
## Depends on: None
## Parallel safe with: all other test-leg streams (disjoint packages)

---

## Context

GeniusLocusKit ships 46 library source files and builds clean on both legs. The Rust leg has
13 `#[test]` functions. The Swift test leg is 20 files, 146 XCTest methods (`import XCTest`),
which register as "0 tests in 0 suites" under the swift-testing runner — substantial test
content providing NO effective coverage.

This mission is a CONVERSION: convert the 20 existing XCTest files to swift-testing
(`import Testing`/`@Test`/`#expect`/`#require`), preserving EVERY assertion. Then confirm the
converted suites cover the source surface and mirror the behaviors the 13 Rust `#[test]`
functions assert; add per-type coverage for any source type lacking a peer suite. TEST-ONLY —
no production source modified. Follows the ST-TEST-01 / SLIB-TEST-01 precedent.

The conformance harness at `docs/validation/substrate_math_performance/` (EE-only) is
off-limits and is not coverage.

## Read First

- Types: `packages/kits/GeniusLocusKit/Sources/**/*.swift` (46 files).
- Existing tests to CONVERT (read each fully; preserve all assertions): `packages/kits/GeniusLocusKit/Tests/**/*.swift` (20 files, 146 methods).
- swift-testing reference style: `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
- Rust behavior to mirror: `packages/kits/GeniusLocusKit/rust/src/**/*.rs` inline `#[test]` (13 tests).
- swift-testing wiring precedent: `packages/libs/SubstrateTypes/Package.swift`.

## Known Ambiguities

1. GeniusLocusKit composes substrate kits + nine verbs + Brain/matrix layers. Some test files
   likely exercise sibling-crate types as integration coverage — preserve those in place, do
   not relocate. Test the behavior each file already asserts; do not invent new semantics.
2. Where Rust does not implement a surface (only 13 Rust tests vs 46 source files), assert the
   Swift behavior and mirror Rust only where the `#[test]` exists. Confirm per type.

## Files You Will Modify

| File | Change |
|---|---|
| `packages/kits/GeniusLocusKit/Tests/**` (all 20 XCTest files) | convert XCTest -> swift-testing (preserve all 146 assertions) |
| `packages/kits/GeniusLocusKit/Tests/**` (new per-type suites) | CREATE for source types lacking peer coverage |
| `packages/kits/GeniusLocusKit/Package.swift` | conditional: additive swift-testing dep only if absent |

## Files You MUST NOT Modify

- `packages/kits/GeniusLocusKit/Sources/**` — released production code. If a test reveals a real bug, STOP and report.
- `packages/kits/GeniusLocusKit/rust/**` — behavior reference only.
- `docs/validation/**` — off-limits.
- Any other package.

## Implementation Parts

### Part 1 — Convert existing 20 XCTest files
Read each fully. Convert framework, preserving every assertion exactly. No behavior change.
**Commit:** `test(geniuslocuskit): convert XCTest suites to swift-testing (assertions preserved)`
→ verify: `cd packages/kits/GeniusLocusKit && swift test` green, registers non-zero (>= 146); no `import XCTest` remains.

### Part 2 — Fill per-source-type gaps
Add peer suites for source types lacking coverage. Mirror Rust where it implements; respect
asymmetry (Known Ambiguity 2).
**Commit:** `test(geniuslocuskit): per-type coverage gaps filled (Swift)`
→ verify: `swift test` green; source types have peer coverage.

### Part 3 — Parity, both legs
Confirm Swift suites assert the 13 Rust `#[test]` behaviors where Rust implements; add missing.
**Commit:** `test(geniuslocuskit): Swift/Rust library-test parity confirmed`
→ verify: `swift test` green and `cd rust && cargo test` green (13 expected); zero warnings both legs.

## Test Requirements

- swift-testing only; zero `import XCTest`.
- All 146 prior assertions preserved.
- Parity with Rust behavior set where Rust implements; asymmetry respected.
- `swift test` green and registers non-zero; `cargo test` green (13); zero warnings both legs.
- No production source modified.

## Test Verification Log
### Baseline: 20 XCTest files, 146 methods, registering 0; Rust #[test] = 13 (verify).
### Final: `cd packages/kits/GeniusLocusKit && swift test 2>&1 | tail -20` exit 0, @Test count recorded (>= 146), verbatim tail; `cd rust && cargo test` exit 0, 13 passed.

## Verification

GeniusLocusKit Swift test leg is swift-testing, all 146 prior assertions preserved and
running, source surface covered, parity with Rust where implemented. Production untouched.
Both legs green.

## Success Criteria

20 suites converted with assertions intact and registering; source covered; Swift/Rust parity
(asymmetry respected); both legs green; production untouched.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-gl
