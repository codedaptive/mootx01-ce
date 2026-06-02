# Smythe Pre-flight: NEURON_ASSOC_RULE_MINING_001

**Branch:** `stream/ar-assoc-rule-mining`
**Baseline:** `4ef8a05`
**Date:** 2026-06-01

---

## Status

GREEN

---

## Status details

- **Blast radius:** verified — four paths correct, three files absent (confirmed), lib.rs present and unmodified from baseline
- **Prior art:** none conflicting — `AssociationRule`, `MiningThresholds`, `mineAssociationRules`, `AssociationRuleEngine`, `association_rule_mining` absent everywhere in repo (grep clean); `Item` absent across all NeuronKit Swift imports and all Rust crates
- **Environment:** clean — baseline commit confirmed, branch is `stream/ar-assoc-rule-mining`; BRR documents Cargo.lock refresh at mission start (forced, not scope creep)
- **Dependencies:** satisfied — SubstrateTypes listed in both NeuronKit library target (Package.swift line 85) and test target (line 92); `substrate-types` listed in Cargo.toml `[dependencies]` (line 36); no Package.swift or Cargo.toml change needed

---

## Blockers

None.

---

## Bilby's stated approach

Swift engine first: `mineAssociationRules` delegates to `internal enum AssociationRuleEngine`; metrics use `O[A,B]/N` for support, `O[A,B]/O[A,A]` for confidence, the four derived metrics from the mission formula set; single-item support from MatrixO diagonal (`O[A,A]`); diagonal excluded from rule emission; edge cases handled (N≤0, zero diagonal, below-threshold drop); output sorted ascending on packed `(antecedent, consequent)` key. Swift tests follow with hand-checked in-code vectors (empty, single pair all-five-metrics, conviction +inf, threshold gating, N==0, diagonal-only, ordering). Rust port mirrors formulas in f64 with inline `#[cfg(test)] mod tests` encoding identical cases; one-line `pub mod association_rule_mining;` registration in lib.rs. Cargo.lock refresh carried in the Rust commit per BRR note.

**Assessment:** accepted. Approach mirrors MMRRank pattern exactly. Formula set matches mission spec. Dependency chain confirmed clean on both sides. No manifest changes required.

---

## Verification findings

### 1. File paths and existence

| File | Path resolves? | Already exists? |
|---|---|---|
| `AssociationRuleMining.swift` | yes — `packages/kits/NeuronKit/Sources/NeuronKit/` has 13 existing files, this one absent | absent — CREATE clear |
| `AssociationRuleMiningTests.swift` | yes — `packages/kits/NeuronKit/Tests/NeuronKitTests/` | absent — CREATE clear |
| `association_rule_mining.rs` | yes — `packages/kits/NeuronKit/rust/src/` has 25 existing files, this one absent | absent — CREATE clear |
| `rust/src/lib.rs` | yes | present — EDIT (one-line registration) |

### 2. Symbol collision — `Item`

Searched across all six NeuronKit Swift import targets:
- `EideticLib/Sources/` — no public `Item`
- `GeniusLocusKit/Sources/` — no public `Item`
- `LocusKit/Sources/` — no public `Item`
- `EngramLib/Sources/` — no public `Item`
- `SubstrateTypes/Sources/` — no public `Item`
- `SubstrateML/Sources/` — no public `Item`
- `NeuronKit/Sources/` itself — no `Item`

Rust: no `pub struct Item` / `pub enum Item` / `pub type Item` in any crate under `packages/`. Clean.

### 3. Input contract — MatrixO.swift

Verified against source:

- `applyRow` (lines 165–175): double loop `for a in fieldValues { for b in fieldValues }` — diagonal `i==j` retained. Confirmed.
- `count(_ key: CooccurrenceKey) -> Int64` (lines 111–122): binary search, `return 0` if absent. Confirmed.
- `entries: [(key: CooccurrenceKey, count: Int64)]` sorted ascending by `key.packed`. Confirmed.
- `CooccurrenceKey.packed` layout: `fieldI:8 | valueI:8 | fieldJ:8 | valueJ:8` (UInt32). Confirmed.
- 6-bit preconditions on both field and value (`< 64`). Confirmed.

### 4. Input contract — matrix_o.rs

Verified against source:

- `apply_row` (lines 99–109): identical double loop `for &a ... for &b`, including diagonal. Confirmed.
- `count(key: CooccurrenceKey) -> i64` (lines 62–69): binary search by `key.packed()`, returns 0 if absent. Confirmed.
- `packed()` layout matches Swift exactly: `field_i:8 | value_i:8 | field_j:8 | value_j:8`. Confirmed.
- `CooccurrenceKey::new` enforces 6-bit preconditions. Confirmed.

### 5. Conformance pattern

`mmr_rank.rs` carries inline `#[cfg(test)] mod tests` (line 127). No `rust/tests/` directory usage. `MMRRankTests.swift` uses `import Testing`, `@Suite`/`@Test`/`#expect`. Both patterns verified. Mission correctly calls for the same approach.

### 6. Package.swift dependency verification

- Library target `NeuronKit` dependencies (lines 79–88): includes `SubstrateTypes`. Confirmed.
- Test target `NeuronKitTests` dependencies (line 92): `["NeuronKit", .product(name: "SubstrateTypes", package: "SubstrateTypes")]`. Confirmed. Tests can access `MatrixO` and `CooccurrenceKey` directly.

### 7. Cargo.toml dependency verification

`substrate-types = { path = "../../../libs/SubstrateTypes/rust" }` in `[dependencies]` (line 36). Confirmed. No Cargo.toml change needed.

### 8. Parallel-stream churn — lib.rs

Sibling worktrees checked:
- `mootx01-ce-fc-forbidden-combo-converge` — lib.rs `pub mod` list is byte-identical to this worktree's baseline; no `association_rule_mining` or `fa` module added. No collision on current content; the `ar`/`fa` one-line merge risk noted in the mission stands but is a future merge concern, not a current blocker.
- `mootx01-ce-dd-datalog-rule-eval` — lib.rs does not target NeuronKit rust (dd stream targets a different module). No collision.
- `mootx01-ce-mt-matrixt-lifecycle-audit` — lib.rs does not have NeuronKit changes. No collision.

### 9. Standard anti-pattern suite

- **Unlocalized strings:** N/A — pure engine, no view or UI layer, no string literals destined for display.
- **Accessibility:** N/A — no UI.
- **Date storage:** N/A — no persistence, no date columns.
- **Bool stored properties on entities:** N/A — result types (`AssociationRule`, `MiningThresholds`) carry only numeric fields as specified.
- **Secrets:** N/A — pure math, no credentials, no API calls.
- **Deprecated vocabulary:** nothing in the mission or referenced code.
- **AI calls in FulcrumKit:** N/A — NeuronKit is not FulcrumKit.
- **Geometric layout directions (.left/.right):** N/A — no UI.

---

## Actions (proceeding order)

1. Implement `AssociationRuleMining.swift` — types + engine per Part 1 spec. Commit: `feat(ar): pairwise association-rule mining engine over MatrixO`.
2. `cd packages/kits/NeuronKit && swift build` — must exit 0 before proceeding.
3. Implement `AssociationRuleMiningTests.swift` — all seven cases per Part 2 spec. Commit: `test(ar): swift unit tests for association-rule mining`.
4. `cd packages/kits/NeuronKit && swift test` — must exit 0; record pass count (baseline 126 + new).
5. Implement `association_rule_mining.rs` + register in `lib.rs`. Include refreshed `Cargo.lock`. Commit: `feat(ar): rust port of association-rule mining with inline conformance tests`.
6. `cd packages/kits/NeuronKit/rust && cargo test` — must exit 0; record pass count (baseline 131 + new).
7. Write signal file to `/Users/bob/devlop/ddfactory/control/signals/.done-ar`.
8. Spawn Adams for post-flight.

---

## Decision needed

None.
