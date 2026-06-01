# Mission QK-TEST-01 — QueueKit library test leg (swift-testing)

## Priority: P1
## Stream: qk
## Branch from: main
## Depends on: None
## Parallel safe with: all other test-leg streams (disjoint packages)

---

## Context

QueueKit ships 8 library source files and builds clean. Its Rust leg has 0 `#[test]` functions
(no Rust test parity to mirror). The Swift test leg is 5 files, 33 XCTest methods
(`import XCTest`), registering as "0 tests in 0 suites" under the swift-testing runner.

This mission is a CONVERSION: convert the 5 existing XCTest files to swift-testing
(`import Testing`/`@Test`/`#expect`/`#require`), preserving EVERY assertion, then cover any
source type lacking a peer suite. There is NO Rust parity step. TEST-ONLY — no production
source modified. Follows the ST-TEST-01 precedent.

The conformance harness at `docs/validation/substrate_math_performance/` (EE-only) is
off-limits and is not coverage.

## Read First

- Types: `packages/kits/QueueKit/Sources/**/*.swift` (8 files).
- Existing tests to CONVERT (read each fully; preserve all assertions): `packages/kits/QueueKit/Tests/**/*.swift` (5 files, 33 methods).
- swift-testing reference style: `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
- swift-testing wiring precedent: `packages/libs/SubstrateTypes/Package.swift`.

## Known Ambiguities

1. QueueKit involves HLC and async queue behavior. Some suites may be timing/ordering
   sensitive; preserve any serialization the existing tests rely on (swift-testing `.serialized`
   trait where XCTest relied on serial execution). Do not change what is asserted.

## Files You Will Modify

| File | Change |
|---|---|
| `packages/kits/QueueKit/Tests/**` (all 5 XCTest files) | convert XCTest -> swift-testing (preserve all 33 assertions) |
| `packages/kits/QueueKit/Tests/**` (new per-type suites) | CREATE for source types lacking peer coverage |
| `packages/kits/QueueKit/Package.swift` | conditional: additive swift-testing dep only if absent |

## Files You MUST NOT Modify

- `packages/kits/QueueKit/Sources/**` — released production code. If a test reveals a real bug, STOP and report.
- `packages/kits/QueueKit/rust/**` — out of scope.
- `docs/validation/**` — off-limits.
- Any other package.

## Implementation Parts

### Part 1 — Convert existing 5 XCTest files
Read each fully. Convert framework, preserving every assertion exactly. Preserve serialization
where ordering-sensitive. No behavior change.
**Commit:** `test(queuekit): convert XCTest suites to swift-testing (assertions preserved)`
→ verify: `cd packages/kits/QueueKit && swift test` green, registers non-zero (>= 33); no `import XCTest` remains.

### Part 2 — Fill per-source-type gaps
Add peer suites for source types lacking coverage.
**Commit:** `test(queuekit): per-type coverage gaps filled (Swift)`
→ verify: `swift test` green; source types have peer coverage; zero warnings.

## Test Requirements

- swift-testing only; zero `import XCTest`.
- All 33 prior assertions preserved.
- No Rust parity step (Rust leg has no tests).
- `swift test` green and registers non-zero; zero warnings.
- No production source modified.

## Test Verification Log
### Baseline: 5 XCTest files, 33 methods, registering 0; Rust #[test] = 0.
### Final: `cd packages/kits/QueueKit && swift test 2>&1 | tail -20` exit 0, @Test count recorded (>= 33), verbatim tail.

## Verification

QueueKit Swift test leg is swift-testing, all 33 prior assertions preserved and running,
source surface covered. Production untouched. Swift leg green.

## Success Criteria

5 suites converted with assertions intact and registering; source covered; Swift leg green;
production untouched.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-qk
