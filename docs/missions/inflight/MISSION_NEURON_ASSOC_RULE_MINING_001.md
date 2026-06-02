# Mission NEURON_ASSOC_RULE_MINING_001 — Pairwise Association-Rule Mining over MatrixO

## Priority: P1
## Stream: ar
## Branch from: main
## Depends on: None
## Parallel safe with: `fc`, `tl`, `fa` — except all NeuronKit-rust missions share the one-line module registration in `rust/src/lib.rs` (see Parallel note below).

---

## Context

**Tree.** This mission targets **mootx01-ce**, base branch **main**.

First symbolic-discovery reasoning function in NeuronKit. The substrate accumulates `MatrixO` on every `capture`/`mutate`/`expunge`; nothing lifts rules off it. This builds the engine that turns co-occurrence into inspectable pairwise association rules. **Tier 3 (no cap) / net-new** — all-new source files, plus the one allowed module-registration line in `rust/src/lib.rs`.

**Pairwise-only, by the shape of `MatrixO` (verified against CE source):** `MatrixO.applyRow` iterates *all* ordered `(i, j)` pairs of a row's fields **including `i == j`** (the double loop `for a in fieldValues { for b in fieldValues }`), so the diagonal is retained: `O[(f,v),(f,v)]` is single-item support and `O[(fi,vi),(fj,vj)]` is 2-itemset support. Enough for single-antecedent → single-consequent rules; NOT enough for k>2 (those need row-replay — a separate future mission).

**Two corrections vs. the council's §3 pseudocode — both confirmed against source, follow the mission not the proposal:**
1. **Single-item support comes from `MatrixO`'s diagonal, not `MatrixF`.** `MatrixF` is the field-*presence* matrix: a flat `[Int64]` of 216 cells (36 fields × 6 bits) counting per-*bit* presence (its header, cookbook §6.1). A 6-bit field value (0–63) is not one bit, so `MatrixF.count` would count bit-presence, the wrong denominator. Single-item support is `O[A,A]` off `MatrixO`'s retained diagonal.
2. **Skip the diagonal when *emitting* rules.** `MatrixO` *stores* the diagonal (that is where support comes from), but the engine must exclude `A == B` when generating rules, or every cell yields an `A → A` self-rule with confidence ≡ 1.

**Verified input contract (`SubstrateTypes/Sources/SubstrateTypes/MatrixO.swift`):**
- `CooccurrenceKey(fieldI: UInt8, valueI: UInt8, fieldJ: UInt8, valueJ: UInt8)`; `Hashable, Comparable, Sendable`; `Comparable` on `packed = fieldI<<24 | valueI<<16 | fieldJ<<8 | valueJ`. Fields/values each `< 64` (6-bit, enforced by precondition).
- `MatrixO.count(_ key: CooccurrenceKey) -> Int64` — binary search, returns 0 if absent. This is `O[A,B]`.
- `MatrixO.entries: [(key, count)]` — sorted, `public private(set)`.
- The diagonal is retained (per `applyRow` above). `O[A,A]` is real and populated.

**Pure engine**, mirroring `MMRRank`: `MatrixO` + active row count + thresholds in, ranked `[AssociationRule]` out. No estate, no clocks, no randomness. Respects B-1 (no substrate access). NeuronKit already imports `SubstrateTypes` (MMRRank does), so no `Package.swift` change.

**Deferred (not this mission):** the estate-facing wrapper that reads a live `MatrixO` through the verb surface and emits rules as `propose` rows (Brain-layer-gated, like the dreaming daemon); k>2 itemset mining; `MatrixT`-based sequential mining (`MatrixT` unpopulated — see `mt`).

## Read First
- `NeuronKit/Sources/NeuronKit/MMRRank.swift` — the pure-engine pattern to mirror.
- `NeuronKit/rust/src/mmr_rank.rs` — the Rust port + **inline** `#[cfg(test)] mod tests` pattern to mirror (line ~127). NeuronKit Rust tests are inline, not in `rust/tests/`.
- `SubstrateTypes/Sources/SubstrateTypes/MatrixO.swift` — input contract (verified above).
- `NeuronKit/Tests/NeuronKitTests/MMRRankTests.swift` — the Swift test/vector pattern to mirror.
- `NeuronKit/README.md` — B-1 and the three-question placement test (algorithm → NeuronKit).

## Conformance pattern — read this before writing tests
The council's plan specified a shared `association_rule_mining_vectors.json` in `Tests/NeuronKitTests/Vectors/` plus a `rust/tests/` conformance file. **The codebase does not work that way** (verified): there is no `Vectors/` directory, `rust/tests/` is empty, and `mmr_rank.rs` carries its tests **inline** in `#[cfg(test)] mod tests`. **Default for this mission: mirror MMRRank** — in-code enumerated vectors on both sides, inline Rust tests, no JSON file, no `rust/tests/` file. Cross-port conformance = the Swift test and the Rust inline test encode the **identical** input cases and expected outputs (floats compared with a documented tolerance). *(If a shared-vector byte-compare harness is wanted as a new NeuronKit convention, that is a deliberate, slightly larger mission — flagged for Bob, not assumed here.)*

## Blast Radius Scope
All-new source files. One existing file edited: `rust/src/lib.rs` gains a single `pub mod association_rule_mining;` line — the sanctioned module registration (the plan's "module/test registration" allowance), not a logic change. No existing symbol changed. Reads the existing `MatrixO` type; does not modify it.

## Files You Will Modify
**Created:**
- `packages/kits/NeuronKit/Sources/NeuronKit/AssociationRuleMining.swift` — result types + pure engine.
- `packages/kits/NeuronKit/Tests/NeuronKitTests/AssociationRuleMiningTests.swift` — Swift unit tests, in-code vectors.
- `packages/kits/NeuronKit/rust/src/association_rule_mining.rs` — Rust port + inline `#[cfg(test)] mod tests` (mirrors `mmr_rank.rs`).

**Edited (registration only):**
- `packages/kits/NeuronKit/rust/src/lib.rs` — add `pub mod association_rule_mining;` in alphabetical/grouped position with the existing `pub mod` lines. One line, no other change.

## Files You MUST NOT Modify
- Any `Package.swift` (new Swift sources land in the existing NeuronKit target).
- Any `SubstrateTypes` file (`MatrixO` is read-only input).
- Any existing NeuronKit source file other than the one `lib.rs` registration line.
- `docs/concepts/`. `Cargo.toml` beyond what registration requires (a new `rust/src/` module needs no `Cargo.toml` change; a deeper change → stop and document).

## Implementation Parts

### Part 1 — Result types + pure Swift engine
- `Item` — `(field: UInt8, value: UInt8)`, `Hashable/Comparable/Sendable/Codable`, `Comparable` on packed `(field<<8)|value`.
- `AssociationRule` — `antecedent: Item`, `consequent: Item`, `support`, `confidence`, `lift`, `conviction`, `leverage: Double`.
- `MiningThresholds` — `minSupport`, `minConfidence: Double`.
- Public `mineAssociationRules(matrix: MatrixO, activeRowCount: Int64, thresholds:) -> [AssociationRule]` delegating to `internal enum AssociationRuleEngine`.

Metrics (`N` = `activeRowCount`; `O[X,Y]` = `matrix.count(CooccurrenceKey(fieldI: X.field, valueI: X.value, fieldJ: Y.field, valueJ: Y.value))`):
- `support(A,B) = O[A,B]/N`
- `confidence(A→B) = O[A,B]/O[A,A]`
- `lift = (O[A,B]·N)/(O[A,A]·O[B,B])`
- `leverage = O[A,B]/N − (O[A,A]/N)(O[B,B]/N)`
- `conviction = (1 − O[B,B]/N)/(1 − confidence)`, `+inf` when `confidence == 1`.

Invariants (documented in-code): relies on `MatrixO` retaining the diagonal (`O[A,A]` = single-item support — verified); `N` is injected, never derived internally.
Edge cases: `N <= 0` → `[]`; `O[A,A] == 0` skip antecedent; `O[B,B] == 0` skip consequent; `A == B` (diagonal) excluded from emission; below-threshold dropped.
Ordering (conformance-critical): sort by `(antecedent, consequent)` ascending on packed key; the pair is unique so no residual ties. This guarantees identical Swift/Rust emission order.

**Commit:** `feat(ar): pairwise association-rule mining engine over MatrixO`
→ verify: `cd packages/kits/NeuronKit && swift build`; run the pre-commit checklist.

### Part 2 — Swift tests (in-code vectors, mirroring MMRRankTests)
Hand-checked cases: empty matrix → `[]`; single co-occurring pair with all five metrics; `confidence == 1` → `conviction == +inf`; threshold gating (one passes, one dropped); `N == 0` → `[]`; diagonal-only (single item, no co-occurrence) → `[]`; an ordering case asserting the exact emitted sequence. Encode inputs and expected outputs in-code; assert equality (ordered; floats with a documented tolerance).

**Commit:** `test(ar): swift unit tests for association-rule mining`
→ verify: `cd packages/kits/NeuronKit && swift test 2>&1 | tail -20` exits 0.

### Part 3 — Rust port + inline conformance tests
Mirror the engine in `association_rule_mining.rs` (same formulas, edge cases, packed-key ordering, `f64`). Carry the conformance tests **inline** in `#[cfg(test)] mod tests` (as `mmr_rank.rs` does), encoding the **same** input cases and expected outputs as the Swift tests. Register the module with one `pub mod association_rule_mining;` line in `rust/src/lib.rs`. Neither port leads.

**Commit:** `feat(ar): rust port of association-rule mining with inline conformance tests`
→ verify: `cd packages/kits/NeuronKit/rust && cargo test` exits 0.

## Test Requirements
Five metrics on hand-checked matrices; threshold gating on support and confidence; all edge cases; deterministic ordering; the Swift and Rust suites assert the identical enumerated cases and expected values.

## Test Verification Log

### Baseline (mission start)
- Pass count at mission start (NeuronKit `swift test` and `cargo test`): NNN (must exit 0; else STOP, write `.stuck`).

### Final
- Commands: `cd packages/kits/NeuronKit && swift test 2>&1 | tail -20`; `cd packages/kits/NeuronKit/rust && cargo test`
- Exit code: 0 (both)
- Pass count: NNN (≥ baseline + new)
- Tail output (verbatim): …

## Verification
`swift build`/`swift test` green in NeuronKit; `cargo test` green; the two ports assert matching cases. Run self-review against the BRR's MUST_UPDATE list (here: the created-files list plus the one `lib.rs` registration line). Spawn Adams for post-flight: net-new plus one registration line only; no edits to existing logic; no orphan code; no stale comments; `MatrixO` unmodified.

## Success Criteria
1. Pure, deterministic engine: `MatrixO` + active row count → rules with all five metrics.
2. Output ordering fully specified and stable (packed-key ascending).
3. Rust port matches the Swift port on every enumerated case (inline conformance, mirroring MMRRank).
4. Zero edits to existing code except the single `lib.rs` module-registration line; `MatrixO` unchanged.
5. Single-item support taken from `MatrixO`'s diagonal (not `MatrixF`); diagonal excluded from rule emission.
6. Estate wrapper and `propose` emission documented as a Brain-layer-gated follow-on, not attempted.

## Non-goal / deferred
Estate-facing wrapper (reads live `MatrixO` via the verb surface, emits `propose` rows, Brain-layer-gated like the dreaming daemon); k>2 itemset mining (needs row-replay); `MatrixT`-based sequential mining (`MatrixT` unpopulated — see the `mt` scout); a shared-vector JSON conformance harness (a separate convention decision).

## Parallel note (lib.rs registration)
`ar` and `fa` are independent in logic and add disjoint source files, but **both add a one-line `pub mod` registration to `rust/src/lib.rs`.** That is the sole overlap. Reserve `rust/src/lib.rs` on both missions so the dispatcher serializes just that write (they otherwise run independently); or accept a trivial one-line merge if run truly concurrently. Reservation is the cleaner default.

## Signal File
Write to: `/Users/bob/devlop/ddfactory/control/signals/.done-ar`
