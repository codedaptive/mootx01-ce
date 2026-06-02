# Blast Radius Report — NEURON_ASSOC_RULE_MINING_001 (pairwise association-rule mining)

Mission: `docs/missions/inflight/MISSION_NEURON_ASSOC_RULE_MINING_001.md`
Stream: ar · Branch: `stream/ar-assoc-rule-mining`
Baseline commit: `4ef8a05` (chore: gitignore .codegraph; GeniusLocus arch spec + CognitionKit interface/spec v0.85)
Tier: **net-new (no cap)** — all-new source files plus the one sanctioned
module-registration line in `rust/src/lib.rs`. No existing symbol modified,
renamed, removed, deprecated, or semantically altered.

## Status: PROCEED — no RESCOPE required

## Baseline test counts (this branch @ `4ef8a05`, captured at mission start)

- NeuronKit Swift `swift test`: **126 tests in 16 suites, all passed, exit 0**.
- NeuronKit Rust `cargo test`: **131 passed, 0 failed, exit 0**.

## MUST_UPDATE list

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `packages/kits/NeuronKit/Sources/NeuronKit/AssociationRuleMining.swift` | yes (CREATE) | result types + pure engine | MUST_UPDATE (new) |
| `packages/kits/NeuronKit/Tests/NeuronKitTests/AssociationRuleMiningTests.swift` | yes (CREATE) | Swift unit tests, in-code vectors | MUST_UPDATE (new) |
| `packages/kits/NeuronKit/rust/src/association_rule_mining.rs` | yes (CREATE) | Rust port + inline `#[cfg(test)] mod tests` | MUST_UPDATE (new) |
| `packages/kits/NeuronKit/rust/src/lib.rs` | yes (registration only) | one `pub mod association_rule_mining;` line | MUST_UPDATE (1-line registration) |
| `packages/kits/NeuronKit/rust/Cargo.lock` | **no** | lockfile refresh forced by environment (see below) | MUST_UPDATE (forced, no manifest change) |

### Cargo.lock note (forced, not scope creep)

The committed `rust/Cargo.lock` is stale relative to the current path-crate
manifests (sibling-crate dependency drift landed without a lockfile refresh).
The mission-start baseline `cargo test` run regenerated it before any code
of this mission existed. No version pin and no `Cargo.toml` is changed by
this mission; the refreshed lock is carried in the Rust commit so the
worktree ends clean. Verified: `cargo test` exits 0 with the refreshed lock.

## Symbols changed

**None.** This mission changes no existing symbol. New public symbols added
(all net-new, no prior references anywhere):

- `Item` — `(field: UInt8, value: UInt8)`, `Hashable/Comparable/Sendable/Codable`,
  `Comparable` on packed `(field<<8)|value`.
- `AssociationRule` — antecedent, consequent, support, confidence, lift,
  conviction, leverage.
- `MiningThresholds` — `minSupport`, `minConfidence`.
- `mineAssociationRules(matrix:activeRowCount:thresholds:)` → `[AssociationRule]`,
  delegating to `internal enum AssociationRuleEngine`.
- Rust mirrors in `association_rule_mining.rs` (same shapes, `f64`).

## Read-only inputs (verified against source, unmodified)

- `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MatrixO.swift` —
  `CooccurrenceKey` (packed u32 ordering, 6-bit preconditions),
  `MatrixO.count(_:) -> Int64` (binary search, 0 if absent), `entries`
  sorted `public private(set)`. `applyRow` iterates ordered pairs
  **including i == j** — the diagonal is retained, so `O[A,A]` is real
  single-item support.
- `packages/libs/SubstrateTypes/rust/src/matrix_o.rs` — Rust mirror with the
  same surface (`CooccurrenceKey::new`, `count`, `entries()`, `apply_row`
  including the diagonal). `neuron-kit` already depends on `substrate-types`
  (Cargo.toml: `substrate-types = { path = "../../../libs/SubstrateTypes/rust" }`),
  and NeuronKit's Swift target already depends on `SubstrateTypes`
  (Package.swift line 85), so **no manifest change is needed on either side**.

## Files NOT touched (mission's MUST-NOT list, confirmed)

- Any `Package.swift` — NeuronKit already imports SubstrateTypes.
- Any `SubstrateTypes` file — `MatrixO` is read-only input.
- Any existing NeuronKit source other than the one `lib.rs` registration line.
- `docs/concepts/`, `Cargo.toml`.

## Prior art / conflict scan

- No `AssociationRule`, `MiningThresholds`, `mineAssociationRules`,
  `association_rule_mining` symbol exists anywhere in the repo (grep clean).
- `Item` as a new public NeuronKit type: no existing `Item` type in the
  NeuronKit module (Swift) or `neuron_kit` crate (Rust) to collide with.
- Parallel-stream overlap: missions `ar` and `fa` both add one `pub mod`
  line to `rust/src/lib.rs` (sole overlap, per mission Parallel note).
  This worktree holds the `ar` line only; merge is a trivial one-line union
  if `fa` lands concurrently.

## Conformance pattern (per mission, verified against codebase)

Mirror MMRRank: in-code enumerated vectors on both sides, inline Rust tests
in `#[cfg(test)] mod tests` (as `mmr_rank.rs` line 127 does), no JSON vector
file, no `rust/tests/` file. Swift and Rust suites encode identical inputs
and expected outputs; floats compared with documented tolerance.

## RESCOPE_REQUIRED items

None.
