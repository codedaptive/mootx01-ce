# Mission LK-TEST-01 — LocusKit test-leg finish (swift-testing)

## Priority: P1
## Stream: lk
## Branch from: main
## Depends on: None
## Parallel safe with: all other test-leg streams (disjoint packages)

---

## Context

LocusKit is ALREADY largely on swift-testing — 41 swift-testing files in place, and the Rust
leg has 408 `#[test]` functions already mirrored by those suites. Only 3 XCTest stragglers
remain (`import XCTest`), registering as 0 under the swift-testing runner: SealedBitTests (?),
KGFactTests (?), LocusKitVocabularyTests (?) — 24 methods total across the three.

This is a FINISH mission, not a from-scratch conversion: convert ONLY the 3 remaining XCTest
files to swift-testing, preserving EVERY assertion. The 41 existing swift-testing files and
the 408-test Rust parity are ALREADY DONE — do NOT re-derive parity against 408, do NOT touch
the existing swift-testing suites. TEST-ONLY — no production source modified.

The conformance harness at `docs/validation/substrate_math_performance/` (EE-only) is
off-limits and is not coverage.

## Read First

- The 3 files to CONVERT (read each fully; preserve all assertions):
  - `packages/kits/LocusKit/Tests/LocusKitTests/SealedBitTests.swift`
  - `packages/kits/LocusKit/Tests/LocusKitTests/KGFactTests.swift`
  - `packages/kits/LocusKit/Tests/LocusKitTests/LocusKitVocabularyTests.swift`
- swift-testing reference style — use LocusKit's OWN existing suites: `packages/kits/LocusKit/Tests/LocusKitTests/*.swift` (the 41 already-converted files).
- Types under test: `packages/kits/LocusKit/Sources/**` (SealedBit, KGFact, vocabulary surfaces).

## Known Ambiguities

1. LocusKit Adjective enums are axis-value encodings (withdrawn-finding precedent F12) — test
   the encoding/identity behavior the existing suites and Rust assert; do not invent semantics.

## Files You Will Modify

| File | Change |
|---|---|
| `packages/kits/LocusKit/Tests/LocusKitTests/SealedBitTests.swift` | convert XCTest -> swift-testing (preserve assertions) |
| `packages/kits/LocusKit/Tests/LocusKitTests/KGFactTests.swift` | convert (preserve assertions) |
| `packages/kits/LocusKit/Tests/LocusKitTests/LocusKitVocabularyTests.swift` | convert (preserve assertions) |

## Files You MUST NOT Modify

- `packages/kits/LocusKit/Sources/**` — released production code. If a test reveals a real bug, STOP and report.
- `packages/kits/LocusKit/rust/**` — behavior reference only; parity already complete.
- The 41 existing swift-testing files — already done; do not touch.
- `packages/kits/LocusKit/Package.swift` — swift-testing already wired (41 files prove it); do not modify.
- `docs/validation/**` — off-limits.
- Any other package.

## Implementation Parts

### Part 1 — Convert the 3 stragglers
Read each fully. Convert framework to swift-testing matching LocusKit's existing suite style,
preserving every assertion exactly. No behavior change.
**Commit:** `test(locuskit): convert 3 remaining XCTest stragglers to swift-testing`
→ verify: `cd packages/kits/LocusKit && swift test` green; `grep -rl 'import XCTest' Tests` returns nothing; registered count rose by ~24; `cd rust && cargo test` still green (408 unchanged).

## Test Requirements

- swift-testing only; zero `import XCTest` remaining in LocusKit/Tests.
- All assertions from the 3 files preserved.
- Existing 41 suites and 408 Rust tests untouched and still green.
- `swift test` green; `cargo test` green (408).
- No production source modified.

## Test Verification Log
### Baseline: 3 XCTest stragglers, 24 methods, registering 0; 41 swift-testing files + 408 Rust already green.
### Final: `cd packages/kits/LocusKit && swift test 2>&1 | tail -20` exit 0, registered count up by ~24, verbatim tail; `grep -rl 'import XCTest' Tests` empty; `cd rust && cargo test` exit 0, 408 passed.

## Verification

LocusKit Tests fully on swift-testing — 3 stragglers converted, 41 prior suites intact, Rust
408 unchanged. Production untouched. Both legs green.

## Success Criteria

3 stragglers converted with assertions intact; zero XCTest remains; existing suites and Rust
parity untouched; both legs green; production untouched.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-lk
