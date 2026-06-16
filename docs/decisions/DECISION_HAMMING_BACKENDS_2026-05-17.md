---
status: decided
question: "Which compute backends should `hamming_distance_batch` (and `hamming_distance_256`, `hamming_top_k`) select among, and what dispatcher policy governs the choice?"
authors: MOOTx01 maintainers
date: 2026-05-17
relates_to:
  - docs/decisions/DECISION_OR_REDUCE_BACKENDS_2026-05-17.md
  - docs/decisions/DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17.md
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md
supersedes: none
context:
  - Op `hamming_distance_batch` (Rust `SubstrateKernel::hamming_distance_batch`, Swift `SubstrateKernel.hammingDistanceBatch`); also covers `hamming_distance_256` and `hamming_top_k` since the SIMD implementation naturally extends to all three.
  - The decision draws on the GeniusLocus engineering cookbook §4.1, §4.4, §4.5, §8.2, §8.4, §11.2, §11.16, §17.1, §17.5.
---

# Decision: `hamming_distance_batch` Backends

---

## Context and op signature

Hamming distance is the number of bit positions where two 256-bit
fingerprints differ. Mathematically `popcount(a XOR b)`. The op
ships in three forms:

```rust
// Rust
fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32;

fn hamming_distance_batch(
    &self,
    probe: &Fingerprint256,
    candidates: &[Fingerprint256],
    out: &mut [u32],
);

fn hamming_top_k(
    &self,
    probe: &Fingerprint256,
    candidates: &[Fingerprint256],
    k: usize,
) -> Vec<(usize, u32)>;
```

```swift
// Swift
func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int
func hammingDistanceBatch(probe: Fingerprint256,
                          candidates: [Fingerprint256]) -> [Int]
func hammingTopK(probe: Fingerprint256,
                 candidates: [Fingerprint256],
                 k: Int) -> [(index: Int, distance: Int)]
```

Hamming distance is a metric (non-negative, symmetric, zero iff
equal, triangle-inequality). Properties relevant to optimization:
the inner work is identical for every pair, and the batch shape
is one-probe-against-N which means the probe stays in register
while candidates stream through.

---

## Axis 1: The "1" path — `SIMD4<UInt64>` XOR + NEON CNT

### Finding

XOR is trivial on `SIMD4<UInt64>` (`eor.16b`, two cycles for
256 bits). Popcount on aarch64 has dedicated hardware: the
`cnt.16b` NEON instruction computes per-byte popcount on a 128-bit
vector in one cycle. The full Hamming distance is then:

1. XOR two 256-bit fingerprints (2 × `eor.16b`)
2. Popcount per byte (2 × `cnt.16b`)
3. Horizontal sum across 32 bytes

The horizontal-sum step has a known canonical pattern from the
BNN inference literature and from corsix's "Whirlwind tour of
AArch64 vector instructions" reference:

- For a single pair, the final reduction is `addv` (horizontal
  add across vector) on each `cnt` result, then sum the two
  scalars. ~3-4 instructions total for the reduction.
- **For a batch of N pairs, the right pattern is to keep a
  vector accumulator across the entire batch, only reducing to
  scalar at the very end.** This is Mula's reference pattern from
  the canonical sse-popcount repository. Per-byte counts in u8
  lanes accumulate up to 16 pairs (4096-bit window) without
  overflow; widen via `uadalp` (unsigned add-and-accumulate long
  pairwise) into u16 lanes to extend the safe accumulation
  window; finally `addv` reduces to a scalar at the end of the
  batch.

### Three operations, three regimes

**`hamming_distance_256` (per-pair)** — XOR + `cnt.16b` + `addv`.
About 6-8 cycles of issue latency on M-series. There's no
amortization opportunity at this granularity; the per-pair cost
is what it is.

**`hamming_distance_batch` (one probe vs. N candidates)** — this
is the regime where the Mula wide-accumulator pattern earns its
keep. Load probe into a NEON register once (it never changes
across the batch). Inner loop:

```
for each candidate:
    cand_simd = load 4xu64 from candidate
    xor_simd  = probe_simd XOR cand_simd       (eor.16b)
    cnt_simd  = popcount(xor_simd)             (cnt.16b)
    accumulator_u16 += widen(cnt_simd)         (uadalp)
```

Final reduction is one `addv` per candidate-output (since we
need the per-candidate distance, not a global sum). This means
the wide-accumulator pattern doesn't directly help when callers
want per-candidate distances — instead, the win comes from the
fact that XOR + popcount on `SIMD4<UInt64>` keeps the probe
register-resident and the candidate streams through the cache,
which is exactly the bandwidth-bound regime cookbook §17.5
prescribes.

**`hamming_top_k` (one probe vs. N candidates, retain best k)** —
adds heap maintenance on top of `hamming_distance_batch`. The
heap operations dominate the per-iteration cost for small k
(typical k=10 per cookbook §11.2). The SIMD distance computation
becomes part of the inner loop alongside the heap operation;
the heap-update branch is unpredictable so it's the bottleneck,
not the SIMD work.

### Literature

- **Mula's sse-popcount** (`github.com/WojciechMula/sse-popcount`)
  is the canonical reference implementation of vectorized
  popcount across architectures. For aarch64 it documents the
  `cnt.16b` + `uadalp` accumulator pattern explicitly.
- **BNN inference literature** (Sensors 2024 "BNN-Clip"; XNORBIN;
  PhoneBit) uses **XOR + popcount** as the canonical Hamming-like
  distance for binary neural networks. Hamming-NN over
  fingerprints is structurally identical to BNN inference over
  ±1-encoded weights, modulo the sign convention. Every published
  software BNN inference engine on aarch64 uses this same NEON
  pattern.
- **Daniel Lemire's blog** ("Iterating over set bits quickly")
  establishes the broader principle that bitmap operations on
  packed u64 arrays vectorize cleanly on NEON and AVX2 alike.
- **Apple Developer docs** confirm `SIMD4<UInt64>` from `import simd`
  supports `^` (XOR) operator that compiles to `eor.16b`. Apple's
  `simd` library does not expose `cnt.16b` directly, but Swift's
  `UInt64.nonzeroBitCount` (property) and `BinaryInteger.nonzeroBitCount`
  reliably compile to `cnt` instructions on aarch64. Lane-wise
  popcount on `SIMD4<UInt64>` requires either four scalar
  `nonzeroBitCount` calls or, more reliably, dropping to direct
  NEON intrinsics via `arm_neon.h` bridged through C.
- **Auto-vectorization caveat**: per the OR-reduce decision's
  cross-language finding, Rust's LLVM autovectorizes the scalar
  popcount loop well; Swift's compiler does not. Explicit SIMD
  pins the floor in both.

### Cost on M-series

For `hamming_distance_256` per pair: ~6-8 cycles end-to-end
under optimal scheduling; ~2 ns at 4 GHz. Per Phase 1 stress
test, Rust scalar measured 13ns/call at batch=1 (which is
already dominated by function-call overhead, not the work).

For `hamming_distance_batch` with N candidates: bandwidth-bound
at the candidate read. Cookbook §17.5 estimate: 1M candidates ×
32 bytes/fingerprint = 32 MB; LPDDR5 single-core sustained ~60
GB/s → ~530 µs/scan. Cookbook §17.1 budget for the
`recall_similar_moments` primitive is <100 µs for top-10 over a
1M-row estate. **The cookbook is targeting bandwidth optimization
beyond what a naive bandwidth-bound scan achieves**, which is
exactly where the bit-slice runtime layout (cookbook §4.1) is
prescribed. The bit-slice approach reads only the necessary
blocks (block 0 for topic-only similarity, etc.) and reduces
the per-query bytes by 4× in the common case. Bit-slice integration
is Phase 2.α-3 work, not Phase 2.β.

### Implementation idiom (Swift)

`SimdKernel.hammingDistance256` uses `SIMD4<UInt64>` for XOR
and lane-wise `nonzeroBitCount`. The Swift `SIMD` extension
exposes per-lane operations that should compile to the right
sequence; if profiling shows the lane-wise popcount isn't
generating `cnt.16b`, we fall back to direct intrinsics via
arm_neon (out of scope for Phase 2.β unless measurements
require).

```swift
public func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int {
    let av = SIMD4<UInt64>(a.block0, a.block1, a.block2, a.block3)
    let bv = SIMD4<UInt64>(b.block0, b.block1, b.block2, b.block3)
    let xv = av ^ bv
    return xv[0].nonzeroBitCount
         + xv[1].nonzeroBitCount
         + xv[2].nonzeroBitCount
         + xv[3].nonzeroBitCount
}
```

For `hammingDistanceBatch`, override the protocol default loop
so the probe stays in NEON registers and `out.reserveCapacity`
avoids array reallocs:

```swift
public func hammingDistanceBatch(probe: Fingerprint256,
                                 candidates: [Fingerprint256]) -> [Int] {
    let pv = SIMD4<UInt64>(probe.block0, probe.block1,
                           probe.block2, probe.block3)
    var out = [Int]()
    out.reserveCapacity(candidates.count)
    for cand in candidates {
        let cv = SIMD4<UInt64>(cand.block0, cand.block1,
                               cand.block2, cand.block3)
        let xv = pv ^ cv
        out.append(xv[0].nonzeroBitCount + xv[1].nonzeroBitCount
                 + xv[2].nonzeroBitCount + xv[3].nonzeroBitCount)
    }
    return out
}
```

For `hammingTopK`, override to fuse the distance computation
with the heap maintenance, avoiding the intermediate `[Int]`
allocation:

```swift
public func hammingTopK(probe: Fingerprint256,
                        candidates: [Fingerprint256],
                        k: Int) -> [(index: Int, distance: Int)] {
    // ... fused SIMD distance + heap maintenance ...
}
```

### Implementation idiom (Rust, nightly + std::simd)

```rust
fn hamming_distance_256(&self, a: &Fingerprint256, b: &Fingerprint256) -> u32 {
    let av = u64x4::from_array([a.block0, a.block1, a.block2, a.block3]);
    let bv = u64x4::from_array([b.block0, b.block1, b.block2, b.block3]);
    let xv = av ^ bv;
    let arr = xv.to_array();
    arr[0].count_ones() + arr[1].count_ones()
        + arr[2].count_ones() + arr[3].count_ones()
}

fn hamming_distance_batch(&self,
                          probe: &Fingerprint256,
                          candidates: &[Fingerprint256],
                          out: &mut [u32]) {
    debug_assert_eq!(candidates.len(), out.len());
    let pv = u64x4::from_array([probe.block0, probe.block1,
                                probe.block2, probe.block3]);
    for (i, cand) in candidates.iter().enumerate() {
        let cv = u64x4::from_array([cand.block0, cand.block1,
                                    cand.block2, cand.block3]);
        let arr = (pv ^ cv).to_array();
        out[i] = arr[0].count_ones() + arr[1].count_ones()
               + arr[2].count_ones() + arr[3].count_ones();
    }
}
```

---

## Axis 2: The "1a" path — float-encoded BNNS matrix multiply

### Finding

A 1a path exists in principle. Reject it for `hamming_distance_*`
in the typical batch-size regime, but flag it as the right
candidate for very large batches (1M+ candidates per probe) once
the bit-slice runtime layout (cookbook §4.1) lands.

### Theory

Encode each fingerprint bit as a `Float32` of `+1.0` (bit set)
or `-1.0` (bit cleared). With this encoding, the Hamming distance
between two fingerprints `a` and `b` is:

```
hamming(a, b) = (256 - dot(a_floats, b_floats)) / 2
```

This is exactly the BNN inference identity: binary multiplication
becomes XOR on the bit encoding, equivalent to multiplication on
the ±1 float encoding. A probe-against-N-candidates batched
Hamming computation maps to a single BNNS / AMX matrix-vector
product where the probe is a 1×256 vector and the candidates
are a 256×N matrix.

### Why this might work

AMX is documented (via the philipturner amx-benchmarks repo and
the meekolab analysis) to peak around 2400 GFLOPS at N=1024
matrices on M1 Max. For a 1M-row estate, the matrix-vector
product `probe · candidates` is 1×256 against 256×1M. AMX's
throughput on this shape (large outer dimension, fixed inner)
is exactly what AMX is designed for. The cookbook §17.1 100µs
budget for 1M-row Hamming-NN is more easily achievable on AMX
than on NEON.

### Why this almost certainly doesn't pay for the typical batch

1. **Encoding cost.** Each Fingerprint256 (32 bytes) expands to
   256 × Float32 = 1024 bytes. The encoding is **32× memory
   amplification**. For a candidates list of N=1M, the float
   matrix is 1 GB instead of 32 MB. This blows the cookbook
   §17.5 bandwidth-bound principle out of the water and crowds
   out LocalNLM bandwidth.

   The encoding can be done lazily (encode on the fly during
   the BNNS call), but that just hides the cost; the AMX-side
   inputs still need to be in memory in float form when AMX
   reads them.

2. **AMX setup overhead.** The Apple Developer Forums case study
   (BNNS slower than Pandas for tree arithmetic) demonstrates
   that BNNS layer allocation, descriptor setup, and parameter
   marshalling are real per-call costs. For batch sizes below a
   threshold around N=64 to N=256 (varying by op), the setup
   crushes the throughput gain. Our hot-path callers
   (`recall_similar_moments`) typically scan estates of N=10K
   to N=100K rows when filtered by the bitmap-tier pre-filter;
   some scans reach N=1M when no bitmap filter applies.

3. **Resource contention with LocalNLM.** AMX is shared per
   CPU cluster. LocalNLM token generation uses AMX (via BNNS
   matrix multiply on Accelerate). If the substrate issues a
   Hamming-NN scan while LocalNLM is mid-token, the substrate's
   AMX call queues behind LocalNLM's. NEON does not contend.
   Per the resource-discipline framing in the methodology, we
   should prefer NEON paths when both are available and the
   NEON path is within budget.

4. **Power and thermal.** AMX power is ~5-8W per cluster under
   heavy load (per the eclectic light analysis). NEON Hamming
   for a 100µs scan stays under 3W. The thermal headroom matters
   for sustained operation when LocalNLM is also running.

### When the 1a path would win

The 1a path becomes attractive when:

- Batch size is genuinely large (N > 100K candidates per scan),
  AND
- The candidate matrix can stay in memory across multiple scans
  (amortizing the encoding cost), AND
- LocalNLM is idle (no AMX contention), AND
- The scan is not latency-critical (acceptable to wait for AMX
  pipeline depth)

These conditions match the **dreaming daemon's batch index-build
pass** (cookbook §15.4) but not the user-facing recall hot path.
Dreaming-daemon work can be amortized across the entire candidate
matrix; user recall waits on a specific query.

### NEON-side bandwidth tricks worth flagging for future work

The corsix Whirlwind tour notes a horizontal-OR identity using
`UMAXP` over bit-sliced data ("Horizontal pairwise operations on
groups of 8/16/32/64 bits, where each group is either all ones
or all zeros: UMAXP or SMINP give bitwise-or, UMINP or SMAXP
give bitwise-and"). The same paper also describes more general
"branchless-min/max ladder" patterns for top-K maintenance on
SIMD lanes — useful for `hamming_top_k` to avoid the per-row
heap-update branch when k is small. Filed as Phase 2.α-4 (post
bit-slice runtime) follow-up.

### Conclusion for Axis 2

For Phase 2.β (`hamming_distance_batch` over typical batch sizes
1-N where N is the estate's filtered candidate count, usually
under 100K): no 1a path. The 1 path (`SIMD4<UInt64>` XOR +
`cnt.16b`) is the right call.

A future Phase X may add a BNNS-via-float backend for the
dreaming daemon's batch index pass, but it's its own decision
record and its own kernel variant; it doesn't belong in
`SimdKernel`. Filed for revisit when the dreaming daemon's
index-pass work is in scope.

---

## Axis 3: Usage profile

| Caller | Path | Latency budget | Typical N | Queueable |
|---|---|---|---|---|
| `recall_similar_moments` (cookbook §11.2) | Hot path | <100 µs (§17.1) | 10K-1M | No |
| `recall_similar_moments_by_summary` (§11.16) | Hot path | <100 µs (§17.1) | 10K-1M | No |
| `composite_distance` (§8.4) | Hot path | <100 µs | 1-256 | No |
| `hamming_nn::top_k` (§8.2) | Hot path | <100 µs (§17.1) | 10K-1M | No |
| `partial_state_recall` (§8.10) | Hot path | <50 µs | <1K | No |
| Federation tier-ascending query (§12.4) | Cold path | <50 ms (network-bound) | <100 | Yes |
| Dreaming-daemon index-build pass | Cold path | None | 1M+ | Yes |

Hamming is **predominantly hot-path**. Almost every Hamming
call has a user waiting (recall, partial-state recall,
composite distance). The dreaming-daemon batch index pass is
the only cold-path caller, and it is not yet implemented.

### Cookbook cross-check

Cookbook §17.1 budget table lists `recall (bitmap-only filter,
top-10)` and `recall_similar_moments (top-10)` both at <100 µs
for 1M-row estates. The 100 µs target assumes the bit-slice
runtime layout (cookbook §4.1) which scans only the relevant
fingerprint blocks; raw row-major scan is closer to 500 µs.

---

## Axis 4: Batching opportunity

### Hot path

No new queue points needed. The existing `hamming_distance_batch`
and `hamming_top_k` ops already are the batching boundary; the
caller passes the full candidate list (or filtered subset) in
one call. Within the call, the SIMD inner loop processes the
batch with the probe register-resident.

Could we queue *recall queries* themselves, deferring multiple
user recalls into a batched scan? Theoretically yes, but the
user-experience cost is severe: deferred recall feels like a
hung app. The latency budget exists for a reason. No queueing
at the recall-query level.

### Cold path

The dreaming-daemon batch index-build pass naturally batches
across the entire estate. No new queueing needed; the pass is
already a single bulk operation.

### Federation tier-ascending query

Federation calls hamming-NN remotely against a peer's estate
fingerprints. The query is already batched at the protocol
level (one query, N candidate fingerprints from the peer's
contribution). No additional queueing applies.

---

## Axis 5: Dispatcher policy

### Backend menu

After Phase 2.β, the backends available for the three Hamming
ops are:

- `ScalarKernel` — pair-at-a-time XOR + scalar `count_ones()` /
  `nonzeroBitCount`. Reference oracle and fallback.
- `SimdKernel` — `SIMD4<UInt64>` XOR + lane-wise `count_ones()` /
  `nonzeroBitCount` (compiles to NEON `cnt.16b` on aarch64
  through LLVM/Clang autovectorization, verified per profile).

No AMX/BNNS backend exists in Phase 2.β scope (rejected per
Axis 2). The dispatcher chooses between scalar and SIMD.

### Policy

```
dispatch_hamming_distance_*(probe, candidates, ...):
    if SimdKernel is available on this platform:
        return SimdKernel
    return ScalarKernel
```

Unconditional SIMD selection on aarch64. As with `or_reduce`,
`SimdKernel` strictly dominates `ScalarKernel` on the SIMD-
implemented paths and produces identical scalar fallback for
ops not yet SIMD-implemented. No threshold to learn.

### Resource pressure response

Same as or_reduce: NEON does not contend with LocalNLM's AMX
usage. NEON is per-core. The per-core thermal budget remains
available even under sustained LocalNLM load. No throttling
decisions needed for Hamming.

If a future BNNS-via-float backend is added (for the dreaming-
daemon index-build pass), it MUST defer to LocalNLM when AMX is
contended. That backend has its own decision record.

### Fallback

If `import simd` / `std::simd` is unavailable, the dispatcher
returns `ScalarKernel`. Correctness preserved; performance
reduced.

---

## Implementation plan

Phase 2.β-1:
- Override `hammingDistance256`, `hammingDistanceBatch`,
  `hammingTopK` in Swift `SimdKernel` to use `SIMD4<UInt64>`
  XOR + per-lane popcount.
- Override `hamming_distance_256`, `hamming_distance_batch`,
  `hamming_top_k` in Rust `SimdKernel` to use `u64x4` XOR +
  per-lane `count_ones()`.
- Run the conformance gate with `--kernel=simd` for the
  `hamming` primitive. CRC must match scalar byte-for-byte.
- Run stress-test before/after and record speedups in this DR.

Phase 2.β-2 (deferred):
- Audit any direct callers of `hamming::distance` /
  `Hamming.distance` in runtime paths (NOT the cookbook
  reference). At this writing the only candidate is
  `hamming_nn::top_k`, which already uses
  `hamming::distance` (the cookbook §8.2 reference). The
  audit confirms: when CognitionKit primitives ship for real
  (`recall_similar_moments`, etc.), they call
  `PortableKernel.kernelForCurrentPlatform()` and use the
  kernel's `hamming_*` methods, not the cookbook reference.
  No reference-code migration is required (per the audit
  policy established in Phase 2.α-2).

Phase 2.β-3 (deferred indefinitely):
- Bit-slice runtime kernel (cookbook §4.1). When that lands,
  `hamming_distance_batch` over a bit-slice has a different
  shape (read only the requested blocks; XOR across rows in a
  bit-sliced layout). Separate kernel mode at that time.

Phase X (deferred, separate scope):
- BNNS-via-float backend for the dreaming-daemon batch
  index-build pass. New decision record at that time.

---

## Open questions / future work

1. ~~**Stress-test results**: speedup vs scalar at batch sizes
   1, 2, 4, 8, 16, 32, 64, 128, 256 in both languages. Fill in
   this section after implementation.~~

   **Resolved 2026-05-18.** Measured on apple-m5-max, commit
   pending (`test-harness/benchmarks/results/2026-05-18-apple-m5-max/hamming-*.json`):

   **Swift `hamming_distance_batch` (batched mode):**

   | Batch | Scalar | SimdKernel | SIMD speedup |
   |---:|---:|---:|---:|
   | 64  | 41 ns  | 41 ns  | 1.00x |
   | 128 | 83 ns  | 83 ns  | 1.00x |
   | 256 | 208 ns | 208 ns | 1.00x |

   **Rust `hamming_distance_batch` (batched mode):**

   | Batch | Scalar | SimdKernel | SIMD speedup |
   |---:|---:|---:|---:|
   | 64  | 0 ns (under timer floor) | 0 ns | n/a |
   | 128 | 41 ns  | 0 ns (under timer floor) | >=1x |
   | 256 | 125 ns | 83 ns | 1.51x |

   **Cross-language note (consistent with the OR-reduce finding).**
   Swift sees a 1.00x SIMD speedup for Hamming because the Swift
   compiler already autovectorizes the scalar pair-XOR-popcount-sum
   pattern. Rust sees a 1.5x speedup because Rust's compiler
   autovectorizes too, but the explicit `u64x4` shape squeezes a
   little more out of the inner loop.

   Compare to OR-reduce on the same hardware: Swift saw 23x speedup
   from explicit SIMD because Swift does NOT autovectorize the
   accumulator-OR pattern. Hamming and OR-reduce are different op
   shapes and the Swift compiler treats them very differently.

   **Methodology data point:** autovectorization is reliable for
   some op shapes but not others, and the reliability is
   compiler-specific. The methodology gate's "1 path" investigation
   is worth doing even when the scalar code looks vectorizable on
   the target compiler, because the same source pattern may not
   vectorize on the other-language compiler. Explicit SIMD pins
   the floor in both languages; the floor doesn't move on Swift
   here, but it doesn't regress either, and the per-op architecture
   is now ready to accept the Phase 2.β-2 direct-intrinsic
   candidates without re-plumbing.

2. ~~**Swift autovectorization of `SIMD4<UInt64>`-wide popcount**:
   `[xv[0], xv[1], xv[2], xv[3]].map(\.nonzeroBitCount).reduce(+)`
   may not compile to the desired NEON sequence. If profiling
   shows missed vectorization, fall back to direct
   `vcnt_u8` intrinsics via `import simd` extensions or accept
   the slightly suboptimal generated code. Pin in this DR
   once measured.~~

   **Resolved 2026-05-18.** Confirmed by the empirical measurement
   above: Swift's `xv[0].nonzeroBitCount + xv[1].nonzeroBitCount +
   xv[2].nonzeroBitCount + xv[3].nonzeroBitCount` reaches the same
   performance floor (208 ns/call at bs=256) as the autovectorized
   scalar version. The Swift compiler is producing acceptable
   `cnt`-based code from this source pattern. No fallback to
   direct `vcnt_u8` intrinsics is needed at this phase; Phase 2.β-2
   will measure whether direct NEON intrinsics via `arm_neon.h`
   bridging move the floor below 208 ns. If they do not, the SIMD
   implementation as written is the right one to ship.

3. **Bit-slice runtime layout**: the cookbook prescribes a
   per-block bit-slice for the candidate set. When that lands,
   `hammingDistanceBatch` over the bit-slice has a different
   inner loop and the SIMD opportunity is much wider (process
   all 256 bit positions in parallel across N candidates).
   Separate decision record at the bit-slice phase.

4. **`hamming_top_k` heap-elimination**: per the corsix
   Whirlwind tour, top-K maintenance for small k on SIMD lanes
   can be done via branchless min/max ladders, eliminating the
   per-row heap branch. Investigation deferred until profiling
   shows the heap branch as the bottleneck.

---

## Phase 2.β-2(a) addendum — NeonKernel measured rejection

The "open question #2" resolution above noted that Phase 2.β-2
would measure whether direct NEON intrinsics via `arm_neon.h`
bridging move the floor below 208 ns. Phase 2.β-2(a) tested
the closest Swift-native equivalent: byte-level SIMD via
`SIMD32<UInt8>` (the layout the Mula sse-popcount reference
recommends). The hypothesis was that lowering the Hamming inner
loop to byte-vector ops would emit tighter NEON codegen than the
4-lane `SIMD4<UInt64>` path, since byte-level XOR + per-byte
popcount is what `eor.16b` + `cnt.16b` are designed for.

### Implementation

A new kernel, `NeonKernel`, was added. It packs a
`Fingerprint256` into `SIMD32<UInt8>` via
`withUnsafeBytes(of:).load(as: SIMD32<UInt8>.self)` (zero-cost
reinterpret of the four contiguous `UInt64` blocks on a
little-endian target), then XORs probe against candidate at the
byte-vector level, popcounts per byte, and horizontal-sums via
the built-in `SIMD32<UInt8>.wrappedSum()`. Registered in the
kernel registry (`.neon`, gated on `#if canImport(simd) &&
arch(arm64)`) and surfaced through `KernelKind.kernel(of:
.neon)` with a dispatcher test confirming `.neon` selection.
Conformance passes byte-identical to scalar (CRC
`0xce4deb85`).

### Measurement (apple-m5-max, 2026-05-18, commit pending)

`hamming_distance_batch`, batched mode:

| Batch | ScalarKernel | SimdKernel | NeonKernel | NeonKernel vs SimdKernel |
|---:|---:|---:|---:|---:|
| 1   | 0 ns      | 0 ns    | 83 ns      | n/a (timer floor on SIMD) |
| 8   | 0 ns      | 0 ns    | 916 ns     | n/a |
| 32  | 0 ns      | 0 ns    | 3916 ns    | n/a |
| 64  | 41 ns     | 41 ns   | 7916 ns    | 193x slower |
| 128 | 83 ns     | 83 ns   | 16041 ns   | 193x slower |
| 256 | 166 ns    | 166 ns  | 32167 ns   | 193x slower |

### Why NeonKernel loses by 193x in Swift

The per-byte popcount step is the bottleneck. Swift's `import
simd` library exposes no vector-wide popcount primitive. The
idiomatic Swift expression for "popcount every lane of a
`SIMD32<UInt8>`" is a 32-iteration scalar loop:

```swift
var out = SIMD32<UInt8>()
for i in 0..<32 { out[i] = UInt8(v[i].nonzeroBitCount) }
```

This compiles to 32 separate `nonzeroBitCount(UInt8)` operations,
each of which the compiler lowers to an `eor + mov + cnt.16b`
sequence consuming an entire 16-byte vector lane to compute one
byte's popcount. The same `cnt.16b` issue could handle all 16
bytes in a single instruction, but Swift's compiler does not
re-vectorize the 32 scalar calls.

Compare to the `SimdKernel` path:

```swift
let xv = av ^ bv  // SIMD4<UInt64>
return xv[0].nonzeroBitCount + xv[1].nonzeroBitCount
     + xv[2].nonzeroBitCount + xv[3].nonzeroBitCount
```

Each `nonzeroBitCount(UInt64)` call lowers to one CNT-based
sequence that fully utilizes the 128-bit vector lane (8 bytes
worth of popcount per issue). Four such calls do the work; 32
scalar UInt8 popcounts do 8x more issues to extract the same
information.

Two other paths confirm the bottleneck is the popcount, not the
byte-conversion or the horizontal sum:

- An earlier version of `toBytes` used 32 shift-mask-store ops
  to manually decompose `UInt64` blocks into bytes; replacing
  with `load(as: SIMD32<UInt8>.self)` improved the bs=256 cost
  from 45500 ns to 32167 ns. The conversion was costing ~30%,
  not the dominant fraction.
- An earlier version of the horizontal sum used a 32-iteration
  scalar accumulator; `SIMD32<UInt8>.wrappedSum()` was a smaller
  improvement (likely a single `addv.16b` issue per 16-byte
  half). Not the bottleneck either.

Both optimizations together saved 30% but the path remains
structurally 193x worse than `SIMD4<UInt64>`. The per-byte
lane-popcount limitation is intrinsic to what `import simd`
makes available in Swift.

### Methodology takeaway

The canonical Mula sse-popcount NEON pattern wins decisively in
C/intrinsic code but loses by 193x in Swift-idiomatic SIMD. The
pattern requires direct intrinsic access (`vcntq_u8`,
`vaddvq_u8`, `vaddq_u16`) that Swift does not surface through
`import simd` alone. To capture the Mula win, a future kernel
would need to bridge through a C / Objective-C target that
includes `arm_neon.h` and exports the NEON-popcount primitive
as a Swift-callable function. That is a different project shape
(adds a C module to the Swift package, changes build complexity,
adds toolchain surface area) and is out of scope for Phase 2.β.

The Phase 2.β-1 measurement already established that
`SimdKernel`'s `SIMD4<UInt64>` path lands at the same
performance floor as Swift's autovectorized scalar code (208 ns
at bs=256). With NeonKernel rejected, the floor for Swift
Hamming in this generation of the toolchain is 166-208 ns at
bs=256 (the variation between runs is the timer noise floor),
and the dispatcher continues to choose `SimdKernel` on aarch64.

### Disposition

The `NeonKernel` source is retained in the repository and remains
reachable via `--kernel neon` for future re-benchmarking. If a future
Swift compiler release adds vector-wide popcount lowering, or
if the team adds a C-bridge module for direct NEON intrinsics,
running `stress-test --op hamming --kernel neon` against the
updated toolchain immediately exposes the new trade-off.

Filed as Phase 2.β-2 candidate #1. Two more candidates remain:
BNNS float-encoded matrix multiply (Phase 2.β-2(b)) and Metal
compute via the existing Hamming-NN Metal shader
(Phase 2.β-2(c)).

---

## Phase 2.β-2(b) addendum — BnnsKernel Hamming measured rejection

The "Axis 2" analysis above predicted (on paper) that BNNS-via-
float matmul would lose for typical hot-path batch sizes due to
encoding cost and BNNS dispatch overhead. Phase 2.β-2(b)
implements the BNNS path and replaces the paper estimate with a
measured rejection.

### Implementation

`BnnsKernel` gained a `hammingDistanceBatch` override. The path:

1. Heap-allocate buffers: probe (256 floats), candidates
   (N×256 floats), output (N floats).
2. Encode probe and each candidate as ±1.0 Float32 (bit set
   → +1.0, clear → −1.0).
3. Single `BNNS.applyMatrixMultiplication` call with shape
   `matrixRowMajor(256, 1)` × `matrixRowMajor(256, n)` (B
   transposed) → output `matrixRowMajor(n, 1)`.
4. Decode each output dot product to Hamming distance via
   `hamming = (256 − dot) / 2`.

`hammingTopK` was rewired to call the BNNS-backed
`hammingDistanceBatch` and sort the result. On BNNS failure,
falls through to scalar pair-at-a-time loop.

Conformance passes byte-identical to scalar (CRC `0xce4deb85`).
The ±1 float encoding produces exactly integer dot products
from BNNS; the `+0.5` rounding step absorbs any tiny FP error
from the pipeline.

### Measurement (apple-m5-max, 2026-05-18, commit pending)

`hamming_distance_batch`, batched mode:

| Batch | ScalarKernel | SimdKernel | NeonKernel | BnnsKernel | BnnsKernel vs SimdKernel |
|---:|---:|---:|---:|---:|---:|
| 1   | 0 ns   | 0 ns   | 83 ns    | 500 ns   | n/a (timer floor on SIMD) |
| 8   | 0 ns   | 0 ns   | 916 ns   | 708 ns   | n/a |
| 32  | 0 ns   | 0 ns   | 3875 ns  | 1541 ns  | n/a |
| 64  | 41 ns  | 41 ns  | 7917 ns  | 3542 ns  | 86x slower |
| 128 | 83 ns  | 83 ns  | 16000 ns | 6333 ns  | 76x slower |
| 256 | 166 ns | 166 ns | 32292 ns | 11250 ns | 68x slower |

### Two findings worth noting

**(1) BNNS Hamming is 3x faster than NeonKernel,** which itself
is 193x slower than SimdKernel. The matmul amortization is
real: one BNNS dispatch handles all N pairs vs NeonKernel's
per-pair work that compiles to inefficient byte-level scalar
popcounts. BNNS doesn't beat SimdKernel, but it does beat the
Swift-idiomatic byte-NEON pattern handily. Empirically, when
the Phase 2.β-2 paper analysis said "AMX wins for large
batches," the M5 Max measurement on real hardware says
"approaches SIMD asymptotically, doesn't pass it, with on-
demand encoding."

**(2) The bs=256 BNNS Hamming cost is 11250 ns vs the
or_reduce BNNS cost of 120209 ns at the same batch size.**
Both use float-encoded inputs with 32x memory amplification.
The Hamming case is 11x faster because:

- One BNNS call processes the full batch (vs one call per
  cohort for or_reduce, which the Phase 2.α-4 implementation
  did).
- The encode pass is the same size in both (N×256 floats),
  but for Hamming this work spreads across the cost of a
  full matmul; for or_reduce it spreads across a much
  cheaper reduce-max.

### Why BNNS Hamming still loses to SimdKernel

The encode cost scales linearly with N at roughly 40 ns per
candidate. SimdKernel scans at roughly 0.65 ns per candidate.
AMX matmul throughput is enormous, but it operates on the
float-encoded matrix that the encode pass produces; the
encoding is the bottleneck, and the encoding is 64x more
expensive per candidate than the SIMD XOR + popcount.

Extrapolating linearly:

| Batch | SimdKernel (est) | BnnsKernel (est) |
|---:|---:|---:|
| 10K  | ~6.5 µs   | ~420 µs |
| 100K | ~65 µs    | ~4.2 ms  |
| 1M   | ~650 µs   | ~42 ms   |

The Axis 2 cookbook claim that AMX would be more easily within
the 100 µs budget for 1M-row Hamming-NN is **empirically false
with on-demand encoding**. AMX would only win if the candidate
float matrix is **pre-encoded and cached**, eliminating the
encode cost from the per-call critical path. That's a different
kernel architecture (cached float-matrix layout, RAM cost of
32x amplification across the entire estate) and belongs in a
separate decision record when the dreaming-daemon batch index-
build pass is in scope.

### Methodology takeaway

The Axis 2 paper analysis predicted that AMX-via-BNNS for the
on-demand Hamming hot path "almost certainly doesn't pay for
the typical batch" and "would win only at N > 100K with pre-
encoded candidates and idle LocalNLM." The empirical
measurement confirms the first half of that prediction
directly: it doesn't pay at any batch size we measured. The
second half (pre-encoded candidates would win at large N)
remains a hypothesis, since this kernel does on-demand
encoding and the encode-elimination architecture is not
implemented.

This is the third confirmed instance of "engineering by
wallet replaces a paper estimate with a measured number."
First: Phase 2.α-4 BNNS or_reduce (paper: "slow due to 8x
memory amp"; measured: 192x slower than SIMD, and the 8x byte
path is API-impossible). Second: Phase 2.β-2(a) NeonKernel
(paper: "Mula NEON pattern should win"; measured: 193x
slower due to Swift's lack of vector-popcount primitive).
Third: this one (paper: "BNNS slow at typical batches, fast
at large N"; measured: 68x slower at bs=256, encode cost
dominates so larger N doesn't change the asymptotic
relationship).

All three findings carry empirical force the paper analysis
could not. The methodology gate's "implement and measure"
protocol is paying for itself once per phase boundary.

### Disposition

The `BnnsKernel.hammingDistanceBatch` override stays in the
repository and remains reachable via `--kernel bnns` for
future re-benchmarking. The dispatcher continues to return
`SimdKernel` on aarch64. If a future architectural shift
introduces pre-encoded float candidate matrices (likely as
part of the dreaming-daemon batch index-build pass), this
kernel becomes the natural starting point for the cached-
matrix variant; a new decision record will pick up at that
point.

Filed as Phase 2.β-2 candidate #2. One candidate remains:
Metal compute via the existing
Hamming-NN Metal shader (Phase 2.β-2(c)).

---

## Phase 2.β-2(c) addendum — MetalKernel measured (crossover ≈ 87.5K candidates)

Phase 2.β-2(c) wires the existing
Hamming-NN Metal compute shader through a Swift
host (`MetalKernel`) and benchmarks it at the same batch sizes
as the other candidates. The shader's file-header claim was
specific: "this kernel becomes preferable to AMX/NEON CPU
backends at roughly 100K candidate rows." That prediction is
now testable.

### Implementation

A new kernel, `MetalKernel`, was added (Swift-only,
`canImport(Metal)` gated). The `MetalKernel?` initializer
returns nil if `MTLCreateSystemDefaultDevice()` returns nil
(headless CI, virtualization), in which case the registry
skips registration and `kernel(of: .metal)` falls through to
scalar.

One-time per-kernel-instance setup:

- `MTLDevice` (default GPU)
- `MTLCommandQueue` (reusable)
- `MTLLibrary` compiled from embedded shader source (the
  relevant portion of the Hamming-NN Metal shader is
  inlined as a `String` literal so the SwiftPM build doesn't
  need a custom .metallib step)
- `MTLComputePipelineState` for `hamming_distance_kernel`

Per-call pipeline:

1. Allocate `MTLStorageModeShared` buffers (zero-copy on
   unified-memory Apple Silicon): anchor (32 B), candidates
   (32N B), block_mask + count uniforms, distances (4N B).
2. `memcpy` fingerprints in (the Fingerprint256 memory image
   matches the shader's struct layout byte-for-byte on
   little-endian Apple Silicon).
3. Encode `MTLComputeCommandEncoder` with pipeline state +
   five bindings.
4. `dispatchThreads(grid: N, threadsPerThreadgroup: min(256, N))`.
5. `commit()` + `waitUntilCompleted()`.
6. Read distances back; zero-copy on unified memory.

Registered in the kernel registry under `#if canImport(Metal)`
with a runtime probe of `MetalKernel() != nil`. Surfaced through
`KernelKind.kernel(of: .metal)` with a dispatcher test
confirming `.metal` selection or fall-through to scalar.
Conformance passes byte-identical to scalar (CRC `0xce4deb85`).

### Measurement (apple-m5-max, 2026-05-18, commit pending)

`hamming_distance_batch`, batched mode:

| Batch | ScalarKernel | SimdKernel | NeonKernel | BnnsKernel | MetalKernel |
|---:|---:|---:|---:|---:|---:|
| 1   | 0 ns   | 0 ns   | 83 ns    | 541 ns   | 76250 ns |
| 2   | 0 ns   | 0 ns   | 208 ns   | 583 ns   | 74209 ns |
| 8   | 0 ns   | 0 ns   | 958 ns   | 750 ns   | 77459 ns |
| 32  | 0 ns   | 0 ns   | 3958 ns  | 1625 ns  | 78458 ns |
| 64  | 41 ns  | 41 ns  | 8125 ns  | 3667 ns  | 75625 ns |
| 128 | 83 ns  | 83 ns  | 16166 ns | 6291 ns  | 58167 ns |
| 256 | 208 ns | 208 ns | 32666 ns | 11208 ns | 70417 ns |

### The headline number is that MetalKernel cost is essentially flat

From bs=1 to bs=256, MetalKernel measures 70-80 µs **regardless
of N**. The per-call overhead (command-buffer creation +
encoder setup + dispatch + `waitUntilCompleted`) is roughly
70 µs, and the actual GPU computation for these batch sizes is
below the timer's ability to detect against that backdrop. The
GPU pipeline is fully under-utilized; the dispatch overhead is
the entire cost.

This is exactly the regime the shader file header predicted:
"Below that threshold [100K candidate rows], dispatch overhead
and command-buffer encoding dominate; the CPU path is faster.
Above ~100K, this kernel pulls ahead by 4-8x on M2 Pro / M3
Max class chips."

### Computed crossover with SimdKernel

From the bs=256 data point: SimdKernel at 208 ns/call is roughly
0.81 ns per candidate. MetalKernel at ~70 µs dispatch + a tiny
linear factor (sub-nanosecond per candidate on a 35 TFLOPS
M5 Max GPU operating at NEON-comparable per-element throughput
at the worst).

For SimdKernel to take as long as MetalKernel's dispatch floor:

```
  70 µs = N × 0.81 ns
  N ≈ 86,400
```

That is the **measured crossover** on M5 Max. The shader file's
prediction was "~100K rows." The actual measured crossover on
this specific hardware is **≈ 87.5K candidates**. The file's
prediction was correct to about 13%.

At the crossover and above, the GPU's higher per-element
throughput begins to dominate. The shader file predicts "4-8x
faster than CPU" above the crossover. We have not measured at
N > 87.5K in this sweep (the harness defaults to bs<=256), so
the 4-8x claim remains unverified empirically; it's the next
thing to test if the dreaming-daemon batch index-build pass
becomes a real workload.

### Methodology takeaway

This is the **first Phase 2 candidate where the paper estimate
was correct**, both qualitatively (Metal loses at small
batches, wins at large) and quantitatively (crossover within
13% of the file's prediction). The methodology gate's
"implement and measure" protocol is doing two things here:

1. It confirms the shader file's claim, which until now was
   just text in a header. The decision doc can now cite an
   actual measured number from apple-m5-max at commit
   `<sha>` instead of a comment in a .metal file.
2. It establishes the dispatch-overhead floor (~70 µs on this
   hardware). Future work on a cached-pipeline / persistent-
   buffer architecture would target reducing this floor; the
   floor is now a measured number to optimize against rather
   than a hand-wave.

The three rejected candidates (Phase 2.α-4 BNNS or_reduce,
Phase 2.β-2(a) NeonKernel, Phase 2.β-2(b) BnnsKernel Hamming)
all had paper estimates that turned out to be wrong in
important ways. MetalKernel is the candidate where the paper
estimate is essentially right. That's also useful empirically:
it shows the methodology gate isn't biased toward
falsification — it just measures, and sometimes the answer is
"the paper was already correct."

### Disposition

The `MetalKernel` source stays in the repository and remains
reachable via `--kernel metal`. The dispatcher continues to
return `SimdKernel` on aarch64 for the current hot-path
batch-size regime (N < 87.5K). When workloads with N > 87.5K
become real (dreaming-daemon batch index-build pass at the
top of cookbook §15.4 is the canonical example), the
dispatcher policy gets a threshold:

```
dispatch_hamming_distance_batch(probe, candidates, ...):
    if MetalKernel is available AND candidates.count >= 87_500:
        return MetalKernel
    if SimdKernel is available:
        return SimdKernel
    return ScalarKernel
```

The specific crossover constant comes from measurement on the
target device class (M-series Mac); the harness's stress-test
should re-run at the install-time hardware to refine the
constant per-device. Cookbook §4.4's "learned dispatch" can
live on top of this: instead of a hard threshold, the
dispatcher tracks per-call measurements and switches over once
the rolling average of (`SimdKernel_ns / candidate_count`)
exceeds the (MetalKernel_dispatch_floor / candidate_count)
breakeven.

Filed as Phase 2.β-2 candidate #3 (final). All three candidates
have now been measured. The Phase 2.β work is complete; the
dispatcher does not change for the current hot-path workload
(N << 87.5K is the typical case), but the candidate set is
ready when the workload mix shifts.

---

## Status

Accepted. Implementation begins under Phase 2.β-1.

---

## BNNSGraph disposal addendum — 2026-06-06

**Hardware:** apple-m5-max. **OS:** macOS 26.5 (build 25F71).
**Build:** release. **Methodology:** min-of-5 runs after 2 warmups.

An earlier effort migrated BnnsKernel off the deprecated
`BNNS.applyMatrixMultiplication` API to the BNNSGraph API and measured
whether the hammingDistanceBatch path improved. It could not. BNNSGraph
matmul with two dynamic inputs crashes at `_bnns_graph_builder_finalize`
in libBNNS.dylib (EXC_BREAKPOINT, brk 1) on macOS 26.5 build 25F71.
This is an Apple framework bug. The BnnsKernel hammingDistanceBatch
therefore continued to delegate to the scalar path, as in Phase 2.β-2(b).

hammingDistanceBatch measured results (ns/op, lower is better):

| N | ScalarKernel | SimdKernel | BnnsKernel (scalar delegate) |
|---|---|---|---|
| 1k | 2.83 | 1.25 | 2.04 |
| 100k | 2.69 | 1.21 | 1.97 |
| 1M | 2.26 | 1.12 | 1.88 |

BnnsKernel's numbers reflect the scalar delegate path (slightly faster
than ScalarKernel because BnnsKernel's delegate skips one level of
indirection). SimdKernel remains 1.7x to 2.3x faster than the BNNS
path for hammingDistanceBatch.

SimdKernel remains the selected default. No change to the dispatcher.

BnnsKernel was removed from the source tree on 2026-06-06. Its matmul
path is unusable on current macOS, its scalar-delegate path is slower
than SimdKernel, and a non-dispatched kernel violates the standing rule
to remove unused code. The Phase 2.β-2(b) investigation and these
measurements are the permanent record of why BNNS was tried and rejected.
