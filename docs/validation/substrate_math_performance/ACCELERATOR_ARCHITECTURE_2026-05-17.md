# Accelerator Architecture — Learned Dispatch

Supersedes `ACCELERATOR_SCOPE_2026-05-17.md` (first scope, retained
for history). The earlier doc treated kernel selection as a
deploy-time choice between three competing tracks (NEON vs AVX vs
Metal). That framing was wrong in three ways the original missed:

1. Speedup numbers were fabricated, not measured.
2. The trait was pair-at-a-time when SIMD wants batches.
3. Threshold-picking was treated as an engineering decision when
   it's a data problem the substrate is already structured to
   solve.

This doc replaces the "pick a track" framing with a different
architecture: **multiple backends compiled in parallel, dispatch
between them is learned from real workload measurements**. The
substrate already learns Bradley-Terry weights, calibration
curves, and ranking weights; kernel dispatch is the same pattern
applied to a new axis.

---

## §1. The reframe

### §1.1. What was wrong with "pick a track"

The original scope doc compared NEON, AVX, and Metal as if one
would be selected and shipped first. That framing forces three
guesses we have no business making:

- **Speedup per op per backend**: I cited "1.5-2× for NEON"
  based on instruction count. Real out-of-order superscalar
  cores on Apple Silicon may retire scalar XOR/popcount at near
  IPC limit, making per-call NEON speedup closer to 1.1-1.3×.
  The number is unmeasured and unmeasurable a priori.
- **Break-even thresholds**: I cited "Metal break-even at 10k
  candidates," revised to 2k under self-attack. Both numbers
  were guesses. Real Apple Silicon dispatch overhead depends on
  command-buffer encoding state, thermal, and temporal locality.
  No fixed threshold serves all workloads.
- **Session-cost estimates**: "4 sessions for NEON, 5-6 for AVX,
  5-6 for Metal." Fabricated.

These are all empirical questions. The substrate is built to
answer empirical questions from data.

### §1.2. What the substrate already does that applies here

The cookbook specifies online learning at four points:

- **Bradley-Terry weights** (§8.12, §6.7): learned per-user per-
  primitive from RecallTrace feedback.
- **LLM calibration curves** (§6.6): learned per-model from
  action outcomes.
- **W_ranking and W_tournament** (§6.7): learned from confirms
  and rejects.
- **Matrix decay half-lives** (§6.8): manifest-configurable,
  effectively learned from operator tuning.

All four follow the same pattern: ship a hardware-tier-appropriate
default, refine from observed data, persist in the manifest. **Kernel
dispatch thresholds are the fifth instance of this pattern**, not
a new architectural concept.

### §1.3. The new shape

Three parallel work streams replace the linear "ship NEON first"
plan:

1. **Trait extension**: add batched op variants. The scalar
   reference implements them as loops, preserving conformance.
   This unblocks every accelerator simultaneously.
2. **Stress-test harness**: encode-store-retrieve loops that
   record per-op latency at varying batch sizes. Output is
   structured data the substrate reads back, not human-readable
   benchmark logs.
3. **Backend implementations**: NEON, AMX-via-BNNS, and Metal as
   independent overlays behind the same trait. None is "first";
   they ship as ready, gated by conformance.

Dispatch between them is a learned manifest parameter, refined
from the stress-test loop's measurements.

---

## §2. The trait extension

### §2.1. Current shape (pair-at-a-time)

```rust
pub trait SubstrateKernel: Send + Sync {
    fn popcount64(&self, x: u64) -> u32;
    fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32;
    fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256;
    fn hamming_top_k(&self, probe: &Fingerprint256,
                     candidates: &[Fingerprint256], k: usize)
                     -> Vec<(usize, u32)>;
    fn simhash_block(&self, input: &[u64], family: &HyperplaneFamily) -> u64;
}
```

`hamming_distance_256` and `simhash_block` are pair-at-a-time.
Any SIMD backend wrapping these pays per-call dispatch overhead
on every fingerprint pair. The wider the SIMD lane (AVX-512
8× u64, Metal thousands), the worse the per-call overhead
relative to the work.

### §2.2. Extended shape (batches additionally)

```rust
pub trait SubstrateKernel: Send + Sync {
    // Existing pair-at-a-time ops retained for the conformance
    // gate and for callers with single-pair workloads.
    fn popcount64(&self, x: u64) -> u32;
    fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32;
    fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256;
    fn hamming_top_k(&self, probe: &Fingerprint256,
                     candidates: &[Fingerprint256], k: usize)
                     -> Vec<(usize, u32)>;
    fn simhash_block(&self, input: &[u64], family: &HyperplaneFamily) -> u64;

    // Batched variants. Default implementations are loops over
    // the pair-at-a-time ops, so trait extensions are non-
    // breaking and every backend gets correct (if slow) batched
    // behavior for free.
    fn hamming_distance_batch(&self, probe: &Fingerprint256,
                              candidates: &[Fingerprint256],
                              out: &mut [u32]) {
        debug_assert_eq!(candidates.len(), out.len());
        for (i, cand) in candidates.iter().enumerate() {
            out[i] = self.hamming_distance_256(probe, cand);
        }
    }

    fn simhash_block_batch(&self, inputs: &[&[u64]],
                           family: &HyperplaneFamily,
                           out: &mut [u64]) {
        debug_assert_eq!(inputs.len(), out.len());
        for (i, input) in inputs.iter().enumerate() {
            out[i] = self.simhash_block(input, family);
        }
    }

    fn or_reduce_batch(&self, batches: &[&[Fingerprint256]],
                       out: &mut [Fingerprint256]) {
        debug_assert_eq!(batches.len(), out.len());
        for (i, batch) in batches.iter().enumerate() {
            out[i] = self.or_reduce_256(batch);
        }
    }
}
```

Three properties of this extension:

- **Additive**: existing callers (the harness, every primitive
  in the conformance suite) keep working.
- **Conformance-preserving**: default implementations are loops
  over the audited scalar ops, so a backend that only overrides
  the batch variants still passes byte-equality conformance.
- **Performance-permitting**: a NEON or Metal backend can
  override `hamming_distance_batch` to process 4-thousands of
  pairs in a single SIMD/dispatch unit, paying the per-call
  cost once for the whole batch.

### §2.3. Swift parity

Same extension applied to the Swift protocol. Default
implementations on the protocol via Swift protocol extensions:

```swift
public protocol SubstrateKernel: Sendable {
    // ... existing ops ...

    func hammingDistanceBatch(probe: Fingerprint256,
                              candidates: [Fingerprint256])
                              -> [Int]
    // ... etc ...
}

extension SubstrateKernel {
    public func hammingDistanceBatch(probe: Fingerprint256,
                                     candidates: [Fingerprint256])
                                     -> [Int] {
        return candidates.map { hammingDistance256(probe, $0) }
    }
}
```

### §2.4. What the trait extension does NOT include

Floating-point ops (NMF inner loops, FFT) stay out of the trait
for now. Their conformance gate is f32/f64 bit-identity, which
collides with GPU fast-math defaults and SIMD reduction-order
sensitivity. Accelerating them is a separate workstream with its
own determinism story; not part of this architecture.

Bit-slice-layout ops (mask-AND-reduce against a single bit-slice
column for predicate filtering, per cookbook §4.1) stay out of
this trait because they need a different data layout. The
current Fingerprint256-array layout serves Hamming-NN and OR-
reduce well; bit-slice work is a separate runtime workstream.

---

## §3. The stress-test harness

### §3.1. Purpose

The stress-test loop serves three purposes simultaneously:

1. **Battle-test correctness**: many iterations of encode-store-
   retrieve at varying sizes, each iteration's output validated
   against the scalar reference. This catches edge cases the
   18-vector conformance suite misses.
2. **Measure dispatch crossovers**: for each (op, backend, batch
   size) tuple, record latency. The crossovers between backends
   become the dispatch thresholds.
3. **Produce manifest defaults**: the harness emits a structured
   table the substrate reads at first launch and refines from
   runtime measurements.

### §3.2. Workload shape

```
For each op in {hamming_distance_batch, simhash_block_batch,
                 or_reduce_batch, hamming_top_k}:
    For each batch_size in {1, 2, 4, 8, ..., 65536}:
        For each backend in available_backends:
            Run op N times at this batch size with this backend
            Record:
              - Median latency over N runs
              - 99th-percentile latency
              - Result CRC (must match scalar reference)
        Determine crossover batch_size for backend_a vs backend_b
        Emit row: (op, backend_a, backend_b, crossover_batch_size,
                   latency_at_crossover)
```

Run N is large enough to dominate measurement noise (~1000 for
small ops, ~100 for large). Total stress-test runtime is a few
minutes per hardware tier. Acceptable as a one-time cost at
deployment.

### §3.3. Output format

Structured manifest fragment:

```json
{
  "kernel_dispatch": {
    "measured_on": {
      "platform": "darwin-arm64",
      "cpu_model_string": "Apple M2 Max",
      "core_arch_features": ["fp16", "bf16", "i8mm", "sme"]
    },
    "measured_at": "2026-05-17T20:00:00Z",
    "harness_version": "1.0.0",
    "ops": {
      "hamming_distance_batch": {
        "scalar_to_neon_crossover": 4,
        "neon_to_metal_crossover": 2048,
        "neon_to_amx_crossover": null
      },
      "simhash_block_batch": {
        "scalar_to_neon_crossover": 2,
        "neon_to_amx_bnns_crossover": 16,
        "amx_to_metal_crossover": 4096
      },
      "or_reduce_batch": {
        "scalar_to_neon_crossover": 4,
        "neon_to_metal_crossover": null
      },
      "hamming_top_k": {
        "k_thresholds": {
          "10": { "scalar_to_neon": 32, "neon_to_metal": 4096 },
          "100": { "scalar_to_neon": 64, "neon_to_metal": 8192 }
        }
      }
    }
  }
}
```

`null` crossover means "this backend is never better than the
prior tier for this op." e.g. `neon_to_metal_crossover: null`
for `or_reduce_batch` means OR-reduce on Metal is never worth
the dispatch overhead at sizes the substrate sees.

### §3.4. Cold-start defaults

The harness ships with a baseline table built from one Apple
Silicon device class (probably whatever Bob runs on). At first
launch on a different device, the substrate either:

a) Detects a known hardware tier (`sysctlbyname("hw.optional.arm.FEAT_*")`)
   and loads a pre-measured table for that tier, or
b) Runs the stress test in the background and refines the
   defaults over the first ~10 minutes of operation.

Option (a) is preferred for user-visible apps (no startup
latency); option (b) is the fallback for unknown hardware.

### §3.5. Online refinement

After cold-start, dispatch decisions are made from the manifest
table. Every dispatch records (op, batch_size, chosen_backend,
measured_latency). Periodically (daily dreaming pass, or after
N dispatches), the substrate:

1. Compares measured latencies against table predictions.
2. If a backend consistently under- or over-performs by > 2×,
   adjusts the crossover threshold.
3. Writes the updated table back to the manifest.

This is the same online-learning pattern Bradley-Terry uses:
gradient step, projection, persist. The math is simpler — just
threshold adjustment — but the architecture is identical.

---

## §4. The backends

### §4.1. NEON

Same content as the previous scope's §3, with the corrections
from the brainstorming pass:

- Per-call speedup on `hamming_distance_256` is probably 1.1-1.3×,
  not 1.5-2×. Out-of-order Apple Silicon retires scalar XOR/popcount
  near IPC limit.
- Per-call speedup is **the wrong metric**. Batched speedup is
  what matters. NEON on `hamming_distance_batch` at batch ≥ 64
  approaches the LPDDR5 bandwidth ceiling because the inner loop
  has zero per-element dispatch overhead.
- Implementation surface is small: `veorq_u64`, `vcntq_u8`,
  `vaddvq_u8`, `vorrq_u64`, `vandq_u64`. ~10 intrinsics total
  across all batched ops.
- Code lives in `glref-rust-kernel-neon.rs` (Rust, `#[cfg(target_arch = "aarch64")]`)
  and in a C bridge under the Swift package
  (`Sources/CGeniusLocusNEON/`) called from Swift.

NEON is the default backend on Apple Silicon for everything
except `simhash_block_batch` at sizes where AMX-via-BNNS wins.

### §4.2. AMX-via-BNNS

This is the new finding from the brainstorming pass that the
original scope doc missed.

**Apple AMX is not directly exposed**. It's reachable through
Accelerate framework's higher-level APIs: `vDSP`, `BLAS`,
`LAPACK`, and **BNNS (Binary Neural Network Subroutines)**. BNNS
specifically supports ±1-weighted dot products, which is exactly
the ±1 hyperplane structure in `simhash_block`.

**The match**: a SimHash block computes 64 outputs from one
192-bit input vector against a 64×192-bit hyperplane family. Each
output is `popcount(input & plane.pos) - popcount(input & plane.neg)`,
which is mathematically a ±1 dot product. BNNS's
`BNNSDirectApplyTwoInputBinary` or the binary-network primitives
can compute this entire 64-output bank as a single matrix-vector
operation, dispatching to AMX automatically when shape and size
permit.

**Where AMX wins**: when batching `simhash_block` across many
inputs (e.g., recomputing fingerprints for an ambient capture
batch, or migrating an existing estate to v0.36 seeds). Batch
sizes ≥ 16 are where AMX's matrix-multiply throughput beats NEON's
SIMD vector throughput.

**Where AMX doesn't win**: `hamming_distance_*` is XOR-popcount,
not a matrix shape. NEON owns this op.

**Risk**: BNNS dispatch heuristics change across macOS releases.
Mitigation: the conformance gate is byte equality against the
scalar reference. If BNNS's output diverges from scalar (it
shouldn't for integer ±1 ops, but verify), the conformance test
fails and we catch the regression at CI time.

**Code**: Swift-only initially. Rust calling Accelerate is
awkward (`accelerate-sys` crate exists but is unmaintained); a
Rust AMX path can wait. The Swift package gets a
`AMXKernel.swift` that overrides `simhash_block_batch` and falls
through to the NEON backend for everything else.

### §4.3. Metal

Same as the previous scope's §5, with corrections:

- Apple Silicon's unified memory eliminates the explicit copy
  that's the killer overhead on discrete GPUs. `MTLResourceStorageModeShared`
  gives the GPU direct access to mmap'd substrate memory.
- Real break-even is closer to 2k candidates than 10k. The
  dispatch overhead estimate of "10-100µs" was discrete-GPU
  documentation; Apple Silicon Metal dispatch is in the single-
  digit microseconds when command buffers are reused.
- Break-even also depends on **temporal locality**. A
  500-candidate query in the middle of a burst is cheap; the
  same query in isolation is expensive. The stress-test harness
  measures both shapes, and the learned threshold reflects
  whichever workload the substrate actually sees.
- The right op to put on Metal is `hamming_top_k` at large batch
  sizes. Compute shader: XOR-popcount across N candidates in
  parallel, then a parallel top-K reduction. Other ops fall
  through to NEON.

**Determinism**: Metal compute shaders default to fast-math.
For integer ops (our case for Hamming) this is moot. For any
future f32 acceleration it would matter; out of scope here.

### §4.4. What about AVX

Deferred indefinitely. No local x86_64 hardware means a blind
dev loop, no current production deployment that runs on x86_64,
and the architectural decisions this doc captures (trait
extension, stress-test, learned dispatch) all work the same way
for AVX when a real Linux/x86_64 target appears. **Adding AVX
later is straightforward.** Not adding it now removes a CI
expansion and a guess-driven dev cycle.

AVX-shaped work resumes when:
- A production deployment lands on x86_64 (fleet/MSP servers,
  Windows desktop substrate, etc.), AND
- That deployment has measured latency budgets that justify
  optimization, AND
- Bob has access to x86_64 hardware for testing (UTM, Tailscale
  to a Linux box, dedicated runner, whatever).

Until all three are true, AVX is theoretical work that adds CI
complexity without runtime users.

---

## §5. Conformance gating

The 18-primitive vector harness already exists. Every backend
adds **one CI job per backend** that runs the validate-side with
that backend explicitly selected:

```sh
GENIUSLOCUS_KERNEL=neon \
  cargo run --release --bin validate-vectors -- \
    docs/validation/substrate_math_performance/test-harness/vectors/*.json

GENIUSLOCUS_KERNEL=amx \
  swift run validate-vectors \
    docs/validation/substrate_math_performance/test-harness/vectors/*.json

GENIUSLOCUS_KERNEL=metal \
  swift run validate-vectors \
    docs/validation/substrate_math_performance/test-harness/vectors/*.json
```

Every backend must produce the same CRCs as scalar on every
vector. A backend that fails one vector is a backend that's
broken; the conformance gate is unforgiving.

For batched ops added in §2.2, the harness needs new test cases.
Recommendation: extend the existing primitives (hamming,
simhash, or_reduce) with batched cases at batch sizes 1, 2, 4,
8, 16, 32, 64. The output remains the same set of distance/block
values; only the calling pattern changes. CRC remains computable
the same way. **No new primitives needed in the harness**; just
new cases on existing primitives.

---

## §6. Sequencing

Four phases. Not strict — phases 2 and 3 can run in parallel
once phase 1 is done.

### Phase 1: trait extension and stress-test scaffold

- Add batched op signatures to `SubstrateKernel` trait in Rust
  and protocol in Swift. Default implementations loop over the
  pair-at-a-time ops.
- Build the stress-test binary in the harness. Runs against the
  scalar kernel only at this phase. Outputs the structured
  latency table.
- Add batched-case generation to the existing primitives in the
  harness (hamming, simhash, or_reduce). Conformance vectors
  regenerate with new cases. CRCs change — record in the
  regeneration log.

**End state**: trait is batch-ready; stress-test produces real
numbers; conformance harness validates batched paths against
scalar. No accelerators yet.

### Phase 2: NEON backend

- `glref-rust-kernel-neon.rs` and `Sources/CGeniusLocusNEON/`.
  Implement batched ops; fall through to scalar default for
  pair-at-a-time (which is already fast enough on Apple
  Silicon).
- Conformance: NEON kernel validates against every committed
  vector, produces identical CRCs.
- Stress-test runs with NEON enabled; populates the
  `scalar_to_neon_crossover` columns of the manifest table.

**End state**: NEON shipped on Apple Silicon. Other platforms
fall through to scalar.

### Phase 3: AMX-via-BNNS backend (Swift, simhash only)

- `AMXKernel.swift` overrides `simhash_block_batch` via BNNS
  binary-dot-product calls. All other ops fall through to NEON.
- Conformance: must produce identical CRCs to scalar on the
  simhash vector.
- Stress-test runs with AMX enabled; populates the
  `neon_to_amx_bnns_crossover` column.

**End state**: AMX accelerates SimHash batching specifically.

### Phase 4: Metal backend (Swift, hamming_top_k at large batch)

- `MetalKernel.swift` + `Resources/HammingTopK.metal`. Overrides
  `hamming_top_k` for batch sizes above the learned threshold.
- Compute shader: parallel XOR-popcount + parallel top-K.
- Conformance: must produce identical CRCs to scalar on the
  hamming_nn vector.
- Stress-test runs with Metal enabled; populates the
  `neon_to_metal_crossover` columns.

**End state**: Metal accelerates large hamming-NN queries.
Learned dispatch picks whichever backend wins at each query's
batch size.

### Phase 5 (deferred): AVX

When a production deployment lands on x86_64. Same shape as
Phase 2 but for `glref-rust-kernel-avx2.rs` and
`glref-rust-kernel-avx512.rs`.

---

## §7. What this architecture buys

- **No upfront guess** about which backend wins or where the
  crossovers are. Defaults are pre-measured; runtime refines
  them per-hardware-per-user.
- **Backends are additive**, not exclusive. The dispatcher picks
  the right one per op per batch size. There is no "first
  track" — they ship as ready, each gated by the same
  conformance test.
- **Stress-test doubles as battle-test**. The measurement
  workload is also the bug-finding workload, which is also the
  workload Bob said he was going to have to write for stress-
  testing anyway. One harness, three purposes.
- **Aligns with how the substrate already works**. Bradley-
  Terry, calibration, ranking weights — all four are
  learn-from-data parameters that live in the manifest. Kernel
  dispatch becomes the fifth instance of the same pattern, not
  a new architectural concept.

## §8. What it doesn't solve

- **Cold-start for unknown hardware**. The first launch on a
  new device class either uses conservative defaults (a known
  baseline) or runs the stress-test in the background. Both
  are imperfect for the first ~10 minutes of operation. Not a
  blocker, but a real cost.
- **Non-monotonic latency curves**. The doc assumes each (op,
  backend) pair has one crossover point with the next backend.
  Some backends (especially Metal with command-buffer encoding
  state effects) may have non-monotonic curves: faster, then
  slower, then faster again as batch grows. Simple thresholds
  may not capture this. Mitigation: per-op decision function
  rather than single threshold, if data shows non-monotonicity.
  Probably a phase-6 refinement.
- **Floating-point ops** (NMF, FFT). Out of scope as noted in
  §2.4. Different determinism story; revisit when those
  workloads need acceleration.

---

## §9. Decision record promotion

This doc supersedes the previous scope's "ship NEON first"
recommendation. When the team is ready, this gets promoted into
a decision record under `docs/decisions/` capturing:

- Trait extension shape (additive batched ops with default
  implementations)
- Stress-test harness as the dispatch-training mechanism
- Backend implementation order (Phase 2-4 above)
- Learned dispatch as the runtime selection mechanism
- AVX deferral until a production x86_64 target exists

Until promoted, this is reference material. Implementation work
should not start until the architecture is endorsed.
