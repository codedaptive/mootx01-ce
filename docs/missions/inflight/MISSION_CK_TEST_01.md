# Mission CK-TEST-01 — CorpusKit library test leg (swift-testing)

## Priority: P1
## Stream: ck
## Branch from: main
## Depends on: None
## Parallel safe with: all other test-leg streams (disjoint packages)

---

## Context

CorpusKit ships 13 library source files and builds clean. Its Rust leg has 0 `#[test]`
functions (no Rust test parity to mirror). The Swift test leg is 4 files, 22 XCTest methods
(`import XCTest`), registering as "0 tests in 0 suites" under the swift-testing runner.

This mission is a CONVERSION: convert the 4 existing XCTest files to swift-testing
(`import Testing`/`@Test`/`#expect`/`#require`), preserving EVERY assertion, then cover any
source type lacking a peer suite. There is NO Rust parity step. TEST-ONLY — no production
source modified. Follows the ST-TEST-01 precedent.

The conformance harness at `docs/validation/substrate_math_performance/` (EE-only) is
off-limits and is not coverage.

## Read First

- Types: `packages/kits/CorpusKit/Sources/**/*.swift` (13 files).
- Existing tests to CONVERT (read each fully; preserve all assertions): `packages/kits/CorpusKit/Tests/**/*.swift` (4 files, 22 methods).
- swift-testing reference style: `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
- swift-testing wiring precedent: `packages/libs/SubstrateTypes/Package.swift`.

## Known Ambiguities

1. CorpusKit consolidated its embed-provider with VectorKit (F11/F13 refactor) and centralizes
   sentence segmentation to EideticLib (F16). Some suites may exercise that integration —
   preserve in place, do not relocate. Do not change what is asserted.

## Files You Will Modify

| File | Change |
|---|---|
| `packages/kits/CorpusKit/Tests/**` (all 4 XCTest files) | convert XCTest -> swift-testing (preserve all 22 assertions) |
| `packages/kits/CorpusKit/Tests/**` (new per-type suites) | CREATE for source types lacking peer coverage |
| `packages/kits/CorpusKit/Package.swift` | conditional: additive swift-testing dep only if absent |

## Files You MUST NOT Modify

- `packages/kits/CorpusKit/Sources/**` — released production code. If a test reveals a real bug, STOP and report.
- `packages/kits/CorpusKit/rust/**` — out of scope.
- `docs/validation/**` — off-limits.
- Any other package.

## Implementation Parts

### Part 1 — Convert existing 4 XCTest files
Read each fully. Convert framework, preserving every assertion exactly. No behavior change.
**Commit:** `test(corpuskit): convert XCTest suites to swift-testing (assertions preserved)`
→ verify: `cd packages/kits/CorpusKit && swift test` green, registers non-zero (>= 22); no `import XCTest` remains.

### Part 2 — Fill per-source-type gaps
Add peer suites for source types lacking coverage.
**Commit:** `test(corpuskit): per-type coverage gaps filled (Swift)`
→ verify: `swift test` green; source types have peer coverage; zero warnings.

## Test Requirements

- swift-testing only; zero `import XCTest`.
- All 22 prior assertions preserved.
- No Rust parity step (Rust leg has no tests).
- `swift test` green and registers non-zero; zero warnings.
- No production source modified.

## Test Verification Log
### Baseline: 4 XCTest files, 22 methods, registering 0; Rust #[test] = 0.
### Final: `cd packages/kits/CorpusKit && swift test 2>&1 | tail -20` exit 0, @Test count recorded (>= 22), verbatim tail.

## Verification

CorpusKit Swift test leg is swift-testing, all 22 prior assertions preserved and running,
source surface covered. Production untouched. Swift leg green.

## Success Criteria

4 suites converted with assertions intact and registering; source covered; Swift leg green;
production untouched.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-ck
