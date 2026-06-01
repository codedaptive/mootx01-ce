# Smythe Pre-flight: ENGRAM-TEST-01

## Status

GREEN — terrain clear. One mission-prose inaccuracy noted (doc nit, not a blocker). Package.swift
change resolves to a no-op. Proceed.

---

## Status details

- **Blast radius:** 3 files declared. Reality is 3 files. No undeclared call sites, no symbol
  collisions, no cross-package entanglement. Blast radius matches claim exactly.
- **Prior art:** No conflicting prior art. No parallel branch touches EngramLib. One remote branch
  exists: `stream/en-engramlib-test-leg` (this branch). No other engram-related branch. Clean.
- **Environment:** Branch `stream/en-engramlib-test-leg` active. Baseline confirmed — Bob's capture
  verified: `swift test` exit 0, 20 XCTest methods pass, swift-testing runner reports 0 tests in
  0 suites. `cargo test` exit 0, 19 passed, 0 failed (+ 1 ignored doc-test). Both legs green.
  Toolchain: Swift 6.3.2 / swiftlang-6.3.2.1.108. swift-testing bundled (no external dep needed).
- **Dependencies:** None listed. Mission declares parallel-safe with alltest, eidetictest, substrate
  test missions. Confirmed — disjoint packages, no shared files.

---

## Blockers

None.

---

## Verified findings

### 1. Swift test file — confirmed 20 methods, all XCTest

`packages/libs/EngramLib/Tests/EngramLibTests/EngramLibTests.swift`: `import XCTest`,
`final class EngramLibTests: XCTestCase`, 20 `func test*` methods. Confirmed.

Method list (20 total):

- `testDistanceIdentical`
- `testDistanceInverse`
- `testDistanceKnown`
- `testDistancesEmpty`
- `testDistancesBatchMatchesPair`
- `testFindNearestEmpty`
- `testFindNearestKZeroOrNegative`
- `testFindNearestKGreaterThanN`
- `testFindNearestOrdering`
- `testFindNearestTieBreakByIndex`
- `testFindNearestSingle`
- `testFindNearestSingleEmpty`
- `testFindWithin`
- `testFindWithinEmpty`
- `testFindWithinNegativeMax` — Swift-only additional coverage (no Rust peer; see §5 below)
- `testUnionEmpty`
- `testUnionTwo`
- `testUnionMany`
- `testSessionMatchesStateless`
- `testMatchOrdering` — Match-type; goes to MatchTests.swift

Per-type split: 19 EngramLib-type (stays in EngramLibTests.swift); 1 Match-type
(`testMatchOrdering` → MatchTests.swift). Split is exact.

---

### 2. Rust test location — MISSION PROSE INACCURACY (doc nit, not a blocker)

**Mission Context says:** "The Rust leg has 19 `#[test]` functions (in `lib.rs` + `matchx.rs`)."

**Mission Read First says:** "Rust behavior to mirror: `packages/libs/EngramLib/rust/src/{lib,matchx}.rs` inline `#[test]` (19 tests)."

**Reality:** Zero inline `#[test]` functions in `rust/src/lib.rs`. Zero in `rust/src/matchx.rs`.
All 19 `#[test]` functions live in `rust/tests/engram_lib_tests.rs` (Rust integration tests).

This is a doc inaccuracy in the mission prose — it does not affect Bilby's work. The 19 tests
exist, `cargo test` runs them, all pass. Bilby reads `engram_lib_tests.rs` for the Rust behavior
reference, not the src files. No blocker.

Rust test inventory (`engram_lib_tests.rs`, 19 `#[test]` functions):

| # | Rust fn | Swift peer |
|---|---|---|
| 1 | `distance_identical` | `testDistanceIdentical` |
| 2 | `distance_inverse` | `testDistanceInverse` |
| 3 | `distance_known` | `testDistanceKnown` |
| 4 | `distances_empty` | `testDistancesEmpty` |
| 5 | `distances_batch_matches_pair` | `testDistancesBatchMatchesPair` |
| 6 | `find_nearest_empty` | `testFindNearestEmpty` |
| 7 | `find_nearest_k_zero` | `testFindNearestKZeroOrNegative` (covers both 0 and -1) |
| 8 | `find_nearest_k_greater_than_n` | `testFindNearestKGreaterThanN` |
| 9 | `find_nearest_ordering` | `testFindNearestOrdering` |
| 10 | `find_nearest_tie_break` | `testFindNearestTieBreakByIndex` |
| 11 | `find_nearest_one` | `testFindNearestSingle` |
| 12 | `find_nearest_one_empty` | `testFindNearestSingleEmpty` |
| 13 | `find_within` | `testFindWithin` |
| 14 | `find_within_empty` | `testFindWithinEmpty` |
| 15 | `union_empty` | `testUnionEmpty` |
| 16 | `union_two` | `testUnionTwo` |
| 17 | `union_many` | `testUnionMany` |
| 18 | `session_matches_stateless` | `testSessionMatchesStateless` |
| 19 | `match_ordering` | `testMatchOrdering` |

Parity: 19 Rust tests, 19 Swift peers (full coverage). One additional Swift-only test noted in §5.

---

### 3. swift-testing wiring — Package.swift change is a no-op

Swift 6.3.2 bundles swift-testing. `import Testing` works without a package dependency.

Confirmed by precedent: `packages/kits/LatticeKit/Package.swift` — no swift-testing entry in
`dependencies:` or in the `testTarget` dependencies list. Multiple test files (`CodeTests.swift`,
`CanonAndChannelsTests.swift`, etc.) use `import Testing` and pass. Same pattern for
`packages/libs/SubstrateTypes/Package.swift` — no swift-testing dep declared; tests use
`import Testing` cleanly.

Mission clause "conditional: additive swift-testing dep only if absent" — the dep is absent AND
not needed. Resolution: **no-op**. Bilby reads `Package.swift`, confirms no existing
swift-testing dep, makes no change. Part 2 of the mission file table row is a non-event.

---

### 4. testFindWithinNegativeMax — additional Swift coverage, not a parity gap

Swift has `testFindWithinNegativeMax` (passes `maxDistance: -1`, asserts empty result). No Rust
peer in `engram_lib_tests.rs`. This is appropriate: the Rust `find_within` takes `max_distance:
u32` (unsigned — a negative value cannot be passed). The Swift API takes `Int` and must handle
the negative case explicitly. Additional coverage, not a gap. Bilby preserves the assertion.

---

### 5. Prior-art conflicts — none

No parallel stream touches EngramLib files. `git branch -a` shows one branch:
`stream/en-engramlib-test-leg`. No undeclared test files exist in
`packages/libs/EngramLib/Tests/EngramLibTests/` beyond `EngramLibTests.swift`.

---

## Bilby's stated approach

*[To be written by Bilby before proceeding. 2-4 sentences: which files first, which pattern,
what is NOT being done.]*

**Assessment:** Pending Bilby's statement.

---

## Actions (proceeding)

1. Read `rust/tests/engram_lib_tests.rs` as the Rust behavior reference — NOT `src/lib.rs` or
   `src/matchx.rs` (the mission prose is wrong on location; the file is correct).
2. Convert `EngramLibTests.swift`: replace `import XCTest` with `import Testing`, replace
   `XCTestCase` subclass with a `@Suite` struct, replace all `XCTAssert*` with `#expect`.
   Retain the 19 EngramLib-type test methods. Remove `testMatchOrdering`.
3. CREATE `MatchTests.swift`: `import Testing`, `@testable import EngramLib`, `@Suite` struct,
   one `@Test` for `testMatchOrdering`. Port assertions from the XCTest original.
4. `Package.swift`: read, confirm no swift-testing dep, make no change. Non-event.
5. Run `swift test` from `packages/libs/EngramLib/`. Verify: exit 0; swift-testing runner reports
   >= 20 @Test functions; zero `import XCTest` lines remain; zero warnings.
6. Run `cargo test` from `packages/libs/EngramLib/rust/`. Verify: exit 0; 19 passed; 0 failed.
7. Record both tails verbatim in the mission's Test Verification Log.

---

## Decision needed

None. Path is clear.

---

## Baseline test counts

| Suite | Count | Status |
|---|---|---|
| Swift `swift test` | 20 XCTest methods pass; 0 swift-testing (the bug) | GREEN baseline |
| Rust `cargo test` | 19 passed, 0 failed | GREEN |

Record these before Part 1. After Part 1 the swift-testing runner must report >= 20 @Test
functions.
