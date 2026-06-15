---
name: substrate-ml
description: Use this skill when an agent needs cold-path or dreaming-driven algorithms — matrix decay, moment summary OR-reduce, Bradley-Terry online weight update, anomaly z-score, information theory (entropy / MI / KL), temporal compression rollups, partial-state recall scoring, FFT for rhythm analysis, NMF factorization, eigenvalue centrality (keystone scoring), audit-log fold for state projection or as-of reads, tier-contribution federation aggregate, or pairing handshake to mint shared hyperplane seeds. All 15 are conformance-gated Swift+Rust byte-identical. Trigger this skill any time an agent is about to write one of those, run a recall query that needs as-of state, compute a population-stat update, or anything dreaming-daemon-shaped. Redirects to the existing implementation.
---

# substrate-ml — learning, graph, projection

## When this skill applies

An agent is about to write code that does any of:
- Half-life decay on a matrix
- OR-reduce over rows matching a time-window predicate (moment summary)
- Bradley-Terry pairwise comparison online update
- Z-score anomaly detection from a cohort centroid
- Entropy, mutual information, or KL divergence
- Temporal compression (detail → hourly → daily rollups)
- Partial-state recall scoring (match on some blocks, differ on others)
- FFT (forward DFT) for rhythm analysis
- NMF factorization on an O-matrix
- Eigenvalue centrality / keystone scoring
- Audit-log fold to project a row's current or as-of state
- Tier contribution fingerprint for federation
- Pairing handshake to generate shared hyperplane seeds

## The one rule

15 primitives in this package are byte-identical Swift+Rust under
the conformance harness. Floating-point determinism holds on Apple
Silicon. **Don't reinvent any of them.** A hand-rolled NMF or
audit-log fold will drift from the gated CRC; CI will catch it.

| Primitive | Use |
|---|---|
| Audit-log fold | `AuditLogFold.projectStateAt(rowID:nounType:events:asOf:)` |
| Matrix decay | `MatrixDecay.apply(to:nowSeconds:)` |
| Moment summary | `MomentSummary.summarize(rows:window:activeDuring:)` |
| Bradley-Terry | `BradleyTerry.update(weights:featureA:featureB:winner:eta:)` |
| Anomaly z-score | `Anomaly.zscore(bucket:contextClass:)` |
| Entropy / MI / KL | `InfoTheory.{entropy, mutualInformation, klDivergence}(...)` |
| Temporal compression | `TemporalCompression.compressToHourly(_:)` |
| Partial-state recall | `PartialStateRecall.score(row:anchor:matchBlocks:differBlocks:)` |
| FFT | `FFT.forward(_:)` |
| NMF | `NMF.factorize(O:K:)` |
| Eigenvalue centrality | `EigenvalueCentrality.compute(adjacency:maxIterations:tolerance:)` |
| Tier contribution | `TierContribution.generate(rows:scope:window:sharedSeeds:)` |
| Pairing handshake | `PairingHandshake.handshake(initiator:responder:scope:)` |
| MatrixF apply | `matrixF.applyRow(delta:bitPresence:)` |

## Anti-patterns

1. Writing a custom audit-log replay. Use `AuditLogFold.projectStateAt`.
   It returns `nil` before the genesis HLC, applies mutations in HLC
   order, and respects the seal — getting any of those wrong is a
   correctness bug.
2. Computing decay with a custom `exp()` approximation. Apple-libm
   `exp()` bit-identity is what the gate verifies; a Padé or
   polynomial approximation will fail conformance.
3. Reordering a loop in a gated primitive. Floating-point summation
   is not associative; Swift and Rust must iterate in identical order.
4. Power iteration without the Perron-Frobenius shift. Bipartite
   graphs oscillate at ±λ; the gated implementation uses `SHIFT = 1.0`.
5. Re-fingerprinting under estate-local seeds for a tier contribution.
   Tier contributions MUST use the shared family for their scope, or
   receiver fingerprints are not comparable.

## How to use

```swift
import SubstrateML

let state = AuditLogFold.projectStateAt(
    rowID: rowID, nounType: .drawer, events: events, asOf: nil
)
let decayed = MatrixDecay.apply(to: matrix, nowSeconds: now)
let summary = MomentSummary.summarize(rows: rows, window: window) { row, w in
    row.captureHLC.physicalTime >= w.start && row.captureHLC.physicalTime < w.end
}
let z = Anomaly.zscore(bucket: sample, contextClass: ctx)
let (W, H) = NMF.factorize(O: oMatrix, K: 10)
```

```rust
use substrate_ml::{audit_log_fold::AuditLogFold, matrix_decay, moment_summary, anomaly, nmf};

let state    = AuditLogFold::project_current_state(row_id, noun, &events);
let decayed  = matrix_decay::MatrixDecay::apply(matrix, now);
let summary  = moment_summary::MomentSummary::summarize(&rows, &window, active_during);
let z        = anomaly::zscore(&sample, ctx);
let (w, h)   = nmf::factorize(&o_matrix, 10);
```

Package wiring:
```swift
.package(path: "../SubstrateML"),
// targets dependencies: ["SubstrateML"]
```

```toml
substrate-ml = { path = "../../SubstrateML/rust" }
```

## Floating-point determinism

Cross-language bit-identity holds on Apple Silicon for Apple's libm
and Rust's `f64::exp` / `f64::sqrt`. The harness empirically verifies
this. If you port to a non-Apple platform, plan to re-verify — some
glibc and Windows CRT versions differ on the last ULP for `exp` and
trig functions.

## If you change a gated primitive

Run the four-way conformance check. See
`docs/validation/substrate_math_performance/test-harness/SKILL.md`.

## What to read

`packages/libs/SubstrateML/AGENTS.md` for the full per-primitive
reference with Swift + Rust code examples.
`docs/engineering/HARNESS_REFERENCE.md` §2.2 (Tier 2)
and §2.3 (Tier 3) for the canonical index.
