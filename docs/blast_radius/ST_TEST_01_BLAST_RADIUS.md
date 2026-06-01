# Blast Radius Report — ST-TEST-01 (SubstrateTypes Swift library test leg)

Mission: `docs/missions/inflight/MISSION_ST_TEST_01.md`
Stream: sttest · Branch: `stream/sttest-substratetypes-test-leg`
Baseline commit: `b42db96` (HEAD of main at branch point) · Head: (this report = first commit)
Tier: **test-only** — no production source is modified. New test files are
authored; two legacy XCTest files are rewritten to swift-testing. No exported
symbol changes meaning. No public API is touched.

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **GREEN** (zero CRITICAL, zero blockers).
Known Ambiguity 1 resolved: swift-testing is bundled with Swift 6.3.2; no
`Package.swift` dependency edit is required (LatticeKit uses `import Testing`
with no manifest wiring — confirmed). `Package.swift` is therefore NOT modified.

Baseline test counts (verified, this branch @ `b42db96`):
- Swift `swift test`: 16 XCTest test methods (3 in `SubstrateTypesTests.swift`,
  13 in `Fingerprint256CombinatorsTests.swift`), 0 `@Test`.
- Rust `cargo test`: 80 `#[test]` functions across 15 modules.

## Symbols modified / removed / renamed / deprecated

**None.** This mission touches only the test target
(`Tests/SubstrateTypesTests/`). Test code exports no symbols consumed by any
other target. Grep across `packages/` and `apps/` confirms the only references
to `SubstrateTypesTests` / `Fingerprint256CombinatorsTests` are the package
manifest (`Package.swift:55,57`) and the package README — neither imports the
test symbols. No cross-package blast radius exists.

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `Tests/SubstrateTypesTests/SubstrateTypesTests.swift` | yes | rewrite XCTest → swift-testing (keep as package smoke test) | MUST_UPDATE |
| `Tests/SubstrateTypesTests/Fingerprint256CombinatorsTests.swift` | yes | rewrite XCTest → swift-testing | MUST_UPDATE |
| 22 new per-type suites in `Tests/SubstrateTypesTests/` | yes (CREATE) | one swift-testing peer suite per `Sources/SubstrateTypes/` type | MUST_UPDATE (new) |
| `Package.swift` | yes (conditional) | **NO EDIT** — swift-testing is bundled; manifest needs no dependency line | INTENTIONALLY_LEFT — conditional edit was contingent on a missing dependency that does not exist |

## INTENTIONALLY_LEFT (with justification)

- `Sources/SubstrateTypes/**` — production library, correct and released. Tests
  prove it; they do not change it. If a test reveals a real bug, the mission
  STOPS and reports (no source edit). Off-limits per mission.
- `rust/**` — the Rust leg is complete (80 `#[test]`); read as behavior
  reference, not modified.
- `docs/validation/substrate_math_performance/**` — conformance harness, tests
  algorithm validity not the library; off-limits per mission.
- `Package.swift` — see table; no dependency line required in Swift 6.3.

## RESCOPE_REQUIRED

**None.** Blast radius is contained entirely within the test target. No item
classifies as RESCOPE.

## Notes for implementation

- 7 Rust modules have zero inline tests (audit_event, bit_tensor/ThreeDBitTensor,
  lattice_anchor, noun_type, row, row_state, time_range). For those types the
  Swift suite is authored from Swift source behavior directly (no Rust mirror to
  copy). Not scope creep — these types are named in mission Part 2.
- Rust has no `recall_types.rs` module. The Swift/Rust asymmetry for RecallTypes
  is intentional and documented in source; do not assert Rust parity there.
- `bit_tensor.rs` ↔ `ThreeDBitTensor.swift` is the same type (non-obvious name
  mapping).
