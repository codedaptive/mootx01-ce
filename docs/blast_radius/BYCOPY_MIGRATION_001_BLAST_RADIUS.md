# Blast Radius Report — BYCOPY_MIGRATION_001

**Baseline:** NeuronKit Swift 172 tests, CognitionKit Swift 96 tests,
NeuronKit Rust 163 tests (162 unit + 1 integration), CognitionKit Rust 82 tests.
All legs exit 0 at mission start.

**Mission:** BYCOPY_MIGRATION_001 — migrate all 9 by-copy conformance families
to shared vector artifacts; flip the checker to --strict.

**Scope:** Test-layer only. ANY source-file edit = RESCOPE_REQUIRED.

**Stated approach (per Smythe YELLOW pre-flight):**
For each family, extend the existing lens_vectors.json artifact (or create
cognition_vectors.json for CognitionKit) with a new top-level section,
add a Codable/Deserialize schema struct in the matching conformance test file,
add a `computed(from:)` branch in the Swift leg (LensVectorConformanceTests.swift),
add a Rust walker in lens_conformance.rs (or cognition_conformance.rs for CK),
run RECORD_LENS_VECTORS=1 to fill expected outputs, re-run verify in both legs,
commit per family. After all 9 families migrate, delete all 9 entries from
FAMILIES dict in check-mirrored-vectors.py and flip the CI workflow --strict.

**Symbol changes:** None. This mission makes NO changes to source symbols.
All edits are in test files, fixture JSON, Rust test loaders, the checker script,
and the CI workflow.

---

## Files MUST_UPDATE

| File | Reason |
|---|---|
| `packages/kits/NeuronKit/Tests/NeuronKitTests/LensVectorConformanceTests.swift` | Add 8 new family sections (schema structs + computed branches) |
| `packages/kits/NeuronKit/Tests/NeuronKitTests/Fixtures/lens_vectors.json` | Add 8 new top-level sections for NeuronKit families |
| `packages/kits/NeuronKit/rust/tests/lens_conformance.rs` | Add 8 new family walkers |
| `packages/kits/CognitionKit/Tests/CognitionKitTests/MigrationRankingTests.swift` | No change (conformance test remains as behavioral gate) |
| `packages/kits/CognitionKit/Package.swift` | Add `resources: [.copy("Fixtures")]` to testTarget |
| `packages/kits/CognitionKit/Tests/CognitionKitTests/Fixtures/cognition_vectors.json` | CREATE — migration_ranking artifact |
| `packages/kits/CognitionKit/rust/tests/cognition_conformance.rs` | CREATE — CognitionKit conformance loader |
| `packages/kits/CognitionKit/rust/Cargo.toml` | Add [[test]] entry for cognition_conformance |
| `docs/validation/substrate_math_performance/test-harness/check-mirrored-vectors.py` | Delete all 9 FAMILIES entries, update header, flip final step |
| `.github/workflows/kit-lens-conformance.yml` | Flip checker step to --strict |

## Files INTENTIONALLY_LEFT (source files — scope boundary)

All NeuronKit/Sources/, CognitionKit/Sources/, and any Rust src/ files are
explicitly out of scope per mission mandate: "ANY source-file edit = STOP and
report RESCOPE_REQUIRED."

## Per-family classification

| Family | Kit | Files | Classification |
|---|---|---|---|
| benchmark_scoring | NeuronKit | LensVectorConformanceTests.swift, lens_vectors.json, lens_conformance.rs | MUST_UPDATE |
| mmr_rank | NeuronKit | same | MUST_UPDATE |
| migration_ranking | CognitionKit | MigrationRankingTests.swift (no schema change), cognition_vectors.json (create), cognition_conformance.rs (create), CognitionKit Package.swift | MUST_UPDATE |
| formal_concept_analysis | NeuronKit | LensVectorConformanceTests.swift, lens_vectors.json, lens_conformance.rs | MUST_UPDATE |
| hybrid_recall | NeuronKit | same (shingleSimilarity overlap noted — will NOT re-add, only add rerank + paging sections) | MUST_UPDATE |
| association_rule_mining | NeuronKit | same | MUST_UPDATE |
| scenario_profile | NeuronKit | same | MUST_UPDATE |
| context_synthesizer | NeuronKit | same | MUST_UPDATE |
| bradley_terry | NeuronKit | same (tolerance-based, not bit-exact) | MUST_UPDATE |

## RESCOPE_REQUIRED items

None. All call sites are within the test-layer scope.

## Notes

- NeuronKit Rust has cargo fmt drift before any feature work. A separate
  `chore(neuron-kit): cargo fmt` commit ships first per Adams standing rule.
- hybrid_recall overlap: `shingleSimilarity` is already in the artifact.
  The new section adds only `rerankCases` and `pagingCases`.
- scenario_profile: sorted-keys JSON agreement must be verified between
  Swift (.sortedKeys) and Rust (BTreeMap serialization) on one case before
  recording all.
- bradley_terry: tolerance-based (1e-6), NOT bit-exact. Checker manifest
  mode for this family is irrelevant (entry deleted on migration).
- context_synthesizer: `successRate` is a hex float; `recommendations` count
  is asserted (content non-deterministic, count deterministic).
