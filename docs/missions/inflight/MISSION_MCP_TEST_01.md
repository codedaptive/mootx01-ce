# Mission MCP-TEST-01 — ARIA_MCP app test leg (swift-testing)

## Priority: P1
## Stream: mc
## Branch from: main
## Depends on: None
## Parallel safe with: all other test-leg streams (disjoint packages)

---

## Context

ARIA_MCP is the MCP server app (implemented in Swift; compiled apps call kits in-process,
bypassing MCP per the ARIA_MCP_SPEC). It builds clean. The Swift test leg is 7 files, 41
XCTest methods (`import XCTest`), registering as "0 tests in 0 suites" under the swift-testing
runner.

This mission is a CONVERSION: convert the 7 existing XCTest files to swift-testing
(`import Testing`/`@Test`/`#expect`/`#require`), preserving EVERY assertion. As an app target
(not a dual-leg kit), there is NO Rust parity step. TEST-ONLY — no production source modified.
Follows the ST-TEST-01 precedent.

## Read First

- App sources: `apps/ARIA_MCP/Sources/**/*.swift`.
- Existing tests to CONVERT (read each fully; preserve all assertions):
  - `apps/ARIA_MCP/Tests/AriaMCPTests/MultiEstateRoutingTests.swift` (6)
  - `apps/ARIA_MCP/Tests/AriaMCPTests/SchemeDiscriminatorTests.swift` (4)
  - `apps/ARIA_MCP/Tests/AriaMCPTests/StdioFramingTests.swift` (3)
  - `apps/ARIA_MCP/Tests/AriaMCPTests/RecipeToolsTests.swift` (6)
  - `apps/ARIA_MCP/Tests/AriaMCPTests/ServerTests.swift` (9)
  - `apps/ARIA_MCP/Tests/AriaMCPTests/ToolProjectionTests.swift` (7)
  - `apps/ARIA_MCP/Tests/AriaMCPTests/JSONRPCTests.swift` (6)
- swift-testing reference style: `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`.
- swift-testing wiring precedent: `packages/libs/SubstrateTypes/Package.swift`.

## Known Ambiguities

1. JSONRPC / stdio framing tests may rely on byte-exact fixtures and ordered I/O. Preserve
   fixture bytes and any serial execution (swift-testing `.serialized` where XCTest ran serial).
   Do not change what is asserted.

## Files You Will Modify

| File | Change |
|---|---|
| `apps/ARIA_MCP/Tests/AriaMCPTests/*.swift` (all 7 XCTest files) | convert XCTest -> swift-testing (preserve all 41 assertions) |
| `apps/ARIA_MCP/Package.swift` (or target manifest) | conditional: additive swift-testing dep only if absent |

## Files You MUST NOT Modify

- `apps/ARIA_MCP/Sources/**` — released production code. If a test reveals a real bug, STOP and report.
- `docs/validation/**` — off-limits.
- Any other package.

## Implementation Parts

### Part 1 — Convert existing 7 XCTest files
Read each fully. Convert framework, preserving every assertion exactly. Preserve fixture bytes
and serial execution where relied on. No behavior change.
**Commit:** `test(aria-mcp): convert XCTest suites to swift-testing (assertions preserved)`
→ verify: `cd apps/ARIA_MCP && swift test` green, registers non-zero (>= 41); no `import XCTest` remains.

## Test Requirements

- swift-testing only; zero `import XCTest`.
- All 41 prior assertions preserved.
- No Rust parity step (app target).
- `swift test` green and registers non-zero; zero warnings.
- No production source modified.

## Test Verification Log
### Baseline: 7 XCTest files, 41 methods, registering 0.
### Final: `cd apps/ARIA_MCP && swift test 2>&1 | tail -20` exit 0, @Test count recorded (>= 41), verbatim tail.

## Verification

ARIA_MCP test leg is swift-testing, all 41 prior assertions preserved and running. Production
untouched. Swift leg green.

## Success Criteria

7 suites converted with assertions intact and registering; Swift leg green; production untouched.

## Signal File

Write to: /Users/bob/devlop/ddfactory/control/signals/.done-mc
