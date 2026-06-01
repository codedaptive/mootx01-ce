# Mission ENGRAM-TEST-01 — EngramLib library test leg (swift-testing, both legs)

## Priority: P1
## Stream: engramtest
## Branch from: main
## Depends on: None
## Parallel safe with: alltest, eidetictest, the substrate test missions (disjoint packages)

---

## Context

EngramLib ships 2 library source files (EngramLib, Match) and builds clean on both legs. The
Rust leg has 19 `#[test]` functions (in `lib.rs` + `matchx.rs`). The Swift library test leg
is a single `EngramLibTests.swift` with 20 methods using `import XCTest` — which violates the
project standard (swift-testing) and registers as "0 tests in 0 suites" under the
swift-testing runner.

This mission converts the existing XCTest file to swift-testing, splitting per source type
(EngramLib, Match), preserving every assertion, and confirms parity with the 19 Rust tests.
TEST-ONLY — no production source modified. Follows the ST-TEST-01 precedent.

The conformance harness at `docs/validation/substrate_math_performance/` (EE-only) is
off-limits and is not coverage.

## Read First

- Types: `packages/libs/EngramLib/Sources/EngramLib/{EngramLib,Match}.swift`.
- Existing test to convert (preserve all 20 assertions): `packages/libs/EngramLib/Tests/EngramLibTests/EngramLibTests.swift` (XCTest).
- swift-testing reference style: `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
- Rust behavior to mirror: `packages/libs/EngramLib/rust/src/{lib,matchx}.rs` inline `#[test]` (19 tests).
- swift-testing wiring precedent: `packages/libs/SubstrateTypes/Package.swift`.

## Known Ambiguities

1. `Engram` is a typealias over a fingerprint type (possible Fingerprint512 widening noted in
   spec). Test the stability contract the Rust tests assert; do not assume a widening not in source.

## Files You Will Modify

| File | Change |
|---|---|
| `packages/libs/EngramLib/Tests/EngramLibTests/EngramLibTests.swift` | convert XCTest -> swift-testing (preserve EngramLib-type assertions) |
| `packages/libs/EngramLib/Tests/EngramLibTests/MatchTests.swift` | CREATE (split out Match-type coverage; preserve any Match assertions from the original 20) |
| `packages/libs/EngramLib/Package.swift` | conditional: additive swift-testing dep only if absent |

## Files You MUST NOT Modify

- `packages/libs/EngramLib/Sources/**` — released production code. If a test reveals a real bug, STOP and report.
- `packages/libs/EngramLib/rust/**` — behavior reference only.
- `docs/validation/**` — off-limits.
- Any other package.

## Implementation Parts

### Part 1 — Convert + split per type
Convert EngramLibTests to swift-testing preserving all 20 assertions; split Match-type
assertions into MatchTests. Cover the behaviors the 19 Rust `#[test]` functions assert.
**Commit:** `test(engramlib): swift-testing conversion + per-type split (Swift)`
→ verify: `cd packages/libs/EngramLib && swift test` green, registers non-zero (>= 20); no `import XCTest` remains.

### Part 2 — Parity, both legs
Confirm Swift suites assert the Rust behavior set; add missing. Run both.
**Commit:** `test(engramlib): Swift/Rust library-test parity confirmed`
→ verify: `swift test` green and `cd rust && cargo test` green (19 expected); zero warnings both legs.

## Test Requirements

- swift-testing only; zero `import XCTest`.
- Both source types (EngramLib, Match) have peer coverage.
- Prior assertions preserved; parity with Rust behavior set.
- `swift test` green and registers non-zero; `cargo test` green (19); zero warnings both legs.
- No production source modified.

## Test Verification Log
### Baseline: 1 XCTest file, 20 methods, registering 0; Rust #[test] = 19 (verify).
### Final: `cd packages/libs/EngramLib && swift test 2>&1 | tail -20` exit 0, @Test count recorded (>= 20), verbatim tail; `cd rust && cargo test` exit 0, 19 passed.

## Verification

EngramLib Swift test leg is swift-testing, prior assertions preserved and running, both types
covered, parity with Rust confirmed. Production untouched. Both legs green.

## Success Criteria

EngramLibTests converted + split; both types covered; Swift/Rust parity; both legs green; production untouched.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-engramtest
