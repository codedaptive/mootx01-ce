# Smythe Pre-flight: CK-TEST-01 (TASK-MXC-2026-0031)

## Status
GREEN

## Status details
- Blast radius: verified — 13 source files, 4 XCTest files, 22 `func test` methods, 38 XCTAssert call-sites
- Prior art: none conflicting — ST-TEST-01 precedent clean, LatticeKit reference style confirmed
- Environment: branch `stream/ck-corpuskit-test-leg` at `16c0579` — correct; worktree clean (mission file untracked only)
- Dependencies: satisfied — all Package.swift deps present; testTarget dep chain resolves

---

## Blast-radius reality

| Claim | Reality | Verdict |
|---|---|---|
| 13 source files (Sources/CorpusKit + Sources/CorpusKitProviders) | **13 confirmed** | MATCH |
| 4 XCTest test files | **4 confirmed** | MATCH |
| 22 `func test` methods | **22 confirmed** | MATCH |
| `import XCTest` in all 4 | **All 4 confirmed** | MATCH |
| 0 `import Testing` currently | **Confirmed** | MATCH |
| swift-testing reference style at LatticeKit/Tests/.../CodeTests.swift | **Present and readable** | MATCH |
| Package.swift wiring precedent at SubstrateTypes/Package.swift | **Present** | MATCH |

One precision note: "22 assertions" in the mission conflates `func test` method count (22) with
assertion call-site count (38 XCTAssert calls). Bilby must preserve all **38** assertion call
sites, not merely 22. The 22 figure is test method count; the mission's "preserve all 22
assertions" language is slightly loose. No blocker — just be precise on conversion: every
XCTAssert* call gets a corresponding `#expect`/`#require`.

Assertion breakdown by file:
- BM25Tests: 4 methods, 7 XCTAssert calls
- BundleStoreTests: 9 methods, 17 XCTAssert calls
- ChunkerTests: 3 methods, 6 XCTAssert calls
- ProvidersTests: 6 methods, 8 XCTAssert calls

---

## Rust discrepancy — assessment

**Mission claim:** "Its Rust leg has 0 `#[test]` functions (no Rust test parity to mirror)."

**Reality:** 32 `#[test]` functions across 6 files in `packages/kits/CorpusKit/rust/tests/`:
- `bm25_tests.rs`: 8
- `bundle_store_tests.rs`: 7
- `chunk_tests.rs`: 5
- `chunker_tests.rs`: 5
- `hybrid_recall_tests.rs`: 4
- `tokenizer_tests.rs`: 3

**Verdict: non-blocking mission-context inaccuracy. Swift-only scope holds.**

The mission explicitly scopes Rust out in two places: "packages/kits/CorpusKit/rust/** — out of
scope" (Files You MUST NOT Modify) and "There is NO Rust parity step." The stated *reason* for
that exclusion ("Rust leg has 0 tests") is factually wrong, but the **exclusion itself** is a
deliberate design choice that stands independently. CK-TEST-01 is a Swift test leg conversion
mission. Rust parity is a separate mission scope. The 32 existing Rust tests are not Bilby's
concern here. Note for the mission file author: the context section has a stale claim. Not a
blocker for execution; worth correcting before the mission is merged.

---

## Package.swift determination

**No swift-testing dependency line needed. Package.swift edit: SKIP.**

LatticeKit/Package.swift confirms the pattern: `import Testing` is toolchain-bundled with Swift
6.0+ and requires no explicit package dependency. LatticeKit's `CodeTests.swift` uses
`import Testing` / `@Suite` / `@Test` / `#expect` with zero `swift-testing` entry in its
Package.swift. CorpusKit is on `swift-tools-version:6.0`. Same situation. Bilby's stated
approach is correct: no Package.swift edit.

The mission's conditional instruction ("additive swift-testing dep only if absent") was a
cautionary hedge. Condition is not triggered.

---

## Coverage gap analysis

Source types with no dedicated peer suite:

| Type | Module | Testable surface | Peer suite needed? |
|---|---|---|---|
| `BM25Index` | CorpusKit | Covered by BM25Tests | NO — covered |
| `BundleStore` | CorpusKit | Covered by BundleStoreTests | NO — covered |
| `Chunk` | CorpusKit | `deriveID` covered in BundleStoreTests (content-addressing tests live there) | PARTIAL — `deriveID` is exercised; `ScoredChunk` struct has no dedicated test |
| `Chunker` | CorpusKit | Covered by ChunkerTests | NO — covered |
| `CorpusKit` | CorpusKit | Module-doc file, only `import Foundation/SubstrateTypes/SubstrateML`; no testable surface | SKIP |
| `CorpusKitError` | CorpusKit | 6 enum cases, all `Error/Sendable/Equatable`; testable surface: equality, error conformance | YES — thin suite worth adding |
| `HybridRecall` | CorpusKit | `HybridRecallConfiguration` (init/default values) and `HybridRecall.recall` (async, requires VectorStore + BM25Index + BundleStore) | YES — config defaults; recall integration is heavy but config struct is worth testing |
| `SyncManifest` | CorpusKit | `CorpusKitSync.manifest(zoneIdentifier:)` — returns a `SyncManifest` struct | YES — validate kitID, schemaVersion, table count, conflict policy |
| `Tokenizer` | CorpusKit | Protocol + default `keywordTokens(_:)` impl | YES — default keywordTokens behavior is directly testable |
| `DeterministicTokenizer` | CorpusKitProviders | Covered by ProvidersTests (3 methods) | NO — covered |
| `EmbeddingGemmaProvider` | CorpusKitProviders | Covered via ProvidersTests testEmptyStringReturnsZeroEngramAllProviders | PARTIAL — zero-engram covered; no happy-path test |
| `MiniLMTextProvider` | CorpusKitProviders | Covered by ProvidersTests | NO — covered |
| `MPNetTextProvider` | CorpusKitProviders | Covered by ProvidersTests | NO — covered |

**Net gap list for Part 2 (peer suites to add):**
1. `CorpusKitErrorTests` — error enum equality + conformance (5 min, trivially testable)
2. `HybridRecallTests` — `HybridRecallConfiguration` default values and custom init (config struct
   only; `HybridRecall.recall` requires full VectorStore stub — assess depth at implementation
   time; the config test is a minimum)
3. `SyncManifestTests` — `CorpusKitSync.manifest(zoneIdentifier:)` output validation
4. `TokenizerTests` — `Tokenizer.keywordTokens` default impl via `DeterministicTokenizer`
   (protocol's default extension is the testable surface)
5. `ChunkTests` — `ScoredChunk` struct (init, stored properties) and optionally `Chunk.deriveID`
   disambiguation from BundleStoreTests if Bilby wants a cleaner split

Bilby's stated approach listed: Chunk, HybridRecall, SyncManifest, Tokenizer protocol,
CorpusKitError. That list matches reality. Assessment: **accepted**.

---

## Blockers
None.

---

## Bilby's stated approach

> Part 1: convert the 4 XCTest files in place, framework-only change, preserving all 22
> assertions verbatim in meaning (XCTAssertEqual→#expect(==), XCTAssertTrue→#expect,
> XCTAssertFalse→#expect(!), XCTAssertNotEqual→#expect(!=),
> XCTAssertGreaterThan/LessThan→#expect(>/<), async preserved). Group each file's tests under
> an `@Suite` struct. Part 2: add peer suites for uncovered source types (Chunk, HybridRecall,
> SyncManifest, Tokenizer protocol, CorpusKitError as appropriate — only where there is real
> testable surface). No Package.swift edit expected (toolchain-bundled). No production source
> touched; if a test reveals a real bug, STOP and report.

**Assessment: accepted.** Approach is exact and actionable. One precision note: "preserving all
22 assertions" means preserving all **38** XCTAssert call-sites (the 22 is test method count).
Bilby should target 38 `#expect`/`#require` equivalents post-conversion.

---

## Actions (Bilby proceeds)

1. Convert `BM25Tests.swift`: drop `XCTestCase`, add `@Suite struct BM25Tests`, convert 7
   XCTAssert calls to `#expect`. Methods are `async` — add `@Test` with `async` signature.
2. Convert `BundleStoreTests.swift`: `async throws` methods — use `@Test` with `async throws`.
   17 call-sites. The helper `makeStore()` and `makeChunk()` become private funcs in the Suite
   struct (or remain free funcs). Preserve `@testable import CorpusKit` → NOT needed if
   BundleStore is public (it is); keep `import CorpusKit` as-is. The `@testable` on BM25Tests
   can stay for `BM25Index` internals if needed.
3. Convert `ChunkerTests.swift`: 3 methods, 6 call-sites. `ChunkerTests` uses `@testable import
   CorpusKit` for `Chunker` access — keep it.
4. Convert `ProvidersTests.swift`: 6 methods, 8 call-sites. `testEmptyStringReturnsZeroEngramAllProviders`
   uses a nested `InferenceShouldNotBeCalled` error struct — fine in swift-testing.
5. Verify `swift test` green, non-zero count (>= 22 @Test registrations).
6. Part 2: add `CorpusKitErrorTests`, `HybridRecallTests` (config only), `SyncManifestTests`,
   `TokenizerTests`, optionally `ChunkTests`. One new file per type.
7. Verify `swift test` green; zero `import XCTest` remains; zero warnings.

---

## Observations for Bilby (non-blocking)

- `BundleStoreTests` has `testDeriveIDMatchesCrossLanguageGroundTruth` — this tests byte-exact
  UUID values. These literal string assertions survive conversion identically; `#expect(expr ==
  "literal")` is fine.
- `BundleStoreTests` helper `makeChunk` does NOT pass `id:` explicitly — Chunk's content-
  addressed init is used. `BM25Tests.makeChunk` uses the explicit-id init for reproducible IDs.
  Keep those semantics intact.
- `ProvidersTests` imports `EngramLib` directly for `Engram.zero`. That import is resolved
  transitively through `CorpusKitProviders`. It compiles. Keep the explicit import.
- `HybridRecall.recall` requires a live `VectorStore` — testing this function end-to-end is
  heavyweight. For Part 2, `HybridRecallConfiguration` default values are the minimum viable
  test surface. Full integration test can follow in a later mission.
- `CorpusKitSync.manifest` is a pure function returning a value type. Simple, high-confidence
  test: assert `kitID == "CorpusKit"`, `schemaVersion == 1`, `tables.count == 1`,
  `tables[0].conflictPolicy == .appendOnly`.
