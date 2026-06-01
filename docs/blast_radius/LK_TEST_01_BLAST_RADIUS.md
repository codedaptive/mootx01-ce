# Blast Radius Report — LK-TEST-01 (LocusKit test leg finish → swift-testing)

Mission: `docs/missions/inflight/MISSION_LK_TEST_01.md`
Stream: lk · Branch: `stream/lk-locuskit-test-finish`
Baseline commit: `16c0579` · Head: (this report = first commit)
Tier: **finish / test-only** — no production source touched. Converts the 3
remaining XCTest straggler files to swift-testing, preserving every assertion.
No-cap tier; the actual footprint is 3 test files.

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **GREEN** (`docs/blast_radius/LK_TEST_01_PREFLIGHT.md`).
Zero blockers. No documentation inaccuracies surfaced for this mission.

Baseline counts (verified, this branch @ `16c0579`):
- `grep -rl 'import XCTest' Tests` → exactly **3 files**: SealedBitTests,
  KGFactTests, LocusKitVocabularyTests. No more, no fewer.
- `grep -l 'import Testing' Tests` → **41 files** already on swift-testing.
- Straggler method count: KGFactTests 18 + SealedBitTests 4 +
  LocusKitVocabularyTests 2 = **24** methods — matches mission claim. These
  register **0** under the swift-testing runner today (the bug this fixes).
- Rust leg: `rust/src` inline `#[test]` = **408** (verified). NOTE: a
  whole-`rust/`-subtree grep returns 442 — it over-counts by including the
  `rust/tests/` conformance + in-memory harnesses. Per the established
  test-leg-validation rule, parity is counted against `rust/src` inline only.
  The Rust leg is NOT touched by this mission.

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

The mission table lists 3 files. The real, in-scope blast radius is **exactly
3 files written**. Fully accounted for.

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `packages/kits/LocusKit/Tests/LocusKitTests/SealedBitTests.swift` | yes | XCTest → swift-testing; 4 tests, all `#expect` replacements; preserve substrate-math guard banner | MUST_UPDATE |
| `packages/kits/LocusKit/Tests/LocusKitTests/KGFactTests.swift` | yes | XCTest → swift-testing; 18 tests; keep `throws` on the codable round-trip test | MUST_UPDATE |
| `packages/kits/LocusKit/Tests/LocusKitTests/LocusKitVocabularyTests.swift` | yes | XCTest → swift-testing; 2 tests; guard-else `XCTFail` → `Issue.record(...); return`; preserve substrate-math guard banner | MUST_UPDATE |

## Symbol-level blast radius (every symbol the mission changes)

The only symbols changed are the 3 test type declarations themselves:
`SealedBitTests`, `KGFactTests`, `LocusKitVocabularyTests` change from
`final class X: XCTestCase` to `@Suite struct X`.

- Grep for external references to these 3 type names across all `*.swift`
  (Sources, Tests, other packages): **NONE** outside their own files. Test
  type names are never imported or referenced elsewhere — no call sites to
  update.
- Grep for `XCTestCase` in `LocusKit/Sources`: **NONE** — production code does
  not reference XCTest in any form.
- No production symbol (SealedBit/BitField, KGFact + its operational enums,
  LocusKitVocabulary) is modified — they are only *read* by the tests, exactly
  as before. Assertions and the values they read are preserved 1:1.

Classification of every hit: the 3 type renames are **MUST_UPDATE** (done
in-file); all other surfaces are **INTENTIONALLY_LEFT** (no reference exists).
Zero **RESCOPE_REQUIRED** items.

## Stated approach (Bilby, per Smythe's pre-flight ask)

Mechanical framework conversion, each file in isolation, assertions verbatim:
1. `import XCTest` → `import Testing`. All other imports preserved as-is
   (SubstrateTypes, SubstrateKernel, SubstrateLib, `@testable import LocusKit`).
2. `final class X: XCTestCase` → `@Suite("X") struct X`.
3. each `func testY()` → `@Test func testY()` (keep `throws` where present).
4. `XCTAssertTrue(a)` → `#expect(a)`; `XCTAssertFalse(a)` → `#expect(!a)`;
   `XCTAssertEqual(a,b)` → `#expect(a == b)`; `XCTAssertNil(x)` →
   `#expect(x == nil)`; `XCTAssertNotNil(x)` → `#expect(x != nil)`. Message
   arguments preserved verbatim as the `#expect` comment.
5. `KGFactTests.test_codableRoundTrip_preservesAllFields()` keeps `throws`;
   `try encoder.encode` / `try decoder.decode` unchanged.
6. `LocusKitVocabularyTests.testVocabularyFreezesClean`: the
   `guard case .success = ... else { return XCTFail("...") }` becomes
   `guard case .success = ... else { Issue.record("..."); return }`.
7. NOT doing: no production source touched, no Rust touched, no Package.swift
   touched, no new behaviors invented, no assertion dropped, the 41 existing
   suites untouched.

## Files NOT modified (per mission's MUST NOT list)

- `packages/kits/LocusKit/Sources/**` — released production code. Untouched.
- `packages/kits/LocusKit/rust/**` — Rust behavior reference only (408 inline).
  Untouched.
- The 41 existing swift-testing suites. Untouched.
- `packages/kits/LocusKit/Package.swift` — swift-testing already wired
  (41 suites prove it; `Testing` is bundled in the toolchain). Untouched.
- `docs/validation/**` — off-limits conformance harness. Untouched.
- Any other package. Untouched.

## Test verification (filled at completion)

- `cd packages/kits/LocusKit && swift test`: exit 0, registered count up by
  ~24 vs baseline. Verbatim tail recorded in the completion report.
- `grep -rl 'import XCTest' Tests` → empty.
- `cd packages/kits/LocusKit/rust && cargo test`: exit 0, 408 passed
  (unchanged — Rust leg not touched).
