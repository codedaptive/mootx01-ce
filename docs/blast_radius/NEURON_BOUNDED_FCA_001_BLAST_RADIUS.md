# Blast Radius Report — NEURON_BOUNDED_FCA_001 (bounded formal concept analysis)

Mission: `docs/missions/inflight/MISSION_NEURON_BOUNDED_FCA_001.md`
Stream: fa · Branch: `stream/fa-bounded-fca`
Baseline commit: `8cad620` (merge: TASK-MXC-2026-0036 — NEURON ASSOC RULE MINING 001)
Tier: **net-new (no cap)** — all-new source files plus the one sanctioned
module-registration line in `rust/src/lib.rs`. No existing symbol modified,
renamed, removed, deprecated, or semantically altered.

## Status: PROCEED — no RESCOPE required

## Baseline test counts (this branch @ `8cad620`, captured at mission start)

- NeuronKit Swift `swift test`: **138 tests in 17 suites, all passed, exit 0**.
- NeuronKit Rust `cargo test`: **143 passed, 0 failed, exit 0**.

## MUST_UPDATE list

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `packages/kits/NeuronKit/Sources/NeuronKit/FormalConceptAnalysis.swift` | yes (CREATE) | `FormalAttribute`, `RowID`, `FormalConcept`, `FormalContext`, `BoundedConceptMiner` | MUST_UPDATE (new) |
| `packages/kits/NeuronKit/Tests/NeuronKitTests/FormalConceptAnalysisTests.swift` | yes (CREATE) | Swift unit tests, in-code vectors | MUST_UPDATE (new) |
| `packages/kits/NeuronKit/rust/src/formal_concept_analysis.rs` | yes (CREATE) | Rust version + inline `#[cfg(test)] mod tests` | MUST_UPDATE (new) |
| `packages/kits/NeuronKit/rust/src/lib.rs` | yes (registration only) | one `pub mod formal_concept_analysis;` line | MUST_UPDATE (1-line registration) |

No `Cargo.lock` churn expected: the `ar` mission's lockfile refresh already
landed at baseline (`8cad620`); the mission-start baseline `cargo test` run
left the worktree clean (verified: `git status` shows only the mission file).

## Symbols changed

**None.** This mission changes no existing symbol. New public symbols added
(all net-new, prior-art grep clean — no `FormalConcept`, `FormalContext`,
`BoundedConceptMiner`, `FormalAttribute`, or `formal_concept` anywhere in
`packages/` Swift or Rust source):

- `FormalAttribute` — `(namespace, key, value)` strings,
  `Hashable/Codable/Sendable/Comparable` (lexicographic, for deterministic
  ordering).
- `RowID` — context-local 0-based row index (`UInt32` / `u32`).
- `FormalConcept` — `extent: [RowID]` (sorted), `intent: [FormalAttribute]`
  (sorted), `support: Int`, `stability: Double?` (**always `nil` in v1** —
  computation omitted per mission correction #1; the optional field carries
  the type shape so a future sampled estimator is non-breaking).
- `FormalContext` — materialized attribute/row bitsets; `extent(of:)`,
  `intent(of:)`, `closure(of:)`.
- `BoundedConceptMiner(minSupport:maxIntentSize:maxConcepts:)` → `mine(context:)`.
- Rust mirrors in `formal_concept_analysis.rs` (same shapes).

## Estate coupling — none (mission correction #2)

The pure engine takes a fully-materialized `FormalContext` as input. It reads
**no estate, no `MatrixO`, no `Adjectives.swift`** — `LocusKit/Adjectives.swift`
is reference-only for the *deferred* estate→context wrapper (Brain-layer
seam, NOT in this mission). The engine imports nothing beyond the standard
library on either leg.

## Bounding guarantees (mission correction #1)

- **No full lattice enumeration**: concepts are seeded only from frequent
  single attributes; one closure per seed; dedup by intent.
- **No exact Kuznetsov stability**: v1 omits stability computation entirely
  (the `Double?` field stays `nil`). No subset enumeration exists anywhere.
- Complexity: O(|attributes| × closure-cost), closure-cost = bitset
  intersections — polynomial, no exponential path.

## Files NOT touched (mission's MUST-NOT list, confirmed)

- Any `Package.swift` — new Swift source lands in the existing NeuronKit target.
- Any existing NeuronKit source other than the one `lib.rs` registration line.
- `SubstrateTypes`/`LocusKit` files (`Adjectives.swift` reference-only, not imported).
- `docs/concepts/`; `Cargo.toml` (registration requires no manifest change).

## Prior art / conflict scan

- Symbol grep clean (above). Both target files absent at baseline (verified).
- `rust/src/lib.rs` has 26 `pub mod` lines at baseline including
  `pub mod association_rule_mining;` (the `ar` stream already merged);
  `fa` adds line 27. The ar/fa parallel-write hazard flagged in the mission
  is **moot in this worktree**: `ar` is already in `main` at baseline, so the
  one-line registration no longer collides.
- The `ar` mission's deferred crate-root re-export note applies here too:
  the `lib.rs` edit is constrained to exactly one `pub mod` line (Success
  Criterion 4); no `pub use` re-export is added.

## Conformance pattern (per mission, verified against codebase)

Mirror MMRRank / association_rule_mining: in-code enumerated vectors on both
sides, inline Rust tests in `#[cfg(test)] mod tests` (as `mmr_rank.rs` does),
no JSON vector file, no `rust/tests/` file. Swift and Rust suites encode
identical inputs and expected outputs; all values here are exact integers and
sorted arrays — no float tolerance needed (stability omitted).

## RESCOPE_REQUIRED items

None.
