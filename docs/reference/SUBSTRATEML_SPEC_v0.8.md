---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-05-29
version: v0.8
package: SubstrateML
kind: Lib
relates_to:
  - SUBSTRATEML_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - SUBSTRATETYPES_SPEC_v0.8.md    (Layer 1: the value types these algorithms operate on)
  - SUBSTRATEKERNEL_SPEC_v0.8.md   (Layer 2: hot-path primitives these algorithms compose)
  - SUBSTRATELIB_SPEC_v0.8.md      (umbrella: orchestration)
  - DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md (the four-package split, this is Layer 3)
  - GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md  (§6 matrices, §8 ML algorithms, §15 dreaming, §17 SimHash family)
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
- **Lattice distance** (`UDCTreeDistance`, `LatticeDistance`,
  `LatticeAnchorStr`, `WikidataAdjacencyProvider`) — distance
  between two lattice anchors per cookbook §8.11.
- **Composite distance** (`CompositeDistance`) — the weighted
  combination of semantic + temporal + lattice distances used by
  recall scoring per cookbook §8.5.
- **Anomaly detection** (`AnomalyDetection`) — outlier detection
  in observation streams, cookbook §8.13.
- **Community detection** (`CommunityDetection`) — community
  partitioning over the tunnel graph, cookbook §8.14.
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

This specification does NOT define:

- API signatures — those live in `SUBSTRATEML_INTERFACE_v0.8.md`.
- The value types these algorithms operate on — those live in
  `SUBSTRATETYPES_SPEC_v0.8.md`.
- Hot-path primitives these algorithms call into — those live in
  `SUBSTRATEKERNEL_SPEC_v0.8.md`.
- Verb mechanics that use these algorithms — those live in
  `SUBSTRATELIB_SPEC_v0.8.md`.
- The dreaming daemon orchestration — lives in `NEURONKIT_SPEC_v0.8.md`.

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

Non-negative matrix factorization. `factor(_ matrix:rank:iterations:)`
returns an `NMFFactorization` of the input matrix into two
non-negative factors `W` and `H` such that `W * H ≈ matrix`. The
algorithm uses alternating least squares with non-negativity
projection.

### § 5.5 FFT

`forward(_ signal:)` and `inverse(_ spectrum:)` over `Complex`
arrays. Power-of-two lengths only. `RhythmResult` is the convenience
shape returned by `detectRhythm(signal:samplingRate:)`.

### § 5.6 EigenvalueCentrality

`computeCentrality(graph:iterations:)` returns a vector of per-node
centrality scores. Power-iteration based.

### § 5.7 LatticeDistance / UDCTreeDistance

`UDCTreeDistance.distance(_ a: LatticeAnchorStr, _ b: LatticeAnchorStr)`
returns the tree distance between two UDC codes (cookbook §8.11).
`WikidataAdjacencyProvider` is the protocol consumers implement to
supply Wikidata-adjacency information; this package does not embed
a Wikidata snapshot.

`LatticeDistance.combined(_:_:wikidataAdjacency:)` combines the UDC
tree distance with optional Wikidata adjacency into a single
distance score.

### § 5.8 CompositeDistance

`CompositeDistance.score(semantic:temporal:lattice:weights:)`
combines the three component distances into a single recall score.
The weights are caller-supplied per cookbook §8.5.

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

## § 6 — Error model (conceptual)

ML algorithms here raise errors only on contract violations:

- `NMFAlternatingLeastSquares` raises on negative-cell inputs.
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
