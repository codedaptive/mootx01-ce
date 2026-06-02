# Post-Flight Report — NEURON_ASSOC_RULE_MINING_001

**Reviewer:** Adams
**Date:** 2026-06-01
**Branch:** `stream/ar-assoc-rule-mining`
**Baseline:** `4ef8a05`
**Commits reviewed:** `ac3c042`, `8021379`, `0e6716d`, `cdd6234`, `f330eed`
**Punch-list commit:** `2f3a2e1`

---

## Final Status: PASS

---

## First Pass Findings

| # | Severity | Finding | File:Line | Resolution | Status |
|---|---|---|---|---|---|
| 1 | WARNING | `mine_association_rules`, `Item`, `AssociationRule`, `MiningThresholds` not re-exported from crate root. `mmr_rank` (the stated mirror) IS re-exported (`pub use mmr_rank::{mmr_rank, mmr_select}`). External consumers must use the full path `neuron_kit::association_rule_mining::*` — the crate root shorthand pattern is broken for this module. | `rust/src/lib.rs:49` | Add `pub use association_rule_mining::{mine_association_rules, Item, AssociationRule, MiningThresholds};` below the `pub mod` line, matching the mmr_rank pattern. | DEFERRED — mission text explicitly prohibits a second lib.rs line (coordination constraint, `ar`+`fa` streams share that file; dispatcher serializes the single-line write). The mission MUST overrides the advisory. Recorded as Outstanding in completion report for trivial batch with `fa` stream registration. |
| 2 | WARNING | `AssociationRuleEngine::mine` (Swift, 71 lines) and `mine_association_rules` (Rust, 78 lines) both exceed the 40-line advisory threshold. No inline comment explains the length. The two-pass structure (diagonal extraction then rule emission) is readable and the comments are clear, but the length advisory requires either a refactor or an explicit justification comment. | `AssociationRuleMining.swift:162-233`, `association_rule_mining.rs:117-195` | Either extract `buildSingleSupport` as a private helper, or add a one-line comment at the function top explaining the two-pass structure justifies the length. Adams accepts either. | CLOSED — commit `2f3a2e1` added the justification comment to both ports. Comment names the specific reason (conformance-critical control flow readability across both ports). Satisfies the advisory. |

---

## Blast Radius Verification

**Files claimed in BRR:** 5 (3 created, 1 edited, 1 forced Cargo.lock refresh)
**Files actually in diff:** 8 total — 5 code/infra + 3 docs (mission, preflight, BRR) — fully accounted for.

| BRR MUST_UPDATE file | In diff? | Notes |
|---|---|---|
| `packages/kits/NeuronKit/Sources/NeuronKit/AssociationRuleMining.swift` | Yes | Created |
| `packages/kits/NeuronKit/Tests/NeuronKitTests/AssociationRuleMiningTests.swift` | Yes | Created |
| `packages/kits/NeuronKit/rust/src/association_rule_mining.rs` | Yes | Created |
| `packages/kits/NeuronKit/rust/src/lib.rs` | Yes | One-line `pub mod` registration only — confirmed by diff |
| `packages/kits/NeuronKit/rust/Cargo.lock` | Yes | Lockfile refresh documented in BRR |

**MUST_UPDATE files missing from diff:** none.

**Out-of-scope files in diff:** none. MatrixO.swift, matrix_o.rs, Package.swift unmodified — verified.

**Cargo.lock scope note:** The BRR describes this as "path-crate dependency drift at baseline." The actual change is 614 → 1371 lines (more than doubled). New entries include `tokio`, `postgres`, `rusqlite`, `rand`, `sqlite-vec` — these are transitive from pre-existing path dependencies (genius-locus-kit, persistence-kit), not introduced by this mission's code. Cargo.toml is byte-identical to baseline. Cargo test exits 0. The BRR's framing is accurate in fact (no version pin, no manifest change) but understates the scale. No action required; noted for transparency.

**Prohibited patterns (bridges, shims, orphan deprecations):** none found. Grep clean across all three new files.

---

## Scope Verification

**Mission "Files You MUST NOT Modify"** — all respected:
- Any `Package.swift` — unmodified.
- Any `SubstrateTypes` file — unmodified.
- Any existing NeuronKit source other than the one `lib.rs` line — unmodified.
- `docs/concepts/`, `Cargo.toml` — unmodified.

**Commit order matches mission Parts:** feat(engine) → test(swift) → feat(rust). Correct.

---

## Test Execution Verification

**Method:** B (re-run — engine code modified)

**Swift:**
- Bilby's claim: 138 tests in 17 suites, exit 0.
- Adams re-run: `cd packages/kits/NeuronKit && swift test` → 138 tests in 17 suites, all passed, exit 0.
- Status: **VERIFIED.**

**Rust:**
- Bilby's claim: 143 passed, 0 failed, exit 0.
- Adams re-run: `cd packages/kits/NeuronKit/rust && cargo test` → 143 passed, 0 failed, exit 0.
- Status: **VERIFIED.**

Suite count delta: +12 Swift tests, +12 Rust tests — exactly the expected addition (9 test functions in each suite × 1 new suite = 9, but both sides have 12 because each has 9 core tests plus the two-threshold-gate tests and the two-N-guard tests each). Count matches Bilby's claim on both sides.

---

## Formula and Logic Audit

All five metrics verified against mission spec, hand-computed fixtures, and engine code:

| Metric | Formula | Swift impl | Rust impl | Status |
|---|---|---|---|---|
| support | O[A,B]/N | `countAB / n` | `count_ab / n` | CLEAN |
| confidence | O[A,B]/O[A,A] | `countAB / Double(countAA)` | `count_ab / (count_aa as f64)` | CLEAN |
| lift | (O[A,B]·N)/(O[A,A]·O[B,B]) | `(countAB * n) / (Double(countAA) * Double(countBB))` | `(count_ab * n) / ((count_aa as f64) * (count_bb as f64))` | CLEAN |
| leverage | O[A,B]/N − (O[A,A]/N)(O[B,B]/N) | `countAB/n - (Double(countAA)/n)*(Double(countBB)/n)` | `count_ab/n - ((count_aa as f64)/n)*((count_bb as f64)/n)` | CLEAN |
| conviction | (1−O[B,B]/N)/(1−conf) or +inf | `if confidence == 1.0 { .infinity } else { (1.0 - Double(countBB)/n) / (1.0 - confidence) }` | same pattern, `f64::INFINITY` | CLEAN |

**Edge cases:**
- N <= 0 → `[]`: CLEAN on both sides.
- O[A,A] == 0 skip antecedent: CLEAN. MatrixO drops zero cells so no false-positive here.
- O[B,B] == 0 skip consequent: CLEAN.
- A == B (diagonal) excluded from emission: CLEAN. Guard is field-and-value equality, not struct pointer equality.
- confidence == 1.0 → +inf conviction: CLEAN. Explicit branch on both sides.
- NaN path analysis: MatrixO drops zero cells → countAB > 0 in Pass 2 → confidence > 0 always. The only singularity (confidence == 1.0 making denominator zero) is explicitly handled. No NaN reachable. CLEAN.

**Ordering claim:** `entries` is sorted by `CooccurrenceKey.packed` ascending (verified against MatrixO.swift). CooccurrenceKey.packed layout = `fieldI<<24 | valueI<<16 | fieldJ<<8 | valueJ`, so iteration order is lexicographic on `(antecedent.packed, consequent.packed)`. The Rust `Item` derives `Ord` over `(field, value)` in declaration order, which is identical to `packed()` ordering for u8 fields. No explicit sort needed — and none is present in either engine. CLEAN.

**Single-item support source:** Pass 1 reads exclusively from diagonal cells (fieldI==fieldJ && valueI==valueJ). Not from MatrixF. CLEAN — mission's correction #1 honored.

**Diagonal exclusion from emission:** Pass 2 skips any entry where antecedent == consequent. CLEAN — mission's correction #2 honored.

**N injection:** Both engines accept activeRowCount as a parameter and never derive it from the matrix. CLEAN.

---

## Conformance Cross-Check (Swift vs Rust)

Case-by-case comparison of Swift `AssociationRuleMiningTests` vs Rust `association_rule_mining::tests`:

| Case | Swift test name | Rust test name | Fixture identical? | Expected values identical? |
|---|---|---|---|---|
| 1 | `emptyMatrixYieldsNoRules` | `empty_matrix_yields_no_rules` | Yes (MatrixO::new(), N=10) | Yes (isEmpty) |
| 2 | `singlePairAllFiveMetrics` | `single_pair_all_five_metrics` | Yes (N=4, 2×AB, 1×A, 1×B) | Yes (all 5 metrics, tolerance 1e-12) |
| 3 | `confidenceOneYieldsInfiniteConviction` | `confidence_one_yields_infinite_conviction` | Yes (main fixture, N=10) | Yes (C→A rule, conf 1.0, +inf) |
| 4a | `minSupportGates` | `min_support_gates` | Yes (main fixture, threshold 0.3/0) | Yes ([A→B, B→A]) |
| 4b | `minConfidenceGates` | `min_confidence_gates` | Yes (main fixture, threshold 0/0.6) | Yes ([B→A, C→A]) |
| 5a | `zeroActiveRowCountYieldsNoRules` | `zero_active_row_count_yields_no_rules` | Yes | Yes (isEmpty) |
| 5b | `negativeActiveRowCountYieldsNoRules` | `negative_active_row_count_yields_no_rules` | Yes (N=-5) | Yes (isEmpty) |
| 6 | `diagonalOnlyYieldsNoRules` | `diagonal_only_yields_no_rules` | Yes (1×A, N=1) | Yes (isEmpty) |
| 7a | `missingAntecedentSupportSkips` | `missing_antecedent_support_skips` | Yes (manual O[A,B]=2, no diagonals) | Yes (isEmpty) |
| 7b | `missingConsequentSupportSkips` | `missing_consequent_support_skips` | Yes (O[A,A]=2, O[A,B]=2, no O[B,B]) | Yes (isEmpty) |
| 8 | `emissionOrderIsPackedKeyAscending` | `emission_order_is_packed_key_ascending` | Yes (main fixture) | Yes ([A→B, A→C, B→A, C→A], full metric sweep) |
| 9 | `twoRunsAreIdentical` | `two_runs_are_identical` | Yes | Yes (first == second) |

Conformance: **12/12 cases matched.** Tolerance 1e-12 on both sides.

---

## Fixture Arithmetic Audit (Hand-Check)

Main fixture N=10: 4×{A,B}, 2×{A,C}, 2×{B}, 1×{A}, 1×{}
- O[A,A] = 4+2+1 = 7 ✓
- O[B,B] = 4+2 = 6 ✓
- O[C,C] = 2 ✓
- O[A,B] = O[B,A] = 4 ✓
- O[A,C] = O[C,A] = 2 ✓
- O[B,C] absent ✓

A→B: sup 4/10=0.4, conf 4/7, lift (4·10)/(7·6)=40/42, lev 4/10−(7/10)(6/10)=−0.02, conv (1−6/10)/(1−4/7)=0.4/(3/7). All ✓.
A→C: sup 2/10, conf 2/7, lift (2·10)/(7·2)=20/14, lev 2/10−(7/10)(2/10)=0.06, conv (1−2/10)/(1−2/7)=0.8/(5/7). All ✓.
B→A: sup 4/10, conf 4/6, lift 40/42 (same as A→B by symmetry), lev −0.02, conv (1−7/10)/(1−4/6)=0.3/(1/3). All ✓.
C→A: sup 2/10, conf 2/2=1 → conviction +inf, lift 20/14, lev 2/10−(2/10)(7/10)=0.06. All ✓.

Single-pair fixture (test 2): O[A,A]=3, O[B,B]=3, O[A,B]=O[B,A]=2, N=4.
A→B and B→A (symmetric): sup 2/4=0.5, conf 2/3, lift (2·4)/(3·3)=8/9, lev 2/4−(3/4)(3/4)=−0.0625, conv (1−3/4)/(1−2/3)=0.25/(1/3)=0.75. All ✓.

---

## Commit Identity

All five commits: `Bilby <bilby@codedaptive>`. Correct per commit-identity spec.

---

## Anti-Pattern Suite

- Prohibited patterns (bridges, shims, `@available(*,deprecated)`, TODO, FIXME): none found.
- Unlocalized strings: N/A — pure engine.
- Accessibility: N/A — no UI.
- Secrets: N/A — pure math.
- Deprecated vocabulary: none.
- Bool stored properties on entities: none. `AssociationRule` and `MiningThresholds` carry only numeric fields.
- AI calls: none — pure deterministic engine, no ML runtime.

---

## Mission Correctness Criteria Audit

1. Pure, deterministic engine: MatrixO + active row count → rules with all five metrics. **MET.**
2. Output ordering fully specified and stable (packed-key ascending). **MET.** No explicit sort; entries() order guarantees it.
3. Rust port matches Swift port on every enumerated case (inline conformance, mirroring MMRRank). **MET.** 12/12 cases.
4. Zero edits to existing code except the single `lib.rs` module-registration line. **MET.**
5. Single-item support from MatrixO diagonal; diagonal excluded from emission. **MET.**
6. Estate wrapper and `propose` emission documented as Brain-layer-gated follow-on, not attempted. **MET** — engine header comment and mission non-goals both note this.

---

## Punch List

**WARNING 1 — Re-export gap (DEFERRED):**
The `pub use` re-export for ARM types was a valid advisory finding. Mission text prohibits a second lib.rs line for documented coordination reasons (streams `ar` and `fa` both add exactly one `pub mod` line each; dispatcher serializes that write). Bilby correctly declined to exceed the mission MUST on a reviewer advisory. The gap is recorded as Outstanding in the completion report for trivial batch with `fa` stream registration.

**WARNING 2 — Function length advisory (CLOSED):**
Commit `2f3a2e1` added the three-line justification comment at the top of both engine bodies. Comment text: "Two-pass over the same canonical scan, kept in one body so the conformance-critical control flow (guard order, gate order, emission order) reads top to bottom in both ports." Satisfies the advisory. No further action required.

---

## Adams Learning Note — NEURON_ASSOC_RULE_MINING_001

**Mission:** Pairwise association-rule mining engine over MatrixO
**Files reviewed:** AssociationRuleMining.swift, AssociationRuleMiningTests.swift, association_rule_mining.rs, lib.rs (1-line edit)
**Date:** 2026-06-01

### Patterns observed

- **Crate root re-export gap:** The "mirror MMRRank" instruction on net-new modules is easy to follow for the module file itself but easy to miss for the `pub use` re-export in lib.rs. MMRRank has `pub use mmr_rank::{mmr_rank, mmr_select}` at the crate root. ARM does not. First occurrence.
  Future signal: whenever a mission says "mirror [existing module]" for a Rust port, check lib.rs for BOTH `pub mod` and `pub use` before signing off.

- **Cargo.lock framing vs. reality:** BRR said "lockfile refresh from stale path-crate dependency drift." Actual diff: 614 → 1371 lines, ~80 new packages. Cargo.toml unchanged; all new entries are transitive from pre-existing path deps. This is fine technically — but the framing in the BRR undersells the scale. The mismatch caught my attention unnecessarily. Better framing: "lockfile regenerated from scratch; sibling crates have significantly grown their transitive dependency graphs."
  Future signal: large Cargo.lock diffs are expected in this codebase as path-crate graphs grow. Verify Cargo.toml unchanged and cargo test exits 0; don't treat line count as a signal.

- **Two-pass algorithm length:** Pure engine functions with two clearly documented passes (Pass 1: build lookup, Pass 2: emit) consistently run 70–80 lines. Not a code quality issue — it's the minimum for this pattern. The 40-line advisory fires on these but should not block them.
  Future signal: for two-pass engines that document both passes in block comments, the length advisory is safe to close as WARNING-acknowledged if the comments are clear.

### Surprises

- Signal file appeared in `COMPLETED/` not at the root path specified in the mission. The orchestrator moves signals to `COMPLETED/` after processing. Good to know — `ls signals/` is the wrong place to look; `find signals/ -name ".done-*"` catches both.

### File-specific notes

- `AssociationRuleMining.swift`: Two-pass structure, heavily commented, no ambiguity. The `@inlinable` on `Item.packed` is appropriate for a hot comparison path.
- `association_rule_mining.rs`: `HashMap<Item, i64>` for single_support — Item is Hash+Eq, so lookup is O(1). Correct choice. The derive(Ord) over (field, value) matching packed() ordering is documented in the comment and correct.
- `AssociationRuleMiningTests.swift`: `try! #require(cToA)` in test 3 — acceptable in test code; the test will fail loudly if the rule is absent. Not a concern.

### Systemic flags

None.
