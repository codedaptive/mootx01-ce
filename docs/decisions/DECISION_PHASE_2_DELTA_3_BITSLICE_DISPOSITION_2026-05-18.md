---
status: decided
question: Should the cookbook §4.1 I-18 bit-slice runtime layout be prototyped at the kernel level for full Hamming, or deferred to a substrate-level decision?
authors: MOOTx01 maintainers
date: 2026-05-18
relates_to:
  - docs/decisions/DECISION_HAMMING_BACKENDS_2026-05-17.md
supersedes: none
context:
  - Bit-slice was the third candidate scoped in Phase 2.δ (cookbook §4.1 I-18 constitutional bit-slice runtime layout).
  - Architectural math from the Phase 2.δ-1 and Phase 2.δ-2 measurements shows a kernel-level prototype would confirm what the bandwidth-floor calculation already predicts.
  - Declined at kernel level; kept as a constitutional requirement at substrate level for the other primitives that depend on it.
  - Cookbook references — §4.1 (I-18 bit-slice 3D tensor working set), §4.2 (memory-mapped working set), §4.3 (SQLite as durability tail), §4.5 (bandwidth budgets), §17.5 (memory bandwidth at scale).
---

# Decision: Phase 2.δ-3 disposition — bit-slice runtime layout

**Status**: Declined at kernel level; deferred to substrate-level decision

---

## Context

The Phase 2.δ scoping doc identified bit-slice as Item 2 and scheduled it for Phase 2.δ-3 as a kernel-level prototype: "in-memory bit-slice tensor built from the AoS Fingerprint256 array at benchmark start, then measure the scan." The scoping doc's prediction was "in-memory bit-slice scan beats AoS SIMD at N >= 10K candidates because the per-bit-column scan amortizes the XOR across the entire row dimension; crossover prediction lands around N = 10K-100K."

After Phase 2.δ-1 and Phase 2.δ-2 measurements, the architectural math is settled enough to revisit the prediction without implementation.

---

## Architectural math

### Phase 2.δ-1 established the bandwidth floor

`SimdKernel.hammingTopK` at K=10, N=1M measured 604 µs on apple-m5-max. Cookbook §17.5 predicts the bandwidth floor for the 32 MB scan: 32 MB / 60 GB/s = **533 µs**. The measured 604 µs is **within 13% of the bandwidth floor**.

### Bit-slice does not change the bandwidth bound for full Hamming

The full-Hamming computation reads 256 bits per fingerprint × N fingerprints = 32 MB total at N=1M. Two layouts produce the same bandwidth demand:

- **AoS layout (current SimdKernel)**: reads N fingerprints × 32 bytes each, sequential per row. Total: 32 MB.
- **Bit-slice layout**: reads 256 bit-arrays × N bits each, sequential per bit-position. Total: 32 MB.

Both layouts stream sequentially. Both saturate the same LPDDR5 bandwidth. The bit-slice layout cannot beat the bandwidth floor that SimdKernel already approaches within 13%.

### Where bit-slice wins (different primitives)

Bit-slice is genuinely faster for primitives that read a **subset of bits**:

- **Partial Hamming** (cookbook §8.2 with `blocks` parameter): block 0 only is 64 bits × N rows = 8 MB read = ~133 µs floor. AoS still reads all 32 bytes per row (can't address a single block efficiently), so AoS is ~4× slower than bit-slice for block 0 only.
- **Bitmap predicate filters** (cookbook §4.5 P1, < 100 µs/predicate at 1M rows): reads one bit-array = 125 KB = ~2 µs floor. AoS can't filter on a single bit efficiently.
- **Cross-row OR-reduce** (cookbook §8.5): bit-slice supports vector-OR per bit-position with no reorganization. AoS works fine too but the bit-slice form is cleaner for ALL fields, not just fingerprints.
- **Bit-level fingerprint arithmetic** (cookbook §8.6 intersect, difference, prototype_of): bit-slice native.
- **Moment-summary fingerprints** (cookbook §8.7): or_reduce over windows, bit-slice native.

### Where bit-slice does NOT win (full Hamming)

The full-Hamming kernel reads every bit of every fingerprint. There is no subset to exploit. The Mula "vertical popcount" technique can reduce popcount operation count by ~3-5× by accumulating bits-disagree across multiple bit-positions before a final popcount, but this only matters if popcount cost was the bottleneck. The measured 604 µs vs 533 µs floor says it's not — we're bandwidth-bound, not compute-bound.

A kernel-level bit-slice prototype for full Hamming would measure 533-600 µs, indistinguishable from the SimdKernel AoS measurement, because both layouts hit the same bandwidth floor.

---

## Cost-benefit analysis

The Phase 2.δ-3 prototype as originally scoped would have required:

- An in-memory bit-slice tensor builder that transposes an AoS `[Fingerprint256]` into 256 bit-arrays
- A new `BitsliceKernel` struct implementing `SubstrateKernel`
- An inner-loop bit-slice Hamming distance computation (likely with vertical popcount accumulator)
- A new stress-test harness extension for bit-slice measurement
- Conformance test against scalar reference
- A decision-doc addendum

Estimated effort: 2 days. Expected measurement outcome based on the bandwidth math: bit-slice lands at 533-600 µs vs SimdKernel AoS 604 µs. Outcome difference: ≤13%, within measurement noise.

The engineering-by-wallet protocol's principle applies: implement candidates whose paper estimate is uncertain. Decline candidates whose architectural-math estimate is well-bounded and within measurement noise. Phase 2.γ-3 established this corollary; Phase 2.δ-3 applies it.

---

## Decision

**Decline the kernel-level bit-slice prototype for full hammingDistanceBatch.**

Three reasons:

1. **The bandwidth floor is already approached within 13%.** The achievable speedup from bit-slice for full Hamming is bounded by the gap from SimdKernel to the bandwidth floor, which is 71 µs absolute (604 - 533) or 13% relative. That's within the noise floor of the measurement harness and indistinguishable from compiler-codegen variance.

2. **Bit-slice belongs at substrate level, not kernel level.** Cookbook §4.1 I-18 makes bit-slice constitutional for the entire working set, not just for Hamming. The full substrate-level implementation (cookbook §4.2 memory-mapped layout, §4.3 SQLite durability tail) provides bit-slice to all 12 cookbook primitives (P1-P12), not just to P2 Hamming-NN. A kernel-level prototype would build a transient in-memory bit-slice tensor that conflicts with the substrate-level layout when the latter materializes, and duplicates the storage cost without serving any other primitive in the meantime.

3. **The substrate-level work has different success criteria.** When bit-slice is implemented at substrate level, the win comes from cookbook §4.5 budgets being met for the OTHER primitives:
   - Bitmap filter (1 predicate) < 100 µs at 1M rows: bit-slice native, AoS cannot achieve
   - Bitmap filter (3-5 predicates compound) < 500 µs at 1M rows: bit-slice native
   - Composite distance with bit-slice block selection: 4× faster than AoS for block-subset Hamming

These are the wins that justify bit-slice. Full Hamming benefits incidentally (or not, given the 13% margin) but is not the driver.

---

## Substrate-level implementation forward path

When the substrate-level bit-slice layout is implemented (separate decision record, scope: cookbook §4.1-§4.3), the kernel layer needs minor adjustments:

1. A new `BitsliceKernel` conforming to `SubstrateKernel` that reads bit-slice memory layouts directly instead of converting from AoS.
2. The `SubstrateKernel` trait gains a query path for "read bit-slice column" since AoS Fingerprint256 reads don't transparently work over a bit-slice store.
3. The kernel registry registers `BitsliceKernel` alongside `SimdKernel` and the dispatcher picks based on the runtime layout (AoS in tests, bit-slice in production).

That work is sized at 1-2 weeks and gates on:
- The substrate-level bit-slice layout decision (file layout on disk, mmap protocol, crash recovery)
- The bitmap predicate filter primitive moving to a real workload that needs it (cookbook P1 at the substrate budget)
- The full §4.2 bit-slice file format being designed and tested at the substrate level

Until those gate, Phase 2.δ-3 remains declined. The kernel layer's full-Hamming SimdKernel hits 90% of the available speedup against the bandwidth floor with the AoS layout, which is sufficient for the documented hot-path workloads.

---

## Methodology takeaway

Eighth engineering-by-wallet finding, second declined-on-architectural-math case (after Phase 2.γ-3 Metal SimHash). The protocol now has two formally-established gates for declining without measurement:

**Gate 1: The relevant floor and slope are both already measured.** Phase 2.γ-3 declined Metal SimHash because the Metal floor (Phase 2.β-2(c)) and the SimdKernel slope (Phase 2.γ-1) gave a crossover beyond harness-measurable range.

**Gate 2: The candidate cannot beat the bandwidth floor that the current approach approaches within measurement noise.** Phase 2.δ-3 declines bit-slice for full Hamming because SimdKernel AoS is within 13% of the bandwidth floor and bit-slice for full Hamming has the same bandwidth demand.

Both gates require **measured** bounds, not paper estimates. Both are reproducible: someone reading the decision record can re-derive the bound from cited measurements. Both leave the door open with explicit trigger conditions for revisitation.

---

## Status

Declined at kernel level. Filed as Phase 2.δ candidate #3, declined. Substrate-level bit-slice implementation tracked under a future decision record covering cookbook §4.1-§4.3 and the cookbook's other I-18-dependent primitives.
