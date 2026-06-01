# Smythe Pre-flight — ST-TEST-01

## Verdict: GREEN — terrain clear, proceed. Zero blockers.

## Blast radius reality (verified against mission claims)
- 24 source files in `Sources/SubstrateTypes/` — confirmed (match).
- 2 XCTest files in test tree, both `import XCTest` — confirmed
  (`SubstrateTypesTests.swift:1` = 3 methods; `Fingerprint256CombinatorsTests.swift:8` = 12/13 methods).
- LatticeKit swift-testing reference present, all `import Testing`, no XCTest — confirmed.
- Rust inline tests present: 80 `#[test]` across 15 modules — confirmed.

## Known Ambiguity 1 — RESOLVED
swift-testing dependency NOT needed in `Package.swift`. Swift 6.3.2 bundles the
Testing framework. LatticeKit's `Package.swift` declares no swift-testing
dependency and uses `import Testing` directly. `Package.swift` edit: NOT needed.

## Findings
- WARNING (non-blocking): 7 Rust modules have zero inline tests (audit_event,
  bit_tensor/ThreeDBitTensor, lattice_anchor, noun_type, row, row_state,
  time_range). Author Swift coverage from Swift source for these.
- INFO: Rust has no `recall_types.rs`; RecallTypes Swift/Rust asymmetry is
  intentional (documented in source) — do not assert Rust parity there.
- INFO: `bit_tensor.rs` ↔ `ThreeDBitTensor.swift` are the same type.
- No source changes required (library is correct; validate against `swift test`).

## Bilby's stated approach
Touch the two existing XCTest files first (rewrite to swift-testing, preserving
the assertions they already make), then author per-type suites in two batches
(Part 1 value types, Part 2 the rest), reading each type's Rust `#[test]` module
to determine the behavior set to mirror — and reading Swift source directly for
the 7 types with no Rust tests. Pattern: `import Testing`, `struct …Tests`,
`@Test` funcs, `#expect`/`#require`, mirroring LatticeKit style. Explicitly NOT
modifying any `Sources/**`, `rust/**`, the conformance harness, or `Package.swift`.
