---
title: SubstrateML Specification
version: 1.0.0
status: active
date: 2026-06-14
description: "Behavioral specification for SubstrateML: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/SUBSTRATEML_INTERFACE.md
  - docs/reference/SUBSTRATETYPES_SPEC.md
  - docs/reference/SUBSTRATEKERNEL_SPEC.md
  - docs/reference/SUBSTRATELIB_SPEC.md
  - docs/engineering/HARNESS_REFERENCE.md#6-the-four-package-substrate-split
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md
purpose: |
  SubstrateML is Layer 3 of the four-package substrate: the
  cold-path and federation-driven algorithms over the value types
  in SubstrateTypes and the kernel primitives in SubstrateKernel.
  It owns the audit-log fold, the matrix decay model, Bradley-Terry
  preference estimation, NMF factorization, FFT, eigenvalue
  centrality, random walks, lattice distance, anomaly detection,
  community detection, feature extractors for ambient signals,
  float-input SimHash, the moment-summary windowed roll-up,
  partial-state recall, the pairing handshake, the tier-contribution
  fingerprint, the tier-ascending federation query, the
  action-outcome matrix, the DP-OR temporal reduction, the LLM
  calibration curve, and the temporal-compression window. The
  companion INTERFACE document carries the bilingual signatures.
---

# SubstrateML Specification

## § 1 — What this package is

SubstrateML is the cold-path and federation-driven algorithm layer.
"Cold-path" means: invoked during the dreaming pass, maintenance
daemons, federation handshakes, or other off-hot-path workflows.
"Federation-driven" means: the algorithms that compute artifacts
peers exchange — tier-contribution fingerprints, federation queries,
the pairing nonce.

This package is a **Lib**: pure functions and value types with no
managed state, no actors, no lifecycle, no I/O. Algorithms here
operate on values from SubstrateTypes (rows, fingerprints, HLC,
matrices), call into SubstrateKernel for hot-path primitives where
needed (SimHash signing, Hamming distance, OR-reduce), and return
new values.

The split between SubstrateKernel (hot path) and SubstrateML (cold
path) tracks the §17.6 cookbook performance gate: kernel operations
have hard latency budgets and run on every audit-write hot path;
ML algorithms have no such budget and run during dreaming, on
periodic compaction, or on federation events. A consumer reaching
for an algorithm here can assume it allocates, may take
milliseconds-to-seconds on realistic inputs, and is intended to
run off the hot path.

## § 2 — Scope

This specification defines:

- **Audit log fold** (`AuditLogFold`) — the projection that
  reconstructs visible row state from the G-Set audit log,
  ordered by HLC.
- **Matrix decay model** (`MatrixDecay`, `DecayingMatrix`) — the
  half-life-based aging applied to MatrixC/O/T per cookbook §6.
- **Bradley-Terry preference estimation** (`BradleyTerryEstimator`) —
  online SGD per cookbook §8.12.
- **NMF factorization** (`NMFAlternatingLeastSquares`) — non-negative
  matrix factorization per cookbook §8.6.
- **FFT and rhythm detection** (`FFT`, `RhythmResult`) — per cookbook
  §8.7.
- **Eigenvalue centrality** (`EigenvalueCentrality`) — graph
  centrality over the tunnel graph, cookbook §8.9.
- **Random walks** (`RandomWalks`, `SplitMix64`) — random walks
  with a deterministic PRNG for reproducibility, cookbook §8.10.
- **Sampling** (`Sampling`) — deterministic continuous-distribution
  samplers (Normal via Box-Muller, Gamma via Marsaglia-Tsang, Beta via
  the Gamma ratio) over `SplitMix64`, cookbook §8.17. The sampling math
  underneath the Thompson-Sampling dreaming-trigger bandit;
  conformance-gated to f64 bit-identity.
- **Shingle similarity** (`ShingleSimilarity`) — character-shingle
  Jaccard set similarity (3-gram lowercase, `|∩|/|∪|` as f32),
  cookbook §8.20. The substrate home for the recall-ranking diversity
  (MMR) similarity term that NeuronKit and GeniusLocusKit currently
  duplicate; conformance-gated to f32 bit-identity.
- **Lattice distance** (`UDCTreeDistance`, `LatticeDistance`,
  `LatticeAnchorStr`, `WikidataAdjacencyProvider`) — distance
  between two lattice anchors per cookbook §8.11.
- **Composite distance** (`CompositeDistance`) — the weighted
  combination of semantic + temporal + lattice distances used by
  recall scoring per cookbook §8.5.
- **Anomaly detection** (`AnomalyDetection`) — outlier detection
  in observation streams, cookbook §8.13.
- **Community detection** (`CommunityDetection`) — community
  partitioning over the tunnel graph, cookbook §8.14. Two entry
  points: `detect` (Louvain phase 1 — the per-level local-move
  engine) and `detectFull` (full Louvain: phase 1 + phase-2
  aggregation loop, with a Reichardt–Bornholdt resolution
  parameter, default 1.0).
  - `detect` carries a documented **pair-locking limitation**: on
    graphs dominated by strongly-bonded pairs (e.g. tunnel bonds,
    w = 1.0) with weaker star bonds (lattice bonds, w = 0.2),
    phase-1 local-move can never pull a member out of its pair —
    the move is strictly negative modularity. At resolution 1.0
    the pair partition is the true modularity optimum, so
    `detectFull(resolution: 1.0)` correctly preserves it.
  - The cure for pair-locking is the **resolution parameter**: a
    supernode with degree k and edge weight w into a target
    community merges whenever γ < w/k, scale-invariantly. Small γ
    (e.g. 0.05) absorbs pair supernodes into hub communities
    without merging large continents over weak bridges (their
    thresholds shrink as w_bridge/m).
  - **Determinism rules** (cross-leg bit-identity): candidate
    communities are evaluated in ascending label order (gain ties
    resolve to the lowest label); labels are canonicalized at
    every level (the label doubles as the supernode index);
    condensation accumulates in ascending node order and emits
    each supernode's adjacency in ascending neighbor order;
    internal weight lands twice on the supernode self-loop
    (degree-preserving — 2m is invariant across levels).
- **Feature extractors** (`FeatureExtractors`, `AmbientSampleRow`,
  `HealthKitSample`, `StreamSourceFlag`) — extract featurized rows
  from ambient signal sources (CoreLocation, EventKit, HealthKit,
  ScreenTime, SystemTelemetry), cookbook §11.4.
- **Float-input SimHash** (`FloatSimHash`) — SimHash variant that
  accepts external-provider float embeddings, cookbook §17.5.
- **Moment summary** (`MomentSummary`, `RowLite`) — windowed
  statistical roll-up over recent rows, cookbook §8.16.
- **Partial state recall** (`PartialStateRecall`) — recall against
  partial fingerprint masks, cookbook §11.7.
- **Pairing handshake** (`PairingHandshake`, `PairingNonce`,
  `PairingRecord`) — federation peer-pairing protocol, cookbook §12.3.
- **Tier contribution fingerprint** (`TierContributionFingerprint`,
  `TierContribution`, `FederationCase`) — federation per-tier
  contribution shape, cookbook §12.5.
- **Tier ascending query** (`TierAscendingQuery`, `TargetTier`,
  `PeerResponse`) — federation query protocol, cookbook §12.7.
- **Action-outcome matrix** (`ActionOutcomeMatrix`,
  `ActionOutcomeKey`, `ActionOutcomeCell`) — cookbook §6.5 keyed
  causal matrix.
- **DP-OR temporal reduction** (`DPORReduction`, `DPParameters`) —
  differential-privacy-style temporal OR-reduce, cookbook §8.18.
- **LLM calibration curve** (`LLMCalibrationCurve`) — confidence
  recalibration for external LLM outputs, cookbook §8.19.
- **Information theory** (`InformationTheory`) — entropy / KL /
  mutual-information primitives.
- **Temporal compression** (`TemporalCompression`, `TemporalWindow`,
  `WindowLevel`) — multi-level temporal-window roll-up, cookbook §15.2.
- **Association-rule mining** (`mineAssociationRules`, `AssociationRule`,
  `Item`, `MiningThresholds`) — pairwise co-occurrence rules over `MatrixO`,
  cookbook §6.3. Pure engine: `MatrixO` + active row count + threshold scalars
  in, ranked `[AssociationRule]` out. No estate, no clocks, no I/O.
- **Bounded formal concept analysis** (`FormalContext`, `FormalAttribute`,
  `FormalConcept`, `BoundedConceptMiner`, `StabilityEstimator`) — finds
  exact attribute closures (emergent provenance and about-ness clusters)
  over a materialized row × attribute context, with optional sampled
  Kuznetsov stability estimation. Pure engine: fully-materialized
  `FormalContext` in, ranked `[FormalConcept]` out. Randomness only when
  `stabilityBudget > 0` (deterministic via explicit seed).
  Bounding contract: seeds are by default frequent single attributes
  (`.single` mode); `.multi` mode additionally seeds from frequent
  2-attribute pairs; one closure per seed; deduplicated by intent; no
  full lattice enumeration. Stability is sampled-only, never exact.
  The audit-log-backed context builder lives in `GeniusLocusKit`
  (`EstateFormalConcepts`). The recipe wrapper lives in `CognitionKit`
  (`FormalConcepts`).
- **Bounded Duquenne–Guigues canonical basis** (`Implication`,
  `ConceptImplications`) — computes sound logical implications over a
  `FormalContext` via bounded D-G pseudo-intent enumeration (Ganter &
  Wille §7). Every emitted implication holds universally: any row
  carrying all attributes in `premise` also carries all attributes in
  `conclusion`. Enumeration visits subsets of the attribute universe in
  non-decreasing size order (lexicographic within each size); each
  candidate is tested against the two D-G pseudo-intent conditions
  ((1) not closed, (2) all smaller pseudo-intent conclusions fit inside
  the candidate). Output is sorted for determinism (premise size asc,
  lex premise, lex conclusion). Two bounding caps: `maxImplications`
  (hard cap; `isTruncated == true` when triggered) and `maxPremiseSize`
  (size filter; never sets `isTruncated`). Both Swift and Rust
  implementations pass the four-way conformance gate on canonical vectors
  `concept_implications.json`. The estate-backed entry point lives in
  `GeniusLocusKit` (`EstateFormalConcepts.conceptImplications`). The
  recipe surface lives in `CognitionKit` (`FormalConcepts.Output.implications`).

This specification does NOT define:

- API signatures — those live in `SUBSTRATEML_INTERFACE.md`.
- The value types these algorithms operate on — those live in
  `SUBSTRATETYPES_SPEC.md`.
- Hot-path primitives these algorithms call into — those live in
  `SUBSTRATEKERNEL_SPEC.md`.
- Verb mechanics that use these algorithms — those live in
  `SUBSTRATELIB_SPEC.md`.
- The dreaming daemon orchestration — lives in `NEURONKIT_SPEC.md`.
- The estate-backed `MatrixO` wiring that feeds `mineAssociationRules` —
  that belongs in `GeniusLocusKit`. SubstrateML owns the pure algorithm;
  GeniusLocusKit owns the estate-tier orchestration that supplies inputs.
- The estate-backed context builder that maps audit-log entries to
  `FormalAttribute` triples — that belongs in `GeniusLocusKit`
  (`EstateFormalConcepts`). SubstrateML owns the pure FCA engine;
  GeniusLocusKit owns the estate-tier orchestration that materializes
  the `FormalContext`.

## § 3 — Position in the kit family

```
              SubstrateLib            (orchestration; verbs call into AuditLogFold for state reconstruction)
                ↑    ↑    ↑
       SubstrateML  ↑   SubstrateKernel
              ↗     ↑
       SubstrateTypes
       ↑       ← THIS PACKAGE depends on Types + Kernel
```

**Depends on:** `SubstrateTypes`, `SubstrateKernel`.

**Consumed by:** `SubstrateLib` (audit-log fold, matrix decay called
from the verb mechanics), `VectorKit` (one site: SimHash projection
for content embedding), `CorpusKit` (FloatSimHash for provider
embeddings; lattice distance for corpus indexing), `LocusKit`
(AuditLogFold for projection at HLC, MatrixDecay for adjective-aging,
TierContributionFingerprint for federation, MomentSummary for
session-level roll-ups).

## § 4 — Invariants

- **I-30.** The substrate ships as four packages. SubstrateML is
  Layer 3.

ML-specific:

- **ML-1.** Every algorithm here is *pure*: given the same inputs
  it returns the same outputs. Algorithms that need randomness
  take a seeded PRNG (e.g. `SplitMix64`) as an explicit parameter;
  there is no hidden time-of-day or system-entropy source.
- **ML-2.** The audit-log fold is order-stable: folding the same
  set of audit entries in any order, sorted by HLC, produces the
  same `ProjectedRowState`.
- **ML-3.** Matrix decay is multiplicative: a matrix decayed by
  half-life `h` over duration `d` has every cell multiplied by
  `exp(-d / h * ln 2)`. This composes: decay over `d1 + d2` equals
  decay over `d1` then decay over `d2`.
- **ML-4.** Bradley-Terry estimation is monotone: an additional
  observation favoring item `A` over item `B` either increases
  `A`'s estimated strength or leaves it unchanged; never decreases.
- **ML-5.** Federation algorithms (`PairingHandshake`,
  `TierContributionFingerprint`, `TierAscendingQuery`) produce
  outputs that are bit-identical across ports per I-7. Peers
  running different ports must agree on every value exchanged.

## § 5 — Behavioral contracts

### § 5.1 AuditLogFold

`projectStateAt(rowId:asOf:log:)` reconstructs the projected state
of `rowId` as of HLC `asOf`. The fold walks the row's audit entries
in HLC order, applying each event's `after` value to the running
state, stopping at the first entry with HLC > `asOf`. The result
includes the projected bitmaps, the lattice anchor at that HLC,
the state enum, and the asOf HLC itself.

If `rowId` has no entries at or before `asOf`, the fold returns
`nil` (row didn't exist yet). If `rowId` has entries but is in a
terminal state, the fold returns the terminal projection.

### § 5.2 MatrixDecay

`DecayingMatrix` wraps a matrix value (MatrixC / MatrixO / MatrixT)
with its last-touched HLC. `decay(by:halfLife:asOf:)` returns a new
`DecayingMatrix` with cells aged according to ML-3.

`DecayHalfLives` is the static table of per-matrix-kind half-lives
per cookbook §6.4 (MatrixC: 30 days, MatrixO: 14 days, MatrixT:
7 days; subject to revision).

### § 5.3 BradleyTerryEstimator

Online SGD over `PreferenceObservation`s. Each observation is a
pairwise preference `(winner, loser, weight)`. `update(_:)` advances
the per-item strength estimates; `strength(_:)` reads the current
estimate. The estimator is monotone per ML-4.

### § 5.4 NMFAlternatingLeastSquares

Non-negative matrix factorization.
`factorize(V:rank:maxIterations:tolerance:seed:)` returns an
`NMFFactorization` of the input matrix `V` into two non-negative
factors `W` and `H` such that `W × H ≈ V`. The algorithm uses
Lee-Seung multiplicative updates, which preserve non-negativity
without explicit projection.

**Domain preconditions** (enforced at entry; §6): `V` must be
rectangular (every row the same column count), all entries finite,
and all entries `≥ 0`. Negative input violates the Lee-Seung theorem
and produces undefined output; the engine rejects it rather than
trapping incidentally or returning garbage.

### § 5.4b NMFDoubleFrobeniusSquared

**Experimental — not yet validated for production. See
`docs/validation/substrate_math_performance/`.**

Double-precision NMF with Frobenius-squared `||O - WH||_F^2` convergence
criterion and floored SplitMix64 initialization (`max(raw, 1e-3)`).

This is an alternate, double-precision NMF algorithm to
`NMFAlternatingLeastSquares` (the canonical f32 RMS algorithm). The
canonical algorithm is `NMFAlternatingLeastSquares`; this f64/Frobenius²
variant is provided so the two approaches can be benchmarked honestly.

Do not wire any production consumer to this variant until it has passed
`docs/validation/substrate_math_performance/` benchmarking:
- Iteration count to convergence vs `NMFAlternatingLeastSquares`
- Wall-time comparison
- Memory footprint
- Recall-quality impact on the estate matrix pipeline

Any SIMD, Metal, BLAS, or NEON acceleration for this f64 variant also
carries FMA-divergence risk and is itself subject to perf-eval-before-
production. The scalar cross-port (Swift ↔ Rust) is the gated floor today.

**Correctness conformance** (the production gate applies to performance,
not correctness): despite the production gate, the Swift and Rust scalar
ports must produce bit-identical output for identical inputs. Cross-port
conformance vector: `nmf_double_frobenius_squared.json`.

`factorize(o:rows:cols:rank:seed:maxIterations:tolerance:)` returns
`NMFDoubleFrobeniusSquaredFactorization` (all `Double` fields).
Default seed: `0xC0FFEE_BABE_BEEF`. Default tolerance: `1e-6` (Frobenius²
delta, distinct from the `1e-4` RMS delta of `NMFAlternatingLeastSquares`).

### § 5.5 FFT

`forward(_ signal:)` and `inverse(_ spectrum:)` over `Complex`
arrays. Power-of-two lengths only. `RhythmResult` is the convenience
shape returned by `detectRhythm(signal:samplingRate:)`.

### § 5.5a Sampling

`Sampling` exposes three deterministic continuous-distribution
samplers over a caller-threaded `SplitMix64`: `sampleNormal` (Box-Muller,
fixed two-uniform consumption), `sampleGamma(shape:)` (Marsaglia-Tsang
for shape ≥ 1, Ahrens-Dieter reduction for shape < 1; precondition
`shape > 0`), and `sampleBeta(alpha:beta:)` (the Gamma ratio;
precondition `alpha, beta > 0`). All randomness routes through
`RandomWalks.uniform01`; the samplers do not re-own the PRNG (ML-4-class
determinism, invariant on seeded PRNG-as-parameter).

Cross-port behavior is exact f64 bit-identity given the same seed and
starting RNG state — the same conformance regime as FFT (§5.5):
transcendentals (`ln`, `sqrt`, `cos`, `pow`) resolve to platform libm,
which the substrate gates to bit-equality across the Swift and Rust
scalar ports. Conformance vector `sampling` (CRC `0xfc883023`, cookbook
§8.17). Sampling is scalar-only; there is no SIMD or Metal path.

### § 5.5b ShingleSimilarity

`ShingleSimilarity` exposes the character-shingle Jaccard set similarity
used by recall-ranking diversity (MMR) passes. `shingles(_:)` builds the
set of 3-character lowercase shingles of a string (1–2 chars collapse to
a single whole-string shingle; `""` yields the empty set);
`similarity(_:_:)` returns `|S(a) ∩ S(b)| / |S(a) ∪ S(b)|` as f32, with
both-empty inputs defined as 0.0. The function is a pure function of its
two string arguments — no locale-sensitive transforms, no clock, no
randomness (ML-4-class determinism).

This is the substrate home for math currently duplicated above the
substrate: `NeuronKit`'s `HybridRecallEngine` rerank similarity term and
`GeniusLocusKit`'s `RecallDirector` unionBest dedup term both compute the
identical 3-gram Jaccard. The duplication's stated reason — GLK cannot
depend on NeuronKit — does not apply to SubstrateML, which both kits
already depend on; per I-25 the math has one owner here and the kits
delegate (rewire is a follow-up). Cross-port behavior is exact f32
bit-identity: the value is a ratio of two integer set cardinalities, so
no transcendental is involved. Conformance vector `shingle_similarity`
(CRC `0x8a5d8888`, cookbook §8.20). Scalar-only; no SIMD or Metal path.

### § 5.6 EigenvalueCentrality

`computeCentrality(graph:iterations:)` returns a vector of per-node
centrality scores. Power-iteration based.

### § 5.7 LatticeDistance / UDCTreeDistance

`UDCTreeDistance.distance(_ a: String, _ b: String)` returns the
UDC tree distance normalized to [0, 1] (cookbook §8.3).

**Normalization choice:** the divisor is `lenA + lenB`, NOT
`max(lenA, lenB)`. Proof of bound: when `lcp = 0`,
`raw = lenA + lenB = divisor`, so the output is 1.0 at worst.
Using `max(lenA, lenB)` would allow outputs greater than 1 (for
example "004" vs "37": raw=5, max=3, d=5/3 ≈ 1.667).

`WikidataAdjacencyProvider` is the protocol consumers implement to
supply Wikidata-adjacency information; this package does not embed
a Wikidata snapshot.

`LatticeDistance.distance(_:_:provider:alphaUDC:alphaQID:)` combines
the UDC tree distance with Wikidata graph distance into a single
distance score in [0, 1] when `alphaUDC + alphaQID = 1`.

### § 5.8 CompositeDistance

`CompositeDistance.distance(latticeDistance:fingerprintHammingDistance:alphaLattice:alphaFingerprint:compatibleSeedScope:)`
combines lattice and fingerprint distances into a single recall score.

**Precondition:** both component distances must be in [0, 1]. The
Swift implementation traps via `precondition()` on out-of-range
inputs; the Rust implementation uses `debug_assert!`. Callers that
derive `latticeDistance` from `LatticeDistance.distance` and
`fingerprintHammingDistance` from `SimHash.hammingDistance` satisfy
the precondition by construction. The weights are caller-supplied
per cookbook §8.5.

### § 5.9 FeatureExtractors

`extractAmbientSample(source:rawRecord:hlc:)` produces an
`AmbientSampleRow` from a raw ambient-signal record. `source` is
`StreamSourceFlag` (one of `.coreLocation`, `.eventKit`, `.healthKit`,
`.screenTime`, `.systemTelemetry`). The extractor normalizes the
record into the substrate's row shape.

### § 5.10 FloatSimHash

Variant of SimHash that accepts float-valued embedding vectors from
external providers (e.g. an embedding API). `sign(embedding:family:)`
produces a `Fingerprint256` whose bits are the sign of the dot
product between the embedding and each hyperplane.

### § 5.11 MomentSummary

`summarize(rows:window:asOf:)` produces a `RowLite` statistical
summary of a windowed slice of recent rows. Used by the maintenance
daemon for session-level roll-ups.

### § 5.12 PartialStateRecall

`recall(query:mask:candidates:topK:)` is a SimHash recall variant
that ignores bits outside the `mask`. Used when only part of a row's
fingerprint is meaningful (e.g. specific feature axes).

### § 5.13 PairingHandshake

`PairingNonce` is the per-peer challenge; `PairingRecord` is the
agreed-pairing record stored after a successful handshake.
`generateNonce(now:)` produces a nonce; `validate(nonce:response:)`
checks a peer's response.

### § 5.14 TierContributionFingerprint, TierAscendingQuery

Federation per-tier shape (cookbook §12.5–12.7).
`TierContribution(tier:fingerprints:)` captures one peer's
contribution to a given tier; `TierContributionFingerprint` is the
namespace for combining contributions. `TierAscendingQuery` is the
query protocol: a peer issues a query for a target tier, peers
respond with their contributions, the issuer aggregates.
`FederationCase` enumerates the federation handling cases per
cookbook §12.2.

### § 5.15 ActionOutcomeMatrix

Cookbook §6.5 causal matrix. Keyed by `(actionKind, outcomeCategory)` —
both 6-bit fields (bitmaps o07/o08). Each `ActionOutcomeCell` accumulates
`successCount` and `totalCount` (plus `lastUpdateHLC`); the empirical
`successRate` and a 95 % `wilsonLowerBound` are derived from those counts.
`observe(action:outcome:success:at:)` records one observation.
`topActions(forOutcome:k:minObservations:)` selects the best actions for an
outcome ranked by the Wilson lower bound (so under-observed cells don't float
to the top) and returns all four signals — `(action, rate, wilsonLowerBound,
count)` — so callers rank and read from the same values rather than re-deriving
a raw rate that would imply a different ordering.

### § 5.16 DPORReduction

Differential-privacy-style temporal OR-reduce. `reduce(window:params:)`
takes a window of events and produces a privacy-budgeted reduction.
`DPParameters` carries the budget.

### § 5.17 LLMCalibrationCurve

`LLMCalibrationCurve(observations:)` builds a recalibration curve
from observed (predicted, actual) pairs. `calibrate(_:)` adjusts a
new prediction using the curve.

### § 5.18 InformationTheory

`entropy(_:)`, `klDivergence(_:_:)`, `mutualInformation(_:_:)`
operating on `[Double]` probability distributions.

### § 5.19 TemporalCompression

`WindowLevel` enumerates the multi-resolution windows (`hour`,
`day`, `week`, `month`, `season`, `year`). `TemporalWindow` is a
single window's `(level, range)` pair. `TemporalCompression.compress
(events:to:)` compresses an event stream into a coarser window
level.

### § 5.20 AssociationRuleMining

Pairwise co-occurrence rule mining over `MatrixO` (cookbook §6.3).

`mineAssociationRules(matrix:activeRowCount:thresholds:)` mines all
single-antecedent → single-consequent rules with support and
confidence at or above `MiningThresholds` thresholds. The five
metrics per rule — `support`, `confidence`, `lift`, `leverage`,
`conviction` — are derived from the co-occurrence counts and
`activeRowCount` (injected by the caller; the engine never derives
it from the matrix). When `confidence == 1.0`, `conviction` is
`+infinity`.

Rules are emitted in ascending packed `(antecedent, consequent)`
key order — total, deterministic, and identical across the Swift and
Rust ports. The diagonal (`O[A,A]`) provides single-item support
but is never emitted as a rule (an `A → A` self-rule has
`confidence ≡ 1` and carries no information). Off-diagonal cells
`O[A,B]` without a corresponding diagonal entry on either side
are silently skipped (engine guard; reachable only via
decay/expunge imbalance).

`activeRowCount <= 0` returns an empty rule list immediately.

### § 5.20a RowAttributeView

Row-replay shape extractor for audit-log–based mining. Converts a
`[RowAuditEntry]` (SubstrateML-native, see §5.20b) into a
`[RowAttributeView]` — one view per (tier, rowID) pair — each holding
a sorted `[(field: UInt8, value: UInt8)]` attribute list.

**Input type `RowAuditEntry`** (`tier`, `rowID`, `fieldPath`, `hlc`,
`value: RowAuditValue`) carries one audit event. `RowAuditValue` is the
SubstrateML-native counterpart to `UnifiedAuditValue`; GeniusLocusKit
converts at the kit boundary to preserve layer separation.

**Extraction algorithm** (pure, deterministic):
1. Build a vocabulary: sorted unique fieldPaths across all entries,
   capped at 64. Field index = vocabulary position.
2. Group entries by `(tier, rowID)`.
3. For each group, for each fieldPath in vocabulary order, take the
   entry with the latest HLC (latest-write-wins deduplication).
4. Extract attributes:
   - `.bitmap(v)`: each set bit → `(field: vocabIdx, value: bitPosition)`.
     Zero bitmaps are dropped. Up to 64 items per field.
   - `.integer(n)`: low byte `UInt8(n & 0xFF)` → `(field: vocabIdx, value: lowByte)`.
   - `.null`: dropped (no categorical content).
5. Output: `RowAttributeView` values sorted by `(tier, rowID.uuidString)`
   for deterministic downstream mining.

**Use by Apriori**: `RowAttributeView.from(auditEntries:)` is the
entry point. Each resulting `RowAttributeView.attributes` array becomes
one `[Item]` row for `AprioriMining.mine`.

**Conformance**: deterministic for identical inputs on any platform.
No Rust port (pure Swift, only used via GeniusLocusKit's Apriori path).

### § 5.20b AprioriMining

Multi-antecedent association-rule mining over row-replay data (Agrawal
& Srikant 1994 Apriori algorithm). Complements `AssociationRuleMining`
(§5.20) with k-item antecedents.

**Input**: `[RowAttributeView]` (from §5.20a) and `AprioriThresholds`
(`minSupport`, `minConfidence`, `minLift`, `maxK`). `maxK` is the
maximum total itemset size (antecedent count + 1); minimum effective
value is 2 (promoted from lower values).

**Output type `AprioriRule`**: `antecedent: [Item]`, `consequent: Item`,
plus `support`, `confidence`, `lift`, `conviction`, `leverage`,
`evidenceCount: Int`. `conviction` is `+infinity` when `confidence ==
1.0`. Antecedent items are sorted ascending on packed key.

**At `maxK = 2`** (one antecedent item) the output is equivalent to
`mineAssociationRules` on the same row data.

**Algorithm outline**:
1. Convert each row to a `Set<Item>` for O(1) subset testing.
2. Level 1: count frequent 1-itemsets (support ≥ minSupport).
3. Join: generate size-k candidates from frequent (k-1)-itemsets that
   share a lexicographic prefix of length k-2 (Apriori join step).
4. Count candidate support via subset tests.
5. Prune below minSupport. Repeat 3-5 until k > maxK or no candidates.
6. Extract rules from all frequent itemsets of size ≥ 2 (iterated in
   canonical sorted order, not dictionary hash order): each item can
   be the consequent.
7. Filter by minSupport, minConfidence, minLift.
8. Sort: lift DESC, confidence DESC, evidenceCount DESC, then
   lexicographic (antecedent packed keys ASC, consequent packed key
   ASC).

**Total-order determinism**: the four-key sort plus canonical-order
itemset iteration make the output a total order. Equal-metric ties
resolve lexicographically rather than by dictionary hash order, so
Swift and Rust produce bit-identical output regardless of their
differing dictionary implementations.

**Free function**: `mineAprioriRules(rows:thresholds:)` is a thin
wrapper around `AprioriMining.mine(rows:thresholds:)` for call-site
convenience.

**Conformance vectors**: `docs/engineering/substrate_reference/
test-harness/vectors/apriori_mining.json`. Both Swift and Rust ports
must produce identical rules for each case.

**Rust port**: `substrate-ml/src/apriori_mining.rs` re-uses
`crate::association_rule_mining::Item`.

### § 5.21 FormalConceptAnalysis

Bounded formal concept analysis over a materialized `FormalContext`
(this is a pure engine — it reads no estate, no `MatrixO`, no clocks,
no randomness).

**Bounding contract** (the reason this is "bounded" FCA):
- Seeds are frequent single attributes only (support ≥ `minSupport`)
  in `.single` mode (the default, v1 behaviour).
- Optional multi-seed pass (`seedMode: .multi`): additionally seeds
  from frequent 2-attribute pairs, each pair tried up to `maxSeeds`
  times. Discovers concepts whose minimal generator is a pair rather
  than a singleton. Still bounded: O(|frequent|²) additional closures,
  capped by `maxSeeds`.
- ONE closure per seed (not full lattice enumeration, in either mode).
- Deduplicated by intent (two seeds whose closure is the same set of
  attributes produce one concept, not two).
- Truncated to `maxConcepts` after sorting.
- `FormalConcept.stability` is `nil` by default (when
  `stabilityBudget == 0`). Set `stabilityBudget > 0` on the miner to
  populate it via `StabilityEstimator`. The exact Kuznetsov stability
  is exponential and is never computed — only the sampled estimate is
  available.

**Sampled Kuznetsov stability** (`StabilityEstimator`):

`StabilityEstimator.estimate(concept:context:budget:seed:)` approximates
Kuznetsov stability by Bernoulli(p=0.5) sampling over the concept's
extent. For each of `budget` independent draws, a random subset of the
extent rows is selected (each row independently included with probability
0.5), the FCA `intent` operator is applied to the subset, and a "hit"
is counted when the resulting intent equals the concept's full intent.
The stability estimate is `hits / budget`.

**Empty-subset semantics**: the empty subset's intent is the full
attribute universe (standard FCA convention). For a concept whose
intent equals the full universe, all draws — including the empty subset
draw — count as hits.

**Per-concept RNG isolation**: the per-concept seed is
`globalSeed XOR fnv64(canonicalKey(concept))`. The canonical key is
`"rowID0,rowID1,...|ns:key:val|ns:key:val|..."` (extent indices
comma-joined; intent attributes, already sorted ascending, pipe-joined
as `namespace:key:value`). This gives each concept an independent PRNG
stream regardless of miner call order.

**Canonical conformance seed**: `0xCAFEBABEDEADBEEF`. Conformance
vectors are at
`docs/engineering/substrate_reference/test-harness/vectors/fca_stability.json`.
Both Swift and Rust ports must produce bit-identical output on these
vectors. The Swift implementation uses `SplitMix64` (from `RandomWalks`)
and `FNV.hash64` (from `SubstrateTypes`); the Rust implementation uses
`crate::random_walks::SplitMix64` and `substrate_types::fnv::hash64`.

`FormalContext(rows:)` materializes a context from per-row attribute
sets. Row `i` of `rows` becomes `RowID(i)`. The attribute universe is
the sorted union across all rows; duplicate attributes within a row are
collapsed. `extent(of:)` and `intent(of:)` are the standard FCA
derivation operators; `closure(of:)` is idempotent.

`FormalContext.from(rowAttributeViews:)` builds a context from
`[RowAttributeView]` — the canonical row-replay input shape shared
with `AprioriMining`. Each `(field, value)` pair becomes
`FormalAttribute(namespace:"row", key:String(field), value:String(value))`.

`BoundedConceptMiner.mine(context:)` returns concepts sorted by support
descending, then intent size ascending, then lexicographic intent (the
stable key), truncated to `maxConcepts`. Cost is O(|attributes| ×
closure) — polynomial, no exponential path.

Output is deterministic and identical across the Swift and Rust ports.

**Cover deltas (structural lens):**

`ConceptCoverDeltas.covering(concepts:)` derives the cover-delta set
over the emitted concept set — a structural lens over the concept order.
For each pair of concepts `(A, B)` where `A.intent ⊂ B.intent` and no
intermediate concept `C` in the input has `A.intent ⊂ C.intent ⊂
B.intent`, the function emits a `CoverDelta`:

    lowerIntent = A.intent
    addedAttributes = B.intent − A.intent

**This is NOT the Duquenne–Guigues canonical basis.** It is the
cover-relation structural lens over the emitted concept set:

- **Structural** — every delta holds within the emitted concept set
  (`lowerIntent` and `lowerIntent ∪ addedAttributes` both correspond
  to emitted concepts).
- **Not universally sound** — a cover delta does NOT assert that every
  row carrying `lowerIntent` also carries `addedAttributes`. Rows not
  in the more-specific concept's extent may carry `lowerIntent` without
  `addedAttributes`.
- **Incomplete** — some implications in the full D-G canonical basis
  may be omitted (those not captured by a direct cover relation in the
  emitted set).

Callers treat cover deltas as structural lattice summaries, not
universally valid rules. For sound logical implications (the full
Duquenne–Guigues canonical basis), see `ConceptImplications`.

The cover-delta set is sorted: `lowerIntent` size ascending, then
lexicographic on `lowerIntent`, then lexicographic on `addedAttributes`.
Output is deterministic and identical across Swift and Rust.

### § 5.22 TemporalCausalityFold

Pure fold engine for the T (temporal causality) matrix population pass
(cookbook §6.4). Invoked by `MatrixTier.rebuildTemporal(from:)` in
GeniusLocusKit on each hourly TemporalCausalitySignal fire per
the temporal-matrix cadence.

**Input types** (local to SubstrateML — GeniusLocusKit maps at the kit
boundary to avoid a circular import):
- `TemporalAuditEntry`: `hlc: HLC`, `fieldCoords: [TemporalFieldCoord]`
- `TemporalFieldCoord`: `fieldPath: String`, `valueRepr: String`
- Entries must be pre-sorted ascending by HLC (caller responsibility).

**Output**: `(deltas: [(TemporalCausalityKey, Int64)], newWatermark: HLC)`
- `TemporalCausalityKey`: `(source: TemporalFieldCoord, target: TemporalFieldCoord, lagBucket: Int)`
- Deltas in stable insertion order (source HLC ascending).

**Algorithm** (cookbook §6.4 update rule):
```
for each new entry E (HLC > startWatermark):
    evict from buffer entries where minuteDiff(E, older) > windowMinutes
    for each older entry O in buffer:
        deltaMinutes = max(1, (E.hlc.physicalTime - O.hlc.physicalTime) / 60_000)
        bucket = lagBucket(deltaMinutes)
        for each srcCoord in O.fieldCoords:
            for each tgtCoord in E.fieldCoords:
                emit delta[(srcCoord, tgtCoord, bucket)] += 1
    add E to buffer
    advance newWatermark to E.hlc
```

**Lag bucket function** (canonical): smallest boundary ≥ deltaMinutes from
{1, 2, 4, 8, 16, 32, 64, 128}; clamped to 128 above. This is the canonical
implementation; GeniusLocusKit's `MatrixTier.lagBucket(forMinutes:)` delegates
to it.

**Window cap**: 256 minutes (defaultWindowMinutes). Entries farther apart
than windowMinutes are excluded by buffer eviction before pairing.

**Determinism**: same sorted input, same startWatermark, same windowMinutes →
identical deltas in identical order. No clocks or randomness.

**Conformance vectors**: `docs/engineering/substrate_reference/
test-harness/vectors/temporal_causality_fold.json`. Swift and Rust ports must
produce identical deltas on canonical test cases.

## § 6 — Error model (conceptual)

ML algorithms here reject out-of-domain input at the public entry
point via precondition (process-terminating, the substrate
convention for programmer-error contract violations):

- `NMFAlternatingLeastSquares.factorize` requires `V` rectangular
  (every row the same length), all entries finite (no NaN, no Inf),
  and all entries `≥ 0` (the Lee-Seung multiplicative-update theorem
  requires `V ≥ 0`).
- `RandomWalks.walk` requires a valid Markov kernel: every neighbor
  index in `[0, N)`, every edge weight finite and `≥ 0`.
  `RandomWalks.sampleWeighted` requires a non-empty neighbor list.
- `AprioriMining.mine` accepts any row set; out-of-domain enforcement
  is not applicable, but its output is a total order (see §5.20b).
- `FFT` raises on non-power-of-two signal lengths.
- `BradleyTerryEstimator` raises on observation weights ≤ 0.
- `PairingHandshake.validate` raises on signature mismatch.

All other failure modes are non-error returns (empty result,
`nil`, default-valued).

## § 7 — Conformance requirements

Per I-7 and ML-5, federation-affecting algorithms ship shared
conformance vectors:

- **AuditLogFold vectors:** fold the same audit log on Swift and
  Rust, get identical `ProjectedRowState`.
- **MatrixDecay vectors:** decay over fixed durations and half-
  lives, identical cell values across ports.
- **TierContributionFingerprint vectors:** identical fingerprints
  across ports for identical contributions.
- **PairingHandshake vectors:** identical nonce derivation across
  ports.
- **FloatSimHash vectors:** identical signing across ports given
  identical hyperplane families and identical input embeddings.

Other algorithms (Bradley-Terry, NMF, FFT, eigenvalue centrality,
random walks) are conformance-tested but not federation-critical;
small floating-point drift between ports is tolerated within an
ε-bound per algorithm.

**Association-rule mining** is deterministic on IEEE-754 integer
arithmetic (counts and multiplications of exact integers over N).
It is bit-for-bit conformance-gated:

- **AssociationRuleMining vectors:** 8 hand-computed cases from
  `docs/validation/substrate_math_performance/test-harness/vectors/association_rule_mining.json`.
  Both ports (Swift SubstrateML and Rust `substrate_ml`) must
  reproduce all metrics bit-for-bit. `conviction == +infinity`
  is encoded as IEEE-754 `+Inf` (`0x000000000000f07f` LE).

## § 8 — VizGraph telemetry layer

SubstrateML's five graph-analytic algorithms emit IntellectusLib telemetry
signals at their result boundary. This is the **VizGraph layer** — the
set of signals the moot-mgr Topology view reads to visualize graph-analytic
results in real time.

### § 8.1 Design principles

- **Off by default.** Monitoring is disabled at process start. The
  off-path cost is a single atomic-bool load plus a branch (~1 ns).
  The result value is bit-identical whether monitoring is enabled or
  disabled — the emit is a pure side-effect that does not alter outputs.

- **Caller-supplied timestamps.** The `ts: Double` parameter is the
  caller's wall-clock epoch time. SubstrateML never reads a clock
  internally per invariant ML-1 (every algorithm here is pure).

- **Estate tagging.** The `estate: String` parameter is forwarded to
  the metric's `tags` dictionary. Callers at the substrate layer pass
  `""` when no estate context is available; kit-layer callers
  (LocusKit, GeniusLocusKit) pass the estate identifier.

### § 8.2 The five VizGraph signals

| Metric name              | Algorithm                       | Value                  | Tags                                              |
|--------------------------|--------------------------------|------------------------|--------------------------------------------------|
| `community.assignment`   | `CommunityDetection.detect` / `detectFull` | community count | estate, node_count, community_count          |
| `centrality.score`       | `EigenvalueCentrality.compute` | 1.0 (completion)       | estate, node_count, iterations_to_convergence    |
| `nmf.factor`             | `NMFAlternatingLeastSquares.factorize` | final reconstruction error | estate, rows, cols, rank            |
| `anomaly.flag`           | `AnomalyDetection.rollingZScore` / `rollingModifiedZScore` | abs(z-score) | estate, method, window_size |
| `edge.decayed_weight`    | `MatrixDecay.apply`            | applied decay factor   | estate, matrix_rows, matrix_cols, elapsed_seconds|

Canonical metric name constants live in `VizGraphSignals.swift` (Swift)
and `viz_graph_signals.rs` (Rust). The string values are identical across
both ports.

### § 8.3 Emit site contract

Each algorithm emits exactly one sample per call when monitoring is
enabled. Early-return paths behave as follows:

- `CommunityDetection.detect`: empty or zero-weight input → returns
  immediately with no emit (no graph, no community signal to report).
- `CommunityDetection.detectFull`: same degenerate-input contract as
  `detect`; otherwise emits exactly ONE sample for the FINAL partition
  at the outer boundary regardless of how many aggregation levels run
  (the per-level phase-1 cores are non-emitting).
- `MatrixDecay.apply`: `dt == 0` (no time elapsed) → emits one sample
  with `value = 1.0` (identity factor, elapsed_seconds="0"). This
  distinguishes "the daemon checked but found no work" from "the daemon
  never ran."

All other algorithms: one sample unconditionally when monitoring is enabled.

### § 8.4 Dependency

IntellectusLib is a declared dependency of SubstrateML
(authority: `the package-dependency rule`).
The VizGraph emit is the only use of IntellectusLib in this package.

### § 8.5 Conformance

The emit does not affect algorithm outputs. The conformance requirement
for each algorithm (§ 7) is extended to include a monitoring conformance
check: the algorithm must produce bit-identical output when called with
monitoring enabled versus disabled, for the same inputs and seed. This is
verified by the `conformance*` tests in `VizGraphSignalsTests.swift` and
`viz_graph_signals_tests.rs`.

## Changelog

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
