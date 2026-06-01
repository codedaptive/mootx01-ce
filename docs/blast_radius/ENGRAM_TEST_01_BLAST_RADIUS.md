# Blast Radius Report — ENGRAM-TEST-01 (EngramLib library test leg → swift-testing)

Mission: `docs/missions/inflight/MISSION_ENGRAM_TEST_01.md`
Stream: engramtest · Branch: `stream/en-engramlib-test-leg`
Baseline commit: `b42db96` · Head: (this report = first commit)
Tier: **net-new / test-only** — no production source touched. Converts one
XCTest file to swift-testing and splits per source type. No-cap tier; the
actual footprint is 2 test files.

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **GREEN** (`docs/blast_radius/ENGRAM_TEST_01_PREFLIGHT.md`).
Zero blockers. One documentation inaccuracy noted below (non-blocking).

Baseline test counts (verified, this branch @ `b42db96`):
- Swift `swift test`: exit 0. **XCTest runner: 20 executed, 0 failures.**
  **swift-testing runner: "0 tests in 0 suites"** — the bug this mission fixes.
  1 file imports `XCTest`.
- Rust `cargo test` (in `rust/`): exit 0. **19 passed, 0 failed** (+1 ignored
  doc-test, expected — the `///` example block is `ignore`).

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

The mission table lists 3 files. The real, in-scope blast radius is **2 files
written** — Package.swift resolves to a no-op (see below). Fully accounted for.

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `packages/libs/EngramLib/Tests/EngramLibTests/EngramLibTests.swift` | yes | XCTest → swift-testing; keep only the 19 EngramLib-type methods | MUST_UPDATE |
| `packages/libs/EngramLib/Tests/EngramLibTests/MatchTests.swift` | yes (CREATE) | new swift-testing suite holding the 1 Match-type method (`testMatchOrdering` → Match `Comparable`/sort) | MUST_UPDATE (new) |
| `packages/libs/EngramLib/Package.swift` | yes (conditional) | **no change** — swift-testing is bundled in the Swift 6.3.2 toolchain; `import Testing` resolves with no package dep. Conditional "only if absent" → absent dependency is the toolchain's, so nothing to add. | NOT MODIFIED (conditional no-op) |

## Per-type split (the 20 current methods)

19 EngramLib-type methods stay in `EngramLibTests.swift` (distance ×3,
distances ×2, findNearest ×7, findWithin ×3, union ×3, session ×1). Exactly
**1** Match-type method (`testMatchOrdering`) moves to `MatchTests.swift`.
Total preserved: **20 assertions across 20 @Test functions** (≥ 20 required).

## Parity with the Rust behavior set (19 `#[test]`)

19 of the 20 Swift methods map 1:1 to the 19 Rust tests
(`rust/tests/engram_lib_tests.rs`). The one Swift method with no Rust peer is
`testFindWithinNegativeMax` — Rust `find_within` takes `u32`, so a negative
`maxDistance` is structurally impossible in the Rust leg. This is Swift-only
**additional** coverage, NOT a parity gap. Preserved as-is.

| Rust `#[test]` | Swift `@Test` | Suite |
|---|---|---|
| distance_identical | distanceIdentical | EngramLib |
| distance_inverse | distanceInverse | EngramLib |
| distance_known | distanceKnown | EngramLib |
| distances_empty | distancesEmpty | EngramLib |
| distances_batch_matches_pair | distancesBatchMatchesPair | EngramLib |
| find_nearest_empty | findNearestEmpty | EngramLib |
| find_nearest_k_zero | findNearestKZeroOrNegative | EngramLib |
| find_nearest_k_greater_than_n | findNearestKGreaterThanN | EngramLib |
| find_nearest_ordering | findNearestOrdering | EngramLib |
| find_nearest_tie_break | findNearestTieBreakByIndex | EngramLib |
| find_nearest_one | findNearestSingle | EngramLib |
| find_nearest_one_empty | findNearestSingleEmpty | EngramLib |
| find_within | findWithin | EngramLib |
| find_within_empty | findWithinEmpty | EngramLib |
| union_empty | unionEmpty | EngramLib |
| union_two | unionTwo | EngramLib |
| union_many | unionMany | EngramLib |
| session_matches_stateless | sessionMatchesStateless | EngramLib |
| match_ordering | matchOrdering | **Match** |
| (no peer — u32 makes it impossible) | findWithinNegativeMax | EngramLib (extra) |

## Stated approach (Bilby, per Smythe's pre-flight ask)

1. Convert `EngramLibTests.swift` first: replace `import XCTest` with
   `import Testing`, wrap in `@Suite("EngramLib API") struct EngramLibTests`,
   each method → `@Test` func, `XCTAssertEqual(a,b)` → `#expect(a == b)`,
   `XCTAssertNil(x)` → `#expect(x == nil)`, `XCTAssertTrue(x)` → `#expect(x)`.
   Drop `testMatchOrdering` from this file.
2. Create `MatchTests.swift`: `@Suite("Match ordering") struct MatchTests`
   holding the `matchOrdering` test. Pattern mirrors `LatticeKit/Tests/
   LatticeKitTests/CodeTests.swift`.
3. `Package.swift`: leave unchanged (verified no-op).
4. NOT doing: no production source touched, no new behaviors invented, no
   assertion dropped. `testFindWithinNegativeMax` kept as Swift-only extra.

## Files NOT modified (per mission's MUST NOT list)

- `packages/libs/EngramLib/Sources/**` — released production code. Untouched.
- `packages/libs/EngramLib/rust/**` — Rust behavior reference only. Untouched.
- `docs/validation/**` — off-limits conformance harness. Untouched.
- Any other package. Untouched.

## Documentation inaccuracy surfaced (non-blocking)

Mission Context + Read First say the 19 Rust `#[test]` functions live "in
`lib.rs` + `matchx.rs`" inline. Reality: `src/lib.rs` and `src/matchx.rs`
contain **zero** inline `#[test]`. All 19 live in the integration test file
`rust/tests/engram_lib_tests.rs`. The tests exist and `cargo test` runs them;
only the mission's pointer is off. Recorded for Skippy; not a blocker.

## Test verification (filled at completion)

- `swift test`: exit 0, ≥20 @Test registered under the swift-testing runner.
  To be recorded verbatim.
- `cargo test`: exit 0, 19 passed (unchanged — Rust leg not touched). To be
  recorded.
