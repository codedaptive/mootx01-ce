# Mission NEURON_BOUNDED_FCA_001 — Bounded Formal Concept Analysis over a Materialized FormalContext

## Priority: P2
## Stream: fa
## Branch from: main
## Depends on: None
## Parallel safe with: `fc`, `tl`, `ar` — except `ar` and `fa` share the one-line module registration in `rust/src/lib.rs` (see Parallel note).

---

## Context

**Tree.** This mission targets **mootx01-ce**, base branch **main**.

Formal Concept Analysis adds explainable attribute-closure structure over the substrate's typed attributes — distinct from Louvain (graph communities), NMF (soft themes), and Hamming recall (nearby fingerprints). FCA finds *exact* attribute closures and the concepts that emerge from observed data rather than the authored taxonomy. **Tier 3 (no cap) / net-new** — all-new source files, plus the one allowed module-registration line in `rust/src/lib.rs`. Pure engine, conformance-gated, Swift + Rust.

**Two corrections vs. the council's §4 — follow the mission, not the proposal:**
1. **Drop or sample `stabilityEstimate`.** Concept stability (Kuznetsov) is the fraction of extent subsets yielding the same intent — **exponential** to compute exactly. Computing it as written reintroduces the exponential cost the bounding exists to kill. v1: **omit** stability, or compute a **sampled** estimate with an explicit, fixed, seeded sample budget — never exact subset enumeration.
2. **FCA is estate-coupled.** It needs per-row attribute sets (`attributesForRow`), a row-level scan, unlike `ar` which needs only `MatrixO`. The **pure engine therefore takes a fully-materialized `FormalContext` as input**; building that context from the estate (which rows carry which `(field,value)` attributes) is the coupled part and is **deferred** to a seam/wrapper (Brain-layer pattern), NOT in this mission. The pure engine reads no estate and no `MatrixO` — it is self-contained bitset closure operators over a given context.

**Conformance pattern (verified, same as `ar`):** NeuronKit uses inline Rust `#[cfg(test)] mod tests` + in-code vectors, NOT a shared `fca_vectors.json` in a `Tests/Vectors/` dir or a `rust/tests/fca_conformance.rs` file — neither exists in the codebase. `fa` mirrors MMRRank, matching `ar`'s style A. *(The plan's `fca_vectors.json` + `rust/tests/` conformance file do not match the codebase; corrected here. A shared-vector harness remains a separate convention decision.)*

**Verified (CE source):** net-new — no `FormalConcept`/`FormalContext`/`BoundedConceptMiner`/`FormalAttribute` exists anywhere in NeuronKit; both target files absent. `rust/src/lib.rs` is the registration point (25 `pub mod` lines today; `fa` adds one). NeuronKit already builds its targets; no `Package.swift` change.

## Read First
- `NeuronKit/Sources/NeuronKit/MMRRank.swift` — the pure-engine pattern to mirror.
- `NeuronKit/rust/src/mmr_rank.rs` — the inline `#[cfg(test)] mod tests` conformance pattern (NeuronKit Rust tests are inline, not in `rust/tests/`).
- `NeuronKit/Tests/NeuronKitTests/MMRRankTests.swift` — the Swift test pattern.
- `LocusKit/Adjectives.swift` — the `(field,value)` attribute space the **deferred wrapper** will build a context from (reference only; NOT imported by the pure engine).
- `NeuronKit/README.md` — B-1 and the three-question placement test (algorithm → NeuronKit).

## Blast Radius Scope
All-new source files. One existing file edited: `rust/src/lib.rs` gains a single `pub mod formal_concept_analysis;` line — the sanctioned module registration, not a logic change. No existing symbol changed. The pure engine reads no existing type.

## Files You Will Modify
**Created:**
- `packages/kits/NeuronKit/Sources/NeuronKit/FormalConceptAnalysis.swift` — `FormalAttribute`, `FormalConcept`, `FormalContext`, `BoundedConceptMiner`.
- `packages/kits/NeuronKit/Tests/NeuronKitTests/FormalConceptAnalysisTests.swift` — Swift unit tests, in-code vectors.
- `packages/kits/NeuronKit/rust/src/formal_concept_analysis.rs` — Rust port + inline `#[cfg(test)] mod tests`.

**Edited (registration only):**
- `packages/kits/NeuronKit/rust/src/lib.rs` — add `pub mod formal_concept_analysis;` in grouped position. One line, no other change.

## Files You MUST NOT Modify
- Any `Package.swift` (new Swift sources land in the existing NeuronKit target).
- Any existing NeuronKit source file other than the one `lib.rs` registration line.
- `SubstrateTypes`/`LocusKit` files (`Adjectives.swift` is reference-only, not imported).
- `docs/concepts/`. `Cargo.toml` beyond what registration requires.

## Implementation Parts

### Part 1 — FormalContext + closure operators (pure)
- `FormalAttribute` — `(namespace, key, value)`, `Hashable/Codable/Sendable/Comparable` (for deterministic ordering).
- `RowID` — a context-local row index (`UInt32`); the materialized context assigns 0-based indices, keeping the engine port-neutral and the conformance vectors language-agnostic. (The deferred wrapper maps estate row identifiers → indices.)
- `FormalConcept` — `extent: [RowID]` (sorted), `intent: [FormalAttribute]` (sorted), `support: Int`, optional sampled `stability: Double?`.
- `FormalContext` — attribute and row bitsets; `extent(of intent)` = bitset intersection of attribute rows; `intent(of extent)` = attribute bitset intersection across rows; `closure(of intent)` = `intent(extent(intent))`.
- Determinism: all sets materialized to sorted arrays at the boundary; iteration order fixed.

**Commit:** `feat(fa): formal context + closure operators (bitset-backed)`
→ verify: `cd packages/kits/NeuronKit && swift build`; run the pre-commit checklist.

### Part 2 — Bounded concept miner
`BoundedConceptMiner(minSupport, maxIntentSize, maxConcepts)`:
- Seed from frequent single attributes (support ≥ `minSupport`).
- For each seed, take `closure([seed])`; skip if `|intent| > maxIntentSize` or `|extent| < minSupport`.
- Optional sampled stability (fixed seeded budget) — or omit in v1.
- Deduplicate by intent; sort by support desc, then intent size asc, then a stable intent key; truncate to `maxConcepts`.
- No full lattice enumeration anywhere; no exact-stability subset enumeration.

**Commit:** `feat(fa): bounded concept miner with support/intent/concept caps`
→ verify: `cd packages/kits/NeuronKit && swift build`; run the pre-commit checklist.

### Part 3 — Swift tests (in-code vectors, mirroring MMRRankTests)
Cases: empty context → `[]`; two clearly distinct cohorts → their two concepts, correctly ordered; closure idempotence (`closure(closure(x)) == closure(x)`); a `maxIntentSize` cap excluding an over-large concept; a `maxConcepts` truncation; (if stability included) sampled estimate deterministic for a fixed seed. Encode inputs and expected outputs in-code.

**Commit:** `test(fa): swift unit tests for bounded FCA`
→ verify: `cd packages/kits/NeuronKit && swift test 2>&1 | tail -20` exits 0.

### Part 4 — Rust port + inline conformance
Mirror the engine in `formal_concept_analysis.rs` (same closure operators, caps, ordering, and sampled-stability-or-omit decision). Carry conformance tests inline in `#[cfg(test)] mod tests` (as `mmr_rank.rs` does), encoding the **same** cases as the Swift tests. Register `pub mod formal_concept_analysis;` in `rust/src/lib.rs`. Neither port leads.

**Commit:** `feat(fa): rust port of bounded FCA with inline conformance tests`
→ verify: `cd packages/kits/NeuronKit/rust && cargo test` exits 0.

## Test Requirements
Closure idempotence; both caps (`maxIntentSize`, `maxConcepts`) enforced; deterministic concept ordering; the Swift and Rust suites assert the identical enumerated cases; if stability is included, the sampled estimate is deterministic for a fixed seed.

## Test Verification Log

### Baseline (mission start, branch @ `8cad620`)
- NeuronKit `swift test`: exit 0 — **138 tests in 17 suites, all passed**.
- NeuronKit `cargo test`: exit 0 — **143 passed; 0 failed**.

### Final
- Commands: `cd packages/kits/NeuronKit && swift test 2>&1 | tail -20`; `cd packages/kits/NeuronKit/rust && cargo test`
- Exit code: 0 (both) — independently re-run and verified by Adams post-flight.
- Pass count: Swift **152 tests in 18 suites** (baseline 138 + 14 new); Rust **157 passed; 0 failed** (baseline 143 + 14 new).
- Swift tail (verbatim): `􁁛  Test run with 152 tests in 18 suites passed after 0.016 seconds.`
- Rust result line (verbatim): `test result: ok. 157 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s`
- New-module filter run: `cargo test formal_concept_analysis` → `14 passed; 0 failed; ... 143 filtered out`, exit 0.

## Verification
`swift build`/`swift test` green both ports; `cargo test` green; the two ports assert matching cases. Run self-review against the BRR's MUST_UPDATE list (created files plus the one `lib.rs` registration line). Spawn Adams for post-flight: net-new plus one registration line only; no full-lattice enumeration; stability omitted or explicitly sampled (no exponential path); no existing logic edited.

## Success Criteria
1. Pure, deterministic bounded-FCA engine over a materialized `FormalContext`.
2. No exponential operation (no full lattice; stability omitted or sampled with a fixed budget).
3. Rust port matches the Swift port on every enumerated case (inline conformance, mirroring MMRRank).
4. Zero edits to existing code except the single `lib.rs` registration line; concept value types live in NeuronKit (first consumer); no persisted concept nouns.
5. Estate → context construction documented as a deferred seam, not attempted.

## Non-goal / deferred
Estate → context construction (`attributesForRow` row-scan, Brain-layer-gated seam); full concept-lattice enumeration; exact Kuznetsov stability; persisted formal-concept nouns; a shared-vector JSON conformance harness (separate convention decision).

## Parallel note (lib.rs registration)
`fa` and `ar` both add a one-line `pub mod` registration to `rust/src/lib.rs` — the sole overlap. Reserve `rust/src/lib.rs` on both missions so the dispatcher serializes just that write; or accept a trivial one-line merge if run truly concurrently. Reservation is the cleaner default.

## Signal File
Write to: `/Users/bob/devlop/ddfactory/control/signals/.done-fa`
