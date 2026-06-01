# Blast Radius Report — PK-TEST-01

**Mission:** PersistenceKit library test leg (swift-testing conversion)
**Stream:** pk · **Branch:** `stream/pk-persistencekit-test-leg`
**Type:** TEST-ONLY (no production source modified)
**Date:** 2026-05-31

---

## Scope (what this stream is allowed to touch)

| Path | Disposition |
|---|---|
| `packages/kits/PersistenceKit/Tests/**` | **MODIFY** — convert 14 XCTest files → swift-testing; CREATE new per-type peer suites |
| `packages/kits/PersistenceKit/Package.swift` | **CONDITIONAL** — additive swift-testing dep only if absent (NOT needed: Swift 6.3.2 bundles Testing) |
| `docs/blast_radius/PK_TEST_01_*.md` | **CREATE** — blast radius + Smythe pre-flight |
| `docs/status/STREAM_pk_PK_TEST_01_COMPLETION.md` | **CREATE** — completion report |

## Off-limits (must NOT touch)

- `packages/kits/PersistenceKit/Sources/**` — released production code (38 files). If a test reveals a real bug: STOP and report.
- `packages/kits/PersistenceKit/rust/**` — out of scope (has 22 `#[test]`, NOT 0 as mission prose claims; no parity step regardless).
- `docs/validation/**` — EE-only conformance harness, off-limits, not coverage.
- Any other package.

---

## Baseline (verified @ HEAD)

- **Swift test leg:** 14 files, **45 `func test*`** methods, all `import XCTest`, **0 `import Testing`** → registers "0 tests in 0 suites" under the swift-testing runner.
- **Rust leg:** **22 `#[test]`** in `rust/tests/inmemory_tests.rs` (mission prose says 0 — recorded as prose error, no executability impact).
- **Toolchain:** Swift 6.3.2 (bundles Testing). LatticeKit reference (`Tests/LatticeKitTests/CodeTests.swift`) uses `import Testing`/`@Suite`/`@Test`/`#expect` with **zero** swift-testing package dependency.

### Method distribution (45)

| File | methods |
|---|---|
| ConformanceRunner.swift (shared `.target`, 0 test methods — asserts run inside 3 conformance `@Test`s) | 0 |
| ConformanceTests.swift | 1 |
| InMemoryBasicTests.swift | 8 |
| InMemoryConformanceTests.swift | 1 |
| InMemoryObserverTests.swift | 3 |
| PostgreSQLBasicTests.swift | 2 |
| PostgreSQLConformanceTests.swift | 1 |
| EncryptionInvariantTests.swift | 4 |
| EncryptionWiringTests.swift | 2 |
| RowCryptoTests.swift | 4 |
| SQLiteBasicTests.swift | 9 |
| SQLiteConformanceTests.swift | 1 |
| EncryptionModeTests.swift | 4 |
| PersistenceKitCoreTypeTests.swift | 5 |
| **Total** | **45** |

---

## Key risk: `ConformanceRunner.swift` (non-test `.target`)

`PersistenceKitConformance` is a regular `.target` (not a `.testTarget`) that imports XCTest and
threads an `XCTestCase` parameter through every fixture method. The three backend conformance tests
call `runner.runAll(in: self)`. Conversion: drop `import XCTest`, drop all `XCTestCase` params,
replace `XCTAssert*` → `#expect`. Testing links in a regular target under Swift 6.3.2 (bundled).
**Convert the runner FIRST, then its three callers** — reverse order breaks the build.

`#expect` inside the shared runner records to the task-local test context of whichever `@Test`
invokes `runAll()` (task-locals propagate across `await` in the same task tree), so failures
attribute correctly to the running conformance test.

---

## Smythe Pre-flight verdict: YELLOW (no blockers)

Full report: `docs/blast_radius/PK_TEST_01_PREFLIGHT.md`. Cautions: (1) ConformanceRunner-first
ordering; (2) PostgreSQL `XCTSkip` → early-return guard. Both addressable without Package.swift edit
or rescope.
