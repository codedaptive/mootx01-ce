# Smythe Pre-flight: PK-TEST-01

**Date:** 2026-05-31
**Mission:** PersistenceKit library test leg (swift-testing conversion)
**Branch:** stream/pk-persistencekit-test-leg

---

## Status

YELLOW — Proceed with noted cautions. Two items require Bilby's explicit attention before
committing; neither blocks mission start.

---

## Status Details

- **Blast radius:** Verified. 14 files, 45 `func test*` methods, all `import XCTest`,
  zero `import Testing`. Counts match mission claim. See detail below.
- **Prior art:** None conflicting. ST-TEST-01 and ENGRAM-TEST-01 precedents are directly
  applicable (same conversion pattern).
- **Environment:** Swift 6.3.2 confirmed. Testing framework bundled (no package dep needed).
  Build baseline not run (read-only pre-flight); Package.swift well-formed.
- **Dependencies:** SubstrateTypes, postgres-nio present. No missing prerequisites.

---

## Blast-Radius Verification

### Claim 1 — 14 XCTest files, 45 `func test*` methods, all `import XCTest`, zero `import Testing`

**Verified. Counts match exactly.**

File-by-file `func test*` count:

| File | func test* count |
|---|---|
| `Tests/PersistenceKitConformance/ConformanceRunner.swift` | 0 (not a test file — see Item 1 below) |
| `Tests/PersistenceKitConformanceTests/ConformanceTests.swift` | 1 |
| `Tests/PersistenceKitInMemoryTests/InMemoryBasicTests.swift` | 8 |
| `Tests/PersistenceKitInMemoryTests/InMemoryConformanceTests.swift` | 1 |
| `Tests/PersistenceKitInMemoryTests/InMemoryObserverTests.swift` | 3 |
| `Tests/PersistenceKitPostgreSQLTests/PostgreSQLBasicTests.swift` | 2 |
| `Tests/PersistenceKitPostgreSQLTests/PostgreSQLConformanceTests.swift` | 1 |
| `Tests/PersistenceKitSQLiteTests/EncryptionInvariantTests.swift` | 4 |
| `Tests/PersistenceKitSQLiteTests/EncryptionWiringTests.swift` | 2 |
| `Tests/PersistenceKitSQLiteTests/RowCryptoTests.swift` | 4 |
| `Tests/PersistenceKitSQLiteTests/SQLiteBasicTests.swift` | 9 |
| `Tests/PersistenceKitSQLiteTests/SQLiteConformanceTests.swift` | 1 |
| `Tests/PersistenceKitTests/EncryptionModeTests.swift` | 4 |
| `Tests/PersistenceKitTests/PersistenceKitCoreTypeTests.swift` | 5 |
| **Total** | **45** |

All 14 files import `XCTest`. Zero import `Testing`. Counts match mission claim.

### Claim 2 — Rust `#[test]` count: mission says 0, reality is 22

**Mission prose is wrong. Reality: 22 `#[test]` in `rust/tests/inmemory_tests.rs`.**

This matches the "mission-prose-wrong-on-rust" pattern seen on ENGRAM-TEST-01. The mission
states "Its Rust leg has 0 `#[test]` functions" — that is incorrect. The file
`packages/kits/PersistenceKit/rust/tests/inmemory_tests.rs` contains 22 `#[test]`
annotated functions.

**Executability impact: none.** Rust is explicitly out of scope for this mission, and
the mission correctly states there is no Rust parity step. The factual error in the mission
prose does not change what Bilby must do. Mission proceeds on the Swift conversion as stated.
The prose error should be noted in the completion report.

### Claim 3 — `ConformanceRunner.swift` non-testTarget risk

**YELLOW. This is the most significant terrain feature. Requires Bilby's explicit decision.**

`Tests/PersistenceKitConformance/ConformanceRunner.swift` is declared as a regular `.target`
(not `.testTarget`) in Package.swift:

```swift
.target(
    name: "PersistenceKitConformance",
    dependencies: ["PersistenceKit", "SubstrateTypes"],
    path: "Tests/PersistenceKitConformance"
)
```

It currently `import XCTest` and its `runAll(in test: XCTestCase)` method takes an
`XCTestCase` parameter. The three backend conformance test targets (InMemory, SQLite,
PostgreSQL) each import `PersistenceKitConformance` and call `runner.runAll(in: self)`.

**The conversion path for this file is non-trivial:**

1. Swift Testing (`import Testing`) links in regular `.target` builds under Swift 6.3.2 —
   Testing is part of the Swift stdlib umbrella since 5.10 and is available to all targets,
   not just testTargets. No Package.swift change is needed to link Testing in a `.target`.

2. However, the _API surface changes completely._ The `runAll(in test: XCTestCase)` signature
   must be redesigned. Under swift-testing, there is no `XCTestCase` to pass. The fixture
   group methods (`schemaFixtures`, `rowFixtures`, etc.) take `XCTestCase` parameters today
   but use it only for implicit test reporting — XCTest macros (`XCTAssertEqual`) route
   failures through it automatically. Under swift-testing, `#expect` and `#require` carry
   no `XCTestCase` dependency; they work from any calling context.

3. **Recommended conversion approach:**
   - Drop `import XCTest` from ConformanceRunner.swift; replace with `import Testing`.
   - Remove the `test: XCTestCase` parameter from `runAll` and all fixture methods.
   - Replace all `XCTAssertEqual/XCTAssertTrue/XCTAssertFalse/XCTAssertNil/XCTAssertNotNil/
     XCTAssertLessThan` with `#expect(...)` equivalents.
   - The calling conformance tests (`InMemoryConformanceTests.swift`, etc.) become
     standard `@Test` functions that call `runner.runAll()` — no `self` to pass.
   - No Package.swift change required for the `.target` declaration.

4. **Risk:** If Bilby converts the calling conformance test files before converting
   ConformanceRunner, the build will fail (XCTestCase param with no XCTestCase import).
   Conversion order matters: ConformanceRunner first, then callers.

### Claim 4 — LatticeKit `import Testing` reference style

**Confirmed.** `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift` uses
`import Testing`, `@Suite`, `@Test`, `#expect`. Valid reference. LatticeKit Package.swift
declares no swift-testing package dependency (Testing is bundled).

### Claim 5 — Swift 6.3.2 bundles Testing

**Confirmed.** Swift 6.3.2 (swiftlang-6.3.2.1.108) confirmed on this machine. Testing has
been bundled with the Swift stdlib since 5.10. LatticeKit and SubstrateTypes both use
`import Testing` with no package dependency declared — precedent is clean. No Package.swift
change needed for PersistenceKit.

### Claim 6 — PostgreSQL `XCTSkip` gated on `POSTGRES_TEST_URL`

**YELLOW. Requires explicit conversion strategy.**

Two files use `XCTSkip`:
- `PostgreSQLBasicTests.swift:33` — `throw XCTSkip("POSTGRES_TEST_URL not set...")`
- `PostgreSQLConformanceTests.swift:13` — `throw XCTSkip("POSTGRES_TEST_URL not set")`

The pattern in both files is: check env var; if absent, throw `XCTSkip`; otherwise proceed.

**swift-testing equivalent:** `try #require(ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"] != nil)`
will cause the test to fail (not skip) when the URL is absent — incorrect behavior.

The correct swift-testing idiom for env-gated skipping:

```swift
@Test func testAllFixtures() async throws {
    guard let cs = ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"] else {
        throw XCTSkip("POSTGRES_TEST_URL not set")  // NOT valid in swift-testing
    }
    // ...
}
```

Must become:

```swift
@Test func testAllFixtures() async throws {
    try withKnownIssue("POSTGRES_TEST_URL not set", isIntermittent: true) { ... }
    // OR use a custom SkipCondition / conditional test tagging
}
```

The cleanest approach under swift-testing is:

```swift
@Test func testAllFixtures() async throws {
    guard let cs = ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"] else {
        return  // test is vacuously passing; no assertions run
    }
    // ... full test body
}
```

This "early return on missing env" pattern keeps the test registering and green in CI
without postgres, identical to the XCTSkip behavior. It is the correct conversion.
`withKnownIssue` is semantically wrong here (the test is not broken, just skipped).

Bilby must use the early-return pattern — not `#require` (would fail), not `withKnownIssue`
(semantically wrong).

### Claim 7 — No cross-package dependency on these test files

**Confirmed.** The five test targets in Package.swift are all internal to PersistenceKit.
No other package references these test targets. No parallel-stream churn on this package
(git status shows only this untracked mission file; no other in-flight modifications).

---

## YELLOW Cautions (non-blocking, require explicit Bilby handling)

**YELLOW-1: ConformanceRunner.swift conversion order and signature redesign.**
`PersistenceKitConformance` is a `.target`, not `.testTarget`. The `XCTestCase` param
signature must be dropped. Convert ConformanceRunner.swift first, then the three callers.
If order is reversed the build breaks mid-mission.
Owner: Bilby. No Package.swift change needed.

**YELLOW-2: PostgreSQL `XCTSkip` replacement.**
Two files use `throw XCTSkip(...)` as an env guard. swift-testing has no `XCTSkip`.
Correct replacement is early-return (`guard ... else { return }`). Do not use `#require`
(causes failure) or `withKnownIssue` (wrong semantics).
Owner: Bilby. Both PostgreSQL test files.

**INFO: `XCTAssertThrowsErrorAsync` helper in InMemoryBasicTests.swift.**
A custom async helper function `XCTAssertThrowsErrorAsync` is defined at file scope (lines
240–251). Under swift-testing, replace the one call site (`testTransactionRollback`) with
`await #expect(throws: (any Error).self) { try await ... }`. Remove the helper.
Owner: Bilby. Scoped to `InMemoryBasicTests.swift`.

**INFO: Mission prose error — Rust `#[test]` count.**
Mission states "Rust leg has 0 `#[test]`". Actual count: 22 in `inmemory_tests.rs`.
Not a mission blocker — Rust is out of scope, no parity step exists. Note in completion report.

---

## Bilby's Stated Approach

I will convert `ConformanceRunner.swift` FIRST (shared `.target`): drop `import XCTest`, drop
every `in test: XCTestCase` parameter, replace each `XCTAssert*` with the `#expect` equivalent
(dynamic `"\(backendName): …"` messages survive as `Comment` string interpolation) — then convert
the three conformance callers to call `runner.runAll()` with no `self`. The remaining 10 files
convert one-for-one: `final class X: XCTestCase` → `struct X` with `@Test` methods; helper methods
(`makeStorage`/`makeSchema`) stay as struct methods (no XCTest `setUp`/`tearDown` exists to port, so
fixture lifecycle is unchanged — each test already mints its own isolated storage). `XCTFail` inside
`if case` checks → `Issue.record(...)`; `do/catch`-throws and `XCTAssertThrowsError(Async)` →
`#expect(throws:)`; PostgreSQL `throw XCTSkip` → `guard let cs = env else { return }` (keeps all 45
registered and green when `POSTGRES_TEST_URL` is absent). I will NOT touch `Sources/**`, `rust/**`,
`docs/validation/**`, or `Package.swift` (Swift 6.3.2 bundles Testing — no dependency to add). All 45
assertions preserved exactly. Then Part 2 fills per-source-type coverage gaps for unit-testable core
value types lacking a peer suite.

---

## Actions (if proceeding)

1. Bilby writes stated approach (2–4 sentences: files first, pattern, what is NOT done).
2. Convert `ConformanceRunner.swift` FIRST: drop `import XCTest`, drop `XCTestCase` params,
   replace all `XCTAssert*` with `#expect`/`#require`. Build-check.
3. Convert the three conformance callers (`InMemoryConformanceTests`, `SQLiteConformanceTests`,
   `PostgreSQLConformanceTests`) to `@Test` functions calling `runner.runAll()`.
4. Convert remaining 10 test files (testTargets only; straightforward XCTest→swift-testing).
5. PostgreSQL files: replace `throw XCTSkip(...)` with early-return guard pattern.
6. `InMemoryBasicTests.swift`: replace `XCTAssertThrowsErrorAsync` call and remove helper.
7. Verify `swift test` green, non-zero registered tests, zero `import XCTest` remaining.
8. Part 2: identify source types lacking coverage; add peer suites.

---

## Decision Needed

None. Proceed with cautions noted above.

---

## Rust Prose Error (for completion report reference)

Mission prose: "Its Rust leg has 0 `#[test]` functions"
Reality: 22 `#[test]` in `packages/kits/PersistenceKit/rust/tests/inmemory_tests.rs`
Impact: none (Rust out of scope, no parity step). Record in completion report.
