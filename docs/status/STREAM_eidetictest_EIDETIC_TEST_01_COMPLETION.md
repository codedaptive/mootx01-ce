# COMPLETION: EIDETIC-TEST-01 — EideticLib library test leg (swift-testing, both legs)

**Status: COMPLETE**
Stream: eidetictest · Branch: `stream/ei-eideticlib-test-leg`
Baseline: `b42db96` (main HEAD) · Head: `e8706a9`
Mission: `docs/missions/inflight/MISSION_EIDETIC_TEST_01.md`
Date: 2026-05-31

---

## Summary

EideticLib's Swift test leg is now swift-testing throughout. The 11 existing
test files used `import XCTest`, so they registered as **0 tests in 0 suites**
under the swift-testing runner and provided no effective coverage. All 11 are
converted to swift-testing (`import Testing` / `@Suite` / `@Test` / `#expect` /
`#require`) with **every assertion preserved**. Per-type peer suites were added
for the source types that lacked one, and the Swift suites were checked against
the Rust leg's `#[test]` behavior set, with the documented Swift/Rust asymmetry
respected (not silently narrowed).

- **swift test: 110 tests in 19 suites, exit 0, zero warnings** (baseline under
  the swift-testing runner was 0/0).
- **cargo test: 45 inline `#[test]` passed, exit 0, zero warnings** (+7+3
  doc/integration tests, all green).
- **No production source modified.** Diff is entirely within
  `packages/libs/EideticLib/Tests/EideticLibTests/`. `Sources/**`, `rust/**`,
  `Package.swift`, `docs/validation/**`, and every other package are untouched.
- **No Package.swift change required** — swift-testing is implicit in
  swift-tools-version 6.0 (confirmed against LatticeKit and SubstrateTypes,
  neither of which declares an explicit dep).

## What Was Done

- **Part 1 — convert 11 XCTest suites to swift-testing** — `1478951`
  (`test(eideticlib): convert XCTest suites to swift-testing (assertions preserved)`)
  - All 11 files converted: `final class …: XCTestCase` → `@Suite struct`;
    `func testFoo()` → `@Test("…") func foo()`; `XCTAssertEqual(a,b)` →
    `#expect(a == b)`; `XCTAssertTrue/False` → `#expect(…)`/`#expect(!…)`;
    `XCTAssertNil/NotNil` → `#expect(… == nil)`/`#expect(… != nil)`;
    `try XCTUnwrap` → `try #require`; `XCTFail("…")` → `Issue.record("…")`.
  - Multi-class files split one `@Suite struct` per former XCTestCase:
    `LatticeLookupTests.swift` → `MDCCLookupTests` (6) + `LicensingBoundaryTests` (1);
    `WordClassTaggerTests.swift` → `WordClassSharedVectorTests` (7) +
    `WordClassMinOSGateTests` (3) + `NovelTokenCacheTests` (2).
  - `XCTestCase.addTeardownBlock` (no swift-testing equivalent) replaced with
    `defer`-based cleanup: `makeWorkPaths()` now returns the work `root` and
    each test defers `removeItem(at: root)`.
  - Precedence fix during conversion: `XCTAssertEqual(contents?.count ?? 0, 0)`
    → `#expect((contents?.count ?? 0) == 0)` (parenthesized — `??` binds looser
    than `==`).
  - Runtime-`String` `#expect` messages (the two conformance-failure joins)
    rewritten as string interpolation, since `Comment` accepts a literal/
    interpolation but not a `String + String` expression.
  - Result: 77 tests in 14 suites pass (was 0). Zero `import XCTest` remains.

- **Part 2 — per-source-type coverage gaps filled** — `5ae12ab`
  (`test(eideticlib): per-type coverage gaps filled (Swift)`)
  - New peer suites: `NormalizerTests` (6), `TokenizerTests` (5),
    `WordClassTests` (5), `WordClassTableTests` (5), `LatticeResolverTests` (8).
  - `NovelTokenCache` already has peer coverage (`NovelTokenCacheTests` suite
    inside `WordClassTaggerTests.swift`); **no duplicate file created** (would
    collide). Justified per mission "CREATE if no peer coverage".
  - Result: 106 tests in 19 suites pass.

- **Part 3 — Swift/Rust parity confirmed** — `e8706a9`
  (`test(eideticlib): Swift/Rust library-test parity confirmed`)
  - Added explicit stemmer spot-check tests mirroring `stemmer.rs` so the
    parity set is one-to-one (not only subsumed by the full-corpus gate).
  - Result: 110 tests in 19 suites pass; cargo test 45 passed.

## Coverage — all 16 Sources/EideticLib types have peer coverage

| Source type | Peer suite(s) |
|---|---|
| ConsentGate | ConsentGateTests |
| EideticLib | EideticLibTests, MDCCLookupTests, LicensingBoundaryTests |
| ForeignSourcePipeline | ForeignSourcePipelineTests |
| LatticeCodeState | LatticeCodeStateTests |
| LatticeResolver | LatticeResolverTests *(new)* |
| Normalizer | NormalizerTests *(new)* |
| NovelTokenCache | NovelTokenCacheTests *(in WordClassTaggerTests.swift)* |
| Scheme | SchemeTests |
| Segmenter | SegmenterTests |
| Stemmer | StemmerTests |
| Tokenizer | TokenizerTests *(new)* |
| WikidataResolver | WikidataResolverTests |
| WikidataSubset | WikidataSubsetTests |
| WordClass | WordClassTests *(new)* |
| WordClassTable | WordClassTableTests *(new)* |
| WordClassTagger | WordClassSharedVectorTests, WordClassMinOSGateTests |

## Swift/Rust parity map (Rust = 45 inline `#[test]`)

**Mirrored (same behavior asserted on both legs):**
- `normalizer.rs` 6/6 → NormalizerTests
- `tokenizer.rs` 5/5 → TokenizerTests (Swift `byWords` matches `unicode-segmentation` on the covered vectors — verified green)
- `wikidata_subset.rs` 4/4 → WikidataSubsetTests
- `word_class.rs` 2/2 → WordClassTests (lowercase serialize) + WordClassTableTests (pinned versions, non-empty sets); shared vectors via WordClassSharedVectorTests
- `stemmer.rs` 6/6 → StemmerTests (full Snowball corpus gate + explicit spot checks)
- `anchor.rs` roundtrip → EideticLibTests.anchorRoundTripsThroughJSON
- `lib.rs` version_pinned / lookup_empty_string / lookup_is_deterministic → EideticLibTests

**Documented asymmetry — asserted Swift-side, NOT mirrored (Known Ambiguity 1):**
- `lib.rs` `lookup_returns_not_implemented_stub` + `lookup_carries_stub_data_version`
  and `anchor.rs` `not_implemented_carries_stub_data_version`: the **Rust `lookup`
  returns a `not_implemented()` sentinel** (code "", dataVersion "0.1.0-stub")
  while the **Swift `lookup` is fully implemented** and carries real canon
  answers (code present in canon, dataVersion "v1"). Verified at `rust/src/lib.rs`
  and `rust/src/anchor.rs`. Swift asserts its real behavior directly.
- `wikidata_resolver.rs` (15 tests): the **Rust resolver is the superseded
  UDC-agreement design** — `ResolverDecision { …, udc_agreement }`,
  `resolve(tokens:&[String], code:&str, subset)`, scoring against
  `entry.udc_hint` (depth-1/2/exact prefix → 2/3/4). The **Swift
  `WikidataResolver` is the post-MDCC design** — `resolve(entry: LatticeEntry,
  subset:)`, surfacing the entry's `sourceIdentity` Q-ID and label/alias
  evidence, no `udc_agreement`, no `udc_hint`, no token/code inputs. The two
  legs test genuinely different algorithms; mirroring the UDC machinery into
  Swift is impossible (the fields/API do not exist). Swift's actual resolver is
  covered by WikidataResolverTests. **This is documented asymmetry, not
  scope-narrowing** (verified by Adams against both source files).
- `segmenter.rs`: 0 Rust `#[test]`. Swift SegmenterTests covers the Swift-only
  platform-NL / deterministic-delimiter path (Known Ambiguity 2).

## Test Verification Log

**Baseline:** 11 XCTest files, 77 methods, registering **0 tests in 0 suites**
under the swift-testing runner; Rust inline `#[test]` = 45 (verified).

**Final — Swift (`cd packages/libs/EideticLib && swift test`), exit 0:**
```
􁁛  Test run with 110 tests in 19 suites passed after 0.286 seconds.
```
@Test count: **110** (≥ 77 required). Zero warnings, zero failures.

**Final — Rust (`cd rust && cargo test`), exit 0:**
```
test result: ok. 45 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
```
45 inline tests passed (+7+3 doc/integration tests green). Zero warnings.

## Smythe Pre-flight (verbatim verdict)

**GREEN. Terrain clear. Proceed.**
- Blast radius verified: 11 files exist, all `import XCTest`, method counts
  match exactly (5/6/6/13/7/4/9/4/6/5/12 = 77).
- No Package.swift change needed (swift-testing implicit in tools 6.0;
  confirmed vs LatticeKit + SubstrateTypes).
- CREATE candidates: Normalizer, Tokenizer, LatticeResolver (definite);
  WordClass/WordClassTable (WARNING — Bilby's call; resolved: thin dedicated
  suites added); NovelTokenCache **already covered** — do not create separate
  file (name collision). Rust = 45 confirmed; `segmenter.rs` has 0 tests; no
  `lattice_resolver.rs` tests.
- No blockers, no prior-art conflict, parallel streams disjoint.

## Adams Post-flight (verbatim verdict)

**PASS. Clean. Ship it.**
- Findings: 1 INFO (no BRR filed — expected; test-only diff, no production
  symbols changed). Zero CRITICAL, zero WARNING.
- Scope: diff touches exactly 16 files, all inside `Tests/EideticLibTests/`.
  Sources/rust/Package.swift/docs/validation untouched.
- Zero XCTest: `grep` for `import XCTest|XCTAssert*|XCTFail|XCTUnwrap` → zero.
- Assertion preservation confirmed file-by-file (StemmerTests +4 is additive
  parity, originals intact). Precedence trap parenthesized correctly.
- Test-name-vs-body: no mismatches.
- Coverage: all 16 source types covered; no duplicate/collision on
  NovelTokenCacheTests.
- Parity claims verified real by reading both source legs (not narrowing).
- **Test execution re-run by Adams (Method B):** `swift test` → 110 tests / 19
  suites / exit 0; cargo log spot-check → 45 passed. Matches Bilby's claim.

## Self-Review

- **Mission scope honored:** test-only; no production source touched; off-limits
  conformance harness (`docs/validation/`) not touched.
- **Assertions preserved:** all 77 original assertions converted 1:1; no
  coverage lost. New tests are additive.
- **Known Ambiguities handled:** (1) Rust not_implemented / superseded UDC
  resolver — asserted Swift behavior, did not fabricate parity; (2) platform-
  gated segmenter/tokenizer — tested the deterministic reference path as the
  existing tests / Rust do.
- **MemPalace recurrence checks (from prior ST-TEST-01 diary):** Part 3 commit
  present (the recurrent miss); signal file written (the recurrent miss);
  parity scope NOT silently narrowed (documented explicitly); no
  test-name/body mismatch (the recurrent Adams finding). Worktree kept clean
  (the wormhole-admission gate).
- **Lifecycle:** MemPalace query → mission/skills read → Smythe (GREEN) →
  implement (3 parts, commit each) → both legs green → Adams (PASS, first
  iteration). Conditional agents (Simms/Friedlander/Nert/Perkins) not
  applicable — test-only, no UI, no user-facing behavior, no security surface.

## Discoveries

- The EideticLib **Rust port has not been migrated to the MDCC design**: its
  `wikidata_resolver` (UDC-agreement scoring, `udc_hint`) and `lookup`
  (not_implemented sentinel) lag the Swift leg's post-MDCC_03 implementation.
  The Rust `wikidata_resolver.rs` header still claims "byte-for-byte mirror of
  the Swift port" — that doc comment is stale relative to the code. Flagged
  here as the canonical asymmetry; a future port mission would close it.
- swift-testing's `#expect(_, _ comment:)` second argument is `Comment?`: it
  accepts string literals and interpolations but **not** a runtime
  `String + String` expression. Conversions that concatenate a computed failure
  list must use interpolation.

## Files Changed

16 files, all in `packages/libs/EideticLib/Tests/EideticLibTests/`:
converted (11): ConsentGateTests, EideticLibTests, ForeignSourcePipelineTests,
LatticeCodeStateTests, LatticeLookupTests, SchemeTests, SegmenterTests,
StemmerTests, WikidataResolverTests, WikidataSubsetTests, WordClassTaggerTests.
created (5): NormalizerTests, TokenizerTests, WordClassTests, WordClassTableTests,
LatticeResolverTests.
