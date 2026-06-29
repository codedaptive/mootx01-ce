---
status: in_progress
created: 2026-06-06
last_updated: 2026-06-20
---

# Primitive Catalog

All primitives currently conformant in the substrate reference
test harness, with cross-references to source files and CRC32
values for the canonical vector files.

This document is kept in sync with the registries in:

- Swift: `test-harness/swift/Sources/Harness/Primitives/PrimitiveRegistry.swift`
- Rust: `test-harness/rust/src/primitives/registry.rs`

## Conformance state

All 29 primitives in the Tier 1-3 tables below pass the conformance
gate. Each has a committed vector file in `test-harness/vectors/`
(29 `.json` files, one per primitive).
A 30th primitive, `community_detection`, has a live reference but
is not yet harnessed; it is listed under "Pending future work" and
is NOT part of the conformance gate.

For the 27 generator-driven primitives, the full four-way matrix is:

| Vector file generated in | Validated by Swift | Validated by Rust |
|---|---|---|
| Swift generator | PASS | PASS |
| Rust generator | PASS | PASS |

The two hand-crafted primitives (`association_rule_mining` and
`formal_concept_analysis`) have no generator path. They are gated by
Swift and Rust validation of their checked-in vector files.

CRC32 values quoted below are over the canonical binary
serialization of all case outputs in case order; same value in
both languages for every primitive.

## Primitives

### Tier 1: bitmap, fingerprint, and content-integrity core

| Primitive | CRC32 | Cookbook | Swift reference | Rust reference |
|---|---|---|---|---|
| `simhash` | `0xddd18e12` | §3.6 | `SubstrateTypes/Sources/SubstrateTypes/SimHash.swift` | `SubstrateTypes/rust/src/simhash.rs` |
| `hamming` | `0xce4deb85` | §8.2 | `SubstrateTypes/Sources/SubstrateTypes/Hamming.swift` | `SubstrateTypes/rust/src/hamming.rs` |
| `or_reduce` | `0x4ee84d73` | §8.5 | `SubstrateTypes/Sources/SubstrateTypes/ORReduce.swift` | `SubstrateTypes/rust/src/or_reduce.rs` |
| `bitwise` | `0x05230c95` | §8.6 | `SubstrateTypes/Sources/SubstrateTypes/BitwiseArithmetic.swift` | `SubstrateTypes/rust/src/bitwise.rs` |
| `fingerprint` | `0x4449238e` | §3.1 | `SubstrateTypes/Sources/SubstrateTypes/Fingerprint256.swift` | `SubstrateTypes/rust/src/fingerprint256.rs` |
| `hlc` | `0x9303e020` | §5.2 | `SubstrateTypes/Sources/SubstrateTypes/HLC.swift` | `SubstrateTypes/rust/src/hlc.rs` |
| `fnv` | `0x275fd2bf` | §3.3 | `SubstrateTypes/Sources/SubstrateTypes/FNV.swift` | `SubstrateTypes/rust/src/fnv.rs` |
| `bit_field_masked_equals` | `0x54f6c65f` | §2.8 | `SubstrateKernel/Sources/SubstrateKernel/BitField.swift` | `SubstrateKernel/rust/src/bit_field.rs` |
| `merkle_commitment` | `0x2476cee9` | NT-P0 / I-27 | `SubstrateKernel/Sources/SubstrateKernel/MerkleCommitment.swift` | `SubstrateKernel/rust/src/merkle_commitment.rs` |

### Tier 2: structural coordinate system

| Primitive | CRC32 | Cookbook | Swift reference | Rust reference |
|---|---|---|---|---|
| `lattice` (aka `udc_tree_distance`) | `0x6c4e453f` | §8.3 | `SubstrateML/Sources/SubstrateML/LatticeDistance.swift` | `SubstrateML/rust/src/lattice_distance.rs` |
| `info_theory` | `0x0cc08713` | §8.11 | `SubstrateML/Sources/SubstrateML/InformationTheory.swift` | `SubstrateML/rust/src/info_theory.rs` |
| `bradley_terry` | `0x601126c7` | §8.12 | `SubstrateML/Sources/SubstrateML/BradleyTerry.swift` | `SubstrateML/rust/src/bradley_terry.rs` |
| `sampling` | `0xfc883023` | §8.17 | `SubstrateML/Sources/SubstrateML/Sampling.swift` | `SubstrateML/rust/src/sampling.rs` |
| `shingle_similarity` | `0x8a5d8888` | §8.20 | `SubstrateML/Sources/SubstrateML/ShingleSimilarity.swift` | `SubstrateML/rust/src/shingle_similarity.rs` |
| `partial_state_recall` | `0xe8d3b221` | §8.8 | `SubstrateML/Sources/SubstrateML/PartialStateRecall.swift` | `SubstrateML/rust/src/partial_state_recall.rs` |
| `temporal_compression` | `0xdc3144c0` | §8.14 | `SubstrateML/Sources/SubstrateML/TemporalCompression.swift` | `SubstrateML/rust/src/temporal_compression.rs` |
| `anomaly` | `0x6c6fda4d` | §8.13 | `SubstrateML/Sources/SubstrateML/AnomalyDetection.swift` | `SubstrateML/rust/src/anomaly.rs` |
| `matrix_decay` | `0x7b12f93d` | §6.8 | `SubstrateML/Sources/SubstrateML/MatrixDecay.swift` | `SubstrateML/rust/src/decay.rs` |
| `moment_summary` | `0x6762440b` | §8.7 | `SubstrateML/Sources/SubstrateML/MomentSummary.swift` | `SubstrateML/rust/src/moment_summary.rs` |
| `field_presence_matrix_f` | `0x2a051f09` | §6.1 | `SubstrateTypes/Sources/SubstrateTypes/MatrixF.swift` | `SubstrateTypes/rust/src/matrix_f.rs` |

### Tier 3: federation, advanced cognition, and audit

| Primitive | CRC32 | Cookbook | Swift reference | Rust reference |
|---|---|---|---|---|
| `tier_contribution` | `0x4b67bcb5` | §12.3 | `SubstrateML/Sources/SubstrateML/TierContributionFingerprint.swift` | `SubstrateML/rust/src/tier_contribution.rs` |
| `pairing_handshake` | `0x67bc56f8` | §12.2 | `SubstrateML/Sources/SubstrateML/PairingHandshake.swift` | `SubstrateML/rust/src/pairing.rs` |
| `fft` | `0xeae5c063` | §8.10 | `SubstrateML/Sources/SubstrateML/FFT.swift` | `SubstrateML/rust/src/fft.rs` |
| `hamming_nn` | `0xeac615f1` | §8.2 | `SubstrateKernel/Sources/SubstrateKernel/HammingNN.swift` | `SubstrateKernel/rust/src/hamming_nn.rs` |
| `nmf` | `0x300bf633` | §6.9 | `SubstrateML/Sources/SubstrateML/NMFAlternatingLeastSquares.swift` | `SubstrateML/rust/src/nmf.rs` |
| `eigenvalue_centrality` | `0x1a9039ea` | §7.2 | `SubstrateML/Sources/SubstrateML/EigenvalueCentrality.swift` | `SubstrateML/rust/src/eigenvalue_centrality.rs` |
| `audit_log_fold` | `0xa747722e` | §5.3+§8.15 | `SubstrateML/Sources/SubstrateML/AuditLogFold.swift` | `SubstrateML/rust/src/audit_log_fold.rs` |
| `association_rule_mining` | `0xdd61f0d0` | §6.3 | `SubstrateML/Sources/SubstrateML/AssociationRuleMining.swift` | `SubstrateML/rust/src/association_rule_mining.rs` |
| `formal_concept_analysis` | `0xfeb1a9e9` | §8 (pure engine) | `SubstrateML/Sources/SubstrateML/FormalConceptAnalysis.swift` | `SubstrateML/rust/src/formal_concept_analysis.rs` |

Note: `association_rule_mining` and `formal_concept_analysis` use hand-crafted
vectors (Rust generator, not RNG-seeded). The Swift harness validates them
using the production SubstrateML implementations; generate() throws for both.

## Harness sources

Each primitive has a Swift harness file under
`test-harness/swift/Sources/Harness/Primitives/<Name>Primitive.swift`
and a Rust harness file under
`test-harness/rust/src/primitives/<name>.rs`. The harness file
constructs test cases, calls the real reference, and emits the
canonical vector format. The vector format spec is in
`test-vector-format.md`; the worked example for adding a new
primitive is in `primitive-walkthrough-SimHash.md`.

## CI matrix

The conformance CI at `.github/workflows/geniuslocus-conformance.yml`
runs the four-way matrix on every push and pull request affecting
the substrate or harness sources.

Of the 29 conformant primitives, the 27 generator-driven ones run
through the generator-driven iterator below. The two hand-crafted
primitives (`association_rule_mining` and `formal_concept_analysis`)
are gated separately, as described in the note under the Tier 3
table: their `generate()` throws, so CI validates them against
checked-in hand-crafted vectors rather than regenerating from a
seed. 27 generator-driven + 2 hand-crafted = all 29 conformant
primitives.

The matrix iterator:

```sh
for primitive in simhash hamming or_reduce bitwise anomaly hlc \
                 fingerprint bit_field_masked_equals \
                 lattice info_theory bradley_terry \
                 partial_state_recall temporal_compression \
                 tier_contribution fft hamming_nn pairing_handshake \
                 nmf audit_log_fold matrix_decay eigenvalue_centrality moment_summary field_presence_matrix_f fnv \
                 sampling shingle_similarity merkle_commitment; do
    swift run gen-vectors --primitive $primitive --seed 0xCAFEBABEDEADBEEF --out /tmp/sw-$primitive.json
    cargo run --release --bin gen-vectors -- --primitive $primitive --seed 0xCAFEBABEDEADBEEF --out /tmp/rs-$primitive.json
    swift run validate-vectors test-harness/vectors/$primitive.json
    cargo run --release --bin validate-vectors -- test-harness/vectors/$primitive.json
    swift run validate-vectors /tmp/rs-$primitive.json
    cargo run --release --bin validate-vectors -- /tmp/sw-$primitive.json
done
```

The loop above covers the 27 generator-driven primitives. The two
hand-crafted primitives (`association_rule_mining`,
`formal_concept_analysis`) are validated in a separate CI step
against their checked-in vectors. Any cell failing in either step
breaks CI.

## Pending future work

The primitives below remain candidates for future expansion. They
have references in either Swift, Rust, or both, but no harness
case generator yet. Each can be added by following the steps in
`primitive-walkthrough-SimHash.md`.

| Primitive | Status | Notes |
|---|---|---|
| `community_detection` | reference live; phase 2 not yet harnessed | §7.3; Louvain phase 1 only |

The kernel-layer accelerator implementations (NEON, AVX-512, AVX2,
Metal) are explicitly Path 4 work; their conformance gate is the
existing primitive harness (each accelerator must produce vectors
that match the scalar reference's CRC).
