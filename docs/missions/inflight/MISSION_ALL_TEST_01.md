# Mission ALL-TEST-01 — AriaLexiconLib library test leg (swift-testing, both legs)

## Priority: P1
## Stream: alltest
## Branch from: main
## Depends on: None
## Parallel safe with: eidetic-test, engram-test, the substrate test missions (disjoint packages)

---

## Context

AriaLexiconLib ships 5 library source files (Acceptance, AriaLexiconLib, Noun, Adjective,
Verb) and builds clean on both legs. The Rust leg has 9 `#[test]` functions (inline in
`lib.rs`). The Swift library test leg is a single `LexiconTests.swift` with 9 methods using
`import XCTest` — which violates the project standard (swift-testing) and registers as
"0 tests in 0 suites" under the swift-testing runner.

This mission converts the existing XCTest file to swift-testing and adds per-source-type
suites mirroring `Sources/`, asserting the behavior set the Rust `#[test]` functions assert.
TEST-ONLY — no production source modified. Follows the ST-TEST-01 precedent.

The conformance harness at `docs/validation/substrate_math_performance/` (EE-only) is
off-limits and is not coverage.

## Read First

- Types: `packages/libs/AriaLexiconLib/Sources/AriaLexiconLib/*.swift` (Acceptance, AriaLexiconLib, Noun, Adjective, Verb).
- Existing test to convert (preserve assertions): `packages/libs/AriaLexiconLib/Tests/AriaLexiconLibTests/LexiconTests.swift` (XCTest, 9 methods).
- swift-testing reference style: `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
- Rust behavior to mirror: `packages/libs/AriaLexiconLib/rust/src/lib.rs` inline `#[test]` (9 tests).
- swift-testing wiring precedent: `packages/libs/SubstrateTypes/Package.swift`.

## Known Ambiguities

1. Adjective/Verb/Noun may encode axis-value enums (the LocusKit Adjective precedent). Test
   the encoding/identity behavior the Rust tests assert; do not invent semantics not in source.

## Files You Will Modify

| File | Change |
|---|---|
| `packages/libs/AriaLexiconLib/Tests/AriaLexiconLibTests/LexiconTests.swift` | convert XCTest -> swift-testing (preserve 9 assertions) |
| `packages/libs/AriaLexiconLib/Tests/AriaLexiconLibTests/AcceptanceTests.swift` | CREATE if no peer coverage |
| `packages/libs/AriaLexiconLib/Tests/AriaLexiconLibTests/NounTests.swift` | CREATE if no peer coverage |
| `packages/libs/AriaLexiconLib/Tests/AriaLexiconLibTests/AdjectiveTests.swift` | CREATE if no peer coverage |
| `packages/libs/AriaLexiconLib/Tests/AriaLexiconLibTests/VerbTests.swift` | CREATE if no peer coverage |
| `packages/libs/AriaLexiconLib/Package.swift` | conditional: additive swift-testing dep only if absent |

## Files You MUST NOT Modify

- `packages/libs/AriaLexiconLib/Sources/**` — released production code. If a test reveals a real bug, STOP and report.
- `packages/libs/AriaLexiconLib/rust/**` — behavior reference only.
- `docs/validation/**` — off-limits.
- Any other package.

## Implementation Parts

### Part 1 — Convert + per-type suites
Convert LexiconTests to swift-testing preserving all assertions. Author per-type suites for
Acceptance, Noun, Adjective, Verb (and confirm AriaLexiconLib top-level surface) covering the
behaviors the 9 Rust `#[test]` functions assert.
**Commit:** `test(arialexiconlib): swift-testing conversion + per-type suites (Swift)`
→ verify: `cd packages/libs/AriaLexiconLib && swift test` green, registers non-zero; no `import XCTest` remains.

### Part 2 — Parity, both legs
Confirm Swift suites assert the Rust behavior set; add missing. Run both.
**Commit:** `test(arialexiconlib): Swift/Rust library-test parity confirmed`
→ verify: `swift test` green and `cd rust && cargo test` green (9 expected); zero warnings both legs.

## Test Requirements

- swift-testing only; zero `import XCTest`.
- Every `Sources/AriaLexiconLib/` type has peer coverage.
- Prior assertions preserved; parity with Rust behavior set.
- `swift test` green and registers non-zero; `cargo test` green (9); zero warnings both legs.
- No production source modified.

## Test Verification Log
### Baseline: 1 XCTest file, 9 methods, registering 0; Rust #[test] = 9 (verify).
### Final: `cd packages/libs/AriaLexiconLib && swift test 2>&1 | tail -20` exit 0, @Test count recorded (>= 9), verbatim tail; `cd rust && cargo test` exit 0, 9 passed.

## Verification

AriaLexiconLib Swift test leg is swift-testing, prior assertions preserved and running, all
5 types covered, parity with Rust confirmed. Production untouched. Both legs green.

## Success Criteria

LexiconTests converted; all types covered; Swift/Rust parity; both legs green; production untouched.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-alltest
