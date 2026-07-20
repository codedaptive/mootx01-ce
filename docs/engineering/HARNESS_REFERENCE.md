---
title: GeniusLocus Substrate Conformance Harness Reference
version: 1.0.2
description: Single-source index of the substrate's conformance-gated primitives, their Swift/Rust API surfaces, test vectors, and file locations.
status: implementation-grade specification
date: 2026-06-20
author: MOOTx01 maintainers
purpose: |
  Single-source index of the substrate's conformance-gated
  primitives, their Swift and Rust API surfaces, the test
  vectors that pin them, and the file paths an agent needs
  to locate them without re-discovery. This document is the
  agentic-discovery entry point: an LLM agent or human reading
  this file once has the locations and contracts for every
  bit-exact-cross-language operation the substrate ships.
relates_to:
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md (the math contract; this doc indexes its conformance gate)
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md (system ownership and package direction)
  - docs/validation/substrate_math_performance/test-harness/primitive-catalog.md (the operator-facing gate catalog, machine-readable)
  - docs/validation/substrate_math_performance/test-harness/test-vector-format.md (canonical JSON + binary CRC format spec)
  - docs/validation/substrate_math_performance/test-harness/primitive-walkthrough-SimHash.md (worked example for adding a primitive)
---

# Substrate Conformance Harness Reference

## §0. Read me first (agents, this is your TL;DR)

If you are an LLM agent or a human and you are about to write a SimHash, a
Hamming distance, an OR-reduce, a fingerprint, a lattice distance,
an HLC compare, a matrix decay, a moment summary, a Bradley-Terry
update, a tier contribution, a FFT rhythm pass, a Hamming-NN top-K,
an NMF factorization, a temporal compression, an audit-log fold,
a Merkle/commitment digest, an anomaly z-score, an info-theoretic measure, an eigenvalue
centrality computation, a field-presence matrix update, a partial
state recall, a pairing handshake, or a bitwise/bitfield extraction
— **stop and look in §2 first**. There is a fully cross-validated,
bit-identical Swift+Rust implementation already shipped. You do not
need to write a second one.

Each of these operations is conformance-gated: the Swift and the
Rust implementations are byte-for-byte identical on their canonical
test vector (32 cases each, CRC-pinned). Drift between the two
languages would be caught by CI in the next harness run.

The gate currently holds **29** conformance-gated primitives (the
count of record is `primitive-catalog.md`, the machine-readable
catalog, and the Swift/Rust harness registries — all three agree at
29). This reference details all 29 in full below. For the canonical
gated-primitive list and CRC source of record, treat
`primitive-catalog.md` as authoritative.

The harness lives at
`docs/validation/substrate_math_performance/test-harness/` (repo-relative).
The reference implementations these primitives wrap are distributed
across the four substrate packages under
`packages/libs/` (SubstrateTypes,
SubstrateKernel, SubstrateML, and SubstrateLib; Swift + Rust legs side
by side). The §2.0 map gives each primitive's package; §6 explains the
split.

To add a new primitive to the gate, follow §5. To verify a code
change against the gate, follow §8. (The "portability contract" framing
that ties §2 back to the cookbook's I-19 invariant lives in §7.)

---

## §1. What this file is, what it is not

**Is.** An index. For each conformance-gated substrate operation,
this file names the canonical Swift API, the canonical Rust API,
the source file each lives in, the harness test vector that pins
them, the test vector's CRC, and a one-line description of what
the operation does. It also documents the four-package library
split (§6), the workflow for adding a new primitive (§5), and the
verification commands (§8).

**Is not.** The math contract. The math contract is the cookbook
(`GENIUSLOCUS_ENGINEERING_COOKBOOK.md`); this doc
points back to the cookbook section for each primitive. The
cookbook says what the operation must compute; this doc says
where the cross-language-conforming implementation already lives.

If a primitive is in this index, it is gated. If a primitive is
not in this index but is in the cookbook, the cookbook-spec exists
but no Swift/Rust pair is yet pinned by a test vector — that is a
candidate for promotion (see §5).

---

## §2. The conformance-gated primitives (29 indexed here)

Each row tells an agent four things:
1. **Where the math lives** (cookbook §).
2. **Where the code lives** (Swift + Rust file paths).
3. **What pins the cross-language equivalence** (test vector + CRC).
4. **What the operation does** (one line).

All file paths in this document are relative to the repository root.

### §2.0. Where each primitive lives (four-package map)

Per the four-package split (§6), each gated primitive's
reference implementation lives in one of the substrate packages below.
Swift paths are `packages/libs/<Package>/Sources/<Package>/<file>`; Rust
paths are `packages/libs/<Package>/rust/src/<module>`.

| Primitive | Package | Swift file | Rust module |
|---|---|---|---|
| `simhash` | SubstrateTypes | `SimHash.swift` | `simhash.rs` |
| `hamming` | SubstrateTypes | `Hamming.swift` | `hamming.rs` |
| `or_reduce` | SubstrateTypes | `ORReduce.swift` | `or_reduce.rs` |
| `bitwise` | SubstrateTypes | `BitwiseArithmetic.swift` | `bitwise.rs` |
| `fingerprint` | SubstrateTypes | `Fingerprint256.swift` | `fingerprint256.rs` |
| `hlc` | SubstrateTypes | `HLC.swift` | `hlc.rs` |
| `fnv` | SubstrateTypes | `FNV.swift` | `fnv.rs` |
| `bit_field_masked_equals` | SubstrateKernel | `BitField.swift` | `bit_field.rs` |
| `merkle_commitment` | SubstrateKernel | `MerkleCommitment.swift` | `merkle_commitment.rs` |
| `lattice` | SubstrateML | `LatticeDistance.swift` | `lattice_distance.rs` |
| `info_theory` | SubstrateML | `InformationTheory.swift` | `info_theory.rs` |
| `bradley_terry` | SubstrateML | `BradleyTerry.swift` | `bradley_terry.rs` |
| `sampling` | SubstrateML | `Sampling.swift` | `sampling.rs` |
| `shingle_similarity` | SubstrateML | `ShingleSimilarity.swift` | `shingle_similarity.rs` |
| `partial_state_recall` | SubstrateML | `PartialStateRecall.swift` | `partial_state_recall.rs` |
| `temporal_compression` | SubstrateML | `TemporalCompression.swift` | `temporal_compression.rs` |
| `anomaly` | SubstrateML | `AnomalyDetection.swift` | `anomaly.rs` |
| `matrix_decay` | SubstrateML | `MatrixDecay.swift` | `decay.rs` |
| `moment_summary` | SubstrateML | `MomentSummary.swift` | `moment_summary.rs` |
| `field_presence_matrix_f` | SubstrateTypes | `MatrixF.swift` | `matrix_f.rs` |
| `tier_contribution` | SubstrateML | `TierContributionFingerprint.swift` | `tier_contribution.rs` |
| `pairing_handshake` | SubstrateML | `PairingHandshake.swift` | `pairing.rs` |
| `fft` | SubstrateML | `FFT.swift` | `fft.rs` |
| `hamming_nn` | SubstrateKernel | `HammingNN.swift` | `hamming_nn.rs` |
| `nmf` | SubstrateML | `NMFAlternatingLeastSquares.swift` | `nmf.rs` |
| `eigenvalue_centrality` | SubstrateML | `EigenvalueCentrality.swift` | `eigenvalue_centrality.rs` |
| `audit_log_fold` | SubstrateML | `AuditLogFold.swift` | `audit_log_fold.rs` |
| `association_rule_mining` | SubstrateML | `AssociationRuleMining.swift` | `association_rule_mining.rs` |
| `formal_concept_analysis` | SubstrateML | `FormalConceptAnalysis.swift` | `formal_concept_analysis.rs` |

(`AuditGate`, `Verbs`, and `RowStateAutomaton` are the orchestration
layer in SubstrateLib — not gated primitives, so not in this table.)

### §2.1. Tier 1 — atomic primitives (9 ops)

These are the substrate's irreducible bit operations. Any kit using
these MUST call the substrate API named below — never a reimplementation
(I-25, cookbook §1.4). The package each lives in is given by the §2.0 map.

#### `simhash` — §3.6 — CRC `0xddd18e12`
- **Swift:** `SimHash.computeBlock(_ v: BitVector192, family: HyperplaneFamily) -> UInt64`
  in `packages/libs/SubstrateTypes/Sources/SubstrateTypes/SimHash.swift`
- **Rust:** `simhash::SimHash::compute_block(v: &[u64; 3], family: &HyperplaneFamily) -> u64`
  in `packages/libs/SubstrateTypes/rust/src/simhash.rs`
- **Harness Swift:** `test-harness/swift/Sources/Harness/Primitives/SimHashPrimitive.swift`
- **Harness Rust:** `test-harness/rust/src/primitives/simhash.rs`
- **Vector:** `test-harness/vectors/simhash.json`
- **Walkthrough:** `test-harness/primitive-walkthrough-SimHash.md`
- **What:** Random-projection SimHash. 64 ±1 hyperplanes over a
  bit vector produce a 64-bit signature. The fingerprint's four
  blocks each invoke this once.

#### `hamming` — §8.2 — CRC `0xce4deb85`
- **Swift:** `Fingerprint256.hammingDistance(_ other: Fingerprint256) -> Int`
- **Rust:** `Fingerprint256::hamming_distance(&self, other: &Self) -> u32`
- **Harness:** `HammingPrimitive.swift` / `hamming.rs`
- **Vector:** `vectors/hamming.json`
- **What:** Bit-count of XOR over two 256-bit fingerprints.
  Drives every nearest-neighbor query.

#### `or_reduce` — §8.5 — CRC `0x4ee84d73`
- **Swift:** `Fingerprint256.orReduce(_ inputs: [Fingerprint256]) -> Fingerprint256`
- **Rust:** `Fingerprint256::or_reduce(inputs: &[Self]) -> Self`
- **Harness:** `OrReducePrimitive.swift` / `or_reduce.rs`
- **Vector:** `vectors/or_reduce.json`
- **What:** Bitwise OR over a set of 256-bit fingerprints.
  Commutative, associative, idempotent. The substrate's
  "merge of evidence" primitive — moment summary, temporal
  compression, and federation tier contribution all use it.

#### `bitwise` — §8.6 — CRC `0x05230c95`
- **Swift:** `Fingerprint256.{intersect,difference,prototype}(...)`
- **Rust:** `Fingerprint256::{intersect,difference,prototype}(...)`
- **Harness:** `BitwisePrimitive.swift` / `bitwise.rs`
- **Vector:** `vectors/bitwise.json`
- **What:** Bitwise AND, XOR, and majority-vote (prototype)
  combinators on fingerprints. Composes with `recall_by_fingerprint`
  (§11.17).

#### `fingerprint` — §3.6 — CRC `0x4449238e`
- **Swift:** `Fingerprint256.compute(row: Row, manifest: Manifest) -> Fingerprint256`
- **Rust:** `Fingerprint256::compute(row: &Row, manifest: &Manifest) -> Self`
- **Harness:** `FingerprintPrimitive.swift` / `fingerprint.rs`
- **Vector:** `vectors/fingerprint.json`
- **What:** Full four-block fingerprint construction.
  Composes SimHash over the four input vectors (bitmap, lattice,
  lineage+temporal, channel+source).

#### `hlc` — §5.2 — CRC `0x9303e020`
- **Swift:** `HLC` struct with `<`, `==`, `wireBytes`
- **Rust:** `HLC { physical_time: i64, logical_count: i32, node_id: i32 }`
  with `wire_bytes() -> [u8; 16]` and `Ord` impl
- **Harness:** `HLCPrimitive.swift` / `hlc.rs`
- **Vector:** `vectors/hlc.json`
- **What:** Hybrid Logical Clock comparison and wire encoding.
  Total order on `(physical_time, logical_count, node_id)`.
  16-byte LE wire format. The substrate's one ordering axis
  (cookbook §5.2, Clock Triangle decision §2).

#### `fnv` — §3.3 — CRC `0x275fd2bf`
- **Swift:** `FNV.hash64(_:) -> UInt64`, `FNV.hash32(_:) -> UInt32`,
  `FNV.hash16(_:) -> UInt16`
  in `packages/libs/SubstrateTypes/Sources/SubstrateTypes/FNV.swift`
- **Rust:** `fnv::hash64(s: &str) -> u64`, `fnv::hash32(s: &str) -> u32`,
  `fnv::hash16(s: &str) -> u16`
  in `packages/libs/SubstrateTypes/rust/src/fnv.rs`
- **Harness Swift:** `test-harness/swift/Sources/Harness/Primitives/FNVPrimitive.swift`
- **Harness Rust:** `test-harness/rust/src/primitives/fnv.rs`
- **Vector:** `test-harness/vectors/fnv.json`
- **What:** Fowler-Noll-Vo 1a string hash family — the substrate's
  deterministic UTF-8-string-to-integer mapping. `hash64` and
  `hash32` are independent families (different offset basis +
  prime). `hash16` is the low-16 fold of `hash64` (cookbook §3.3
  / §3.4). Used wherever a kit needs a deterministic non-
  cryptographic id from a string: drawer fingerprint feature
  hashes, manifest-derived maker node ids, deterministic
  tokenization.

#### `bit_field_masked_equals` — §2.8 — CRC `0x54f6c65f`
- **Swift:** `BitField.maskedEquals(_ bitmap: Int64, mask: Int64, expected: Int64) -> Bool`
  in `packages/libs/SubstrateKernel/Sources/SubstrateKernel/BitField.swift`
- **Rust:** `bit_field::masked_equals(bitmap: i64, mask: i64, expected: i64) -> bool`
  in `packages/libs/SubstrateKernel/rust/src/bit_field.rs`
- **Harness Swift:** `test-harness/swift/Sources/Harness/Primitives/BitFieldMaskedEqualsPrimitive.swift`
- **Harness Rust:** `test-harness/rust/src/primitives/bit_field_masked_equals.rs`
- **Vector:** `test-harness/vectors/bit_field_masked_equals.json`
- **What:** Masked field-equality predicate, `(bitmap & mask) == expected`,
  over packed-row Int64 bitmaps (cookbook §2.8 / §7.7). The
  atomic-centralization primitive that kit-level field-equality
  checks route through (the atomic-centralization primitive):
  LocusKit's `andMask` is a one-line
  passthrough, mirroring how `thresholdCompare` and `shiftExtract`
  delegate to `extractField`/`popcount`. `mask` and `expected`
  share the same bit range (caller invariant); `expected` with bits
  outside `mask` yields `false` for any `bitmap`. No precondition on
  parameter values — any Int64 inputs are well-defined; sign-bit
  behavior is the standard two's-complement AND, byte-identical
  across ports.

#### `merkle_commitment` — NT-P0 / I-27 — CRC `0x2476cee9`
- **Swift:** `MerkleCommitment.{canonicalLeafPayload,leafHash,interiorRoot,tombstoneHash,keyedCommitment}(...)`
  in `packages/libs/SubstrateKernel/Sources/SubstrateKernel/MerkleCommitment.swift`
- **Rust:** `merkle_commitment::{canonical_leaf_payload,leaf_hash,interior_root,tombstone_hash,keyed_commitment}(...)`
  in `packages/libs/SubstrateKernel/rust/src/merkle_commitment.rs`
- **Types:** `ContentHash`, `MerkleRoot`, and `KeyedCommitment`
  in `packages/libs/SubstrateTypes/Sources/SubstrateTypes/ContentHash.swift`
  and `packages/libs/SubstrateTypes/rust/src/content_hash.rs`
- **Harness Swift:** `test-harness/swift/Sources/Harness/Primitives/MerkleCommitmentPrimitive.swift`
- **Harness Rust:** `test-harness/rust/src/primitives/merkle_commitment.rs`
- **Vector:** `test-harness/vectors/merkle_commitment.json`
- **What:** Domain-separated SHA-256 Merkle leaf/interior/tombstone/
  empty-root construction plus HMAC-SHA256 keyed commitments over
  canonical drawer content and VectorKit-sidecar vector bytes. This
  is the NT-P0 extension of the I-27 integrity surface; it reuses
  SubstrateKernel `SHA256` and the existing `GrantHKDF`/`hkdf`
  HMAC implementation rather than adding a second HMAC primitive.

### §2.2. Tier 2 — algorithmic primitives (9 ops)

These compose Tier-1 primitives with substrate-state-aware
algorithms. Higher-level than bitops but still bandwidth-bounded.

#### `lattice` (aka `udc_tree_distance`) — §8.3 — CRC `0x6c4e453f`
- **Swift:** `UDCTreeDistance.distance(_ a: String, _ b: String) -> Double`
- **Rust:** `lattice_distance::udc_tree_distance(a: &str, b: &str) -> f64`
- **Harness:** `LatticePrimitive.swift` / `lattice.rs`
- **Vector:** `vectors/lattice.json`
- **What:** UDC code tree distance (longest-common-prefix delta,
  normalized to [0,1]). The cheap deterministic half of lattice
  distance; the Wikidata graph half is not currently gated (it
  requires a remote adjacency provider).

#### `info_theory` — §8.11 — CRC `0x0cc08713`
- **Swift:** `InfoTheory.{entropy,mutualInformation,klDivergence}(...)`
- **Rust:** `info_theory::{entropy,mutual_information,kl_divergence}(...)`
- **Harness:** `InfoTheoryPrimitive.swift` / `info_theory.rs`
- **Vector:** `vectors/info_theory.json`
- **What:** Shannon entropy (bits), mutual information, KL
  divergence over discrete distributions. Backs the anomaly
  primitive's KL mode (§8.13) and the dreaming daemon's drift
  detection (§15.1 rule 4).

#### `bradley_terry` — §8.12 — CRC `0x601126c7`
- **Swift:** `BradleyTerry.update(weights:featureA:featureB:winner:eta:) -> WeightVector`
- **Rust:** `bradley_terry::update(...) -> WeightVector`
- **Harness:** `BradleyTerryPrimitive.swift` / `bradley_terry.rs`
- **Vector:** `vectors/bradley_terry.json`
- **What:** Online pairwise-comparison gradient update with
  projection to the non-negative simplex. Drives W_tournament
  and W_ranking learning (cookbook §6.7).

#### `sampling` — §8.17 — CRC `0xfc883023`
- **Swift:** `Sampling.{sampleNormal,sampleGamma,sampleBeta}(rng:)`
  in `packages/libs/SubstrateML/Sources/SubstrateML/Sampling.swift`
- **Rust:** `sampling::{sample_normal,sample_gamma,sample_beta}(rng:)`
  in `packages/libs/SubstrateML/rust/src/sampling.rs`
- **Harness:** `SamplingPrimitive.swift` / `sampling.rs`
- **Vector:** `vectors/sampling.json`
- **What:** Deterministic SplitMix64-threaded Normal, Gamma, and
  Beta sampling. This is the substrate-owned sampling math under
  Thompson-style dreaming-trigger selection; policy remains above
  the substrate.

#### `shingle_similarity` — §8.20 — CRC `0x8a5d8888`
- **Swift:** `ShingleSimilarity.similarity(_:_:) -> Float32`
  in `packages/libs/SubstrateML/Sources/SubstrateML/ShingleSimilarity.swift`
- **Rust:** `shingle_similarity::similarity(a:b:) -> f32`
  in `packages/libs/SubstrateML/rust/src/shingle_similarity.rs`
- **Harness:** `ShingleSimilarityPrimitive.swift` / `shingle_similarity.rs`
- **Vector:** `vectors/shingle_similarity.json`
- **What:** Character 3-shingle Jaccard similarity used by recall
  ranking diversity and MMR-style deduplication. Pure string-set
  math; no tokenizer, clock, or randomness.

#### `partial_state_recall` — §8.8 — CRC `0xe8d3b221`
- **Swift:** `PartialStateRecall.score(row:anchor:matchBlocks:differBlocks:) -> Double`
- **Rust:** `partial_state_recall::score(...) -> f64`
- **Harness:** `PartialStateRecallPrimitive.swift` / `partial_state_recall.rs`
- **Vector:** `vectors/partial_state_recall.json`
- **What:** Composite score that rewards matching on some
  fingerprint blocks AND differing on others. Used by
  `recall_partial_match` (§11.10).

#### `temporal_compression` — §8.14 — CRC `0xdc3144c0`
- **Swift:** `TemporalCompression.compressToHourly(_ detail: [AmbientSample]) -> AmbientSample`
- **Rust:** `temporal_compression::compress_to_hourly(detail: &[AmbientSample]) -> AmbientSample`
- **Harness:** `TemporalCompressionPrimitive.swift` / `temporal_compression.rs`
- **Vector:** `vectors/temporal_compression.json`
- **What:** Cascading OR-reduce of 12 five-minute buckets into one
  hour bucket, with mode-of/union aggregation on metadata fields.
  Daily compression composes hourly the same way.

#### `anomaly` — §8.13 — CRC `0x6c6fda4d`
- **Swift:** `Anomaly.zscore(bucket:contextClass:) -> Double`
- **Rust:** `anomaly::zscore(bucket: &AmbientSample, context: ContextClass) -> f64`
- **Harness:** `AnomalyPrimitive.swift` / `anomaly.rs`
- **Vector:** `vectors/anomaly.json`
- **What:** Hamming-distance z-score from the cohort centroid
  (computed via OR-reduce as a fingerprint proxy). Fires the
  anomaly standing signal at z > 3.0.

#### `matrix_decay` — §6.8 — CRC `0x7b12f93d`
- **Swift:** `MatrixDecay.apply(to:nowSeconds:) -> Matrix`
- **Rust:** `matrix_decay::MatrixDecay::apply(matrix: Matrix, now: i64) -> Matrix`
- **Harness:** `MatrixDecayPrimitive.swift` / `matrix_decay.rs`
- **Vector:** `vectors/matrix_decay.json`
- **What:** Lazy multiplicative half-life decay over matrix
  cells. `factor = pow(0.5, elapsed_days / half_life_days)`.
  Used by O, T, ActionOutcomes, and industry-tier matrices.
  Cross-language bit-identity holds via Apple-libm `exp()`
  identity (empirically verified).

#### `moment_summary` — §8.7 — CRC `0x6762440b`
- **Swift:** `MomentSummary.summarize(rows:window:activeDuring:) -> Fingerprint256`
- **Rust:** `moment_summary::MomentSummary::summarize(rows:window:active_during:) -> Fingerprint256`
- **Harness:** `MomentSummaryPrimitive.swift` / `moment_summary.rs`
- **Vector:** `vectors/moment_summary.json`
- **What:** OR-reduce of fingerprints over rows matching an
  `active_during(row, window)` predicate. The substrate's
  "everything observed in a time window" primitive.
  *Note:* Swift takes the full production `Row` type; Rust takes
  a minimal `RowLite { fingerprint, capture_hlc }` stub. The
  harness bridges this asymmetry — both ports produce identical
  output. New code that calls `summarize` should pass whichever
  type its language exposes; results are equivalent.

#### `field_presence_matrix_f` — §6.1 — CRC `0x2a051f09`
- **Swift:** `MatrixF.applyRow(delta:bitPresence:)` (mutating)
- **Rust:** `matrix_f::MatrixF::apply_row(&mut self, delta: i64, bit_presence: impl Fn(usize, usize) -> bool)`
- **Harness:** `FieldPresenceMatrixFPrimitive.swift` / `field_presence_matrix_f.rs`
- **Vector:** `vectors/field_presence_matrix_f.json`
- **What:** Population statistic over (field, bit_position)
  presence: 36 fields × 6 bits = 216 i64 cells. Capture
  increments, expunge decrements; mutate is a paired -/+.
  The matrix has no decay (cookbook §6.8 table: half_life = None).

### §2.3. Tier 3 — substrate-level operations (7 ops)

Pattern-discovery, federation, and graph algorithms. Mostly
dreaming-daemon-driven; sub-linear amortized cost per row.

#### `tier_contribution` — §12.3 — CRC `0x4b67bcb5`
- **Swift:** `TierContribution.generate(rows:scope:window:sharedSeeds:) -> Fingerprint256`
- **Rust:** `tier_contribution::generate(rows:scope:window:shared_seeds:) -> Fingerprint256`
- **Harness:** `TierContributionPrimitive.swift` / `tier_contribution.rs`
- **Vector:** `vectors/tier_contribution.json`
- **What:** Re-fingerprint contributing rows under shared
  hyperplane seeds (scope-specific), then OR-reduce. The federation
  primitive (cookbook §12.3); paired estates and tier ascendant
  queries both call this.

#### `pairing_handshake` — §12.2 — CRC `0x67bc56f8`
- **Swift:** `PairingHandshake.handshake(initiator:responder:scope:) -> Result<HyperplaneFamily, Error>`
- **Rust:** `pairing_handshake::handshake(...) -> Result<HyperplaneFamily, PairingError>`
- **Harness:** `PairingHandshakePrimitive.swift` / `pairing_handshake.rs`
- **Vector:** `vectors/pairing_handshake.json`
- **What:** Generate-and-exchange the shared hyperplane family
  for a pairing scope (household, fleet, company, industry, MSP).
  Deterministic given inputs; transport is TLS/QR/AirDrop
  (cookbook §12.2).

#### `fft` — §8.10 — CRC `0xeae5c063`
- **Swift:** `FFT.forward(_ samples: [Double]) -> [Complex]`
- **Rust:** `fft::forward(samples: &[f64]) -> Vec<Complex<f64>>`
- **Harness:** `FFTPrimitive.swift` / `fft.rs`
- **Vector:** `vectors/fft.json`
- **What:** Discrete Fourier transform for rhythm analysis
  (`recall_rhythm_analysis`, §11.14). Power-of-two windows.

#### `hamming_nn` — §8.2 — CRC `0xeac615f1`
- **Swift:** `HammingNN.topK(anchor:candidates:K:) -> [(Row, Int)]`
- **Rust:** `hamming_nn::top_k(anchor:candidates:k:) -> Vec<(Row, u32)>`
- **Harness:** `HammingNNPrimitive.swift` / `hamming_nn.rs`
- **Vector:** `vectors/hamming_nn.json`
- **What:** Top-K nearest neighbors by Hamming distance, with
  branchless K-element sorted ladder. The primary hot-path
  retrieval primitive; measured ~604 µs at K=10, N=1M on
  apple-m5-max (cookbook §17.6).

#### `nmf` — §6.9 — CRC `0x300bf633`
- **Swift:** `NMF.factorize(O:K:) -> (W: Matrix, H: Matrix)`
- **Rust:** `nmf::factorize(o:k:) -> (Matrix, Matrix)`
- **Harness:** `NMFPrimitive.swift` / `nmf.rs`
- **Vector:** `vectors/nmf.json`
- **What:** Non-negative matrix factorization via alternating
  least squares with multiplicative updates. Discovers latent
  factors in the co-occurrence matrix; runs in the dreaming
  daemon's weekly pass.

#### `eigenvalue_centrality` — §7.2 — CRC `0x1a9039ea`
- **Swift:** `EigenvalueCentrality.compute(adjacency:maxIterations:tolerance:) -> [Double]`
- **Rust:** `eigenvalue_centrality::EigenvalueCentrality::compute(adjacency:max_iterations:tolerance:) -> Vec<f64>`
- **Harness:** `EigenvalueCentralityPrimitive.swift` / `eigenvalue_centrality.rs`
- **Vector:** `vectors/eigenvalue_centrality.json`
- **What:** Power iteration with Perron-Frobenius shift
  (`SHIFT = 1.0`, breaks ±λ oscillation on bipartite graphs).
  Drives keystone scoring (`recall_keystone`, §11.11) and the
  dreaming daemon's daily Rule 10.

#### `audit_log_fold` — §5.3 + §8.15 — CRC `0xa747722e`
- **Swift:** `AuditLogFold.projectStateAt(rowID:nounType:events:) -> RowState?`
- **Rust:** `audit_log_fold::AuditLogFold::project_current_state(row_id:noun:events:) -> Option<RowState>`
- **Harness:** `AuditLogFoldPrimitive.swift` / `audit_log_fold.rs`
- **Vector:** `vectors/audit_log_fold.json`
- **What:** Replay a row's audit events in HLC order to produce
  the projected state (current or as-of HLC). The substrate's
  source-of-truth read path under the capture-genesis-event model
  (cookbook §5.3, Capture Genesis Event decision).

#### `association_rule_mining` — §6.3 — CRC `0xdd61f0d0`
- **Swift:** `mineAssociationRules(matrix:activeRowCount:thresholds:) -> [AssociationRule]`
  in `packages/libs/SubstrateML/Sources/SubstrateML/AssociationRuleMining.swift`
- **Rust:** `association_rule_mining::mine_association_rules(...) -> Vec<AssociationRule>`
  in `packages/libs/SubstrateML/rust/src/association_rule_mining.rs`
- **Harness:** `AssociationRuleMiningPrimitive.swift` / `association_rule_mining.rs`
- **Vector:** `vectors/association_rule_mining.json`
- **What:** Pairwise association-rule mining over MatrixO
  co-occurrence counts, emitting support, confidence, lift,
  leverage, and conviction. The vector is hand-crafted and
  validates in both languages.

#### `formal_concept_analysis` — §8 pure engine — CRC `0xfeb1a9e9`
- **Swift:** `FormalContext`, `BoundedConceptMiner`, `ConceptCoverDeltas`,
  and implication helpers in
  `packages/libs/SubstrateML/Sources/SubstrateML/FormalConceptAnalysis.swift`
- **Rust:** `formal_concept_analysis::{FormalContext,BoundedConceptMiner,...}`
  in `packages/libs/SubstrateML/rust/src/formal_concept_analysis.rs`
- **Harness:** `FormalConceptAnalysisPrimitive.swift` / `formal_concept_analysis.rs`
- **Vector:** `vectors/formal_concept_analysis.json`
- **What:** Bounded Formal Concept Analysis over materialized
  row-attribute contexts. It mines exact closures and cover deltas
  without enumerating the full concept lattice. The vector is
  hand-crafted and validates in both languages.

### §2.4. Pending promotion (deferred, not yet gated)

- `community_detection` phase 2 (Louvain phase 2 graph aggregation)
  — cookbook §7.3. **Deferred — not yet gated.** Do NOT promote yet.

All other primitives previously on the pending list (matrix_decay,
eigenvalue_centrality, moment_summary, field_presence_matrix_f,
udc_tree_distance) are either gated above or clarified as already
covered (udc_tree_distance is the `lattice` row).

All other catalogued primitives are indexed above.

---

## §3. Harness invariants — what the gate guarantees

If a primitive appears in §2, an agent or maintainer can rely on
the following:

1. **Bit-identity across languages.** The Swift implementation
   and the Rust implementation produce byte-identical canonical
   binary output for the same 32-case test vector. The CRC-32 of
   that canonical output is fixed across both languages and
   pinned in `test-harness/primitive-catalog.md`.

2. **Bit-identity across platforms** for integer-only ops, and
   for transcendental ops (`exp`, `sqrt`, `cos`, etc.) on
   IEEE-754-correctly-rounded libms (Apple platforms,
   glibc-on-x86_64). `sqrt` is mandated correctly-rounded;
   `exp` and friends have 1-ULP wiggle room — empirically
   verified bit-identical across Apple's libm and Rust's
   `f64::exp` on Apple Silicon.

3. **Four-way conformance every promotion.** A primitive enters
   the gate only after Swift-gen × Swift-validate, Swift-gen ×
   Rust-validate, Rust-gen × Swift-validate, and Rust-gen ×
   Rust-validate all PASS at the same CRC. CI re-runs all four
   cells nightly.

4. **Order-determinism.** Where floating-point summation order
   matters (e.g. `eigenvalue_centrality`'s inner product),
   both ports iterate inputs in identical order. Don't reorder.

5. **No private state.** Harness primitives test pure functions
   or stateless update operations. Anywhere the substrate
   has state (matrices, audit log), the harness takes that
   state as input and returns the new state — there is no
   hidden side channel.

---

## §4. Cross-language API correspondence — known gotchas

These are surprises an agent will hit if they assume Swift and
Rust APIs are 1:1. They are not. The harness bridges them; new
code should match its language's idiom.

| Concept | Swift | Rust | Notes |
|---|---|---|---|
| Fingerprint256 construction | `Fingerprint256(block0:block1:block2:block3:)` | struct literal `Fingerprint256 { block0, block1, block2, block3 }` — no `new()` | |
| Fingerprint256 bytes | `wireBytes: [UInt8]` property; `init(wireBytes:) throws` | `wire_bytes(&self) -> [u8; 32]`; `from_wire_bytes(&[u8]) -> Result<Self, FingerprintError>` | Rust uses `wire_bytes` not `to_bytes`/`from_bytes`. |
| HLC construction | `HLC(physicalTime:logicalCount:nodeID:)` | struct literal `HLC { physical_time, logical_count, node_id }` — no `new()` | |
| HLC wire bytes | `wireBytes: [UInt8]` property (16 bytes LE) | no `wire_bytes` method on HLC; harness uses local `hlc_wire_bytes()` helper | Asymmetric; if you need Rust HLC wire encoding, write the LE encode inline (8B phys + 4B log + 4B node). |
| Row vs RowLite | `Row` full production type from `packages/libs/SubstrateTypes/Sources/SubstrateTypes/Row.swift` (no `capture_hlc` field; lives in the audit log in production) | `RowLite { fingerprint, capture_hlc }` lightweight stub for moment_summary | Harness bridges via index-counter closure in Swift. |
| AuditEvent | `eventID: UUID` (in `SubstrateTypes/AuditEvent.swift`) | `event_id: u128` (deterministic content-ID per `audit_gate::content_id`, in `SubstrateTypes/rust/src/audit_event.rs`) | Both ports expose the field; both ports' audit-log-fold algorithms ignore it, so output is independent of it. |
| TimeRange::new | `TimeRange(start:end:)` with `precondition` on order | `TimeRange::new(start, end)` with `assert!` on order | Symmetric. |

---

## §5. Workflow — adding a new primitive to the gate

Every gated op (29 at time of writing — see §0/§2) was promoted
through this workflow. If you are adding the next primitive, the
steps are mechanical. The worked example lives at
`test-harness/primitive-walkthrough-SimHash.md`.

1. **Decide what you are gating.** A primitive is a pure function
   or a stateless update. It takes JSON-encodable inputs and
   produces JSON-encodable outputs. It has a Swift reference
   implementation in `packages/libs/SubstrateTypes/Sources/SubstrateTypes/`,
   `packages/libs/SubstrateKernel/Sources/SubstrateKernel/`, or
   `packages/libs/SubstrateML/Sources/SubstrateML/` (per the
   four-package split; see `docs/validation/substrate_math_performance/test-harness/primitive-catalog.md`
   for the per-primitive location), and a Rust mirror at the
   corresponding `rust/src/` path under the same package.

2. **Write the Swift harness primitive.**
   `test-harness/swift/Sources/Harness/Primitives/<Name>Primitive.swift`.
   Follow the structure of `MatrixDecayPrimitive.swift` (good
   template for transcendental-bearing primitives) or
   `FieldPresenceMatrixFPrimitive.swift` (good template for
   integer-only primitives).

3. **Write the Rust harness primitive.**
   `test-harness/rust/src/primitives/<name>.rs`. Mirror the Swift
   structure, schema, and case generation function. Iteration
   order MUST match — floating-point summation is non-associative.

4. **Register in three places.**
   `test-harness/swift/Sources/Harness/Primitives/PrimitiveRegistry.swift`
   gets one descriptor line. `test-harness/rust/src/primitives/mod.rs`
   gets the `pub mod <name>;`. `test-harness/rust/src/primitives/registry.rs`
   gets the `use` line and the descriptor push.

5. **Build both legs.** From `test-harness/rust/`: `cargo build
   --release`. From `test-harness/swift/`: `swift build`. Both
   must compile clean.

6. **Run four-way conformance.** From `test-harness/swift/`:
   ```
   .build/debug/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF
   .build/debug/validate-vectors ../vectors/<name>.json
   ../rust/target/release/validate-vectors ../vectors/<name>.json
   ../rust/target/release/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF --out /tmp/<name>-rust.json
   .build/debug/validate-vectors /tmp/<name>-rust.json
   ../rust/target/release/validate-vectors /tmp/<name>-rust.json
   ```
   All four must PASS at the same CRC. If they don't, drift
   exists — debug before continuing.

7. **Commit the Swift-generated vector.**
   The Swift gen-vectors output at `../vectors/<name>.json` is the
   canonical artifact. The Rust-generated output is verified to
   match but is not the canonical one.

8. **Update the catalog.** `test-harness/primitive-catalog.md`
   gets a new tier row with the CRC. Update the "All N primitives"
   count and the CI matrix iterator. Remove from the pending list
   if applicable.

9. **Update this reference.** Add a §2.x entry with the CRC, the
   Swift API, the Rust API, file paths, and a one-line "what".

10. **Add a regen-log entry.** `test-harness/test-vector-format.md`
    gets a dated entry explaining the new primitive, the test case
    design, why bit-identity holds, the CRC, and the four-way PASS.

11. **Update the CI workflow.** `.github/workflows/geniuslocus-
    conformance.yml` has 7 places where the primitive list is
    iterated; append the new name to each.

---

## §6. The four-package substrate split

The substrate ships as **four
sibling packages** under `packages/libs/`: `SubstrateTypes`,
`SubstrateKernel`, `SubstrateML`, and the retained `SubstrateLib`
orchestration layer (nine-verb mechanics + row-state automaton +
AuditGate) that depends on the other three. They are **siblings on
disk**, each its own SPM package (Swift) and Cargo crate (Rust) — not
nested inside SubstrateLib. Consumers depend on whichever combination
they need; SubstrateLib does not re-export the sub-packages.

### §6.1. SubstrateTypes — pure data, zero compute

**Swift:** `packages/libs/SubstrateTypes/Sources/SubstrateTypes/`
**Rust:** `packages/libs/SubstrateTypes/rust/`

Contains the data types every kit speaks, with NO algorithms:

- `Fingerprint256` (struct + wire encoding)
- `HLC` (struct + ordering + wire encoding)
- `LatticeAnchor` (struct + UDC/QID accessors)
- `Row` / `RowLite` / `NounType` / `RowStateValue`
- `AuditEvent` (both ports expose the identity field: Swift `eventID`, Rust `event_id`)
- `MatrixF` / `MatrixC` / `MatrixO` / `MatrixT` (storage + indexing,
  no learning)
- `BlockMask` / `RowBitmaps` / `BitVector216` (the layout constants)
- `TimeRange`
- All enums: `MutationKind`, `PairingScope`, `GeneratedByClass`, etc.

**Rule:** No transcendentals here, no algorithms, no I/O. Pure
shape. Any kit that just wants to talk substrate-shape (e.g.
ConvergenceKit serializing rows to CloudKit) depends only on
SubstrateTypes.

### §6.2. SubstrateKernel — bandwidth-bound bit operations

**Swift:** `packages/libs/SubstrateKernel/Sources/SubstrateKernel/`
**Rust:** `packages/libs/SubstrateKernel/rust/`

Contains the hot-path bit-tensor operations that the performance
measurement work selected (cookbook §17.6). All of these are
gated by §2.1 of this document:

- `SimHash` family
- `Fingerprint256` distance/OR/AND/XOR/prototype ops
- `HammingNN` top-K
- The `combinators` layer: `zip4`/`reduce4`/`map4`/`popcount`
  over Fingerprint256
- `SimdKernel` (Swift NEON via `import simd`; Rust `std::simd`)
- `AuditGate` (the write-gate that admits FieldWrite sets;
  validates against VocabularyValidator)
- `HLCGenerator` (`open`/`tick`/`takeover`)
- SHA-256 content-ID (`audit_gate::content_id` in Rust;
  `ContentID.compute` in Swift)
- Seal computation (`SHA256` over wire fields including HLC and
  node id, per integrity-triangle decision §3)

**Rule:** Depends only on SubstrateTypes. No matrix updates here,
no learning, no graph algorithms — those belong above.

### §6.3. SubstrateML — learning + graph algorithms

**Swift:** `packages/libs/SubstrateML/Sources/SubstrateML/`
**Rust:** `packages/libs/SubstrateML/rust/`

Contains the cold-path or dreaming-driven algorithms (§2.2 Tier 2
+ §2.3 Tier 3 of this document):

- `MatrixDecay`
- `MomentSummary`
- `BradleyTerry`
- `Anomaly` (z-score)
- `InfoTheory` (entropy / MI / KL)
- `TemporalCompression`
- `PartialStateRecall`
- `FFT`
- `NMF`
- `EigenvalueCentrality`
- `AuditLogFold` (the projection algorithm)
- `TierContribution`
- `PairingHandshake`

**Rule:** Depends on SubstrateTypes and SubstrateKernel. Most kits
do NOT need this package — only LocusKit, CognitionKit, and
GeniusLocusKit consume it.

### §6.4. Why four packages, not one

The cost was small (a few `package.swift` and `Cargo.toml` edits)
and the value is concrete:

1. **Compile time.** A kit that only serializes rows
   (ConvergenceKit) compiles against SubstrateTypes alone and
   avoids waiting on SubstrateKernel's SIMD code generation.

2. **Dependency clarity.** Looking at a kit's Package.swift tells
   you whether it's a substrate consumer, a hot-path consumer, or
   a learning consumer. The boundary is documented in the build
   graph, not just in prose.

3. **Future portability.** A WASM target or a non-Apple-Silicon
   port that wants to ship without `simd_*` intrinsics can take
   SubstrateTypes and a stub SubstrateKernel without touching
   SubstrateML.

4. **Test isolation.** Each package's test suite is independent.
   SubstrateKernel's CRC-pinned conformance vectors (the harness)
   don't need to recompile when SubstrateML changes.

The cookbook's `I-25` invariant (cookbook §1.4 — one
implementation per atomic) applies across all three: atomics live
in whichever package they belong to, and EVERY consumer (kit or
test harness) imports them by name.

---

## §7. The harness as portability contract — I-19 revisited

Cookbook §4.4 (I-19) states that the kernel layer is portable
across SIMD families and that **the scalar reference is the
authoritative source for correctness; per-backend implementations
must produce bit-identical results to the scalar reference (CRC
test against the reference vectors in
`conformance/kernel/`)**.

This document's §2 is the realization of that contract. The CRC
beside each primitive IS the portability seal. A new platform,
backend, or compiler is conforming if and only if it can:

1. `gen-vectors --primitive <name>` and produce a JSON whose
   canonical binary CRC matches the §2 row.
2. `validate-vectors <name>.json` against the Swift-generated
   canonical vector and PASS.

A platform that passes for all gated primitives (29 — the
`primitive-catalog.md` total) is fully substrate-conforming. A
platform that passes for the Tier-1 subset (§2.1) is
hot-path-conforming and can run reads but not the dreaming daemon.

---

## §8. Verification — the commands

If you've changed code and want to know whether the gate still
passes:

```bash
# Full gate sweep, both languages, on-disk vectors:
cd docs/validation/substrate_math_performance/test-harness/swift
for v in ../vectors/*.json; do
  name=$(basename "$v" .json)
  swift_result=$(.build/debug/validate-vectors "$v" 2>&1 | tail -1)
  rust_result=$(../rust/target/release/validate-vectors "$v" 2>&1 | tail -1)
  printf "%-30s swift=%s  rust=%s\n" "$name" "$swift_result" "$rust_result"
done
```

If you've added a primitive and want to verify just that one:

```bash
cd test-harness/swift
.build/debug/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF
.build/debug/validate-vectors ../vectors/<name>.json   # cell 1
../rust/target/release/validate-vectors ../vectors/<name>.json   # cell 2
../rust/target/release/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF --out /tmp/<name>-rust.json
.build/debug/validate-vectors /tmp/<name>-rust.json    # cell 3
../rust/target/release/validate-vectors /tmp/<name>-rust.json    # cell 4
```

All four cells must report PASS at the same CRC.

---

## §9. Open gaps in the harness — known but not yet closed

These are tracked carry-forward items that the gate does not yet
cover, listed here so agents don't think they're missing them by
accident.

1. **`community_detection` phase 2.** Deferred per
   cookbook §7.3 (Louvain phase 2 graph aggregation). Not yet
   gated.

2. **Wikidata graph distance** (the QID half of lattice distance).
   Requires a remote adjacency provider; not currently gated.
   `lattice` covers only the UDC-tree half (the deterministic
   cheap part).

3. **`bitmap_filter` over the bit-slice tensor.** Cookbook §4.5 P1.
   Requires the bit-slice substrate-level work (§4.1 I-18) to land
   first.

4. **Composite distance (`α·lattice + β·fingerprint`).** Cookbook
   §8.4. Not yet gated. Awaits Wikidata adjacency provider gating.

5. **NMF, FFT, eigenvalue_centrality cookbook estimates.** Cookbook
   §17.1 / §17.2 budgets for these are pre-measurement
   estimates. The gate verifies correctness; performance budgets
   for these primitives are not yet measured against real
   workloads on apple-m5-max.

---

## §10. References

- Cookbook: `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md`
- System reference: `docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md`
- Performance gate: `docs/engineering/SUBSTRATE_PERFORMANCE_GATE.md`
- Catalog (machine-readable): `docs/validation/substrate_math_performance/test-harness/primitive-catalog.md`
- Vector format spec + regen log: `docs/validation/substrate_math_performance/test-harness/test-vector-format.md`
- Worked example: `docs/validation/substrate_math_performance/test-harness/primitive-walkthrough-SimHash.md`
- CI: `.github/workflows/geniuslocus-conformance.yml`

---

*End of harness reference. If you found yourself about to write a
SimHash, a Hamming distance, an OR-reduce, or any of the other gated
operations in §2: stop. Use the one already in the substrate (the §2.0
map gives its package). It is
gated, byte-identical Swift↔Rust, and the next 12 lines of code
you don't have to write are 12 lines of bugs you don't have to
fix.*

## Changelog

### 1.0.2 -- 2026-06-20
Added `merkle_commitment` as the 29th conformance-gated primitive
at CRC `0x2476cee9`. The entry records the NT-P0 content-integrity
extension, the SubstrateKernel Swift/Rust byte-contract APIs, the
SubstrateTypes digest wrappers, and the canonical vector file.
Closed the four remaining catalog-only §2 entries for
`association_rule_mining`, `formal_concept_analysis`, `sampling`,
and `shingle_similarity`; this reference now indexes all 29 gated
primitives.

### 1.0.1 -- 2026-06-14
Reconciled the gated-primitive count against ground truth: the harness now gates 28 primitives (per `primitive-catalog.md` and both Swift/Rust harness registries), not 24. The §0 TL;DR, §2 header, §2.4, §5, and §7 count claims were updated; this reference indexes 24 in full, with four newly promoted primitives (`association_rule_mining`, `formal_concept_analysis`, `sampling`, `shingle_similarity`) gated but their per-primitive §2.x entries pending (§5 step 9). `primitive-catalog.md` is named as the authoritative count of record.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
