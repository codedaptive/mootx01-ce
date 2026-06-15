# SubstrateML

The substrate's cold-path layer. Learning, graph algorithms, the
audit-log projection, and federation primitives. Mostly invoked
from the dreaming daemon, but several primitives also serve the
hot path (anomaly scoring, partial-state recall, audit-log fold
for as-of reads).

## When to use this package

Use this when you need to:
- Project a row's current or as-of state from its audit events
- Decay a matrix's cells by half-life
- Build a moment-summary fingerprint from a time window
- Update a Bradley-Terry weight vector from pairwise comparisons
- Score an ambient sample's anomaly z-score
- Compute entropy, mutual information, or KL divergence
- Compress detail buckets into hourly / daily rollups
- Score a partial-state recall query
- Run an FFT for rhythm analysis
- Factor an O-matrix into latent factors with NMF
- Compute eigenvalue centrality (keystone scores)
- Generate a tier-contribution fingerprint for federation
- Run a pairing handshake to mint shared hyperplane seeds

## DON'T reinvent these — they're conformance-gated

15 primitives in this package are byte-identical Swift+Rust under
the conformance harness. If you write a second NMF or a second
audit-log fold, CI will catch the drift.

### Tier 2 — algorithmic primitives

| Primitive | Cookbook § | CRC |
|---|---|---|
| `udc_tree_distance` (lattice) | §8.3 | `0x6c4e453f` |
| `entropy` / `mutual_information` / `kl_divergence` | §8.11 | `0x8d2f4a91` |
| `bradley_terry` online update | §8.12 | `0xb9c1a405` |
| `partial_state_recall` | §8.8 | `0xf6b08e2c` |
| `temporal_compression` | §8.14 | `0x2e9d7b13` |
| `anomaly` z-score | §8.13 | `0xa37c5b81` |
| `matrix_decay` (half-life) | §6.8 | `0x7b12f93d` |
| `moment_summary` | §8.7 | `0x6762440b` |
| `field_presence_matrix_f.apply_row` | §6.1 | `0x2a051f09` |

### Tier 3 — substrate-level operations

| Primitive | Cookbook § | CRC |
|---|---|---|
| `tier_contribution` | §12.3 | `0x8c9e3a72` |
| `pairing_handshake` | §12.2 | `0xd83e0f4a` |
| `fft` (forward DFT) | §8.10 | `0x14d7e9b2` |
| `hamming_nn` top-K | §8.2 | `0xb1a25c93` |
| `nmf` (alternating least squares) | §6.9 | `0x300bf633` |
| `eigenvalue_centrality` | §7.2 | `0x1a9039ea` |
| `audit_log_fold` (state projection) | §5.3+§8.15 | `0xa747722e` |

## Cold-path primitives — by name

### AuditLogFold — project state from events

The substrate's source-of-truth read path. Replay a row's audit
events in HLC order to produce its current state (or its state
as of a given HLC). The first event is always the genesis event
emitted at capture (I-26).

```swift
import SubstrateML

let state: RowState? = AuditLogFold.projectStateAt(
    rowID: rowID, nounType: .drawer, events: events, asOf: nil
)
// Returns nil for HLCs strictly before the genesis event.
```

```rust
use substrate_ml::audit_log_fold::AuditLogFold;

let state: Option<RowState> = AuditLogFold::project_current_state(
    row_id, noun, &events
);
```

### MatrixDecay — lazy half-life

Multiplicative decay over matrix cells. `factor = pow(0.5,
elapsed_days / half_life_days)`. Called once per day at most;
the dreaming pass invokes it before applying new increments.

```swift
let updated: Matrix = MatrixDecay.apply(to: matrix, nowSeconds: now)
```

```rust
let updated = matrix_decay::MatrixDecay::apply(matrix, now);
```

Default half-lives are listed in cookbook §6.8 (O = 365d,
T = 90d, ActionOutcomes = 90d, etc.).

### MomentSummary — OR-reduce a time window

The substrate's "everything observed in this window" primitive.
OR-reduces fingerprints of rows whose `active_during(window)`
predicate is true.

```swift
let summary: Fingerprint256 = MomentSummary.summarize(
    rows: rows, window: timeRange, activeDuring: { row, w in ... }
)
```

```rust
let summary = moment_summary::MomentSummary::summarize(
    &rows, &window, active_during
);
```

### MatrixF.applyRow — population-stat increment

The cell-update for the field-presence matrix. 216 i64 cells
(36 fields × 6 bits). Capture increments, expunge decrements,
mutate is a paired -/+.

```swift
matrixF.applyRow(delta: +1, bitPresence: { field, bit in ... })
```

```rust
matrix_f.apply_row(1, |field, bit| { ... });
```

### BradleyTerry — online weight update

Pairwise comparison gradient step with projection to the
non-negative simplex. Drives W_tournament (branch scoring) and
W_ranking (recall-trace feedback).

```swift
let wNew = BradleyTerry.update(weights: w,
                                featureA: fa, featureB: fb,
                                winner: .a, eta: 0.01)
```

```rust
let w_new = bradley_terry::update(&w, &fa, &fb, Winner::A, 0.01);
```

### Anomaly — z-score from cohort centroid

```swift
let z: Double = Anomaly.zscore(bucket: sample, contextClass: ctx)
```

```rust
let z: f64 = anomaly::zscore(&sample, ctx);
```

Z > 3.0 fires the anomaly standing signal (dreaming Rule 4).

### InfoTheory — Shannon entropy, MI, KL

```swift
let h: Double = InfoTheory.entropy(distribution: dist)
let mi: Double = InfoTheory.mutualInformation(joint: j, marginalA: a, marginalB: b)
let kl: Double = InfoTheory.klDivergence(p: p, q: q)
```

```rust
let h  = info_theory::entropy(&dist);
let mi = info_theory::mutual_information(&joint, &a, &b);
let kl = info_theory::kl_divergence(&p, &q);
```

### TemporalCompression — cascading OR-reduce

Compress detail (5-min) buckets into hourly; hourly into daily.
Used by the dreaming daemon at retention boundaries.

```swift
let hourly: AmbientSample = TemporalCompression.compressToHourly(detailBuckets)
```

```rust
let hourly = temporal_compression::compress_to_hourly(&detail);
```

### PartialStateRecall — match on some blocks, differ on others

```swift
let score: Double = PartialStateRecall.score(
    row: row, anchor: fp,
    matchBlocks: [0, 1], differBlocks: [2]
)
```

```rust
let score = partial_state_recall::score(&row, &fp, &match_blocks, &differ_blocks);
```

### FFT — forward DFT for rhythm analysis

Power-of-two windows. ~10 µs at N=1024.

```swift
let spectrum: [Complex] = FFT.forward(samples)
```

```rust
let spectrum: Vec<Complex<f64>> = fft::forward(&samples);
```

### NMF — alternating least squares

Factors an O-matrix into W and H. Runs weekly in the dreaming
daemon.

```swift
let (W, H) = NMF.factorize(O: oMatrix, K: 10)
```

```rust
let (w, h) = nmf::factorize(&o_matrix, 10);
```

### EigenvalueCentrality — power iteration

Sparse adjacency input. Perron-Frobenius shift (`SHIFT = 1.0`)
breaks ±λ oscillation on bipartite graphs. Drives keystone
scoring (`recall_keystone`).

```swift
let scores: [Double] = EigenvalueCentrality.compute(
    adjacency: adj, maxIterations: 100, tolerance: 1e-6
)
```

```rust
let scores: Vec<f64> = eigenvalue_centrality::EigenvalueCentrality::compute(
    &adj, 100, 1e-6
);
```

### TierContribution — federation aggregate

Re-fingerprint contributing rows under shared hyperplane seeds
(scope-specific), then OR-reduce. Used by paired-estate sync and
tier-ascending queries.

```swift
let contribution: Fingerprint256 = TierContribution.generate(
    rows: rows, scope: .household, window: window, sharedSeeds: seeds
)
```

```rust
let contribution = tier_contribution::generate(
    &rows, scope, &window, &shared_seeds
);
```

### PairingHandshake — mint shared seeds

Generate-and-exchange shared hyperplane family for a pairing
scope (household, fleet, company, industry, MSP).

```swift
let seeds = try PairingHandshake.handshake(
    initiator: a, responder: b, scope: .fleet
)
```

```rust
let seeds = pairing_handshake::handshake(&a, &b, scope)?;
```

## Importing

Swift `Package.swift`:
```swift
dependencies: [
    .package(path: "../SubstrateML"),
],
targets: [
    .target(name: "YourKit", dependencies: ["SubstrateML"]),
],
```

Rust `Cargo.toml`:
```toml
[dependencies]
substrate-ml = { path = "../../SubstrateML/rust" }
```

`SubstrateML` depends transitively on `SubstrateTypes` and
`SubstrateKernel`. If you also need their public types directly,
declare those as explicit dependencies too.

## Anti-patterns (agents commonly do these — don't)

1. **Writing a custom audit-log replay.** The fold algorithm is
   `AuditLogFold.projectStateAt`. Don't write a second one. It
   produces the right answer (returning `nil` before the genesis
   HLC, applying mutations in HLC order, respecting the seal).

2. **Computing decay inline.** Use `MatrixDecay.apply`. The decay
   uses `pow(0.5, dt / half_life)` with Apple-libm `exp()`
   bit-identity across Swift and Rust on Apple Silicon; a custom
   `exp()` approximation will fail the conformance gate.

3. **Reordering a loop in a gated primitive.** Floating-point
   summation is not associative. The Swift and Rust ports MUST
   iterate inputs in identical order. If you reorder, expect the
   gate to fail.

4. **Eigenvalue centrality without the Perron-Frobenius shift.**
   Bipartite graphs (star graphs n=odd, others) oscillate at ±λ
   in plain power iteration. The shift is non-optional; it's
   baked into the gated implementation at `SHIFT = 1.0`.

5. **Re-fingerprinting under estate-local seeds for a tier
   contribution.** Tier contributions MUST use the shared
   hyperplane family for their scope, not the estate's private
   seeds. Otherwise the receiver's fingerprints are not comparable.

## Floating-point determinism

Several gated primitives in this package use floating-point
arithmetic. Cross-language bit-identity holds on Apple Silicon
for Apple's libm and Rust's `f64::exp` / `f64::sqrt`. The harness
empirically verifies this — see the regen log entries in
`../../docs/validation/substrate_math_performance/test-harness/test-vector-format.md`.

If you port to a non-Apple platform, plan to re-verify the float
bit-identity assumption. Some glibc versions and some Windows
CRTs differ from Apple's libm on the last ULP for `exp` and
trig functions.

## Conformance — running the gate

Same four-way protocol as `SubstrateKernel`. From
`../../../docs/validation/substrate_math_performance/test-harness/`:

```bash
cd swift
.build/debug/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF
.build/debug/validate-vectors ../vectors/<name>.json
../rust/target/release/validate-vectors ../vectors/<name>.json
../rust/target/release/gen-vectors --primitive <name> --seed 0xCAFEBABEDEADBEEF --out /tmp/x.json
.build/debug/validate-vectors /tmp/x.json
../rust/target/release/validate-vectors /tmp/x.json
```

All four cells must PASS at the CRC listed in the tables above.

## Related docs

- `../../../docs/engineering/HARNESS_REFERENCE.md`
  §2.2 (Tier 2) and §2.3 (Tier 3) — primitives indexed with Swift
  API, Rust API, file paths, and CRCs.
- Cookbook v1.0 §6 (matrix tier), §7 (estate as graph), §8 (algorithms),
  §11 (CognitionKit primitives), §12 (federation).

## License

MIT OR Apache-2.0.
