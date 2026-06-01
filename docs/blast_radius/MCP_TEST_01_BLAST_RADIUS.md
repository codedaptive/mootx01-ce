# Blast Radius Report — MCP-TEST-01 (ARIA_MCP app test leg → swift-testing)

Mission: `docs/missions/inflight/MISSION_MCP_TEST_01.md`
Stream: mc · Branch: `stream/mc-aria-mcp-test-leg`
Baseline commit: `16c0579` · Head: (this report = first stream commit, hard gate)
Tier: **test-only / no-cap** — no production source touched. Converts 7
XCTest files to swift-testing in place. App target, so **no Rust parity step**
(ARIA_MCP is a compiled app; the substrate dual-leg rule does not apply).

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **GREEN** (`docs/blast_radius/MCP_TEST_01_PREFLIGHT.md`).
Zero blockers.

## Baseline (verified, this branch @ `16c0579`)

`cd apps/ARIA_MCP && swift test`: exit 0.
- **XCTest runner: "Executed 41 tests, with 0 failures"** across the 7 files.
- **swift-testing runner: "Test run with 0 tests in 0 suites passed"** — the
  bug this mission fixes (41 XCTest methods are invisible to the swift-testing
  runner).
- All 7 test files carry `import XCTest`; **0** carry `import Testing`.
- `func test` method count per file (verified):

| File | `func test` methods |
|---|---|
| `MultiEstateRoutingTests.swift` | 6 |
| `SchemeDiscriminatorTests.swift` | 4 |
| `StdioFramingTests.swift` | 3 |
| `RecipeToolsTests.swift` | 6 |
| `ServerTests.swift` | 9 |
| `ToolProjectionTests.swift` | 7 |
| `JSONRPCTests.swift` | 6 |
| **Total** | **41** |

XCT assertion-call census (verified, all preserved on conversion):
`XCTAssertEqual` ×46, `XCTAssertTrue` ×28, `XCTAssertFalse` ×15, `XCTAssertNil`
×8, `XCTAssertNotNil` ×3, `XCTAssertNotEqual` ×2, `XCTFail` ×17, `XCTUnwrap`
×53. None dropped; each maps 1:1 to a swift-testing equivalent (table below).

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

The mission table lists 7 test files + a conditional `Package.swift`. The real,
in-scope blast radius is **7 files written** — `Package.swift` resolves to a
no-op (see below). Fully accounted for.

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `apps/ARIA_MCP/Tests/AriaMCPTests/JSONRPCTests.swift` | yes | XCTest → swift-testing (6 tests) | MUST_UPDATE |
| `apps/ARIA_MCP/Tests/AriaMCPTests/MultiEstateRoutingTests.swift` | yes | XCTest → swift-testing (6 tests) | MUST_UPDATE |
| `apps/ARIA_MCP/Tests/AriaMCPTests/SchemeDiscriminatorTests.swift` | yes | XCTest → swift-testing (4 tests) | MUST_UPDATE |
| `apps/ARIA_MCP/Tests/AriaMCPTests/StdioFramingTests.swift` | yes | XCTest → swift-testing (3 tests) | MUST_UPDATE |
| `apps/ARIA_MCP/Tests/AriaMCPTests/RecipeToolsTests.swift` | yes | XCTest → swift-testing (6 tests) | MUST_UPDATE |
| `apps/ARIA_MCP/Tests/AriaMCPTests/ServerTests.swift` | yes | XCTest → swift-testing (9 tests) | MUST_UPDATE |
| `apps/ARIA_MCP/Tests/AriaMCPTests/ToolProjectionTests.swift` | yes | XCTest → swift-testing (7 tests) | MUST_UPDATE |
| `apps/ARIA_MCP/Package.swift` | yes (conditional) | **no change** — swift-testing is bundled in the Swift 6.3.2 toolchain; `import Testing` resolves with no package dep (same as the LatticeKit reference + ST-TEST-01 / ENGRAM-TEST-01 precedents). Conditional "only if absent" → the dependency is the toolchain's, so nothing to add. | NOT MODIFIED (conditional no-op) |

## Conversion mapping (XCTest → swift-testing)

| XCTest | swift-testing |
|---|---|
| `final class X: XCTestCase {` | `@Suite struct X {` (`.serialized` on estate/IO suites — see Known Ambiguity 1) |
| `func testFoo() [async] throws {` | `@Test func testFoo() [async] throws {` |
| `XCTAssertEqual(a, b[, msg])` | `#expect(a == b[, msg])` |
| `XCTAssertNotEqual(a, b[, msg])` | `#expect(a != b[, msg])` |
| `XCTAssertTrue(x[, msg])` | `#expect(x[, msg])` |
| `XCTAssertFalse(x[, msg])` | `#expect(!(x)[, msg])` |
| `XCTAssertNil(x)` | `#expect(x == nil)` |
| `XCTAssertNotNil(x)` | `#expect(x != nil)` |
| `try XCTUnwrap(x)` | `try #require(x)` |
| `XCTFail("msg")` (in guard/else + return) | `Issue.record("msg")` (control flow preserved) |

`private` helper methods (`makeDispatcher`, `openEstate`, `captureArgs`,
`recallArgs`, `text`, `isError`, `capture`, static `uuids`/`uniqueUUIDs`) and
the `Self.` static references carry over unchanged — `struct` supports instance
and static methods identically to the former `XCTestCase` subclass.

## Known Ambiguity 1 — serial execution / fixture bytes (resolved)

The mission flags that JSONRPC / stdio framing may rely on byte-exact fixtures
and ordered I/O.

- **Fixture bytes preserved verbatim.** The newline terminator (`0x0A`), the
  `"{ not json\n"` garbage frame, `protocolVersion "2024-11-05"`, JSON-RPC
  error codes, and every literal argument object are carried over unchanged.
  No asserted value is altered.
- **Serial execution.** XCTest runs a suite's methods serially. swift-testing
  parallelizes by default. The five suites that open live in-memory estates,
  run the stdio server over real `Pipe()`s, or issue federation grants
  (`ServerTests`, `StdioFramingTests`, `MultiEstateRoutingTests`,
  `RecipeToolsTests`, `SchemeDiscriminatorTests`) are marked
  `@Suite(.serialized)` to preserve the ordered, one-at-a-time execution they
  ran under XCTest. The two pure suites — `JSONRPCTests` (wire value types) and
  `ToolProjectionTests` (static projection contract) — touch no shared mutable
  state and are left parallel-safe (no `.serialized`), matching the
  library-test precedents. This preserves behavior; it does not change any
  assertion.

## App target — NO Rust parity step

ARIA_MCP is a compiled Swift app (`apps/ARIA_MCP`), not a dual-leg substrate
kit. Per the mission, there is no Rust behavior set to mirror and no
`cargo test` leg. This is the explicit difference from ST-TEST-01 / ENGRAM-
TEST-01 (which were substrate libraries with Rust legs). No parity map applies.

## Files NOT modified (per mission's MUST NOT list)

- `apps/ARIA_MCP/Sources/**` — released production code. Untouched. If a test
  had revealed a real bug, the mission orders STOP-and-report; none did.
- `apps/ARIA_MCP/Package.swift` — conditional no-op (verified above).
- `docs/validation/**` — off-limits conformance harness. Untouched.
- Any other package. Untouched.

## Stated approach (Bilby, per Smythe's pre-flight ask)

1. Convert each of the 7 files in place: swap `import XCTest` → `import
   Testing` (keeping the other domain imports), `final class X: XCTestCase` →
   `@Suite [(.serialized)] struct X`, each `func testFoo` → `@Test func
   testFoo`, and every `XCT*` assertion per the mapping table. Preserve helper
   methods, fixtures, and control flow exactly.
2. `XCTFail` inside `guard ... else { ...; return }` → `Issue.record(...)`,
   keeping the `return` so the failing case still short-circuits identically.
3. `Package.swift`: leave unchanged (verified no-op).
4. NOT doing: no production source touched, no behavior invented, no assertion
   dropped, no Rust step.

## Test verification (filled at completion)

- `cd apps/ARIA_MCP && swift test`: exit 0; swift-testing runner registers ≥ 41
  `@Test`; zero `import XCTest` remains; zero warnings. Verbatim tail recorded
  in the completion report.
