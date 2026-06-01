# Blast Radius Report — SLIB-TEST-01 (SubstrateLib library test leg, swift-testing)

Mission: `docs/missions/inflight/MISSION_SLIB_TEST_01.md`
Stream: slibtest · Branch: `stream/sl-substratelib-test-leg`
Baseline commit: `b42db96` · Head: `e79941e` (this report = next commit)
Tier: **net-new / test-only (no cap)** — TEST-ONLY conversion + additive test
authoring. Zero production source touched, so there is no symbol-semantics
blast radius. The "blast radius" here is the test target surface only.

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **GREEN** (terrain clear; report inline in the
completion report, Smythe agent `ab1e15694552c8762`). Zero blockers.

Baseline test counts (orchestrator-verified, branch @ `b42db96`):
- Swift `swift test`: XCTest bridge ran **101 passed, 0 failed**; the
  **swift-testing runner reported 0 tests in 0 suites** (the mission's
  premise — XCTest is invisible to the swift-testing harness).
- Rust `cargo test`: **35** source-module unittests passed (audit_gate 14 +
  verbs 12 + row_state 9), integration tests green, exit 0.

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

The mission table listed the 7 SubstrateLibTests files + conditional
conformance files + 2 CREATE files + Package.swift (conditional). Real
in-scope blast radius is **12 files**, all under `Tests/`. Package.swift is
**NOT** modified (confirmed below).

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `Tests/SubstrateLibTests/AuditGateTests.swift` | yes | XCTest→swift-testing (17 assertions preserved) | MUST_UPDATE |
| `Tests/SubstrateLibTests/BitFieldTests.swift` | yes | convert (14 preserved) | MUST_UPDATE |
| `Tests/SubstrateLibTests/CountVector256Tests.swift` | yes | convert (13 preserved) | MUST_UPDATE |
| `Tests/SubstrateLibTests/SubstrateLibTests.swift` | yes | convert (10 preserved) | MUST_UPDATE |
| `Tests/SubstrateLibTests/SHA256Tests.swift` | yes | convert (5 preserved) | MUST_UPDATE |
| `Tests/SubstrateLibTests/SharedFamilyTests.swift` | yes | convert (5 preserved) | MUST_UPDATE |
| `Tests/SubstrateLibTests/HammingTopKTieBreakTests.swift` | yes | convert (4 preserved) | MUST_UPDATE |
| `Tests/SubstrateLibConformanceTests/BitmapFieldConstantsConformanceTests.swift` | yes (`*ConformanceTests`) | convert (3 preserved) | MUST_UPDATE |
| `Tests/SubstrateLibConformanceTests/SubstrateLibConformanceTests.swift` | yes (`*ConformanceTests`) | convert (2 preserved) | MUST_UPDATE |
| `Tests/SubstrateLibConformanceTests/WireFormatConformanceTests.swift` | yes (`*ConformanceTests`) | convert (28 preserved) | MUST_UPDATE |
| `Tests/SubstrateLibTests/RowStateAutomatonTests.swift` | yes (CREATE) | new peer suite (9 tests) mirrors Rust row_state | MUST_UPDATE (new) |
| `Tests/SubstrateLibTests/VerbsTests.swift` | yes (CREATE) | new peer suite (12 tests) mirrors Rust verbs | MUST_UPDATE (new) |

Total: 10 conversions (101 assertions preserved) + 2 new suites (21 tests) =
**122 swift-testing tests in 12 suites**.

## Package.swift — NOT modified (justified)

Mission lists Package.swift as "conditional: additive swift-testing dep only
if absent." Smythe verified — and the orchestrator independently confirmed —
that swift-testing ships with the Swift 6.0 toolchain and needs **no** package
dependency entry. The baseline `swift test` already invoked the swift-testing
runner (it reported "0 tests in 0 suites"), proving the framework is resolved
without any Package.swift change. LatticeKit (the cited style precedent) also
declares no swift-testing dep. Adding one would be unnecessary scope. **No
change made.**

## Symbols changed (semantics)

**None.** No production source under `Sources/**` or `rust/**` was modified.
This is a pure test-framework conversion plus additive test authoring. No
symbol changed meaning; no caller anywhere is affected.

## Files NOT modified (per mission's MUST NOT list)

- `packages/libs/SubstrateLib/Sources/**` — released production code; untouched
  (verified: `git diff` shows zero Sources changes). No test revealed a bug.
- `packages/libs/SubstrateLib/rust/**` — complete; behavior reference only;
  untouched.
- `docs/validation/**` — EE-only conformance harness; off-limits; untouched.
- `Package.swift` — not modified (see above).
- Any other package — untouched.

## Swift/Rust parity (Part 3) — confirmation, no new code

Parity was already satisfied after Parts 1–2; Part 3 required no additions:
- **audit_gate**: Rust 14 behaviors ↔ Swift AuditGateTests 17 (superset:
  Swift adds content-ID-changes-with-payload, value-exceeds-width freeze, and
  the I-22-via-gate test).
- **row_state**: Rust 9 ↔ Swift RowStateAutomatonTests 9 (1:1).
- **verbs**: Rust 12 ↔ Swift VerbsTests 12 (1:1, with one documented port
  divergence — see below).

### Documented port divergence (not a bug, not in scope to change)

The Rust `verbs::deterministic_row_ids_across_calls` test asserts that
identical call sequences produce identical `RowId(u128)` values. The Swift
`Substrate.capture` (Verbs.swift:127) assigns `UUID()` (random) per row, so
deterministic row IDs is a **Rust-only port property**, not a Swift behavior.
The Swift-faithful counterpart (`testCaptureRowIdsAreUnique`) asserts row-ID
uniqueness instead. Changing the Swift source to deterministic IDs is OUT OF
SCOPE (production code, MUST NOT modify) and was not done.

## Test verification (filled at completion)

- `swift test` (packages/libs/SubstrateLib): **exit 0, 122 tests in 12 suites
  passed**, 0 warnings. (baseline 101 XCTest-bridge → 122 swift-testing;
  +21 net-new, 101 preserved.)
- `cargo test` (packages/libs/SubstrateLib/rust): **exit 0, 35 source-module
  passed**, 0 warnings. (reference leg, untouched.)
