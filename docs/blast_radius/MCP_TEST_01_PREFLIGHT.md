# Smythe Pre-flight — MCP-TEST-01

## Verdict: GREEN — terrain clear, proceed. Zero blockers.

---

## Status

GREEN

## Status details

- **Blast radius:** verified. 7 files, counts exact, 0 partial conversions.
- **Prior art / conflicts:** none. Single stream `stream/mc-aria-mcp-test-leg`; no
  other branch touches `apps/ARIA_MCP`.
- **Environment:** clean. `swift build` exit 0. Baseline `swift test` exit 0, 41
  XCTest executions, 0 swift-testing suites (the bug this mission fixes).
- **Dependencies:** all satisfied. `Package.swift` no-op confirmed (see below).

---

## Blast radius reality (verified against BRR)

### File count
7 files present in `apps/ARIA_MCP/Tests/AriaMCPTests/`. Exact match.

### `import XCTest` / `import Testing` census
- `import XCTest`: 7/7 files. Confirmed.
- `import Testing`: 0 files. Confirmed — zero partial conversions.

### `func test` method counts

| File | BRR claim | Actual | Match |
|---|---|---|---|
| `MultiEstateRoutingTests.swift` | 6 | 6 | YES |
| `SchemeDiscriminatorTests.swift` | 4 | 4 | YES |
| `StdioFramingTests.swift` | 3 | 3 | YES |
| `RecipeToolsTests.swift` | 6 | 6 | YES |
| `ServerTests.swift` | 9 | 9 | YES |
| `ToolProjectionTests.swift` | 7 | 7 | YES |
| `JSONRPCTests.swift` | 6 | 6 | YES |
| **Total** | **41** | **41** | YES |

All 41 methods confirmed. BRR table is accurate.

### swift-testing reference style
`packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift` — present,
correct. Uses `import Testing`, `@Suite`, `@Test`, `#expect`. Bilby has a clean
reference.

### `Package.swift` — no-op confirmed
Swift 6.3.2 (`swiftlang-6.3.2.1.108`). Testing framework is bundled in the
toolchain. `Package.swift` carries no swift-testing dependency entry and needs
none — identical to LatticeKit's `Package.swift` and the ST-TEST-01 /
ENGRAM-TEST-01 precedents. No edit required.

---

## Baseline build and test

```
swift build   → Build complete! (7.10s)   exit 0
swift test    → Executed 41 tests, with 0 failures (XCTest runner)
               Test run with 0 tests in 0 suites passed (swift-testing runner)   exit 0
```

The "0 tests in 0 suites" output is the known registration bug this mission
fixes, not a failure. Baseline is clean.

---

## Known Ambiguity 1 — serial execution / fixture bytes: RESOLVED

Scanned all 7 files for shared global state. Assessment:

**Suites with live estate / IO / inter-test ordering dependency (mark `.serialized`):**

- `ServerTests` — each `func test` calls `makeDispatcher()` which opens a fresh
  `InMemoryStorage`. Per-method isolation, but `GeniusLocusKit` and
  `PersistenceKit` singletons may carry internal state across tests within the
  suite. Mark `.serialized`.
- `StdioFramingTests` — opens live `Pipe()` pairs per test; each test spawns a
  `StdioServer` read loop. No shared estate, but Pipe file-descriptor
  lifecycle + concurrent async read loops are fragile under parallel execution.
  Mark `.serialized`.
- `MultiEstateRoutingTests` — opens multiple real `InMemoryStorage` estates per
  test, issues federation grants, fans across estates. State is per-test but
  federation grant mechanics could exhibit ordering sensitivity. Mark
  `.serialized`.
- `RecipeToolsTests` — opens real in-memory estates, runs multi-step
  benchmark→confirm sequences (`testMigrationBenchmarkRunThenConfirmDispatch`),
  calls `kit.branchHandle(for:)` with live branch IDs. The confirm test reads
  back a branch by UUID extracted from run-output text. Must be serial.
  Mark `.serialized`.
- `SchemeDiscriminatorTests` — opens real in-memory estates, issues
  `capture_drawer` / `drawer_recall` multi-step sequences. Mark `.serialized`.

**Suites safe to run parallel (no `.serialized`):**

- `JSONRPCTests` — operates only on pure value types (`JSONValue`,
  `JSONRPCRequest`, `JSONRPCResponse`). No estate, no Pipe, no shared mutable
  state. Fully parallel-safe.
- `ToolProjectionTests` — calls `ToolProjection.tools()` and
  `ToolDispatcher.parseToolName()` (pure static functions on value types). No
  estate, no IO. Fully parallel-safe.

Bilby's stated plan (5 serialized, 2 parallel) is correct. No revision needed.

**Fixture bytes** in `StdioFramingTests`: `0x0A` newline terminator, the literal
`"{ not json\n"` garbage frame, `"2024-11-05"` protocol version, and error
code integers are all present verbatim. Preservation is straightforward — do not
alter them.

---

## Prior art

No conflicting ADRs or prior decisions found. One prior commit touches
`apps/ARIA_MCP` (`3ea52cb feat(cognitionkit): behaviour-recipe layer + ARIA_MCP recipe tools`)
— this added `RecipeToolsTests.swift` as XCTest; it is one of the 7 files in
scope. Not a conflict; it is in the mission's MUST_UPDATE list.

---

## Bilby's stated approach

1. Convert each of the 7 files in place: swap `import XCTest` → `import
   Testing` (keeping other domain imports), `final class X: XCTestCase` →
   `@Suite [(.serialized)] struct X`, each `func testFoo` → `@Test func
   testFoo`, and every `XCT*` assertion per the BRR mapping table. Preserve
   helper methods, fixtures, and control flow exactly.
2. `XCTFail` inside `guard ... else { ...; return }` → `Issue.record(...)`,
   keeping the `return` so the failing case still short-circuits identically.
3. `Package.swift`: leave unchanged (verified no-op).
4. NOT doing: no production source touched, no behavior invented, no assertion
   dropped, no Rust step.

Assessment: **accepted.** Approach is correct and complete. The serialization
split (5 estate/IO suites serialized, 2 pure suites parallel) matches terrain.
Fixture byte handling in `StdioFramingTests` is straightforward — literals
survive the rewrite unchanged.

---

## Actions (proceeding)

1. Read each of the 7 source files in full (Bilby reads before touching).
2. Convert in order: JSONRPCTests → ToolProjectionTests → StdioFramingTests →
   SchemeDiscriminatorTests → MultiEstateRoutingTests → RecipeToolsTests →
   ServerTests (pure suites first, estate/IO suites second — establishes
   pattern before the serialized cases).
3. After all 7 converted: `cd apps/ARIA_MCP && swift test`. Verify exit 0,
   swift-testing runner registers ≥ 41 `@Test`, zero `import XCTest` remains,
   zero warnings.
4. Commit: `test(aria-mcp): convert XCTest suites to swift-testing (assertions preserved)`.
5. Write signal file to `/Users/bob/devlop/ddfactory/control/signals/.done-mc`.

---

## Notes for Bilby

- `SchemeDiscriminatorTests` has a `capture()` helper that calls `XCTUnwrap` —
  that helper itself needs rewriting to use `#require` and return type must stay
  compatible. Helper signature: `async throws -> JSONRPCResponse`; the `try
  XCTUnwrap(raw)` call becomes `try #require(raw)`. Return type unchanged.
- `RecipeToolsTests.testConfirmRefusesDisqualifiedWinner` uses the field name
  `disqualifiedBranchIDs` in the confirm args object. The test currently passes
  (confirmed by baseline), so the key name is correct even if it differs from
  what you might expect. Preserve it exactly.
- `ToolProjectionTests.testFederationToolIsPresentAboveTheProjection` uses `throws`
  and `try XCTUnwrap(federation.first)` — convert to `@Test func ... throws`
  with `try #require(federation.first)`. The `throws` annotation is required
  (swift-testing propagates thrown errors as test failures, same as XCTest).
- `MultiEstateRoutingTests` and `ServerTests` both call `makeDispatcher()` /
  `openEstate()` as private helper methods — these carry over unchanged to the
  struct.

---

*Pre-flight complete. 2026-05-31.*
