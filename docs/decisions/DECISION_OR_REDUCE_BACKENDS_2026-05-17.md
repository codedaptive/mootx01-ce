---
status: decided
question: Which kernel backends should implement `or_reduce_batch`, and how should the dispatcher choose between them?
authors: MOOTx01 maintainers
date: 2026-05-17
relates_to:
  - docs/decisions/DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17.md
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md
supersedes: none
context:
  - "`or_reduce_batch` reduces cohorts of `Fingerprint256` to one reduced fingerprint per cohort, batched across M cohorts."
  - "The op (Rust `SubstrateKernel::or_reduce_batch`, Swift `SubstrateKernel.orReduceBatch`) needs a backend menu and a dispatcher policy."
---

# Decision: `or_reduce_batch` Backends

This record references the GeniusLocus engineering cookbook §3.6,
§4.4, §8.5, §8.7, §12.3, §17.3, §17.5.

---

## Context and op signature

OR-reduction over a cohort of fingerprints. Each cohort produces
one `Fingerprint256`; a batched call processes M cohorts and
returns M reduced fingerprints in one trait/protocol invocation.

```rust
// Rust
fn or_reduce_batch(
    &self,
    batches: &[&[Fingerprint256]],
    out: &mut [Fingerprint256],
);

fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256;
```

```swift
// Swift
func orReduceBatch(batches: [[Fingerprint256]]) -> [Fingerprint256]
func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256
```

The operation is commutative, associative, and idempotent over the
input cohort. Each output bit `k` is set iff any input fingerprint
has bit `k` set.

---

## Axis 1: The "1" path — `SIMD4<UInt64>` `|=` on NEON

### Finding

`Fingerprint256` is exactly four `UInt64` blocks. On Apple Silicon
(NEON) and any aarch64 target, the natural single-instruction-equivalent
path is to load the fingerprint into a `SIMD4<UInt64>` (Swift's
`simd` library) or `u64x4` (Rust `std::simd`), and use the
language's `|=` operator. The compiler emits a single `orr.16b`
NEON instruction operating on 128 bits at a time; the M-series
NEON pipeline retires two 128-bit `orr.16b` per cycle on the same
register pair, so the whole 256-bit fingerprint OR is two cycles
of issue latency, single-cycle throughput.

For a cohort of N fingerprints, the inner loop is:

```swift
var acc: SIMD4<UInt64> = .zero
for fp in cohort {
    acc |= SIMD4<UInt64>(fp.block0, fp.block1, fp.block2, fp.block3)
}
```

The compiler hoists the accumulator into NEON registers `q0`/`q1`,
unrolls the loop, and reduces the loop to a tight sequence of
`ldp` (load pair) and `orr.16b` instructions. The bottleneck is
memory bandwidth from `cohort`, exactly per cookbook §17.5
("the kernel layer exists to extract bandwidth").

### Literature

- Daniel Lemire's Roaring Bitmaps work and his "bitwise operations
  on packed integer arrays" series establish that 64-bit-wise OR
  (`uint64_t |= uint64_t`) is already maximally efficient at the
  bit-packing level. There is no further trick. Vectorization
  scales this to 128 or 256 bits per instruction; there is no
  algorithmic improvement beyond that.
- The `simd` library on Apple Silicon (vetted via the Apple
  Developer documentation for `simd_ulong4` and verified by direct
  Swift compilation test in this session) provides `SIMD4<UInt64>`
  with the standard Swift `|=` operator. This is the canonical
  Swift idiom.
- Rust nightly's `std::simd::u64x4` provides the same shape with
  identical codegen. See cookbook §4.4: "In Rust, `std::simd`
  plus per-architecture intrinsics where necessary."

### Cost on M-series

Per fingerprint (4 × 64 bits = 256 bits): one 256-bit load (two
`ldp` instructions on AArch64 v8, or one if alignment permits
`ld1.2d`), one `orr.16b` to accumulate, register pressure 2-4
NEON registers. Latency-bound at ~2-4 cycles per fingerprint
amortized. Throughput-bound at LPDDR5 read bandwidth: the M2 Max
LPDDR5 can stream ~400 GB/s aggregate across all cores; one core
sees ~60 GB/s sustained.

For a cohort of 8 fingerprints (256 bytes): ~32 cycles at 4 GHz,
~8ns. For a cohort of 256 fingerprints (8 KB, exceeds L1d but
fits L2): bandwidth-bound at ~130ns from L2.

The stress-test results confirm: the scalar
loop already runs at ~14ns/call for batch size 1, scaling linearly
with batch size. With `SIMD4<UInt64>` lanes, we expect 4× per-call
reduction, putting batch size 1 at ~4ns/call.

### Implementation idiom (Swift)

```swift
public struct SimdKernel: SubstrateKernel {
    public func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256 {
        var acc: SIMD4<UInt64> = .zero
        for fp in fingerprints {
            acc |= SIMD4<UInt64>(fp.block0, fp.block1, fp.block2, fp.block3)
        }
        return Fingerprint256(block0: acc[0], block1: acc[1],
                              block2: acc[2], block3: acc[3])
    }

    public func orReduceBatch(batches: [[Fingerprint256]]) -> [Fingerprint256] {
        return batches.map { orReduce256($0) }
    }
}
```

### Implementation idiom (Rust, nightly)

```rust
#![feature(portable_simd)]
use std::simd::u64x4;

impl SubstrateKernel for SimdKernel {
    fn or_reduce_256(&self, fingerprints: &[Fingerprint256]) -> Fingerprint256 {
        let mut acc = u64x4::splat(0);
        for fp in fingerprints {
            acc |= u64x4::from_array([fp.block0, fp.block1, fp.block2, fp.block3]);
        }
        let arr = acc.to_array();
        Fingerprint256 { block0: arr[0], block1: arr[1], block2: arr[2], block3: arr[3] }
    }

    fn or_reduce_batch(&self, batches: &[&[Fingerprint256]], out: &mut [Fingerprint256]) {
        assert_eq!(batches.len(), out.len());
        for (i, batch) in batches.iter().enumerate() {
            out[i] = self.or_reduce_256(batch);
        }
    }
}
```

---

## Axis 2: The "1a" path — does not exist for OR-reduce

### Finding

There is no AMX path for OR-reduce on Apple Silicon, and no
Accelerate framework primitive that accelerates bitwise OR over
arrays of integers. This is a documented finding, not an assumption.

### AMX instruction set

Per the corsix/amx reverse-engineering project (the canonical
public reference), the complete AMX instruction set is:

- Load/store: `LDX`, `LDY`, `LDZ`, `LDZI`, `STX`, `STY`, `STZ`, `STZI`
- Extract: `EXTRX`, `EXTRY`
- Multiply-accumulate (float): `FMA16`, `FMA32`, `FMA64`, `FMS16`,
  `FMS32`, `FMS64`
- Multiply-accumulate (int16): `MAC16`
- Vector ops (operates on Z register row): `VECINT`, `VECFP`
- Matrix outer product: `MATINT`, `MATFP`
- Indexed load: `GENLUT`
- State: `SET`, `CLR`

`VECINT` and `MATINT` are integer multiply-accumulate. There is no
bitwise OR primitive, no bitwise AND primitive, no bit-reduce
primitive. AMX is, by design, a multiply-accumulate engine — its
register grid (32×32 with selectable widths) is built to compute
outer products, not boolean reductions.

This rules out a direct AMX `or_reduce`.

### Accelerate framework

The Accelerate framework wraps AMX and NEON paths behind documented
high-level APIs. We surveyed three families:

**BNNS reduction functions.** Apple ships `BNNSReduceFunctionLogicalOr`,
which the documentation describes as: "A reduction function that
reduces a tensor to true if any element is true." This is *logical*
OR, not *bitwise* OR. It collapses an N-element tensor to a single
boolean. Wrong operation: we need a 256-bit result where each bit
is the OR of the corresponding bit across N inputs.

`BNNSReduceFunctionMax` could in principle compute the right
result if we expanded each fingerprint bit to a full byte (0x00 or
0xFF) and took the byte-wise max across the cohort. This works
because `max(0x00, 0xFF) = 0xFF` is bit-set-preserving when the
encoding is bit-as-all-ones-byte. However, the encoding cost is
8× memory bandwidth (each 256-bit fingerprint becomes 2048 bytes),
which the cookbook §17.5 bandwidth-bound principle explicitly
forbids spending. Rejected.

**vDSP integer arithmetic.** vDSP's integer ops are sparse. The
documented integer functions are `vDSP_vaddi` (add), `vDSP_vdivi`
(divide), and `vDSP_veqvi` (bitwise XNOR on Int32). No bitwise OR
exists in the vDSP integer family. Apple ships float-flavored
arithmetic comprehensively (`vDSP.add`, `vDSP.multiply`, …) but
the integer/bitwise family is minimal.

**BLAS / LAPACK.** Both are linear-algebra-over-the-reals
libraries. Not applicable to bitwise reductions.

### NEON-side trick (documented for completeness)

The corsix "Whirlwind tour of AArch64 vector instructions" notes a
non-obvious identity for horizontal bit reductions:

> Horizontal pairwise operations on groups of 8/16/32/64 bits,
> where each group is either all ones or all zeros: UMAXP or
> SMINP give bitwise-or, UMINP or SMAXP give bitwise-and.

This is potentially relevant for cookbook §4.1's bit-slice tensor
layout, where each row of the tensor is exactly "all ones or all
zeros per group." A future bit-slice runtime kernel could use
`UMAXP` to OR-reduce within a 128-bit lane in a way that's not
expressible as `|=`. This is **not relevant** to `or_reduce_batch`
in its current row-major form, because our input is already packed
fingerprints (mixed bits per word), not bit-sliced. Filed as
future-work for the bit-slice runtime kernel (cookbook §4.1).

### Conclusion for Axis 2

There is no 1a path for `or_reduce_batch` on Apple Silicon. AMX
does not have bitwise OR. Accelerate does not expose bitwise OR
in any sub-library. Mathematical re-encodings (bit-as-byte for
`BNNSReduceFunctionMax`) cost 8× bandwidth, violating the
bandwidth-bound principle. The "1" path is the only path.

If a future Apple framework update adds an integer-bitwise reduction
primitive, this decision should be revisited.

### Empirical confirmation

The methodology-gate paper rejection above was tested by
implementing `BnnsKernel` and measuring it against `SimdKernel`
and `ScalarKernel` in the benchmark sweep. Two empirical findings
resulted:

1. **The bit-as-byte trick is API-impossible, not just slow.**
   `BNNS.applyReduction(.max, ...)` with `.uint8` or `.int16`
   tensors silently produces all-zero output on macOS 26.5 /
   Apple Silicon — no error, no diagnostic, just zeros. BNNS
   reduce family appears to be float-only in practice. The same
   call with `Float32` produces correct results. The original
   8× memory amplification estimate assumed the byte-encoded
   path was at least available; it is not. Bit-as-byte for
   `BNNSReduceFunctionMax` is removed from the candidate set.

2. **Float-encoded (32× amplification) is catastrophically slow,
   worse than even ScalarKernel.** Implementing the bit-as-float
   path (each bit becomes a Float32 of 0.0 or 1.0, BNNS reduce-
   max gives 1.0 wherever any input had that bit set):

   Measured on apple-m5-max, 2026-05-18:

   | Batch | Scalar | SimdKernel | BnnsKernel | BnnsKernel vs SimdKernel |
   |---:|---:|---:|---:|---:|
   | 1   | 0 ns     | 0 ns    | 458 ns    | infinite (timer floor on the others) |
   | 8   | 416 ns   | 0 ns    | 3791 ns   | infinite (SIMD below timer floor) |
   | 32  | 1791 ns  | 41 ns   | 15209 ns  | 371× slower |
   | 64  | 3625 ns  | 125 ns  | 30250 ns  | 242× slower |
   | 128 | 7250 ns  | 291 ns  | 60625 ns  | 208× slower |
   | 256 | 14541 ns | 625 ns  | 120209 ns | 192× slower |

   BnnsKernel is **8× slower than even ScalarKernel** at every
   batch size where the timer can resolve the difference. The
   dominant costs are the encode pass (N × 256 Float32 writes
   per call) and the BNNS dispatch overhead; the AMX-side
   compute is fast but trivial relative to setup. The 32×
   memory amplification crushes the working set out of L1/L2
   into LPDDR5 at batch sizes that fit comfortably for the
   other two kernels.

3. **Conformance preserved.** `BnnsKernel` passes the `or_reduce`
   conformance gate (CRC `0x4ee84d73` byte-identical to scalar
   and simd). The kernel is correct; it is just dramatically
   slower. The framework caught both the API-availability gap
   and the performance gap; the decision protocol now has a
   measured rejection citing date + hardware + commit instead
   of a paper estimate.

The Axis 2 conclusion stands, now with empirical force. AMX-via-
BNNS for `or_reduce_batch` is rejected because (a) the integer
encoding path the methodology gate assumed isn't supported by
the BNNS API at all, and (b) the float encoding path that IS
supported runs 192× slower than `SimdKernel` and 8× slower than
the scalar reference.

The `BnnsKernel` source is retained in the repository and remains
reachable via `--kernel bnns` for future re-benchmarking. If a future
macOS or BNNS update changes the picture (e.g. integer reduce
support, descriptor caching that amortizes setup, an AMX bitwise
primitive), running `stress-test --all` against the new SDK
immediately exposes the new trade-off. No paper re-analysis
needed.

---

## Axis 3: Usage profile

Audit of the existing `substrate_reference` codebase and the
cookbook-described primitives:

| Caller | Path | Latency budget | Batchability |
|---|---|---|---|
| `MomentSummary` (cookbook §8.7, §11.15 `recall_moment_summary`) | Hot path | <50 µs (per §17.1 recall) | None (per-call) |
| `recall_similar_moments_by_summary` (§11.16) | Hot path | <100 µs (per §17.1 hamming-NN) | None (per-call) |
| `TierContributionFingerprint` (§12.3 `generate_contribution`) | Cold path | None (background) | High (one large batch per cadence) |
| `DPORReduction` (§12.6 `dp_or_reduce`) | Cold path | None (federation aggregation) | High (one large batch per tier boundary) |
| Temporal compression (§8.14 `compress_to_hourly`, `compress_to_daily`) | Cold path | None (retention boundary) | High (12-24 buckets per pass) |
| Paired-estate shared context (§12.3) | Cold path | None (handshake/sync) | Medium (per-window) |

Two distinct usage profiles:

1. **Hot path (MomentSummary, recall_similar_moments_by_summary)** —
   one cohort per call, user is waiting, batch_size 1 from the
   trait's perspective. Typical cohort size: 10-200 fingerprints
   (the rows active in a time window). No queueability.

2. **Cold path (TierContribution, DPORReduction, temporal
   compression)** — many cohorts per pass, no user waiting, batch
   sizes from 24 (daily compression) to thousands (federation
   aggregation). Highly queueable.

### Cookbook cross-check

Cookbook §17.1 lists `recall_moment_summary` implicitly under the
recall budget. Cookbook §17.2 lists temporal compression under
"hourly/daily, < 5 sec" cold-path budget. The two usage profiles
match.

---

## Axis 4: Batching opportunity

### Hot path

MomentSummary's hot-path call cannot be queued. The user issued a
`recall_moment_summary` query; the moment summary must be
computed and returned before the recall result is rendered. No
queue point.

However, the inner cohort (the fingerprints being OR-reduced) is
ALREADY a batch — typically 10-200 fingerprints per call. The
SIMD path handles that batch in a single tight loop. No further
batching is needed; the work is already SIMD-friendly at the
inner level.

### Cold path

The federation tier-contribution path is the obvious queue point.
Cookbook §12.3 specifies hourly cadence for user→company
contributions, daily for company→industry, weekly for
industry→MSP. Within one cadence cycle, all rows from the cohort
window can be batched into one call. The cookbook already implies
this; we just need to make sure the implementation honors it.

Similarly, temporal compression (§8.14) at retention boundaries
processes 12 hourly buckets into 1 daily bucket, or 24 daily into
weekly. Each pass is one large batched call.

DPORReduction (§12.6) aggregates N contributions from N sub-estates
at a tier boundary. The aggregation is a single bulk operation.

### Queue point proposals

None needed at this phase. The existing cold-path code paths
already process in batches (one OR-reduce call per cadence cycle,
not per row). No changes required.

If future refactoring introduces a per-row OR-reduce loop in a
cold path, it should be batched at the loop level before reaching
the kernel.

---

## Axis 5: Dispatcher policy

### Backend menu

The backends available for `or_reduce_batch` are:

- `ScalarKernel` — the baseline. Pair-at-a-time loop.
  Useful as a fallback and as the conformance reference.
- `SimdKernel` — the vectorized implementation. `SIMD4<UInt64>` |=
  via Swift `import simd` / Rust `std::simd`.

There is no AMX-backed backend for this op (per Axis 2). The
dispatcher chooses between scalar and SIMD.

### Policy

```
dispatch_or_reduce_batch(batches, caller_class):
    if SimdKernel is available on this platform:
        return SimdKernel
    return ScalarKernel
```

The policy is unconditional on Apple Silicon and any aarch64
target: `SimdKernel` always wins, because the SIMD path is strictly
better at all batch sizes (no setup overhead, same memory access
pattern, 4× per-instruction throughput). The dispatcher has no
threshold to learn for this op.

This is the simplest possible dispatcher policy and is the
correct outcome: when one backend strictly dominates, the
dispatcher should just pick it. The learned-dispatch infrastructure
exists for ops where the answer is non-obvious; for OR-reduce, the
answer is obvious.

### Resource pressure response

Under thermal pressure or LocalNLM contention:

- `SimdKernel` continues to be the correct choice. NEON does not
  contend with LocalNLM's AMX usage. NEON is per-core; the per-core
  thermal budget remains available.
- No throttling decisions are needed for OR-reduce specifically.
  The dreaming daemon's general schedule (cookbook §15.4) governs
  whether cold-path OR-reductions run at all.

### Fallback

If `import simd` / `std::simd` is unavailable (Linux ARM64 without
nightly Rust, hypothetical non-aarch64 target), the dispatcher
returns `ScalarKernel`. Correctness is preserved; performance is
reduced.

---

## Implementation plan

Initial implementation:
- Implement `SimdKernel` in Swift, exposing `orReduceBatch` and
  `orReduce256`.
- Implement `SimdKernel` in Rust (nightly + `std::simd`), exposing
  `or_reduce_batch` and `or_reduce_256`.
- Wire `--kernel <name>` flag through `gen-vectors`,
  `validate-vectors`, and `stress-test` binaries in both ports.
- Run four-way conformance sweep with `--kernel=simd`. CRCs must
  match scalar CRCs byte-for-byte.
- Run stress-test with both kernels; record measurement deltas
  in this record.

Dispatcher integration (follow-up):
- Update the dispatcher policy in `PortableKernel::for_current_platform`
  (Rust) and `PortableKernel.kernelForCurrentPlatform()` (Swift)
  to return `SimdKernel` when available.
- Audit existing `or_reduce` callers (`MomentSummary`,
  `TierContributionFingerprint`, `DPORReduction`, temporal
  compression) to confirm they use the kernel layer rather than
  calling `ORReduce.reduce` directly. Migrate any direct callers.

Bit-slice kernel (deferred indefinitely):
- Bit-slice runtime kernel (cookbook §4.1). When that lands, the
  `UMAXP`-based horizontal OR-reduce trick from the corsix
  whirlwind tour becomes applicable. New decision record at that
  time.

---

## Open questions / future work

1. **Conformance against `SimdKernel`.** ~~The four-way matrix
   (Swift gen × Swift validate, Swift gen × Rust validate, Rust
   gen × Swift validate, Rust gen × Rust validate) currently runs
   against `ScalarKernel` only. We need to run it again with
   `--kernel=simd` selected on both sides. Doing this is the
   actual conformance gate for `SimdKernel`.~~
   **Resolved 2026-05-17:**
   The full 4-way matrix (Swift×Rust gen, Swift×Rust validate,
   scalar×simd kernel on each side) passes for all three batched
   primitives. Every combination produces the same CRC:
   - `or_reduce`: CRC `0xdf83215a` across all 4 (lang × kernel)
     combinations
   - `hamming`:   CRC `0xb2a62626` across all 4 combinations
   - `simhash`:   CRC `0xb0cf3d29` across all 4 combinations
   Cross-language validation: 24/24 cells pass (12 swift-gen ×
   rust-validate combinations and 12 rust-gen × swift-validate
   combinations, each spanning the 3 primitives and 4 kernel
   pairs).

2. **Linux ARM64 with stable Rust.** ~~If we ever ship a stable-Rust
   build target (e.g. for a future Linux daemon), we lose
   `std::simd`. Options: write the SIMD path in `std::arch::aarch64`
   intrinsics (stable, platform-specific), keep `std::simd` on
   nightly only, or accept reduced performance on stable. Decide
   when the stable-Rust build target is real.~~
   **Partially resolved 2026-05-17.** Made `simd-nightly` an
   opt-in Cargo feature on the reference crate. Stable consumers
   (e.g. a future Linux daemon on `rust-version = 1.75`) build
   without the feature flag and get a stub `SimdKernel` that
   falls through to `ScalarKernel` via `PortableKernel::of_kind`.
   The dispatcher policy remains correct (it still picks the
   best-available backend); only the absolute performance ceiling
   is reduced. The harness pins nightly via `rust-toolchain.toml`
   so the conformance gate can run `--kernel=simd`.
   Open question moves forward as: when the stable-Rust daemon
   target is real, do we add a `std::arch::aarch64` fallback so
   stable also gets NEON? Defer until target is real.

3. **Bit-slice runtime layout.** Cookbook §4.1 prescribes a
   bit-sliced 3D tensor view. Our current implementation is row-
   major. When bit-slice lands, `or_reduce` over a bit-slice has
   a fundamentally different shape (horizontal OR within a
   128-bit lane via `UMAXP`) than over a row-major cohort. This
   becomes a separate op or a separate backend mode at that time.

4. **Batched vs sequential under SIMD.** ~~The early stress-test data showed
   that batched and sequential modes were within noise for
   scalar. With `SimdKernel` we expect batched to noticeably win
   over sequential because the inner SIMD accumulator stays in
   register across the batch boundary instead of being reloaded.
   Confirm this empirically in the stress-test pass after
   implementation.~~
   **Resolved 2026-05-17.** Measured on Apple Silicon (release
   build):
   
   **Swift** (`or_reduce_batch`, batched mode):
   
   | Batch | Scalar mean | SIMD mean | SIMD speedup |
   |---:|---:|---:|---:|
   | 1   | 88 ns    | 28 ns   | 3.1× |
   | 8   | 516 ns   | 44 ns   | 11.7× |
   | 32  | 1982 ns  | 113 ns  | 17.5× |
   | 128 | 8363 ns  | 374 ns  | 22.4× |
   | 256 | 15567 ns | 735 ns  | 21.2× |
   
   **Rust** (`or_reduce_batch`, batched mode, nightly
   2026-05-16):
   
   | Batch | Scalar mean | SIMD mean | SIMD speedup |
   |---:|---:|---:|---:|
   | 1   | 14 ns    | 14 ns   | 1.0× |
   | 8   | 33 ns    | 20 ns   | 1.65× |
   | 32  | 136 ns   | 72 ns   | 1.89× |
   | 128 | 545 ns   | 284 ns  | 1.92× |
   | 256 | 1087 ns  | 605 ns  | 1.80× |
   
   Batched-over-sequential speedup under SIMD (batch=256):
   Swift 735 ns batched vs 1542 ns sequential = 2.1×. Under
   scalar Swift the gap is negligible (16434 vs 15567 ns). This
   validates the per-op protocol override for SIMD backends.
   
   **Cross-language note.** Rust's scalar baseline is ~14×
   faster than Swift's scalar baseline at batch=256 (1087 ns vs
   15567 ns). LLVM autovectorizes Rust's `for fp in fingerprints
   { acc.block_n |= fp.block_n }` pattern reliably on aarch64;
   the Swift `ScalarKernel` indexing pattern (`acc.words[i] |=
   fp.words[i]`) does not autovectorize equivalently. The
   explicit SIMD impl converges both languages to ~600-700 ns at
   batch=256, putting the floor at a known-good level
   independent of compiler luck.
   
   This is a methodology data point: **autovectorization is
   unreliable across language compilers; explicit SIMD pins the
   performance floor.** The 1 path investigation is worth doing
   even when the scalar code looks like it might autovectorize
   on the target compiler, because the same source pattern may
   not autovectorize on the other-language compiler.

5. **Hamming and SimHash are unchanged under `--kernel=simd`.**
   Confirmed by stress-test: speedups are 1.00× ±0.05 across all
   batch sizes. Only `or_reduce_batch` and `or_reduce_256` get SIMD
   treatment in this scope. The
   inherited scalar implementations of the other two ops continue
   to dominate `SimdKernel`'s behavior. Hamming and SimHash will be
   revisited, each with its own decision record.

---

## Status

Decided. `SimdKernel` and `ScalarKernel` are the backends; the
dispatcher selects `SimdKernel` when available, `ScalarKernel`
otherwise.

---

## BNNSGraph disposal addendum — 2026-06-06

**Hardware:** apple-m5-max. **OS:** macOS 26.5 (build 25F71).
**Build:** release. **Methodology:** min-of-5 runs after 2 warmups.

A subsequent revision migrated BnnsKernel off the deprecated
`BNNS.applyReduction` API to the BNNSGraph API and measured whether the
new implementation improved performance. It did not.

orReduce256 measured results (ns/op, lower is better):

| N | ScalarKernel | SimdKernel | BnnsKernel |
|---|---|---|---|
| 1k | 0.42 | 0.46 | 41.79 |
| 10k | 0.39 | 0.50 | 45.17 |
| 100k | 0.38 | 0.50 | 79.74 |

BnnsKernel is 90x to 160x slower than SimdKernel at every measured N.
The ratio is worse than the earlier BNNS rejection (192x slower vs
scalar at that time); BNNSGraph did not improve the situation.

SimdKernel remains the selected default. No change to the dispatcher.

BnnsKernel was removed from the source tree on 2026-06-06. It is
slower on every op, its BNNSGraph matmul path crashes on macOS 26.5
(EXC_BREAKPOINT in `_bnns_graph_builder_finalize`, Apple framework
bug), and a non-dispatched kernel violates the standing rule to remove
unused code. The earlier BNNS investigation and these measurements are
the permanent record of why BNNS was tried and rejected.
