# COMPLETION: BYCOPY_MIGRATION_001

**Status:** COMPLETE

**Branch:** worktree-agent-a64608722462a3e46
**Merge-base:** 9d6abe6 (matches main HEAD — no rebase needed)

---

## What Was Done

- **Pre-work 1:** Blast Radius Report — `700b639`
- **Pre-work 2:** `chore(neuron-kit): cargo fmt` (pre-existing fmt drift,
  separate commit per Adams standing rule) — `ab14b90`
- **Main migration:** All 9 by-copy conformance families migrated to
  shared vector artifacts; checker flipped to `--strict` — `81273c9`

---

## Per-Family Outcome

| Family | Kit | Status | Notes |
|---|---|---|---|
| benchmark_scoring | NeuronKit | MIGRATED | BS-1..5 cases; 4 float metrics + 2 string arrays as f32 hex |
| mmr_rank | NeuronKit | MIGRATED | blockBits encoding for Engram reconstruction; Swift uses ids, Rust uses indices |
| migration_ranking | CognitionKit | MIGRATED | New cognition_vectors.json artifact; new Swift gate + Rust loader created |
| formal_concept_analysis | NeuronKit | MIGRATED | Cohort fixture from FormalConceptAnalysisTests; extent as Int (UInt32→Int) |
| hybrid_recall | NeuronKit | MIGRATED | shingleSimilarity already present; added rerankCases + pagingCases only |
| association_rule_mining | NeuronKit | MIGRATED | MatrixO via applyRow/apply_row; infinite conviction → sentinel "inf" |
| scenario_profile | NeuronKit | MIGRATED | Round-trip per-leg; canonicalJson carries Swift encoding for reference only |
| context_synthesizer | NeuronKit | MIGRATED | adjectiveBitmap cluster formula verified |
| bradley_terry | NeuronKit | MIGRATED | Tolerance-based (1e-6); NOT bit-exact per documented C-6-adjacent contract |

---

## Hybrid_Recall Overlap Resolution

The existing `shingleSimilarity` artifact section already covers the three
shingle test inputs from `BenchmarkScoringTests` (via `NeuronKit.shingleSimilarity`).
The new `hybridRecall` section adds only `rerankCases` and `pagingCases`
(HybridRecallEngine.rerank + paging), as directed.

---

## Scenario_Profile Sorted-Keys Verification Result

**Finding:** Swift `.sortedKeys` produces camelCase keys; Rust BTreeMap
serialization produces snake_case keys. These are NOT byte-identical. The
canonical-JSON byte-comparison approach is not viable across language legs.

**Resolution:** The `canonicalJson` field in the artifact carries the
Swift-produced JSON for documentation only. The Rust verifier does its own
round-trip (encode → decode → compare field values), not byte-comparison
to `canonicalJson`. Both legs verify their own codec fidelity. The cross-leg
contract is on the *field values*, not the JSON serialization format.

---

## Context_Synthesizer `adjectiveBitmap` Finding

Smythe's note said "bits 0..<3 = state cluster" which was an approximation.
The correct formula is `(state_raw >> 4) & 0x3 == 0` for Cluster A
(currently believed), where `state_raw` is bits 0-5 of `adjectiveBitmap`.

This covers raws 0-15: active=0, pending=1, contested=2, accepted=3.
A naive `bits & 0b111 == 0` check fails for `contested` (raw 2) which IS
currently believed. The Rust loader uses the correct cluster formula.
Discovery documented in the artifact schema comment for future reference.

---

## Test Verification Log

### Baseline (from Blast Radius Report, Step 0)
- NeuronKit Swift: 172 tests
- CognitionKit Swift: 96 tests
- NeuronKit Rust: 162 unit + 1 integration = 163 tests
- CognitionKit Rust: 82 tests

### Final (post-commit, pre-signal)

**NeuronKit Swift:**
```
swift test (packages/kits/NeuronKit)
Exit code: 0
Pass count: 172 (unchanged from baseline)
```

**CognitionKit Swift:**
```
swift test (packages/kits/CognitionKit)
Exit code: 0
Pass count: 97 (+1 CognitionVectorConformance gate)
```

**NeuronKit Rust:**
```
cargo test (packages/kits/NeuronKit/rust)
Exit code: 0
Unit tests: 162 passed
Integration (lens_conformance): 1 passed
```

**CognitionKit Rust:**
```
cargo test (packages/kits/CognitionKit/rust)
Exit code: 0
Unit tests: 82 passed
Integration (cognition_conformance): 1 passed
```

**Checker:**
```
python3 check-mirrored-vectors.py --strict
Exit code: 0 (FAMILIES dict empty, no unmigrated families)
```

---

## --strict Flip Status

DONE. The CI workflow `kit-lens-conformance.yml` step `check-mirrored-vectors`
now runs with `--strict`. Since all 9 families are migrated and `FAMILIES` is
empty, `--strict` exits 0. Any new by-copy family added in the future will
fail the pipeline immediately.

---

## Discoveries

1. **Context-synthesizer bit semantics:** The cluster formula
   `(state_raw >> 4) & 0x3 == 0` is the correct `isCurrentlyBelieved`
   predicate, not `bits & 0b111 == 0`. The Rust loader now documents this
   precisely, preventing future mis-implementation.

2. **Scenario_profile cross-language JSON:** Swift JSONEncoder uses camelCase
   keys; Rust serde_json with snake_case struct fields uses snake_case keys.
   Canonical-JSON byte-comparison is not feasible for this family without
   a shared field-naming convention. The per-leg round-trip approach is the
   correct gate for codec fidelity.

3. **NeuronKit Rust pre-existing clippy issues:** The library source has
   9 clippy -D warnings violations (doc list indentation, clone-on-Copy,
   index loop variables). These are pre-existing and in source files that
   are out of scope for this test-layer mission. Noted for a future
   source-cleanup mission.

4. **mmrRank Rust uses indices, Swift uses ids:** The artifact carries both
   `expectedIDs` (Swift string ordering) and `expectedIndices` (Rust position
   ordering). The Rust walker validates against indices; the Swift walker
   validates against ids. Both verify the same selection order through their
   native representations.

---

## Outstanding

- Pre-existing NeuronKit Rust clippy violations in source files (out of scope;
  RESCOPE_REQUIRED if addressed separately).
- The `scenarioProfile` family's canonical JSON cross-leg comparison is
  unverifiable without a shared serialization convention — this is accepted
  behavior for this artifact family (each leg round-trips independently).
