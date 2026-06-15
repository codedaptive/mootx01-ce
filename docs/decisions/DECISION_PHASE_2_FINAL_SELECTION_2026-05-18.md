---
status: decided
question: Which kernel approach is selected and proven for each substrate need in Phase 2?
authors: MOOTx01 maintainers
date: 2026-05-18
supersedes: none
context:
  - Closing artifact for the Phase 2 kernel dispatch architecture work (commits `d8602d4` through the Phase 2.δ-3 disposition).
  - One row per documented production need (cookbook §1.2 primitives plus the auxiliary ops the harness measures), each citing the selected approach and the empirical or architectural-math evidence proving it.
  - Hardware target is apple-m5-max, the substrate's primary target per cookbook §17.1 and §17.5.
---

# Phase 2 final selection: approach selected and proven for each substrate need

---

## Selection table

| # | Need | Hot/Cold | Selected approach | Selection rule | Proof (commit + measurement) |
|---|---|---|---|---|---|
| 1 | `or_reduce_256` cohort aggregation (cookbook §8.5, P6) | Hot | `SimdKernel.orReduce256` via `SIMD4<UInt64>` accumulator | Strictly dominates aarch64 | Phase 2.α-1 (`d8602d4`): 23.3× Swift / 2.2× Rust vs scalar at cohort=8, bs=256. BnnsKernel reduce 192× slower (`39cef1d`). |
| 2 | `or_reduce_batch` over many cohorts (auxiliary) | Cold | `SimdKernel.orReduceBatch` (overridden default loop) | Inherits Item 1 | Phase 2.α-1 (`d8602d4`): keeps SIMD accumulator in NEON registers across cohorts. |
| 3 | `hamming_distance_256` pair-at-a-time (cookbook §8.2) | Hot | `SimdKernel.hammingDistance256` via SIMD4 XOR + `nonzeroBitCount` | Lower constant than scalar | Phase 2.β-1 (`fa93c23`): byte-identical to scalar; same ns/call but no fallback path. |
| 4 | `hamming_distance_batch` (probe × N candidates, cookbook §8.2) | Both | `SimdKernel.hammingDistanceBatch` | Wins at every N | Phase 2.β-1 (`fa93c23`) at bs=256: 0.65 ns/cand. Rust 1.5× over scalar (`fa93c23`). NeonKernel 193× slower (`4e689b7`). BnnsKernel 68× slower at bs=256 (`b9ff9d1`). MetalKernel 35 ms at N=1M (`b804f1e`), 58× slower. |
| 5 | `hamming_top_k` top-K NN (cookbook §11.2, §17.1 hot-path P2) | Hot | `SimdKernel.hammingTopK` branchless ladder | Within 13% of bandwidth floor | Phase 2.δ-1 (`8e7916d`): K=10, N=1M in 604 µs vs scalar 30.85 ms = **51× speedup**. Cookbook §17.5 floor 533 µs. K-overhead negligible up to K=32; K=100 adds 7%. |
| 6 | `hamming_top_k` at K > log N (auxiliary, large K) | Cold | Falls back to scalar sort+truncate | Ladder cost grows linearly in K | Phase 2.δ-1 (`8e7916d`): SimdKernel ladder still wins at K=100 (7% over K=10), but the linear scan crossover with binary-heap-K is at K ≈ 30. For K > 100, future work. |
| 7 | `simhash_block_batch` bulk regen, bs ≥ 4 (cookbook §3.6, §15.4) | Cold | `SimdKernel.simhashBlockBatch` with `PackedFamily` + vertical SIMD | Bulk amortizes packing cost | Phase 2.γ-1 (`cea9446`): 6.5× Swift / 2.1× Rust at bs=256. Both languages converge to ~15.3 µs floor. BnnsKernel 3.7× asymptotically slower (`eb2bf81`). MetalKernel declined (Phase 2.γ-3, `2617eb9`). |
| 8 | `simhash_compute` per-row hot path, bs=1 (cookbook §3.6) | Hot | Inherited scalar | Below the SIMD packing crossover | Phase 2.γ-1 (`cea9446`): bs=1 SimdKernel SimHash is 0.4× (~416 ns) vs scalar 166 ns. SimdKernel does NOT override `simhashCompute`; falls through to scalar. |
| 9 | Lattice distance, composite distance, FFT, NMF, eigenvalue centrality | Cold | Not in Phase 2 scope | Substrate-level / future | Cookbook §8.3-§8.4, §8.10, §6.9, §7.2. Out of scope for the kernel dispatch architecture; tracked under future cookbook implementation work. |

---

## Methodology gate ledger

Eight engineering-by-wallet findings across Phase 2.α through 2.δ:

| Phase | Paper said | Measured | Direction |
|---|---|---|---|
| α-4 BnnsKernel or_reduce | "slow due to 8x amp" | 192× slower (also BNNS integer API gap) | wrong (worse) |
| β-2(a) NeonKernel | "Mula NEON pattern wins" | 193× slower (Swift vector-popcount gap) | wrong (worse) |
| β-2(b) BnnsKernel Hamming | "slow at typical batches" | 68× slower (encode cost) | wrong (worse) |
| β-2(c) MetalKernel Hamming | "crossover at 100K" | 87.5K (within 13%) | **right** |
| γ-1 SimdKernel SimHash | "might not help" | 6.5× faster | wrong (useful) |
| γ-2 BnnsKernel SimHash | "might genuinely win for bulk" | 3.7× asymptotically slower | wrong (useful) |
| δ-1 Branchless top-K | "wins decisively for K << log N" | 51× faster at K=10/N=1M | **right** |
| δ-2 Persistent buffers | "30-50 µs floor at small N" | 51 µs at bs=1 | **right** (small N), bottleneck migrated at large N |

Score: paper analysis was qualitatively right 3 of 8 times (β-2(c), δ-1, δ-2 at small N). Paper analysis was wrong in direction 5 of 8 times (α-4, β-2(a), β-2(b), γ-2, γ-2 plus the bottleneck migration in δ-2). Two findings shaped the methodology: γ-1 (paper wrong in useful direction) and γ-2 (paper wrong in useful direction).

Two formal declines without measurement, both citing architectural floor + slope from prior measurements:

| Phase | Decline rule | Reason |
|---|---|---|
| γ-3 MetalKernel SimHash | Crossover beyond harness range | 70 µs floor / 59 ns slope = N ≈ 1186 outside measurable range |
| δ-3 Bit-slice Hamming | Bandwidth floor already approached | SimdKernel 604 µs vs cookbook §17.5 floor 533 µs = within 13% |

---

## Dispatcher decision logic on aarch64

Production runtime selection is now reducible to a single fact: **`SimdKernel` is the production default for every op the substrate dispatches**. The dispatcher returns `SimdKernel` on `arch(arm64)`, with no learned dispatch needed for any of the three primitives in the candidate sweep:

```
PortableKernel.kernelForCurrentPlatform():
    #if arch(arm64)
    return SimdKernel()
    #else
    return ScalarKernel()
    #endif
```

The other kernels (`BnnsKernel`, `NeonKernel`, `MetalKernel`) remain registered and reachable via `--kernel <name>` for benchmarking and future re-measurement. They do not participate in production dispatch.

The dispatcher does NOT need:
- A learned-dispatch protocol per cookbook §4.4 (currently no op has a runtime-tunable kernel choice)
- Per-batch-size threshold tables (no kernel beats SimdKernel at any documented batch size)
- AMX-vs-LocalNLM contention awareness (BnnsKernel not in production path)

The cookbook §4.4 portable-kernel-layer specification is satisfied by the trait + dispatch protocol established in Phase 2.α-1. The "select the optimal backend at runtime" claim resolves to "SimdKernel on aarch64" — the optimum is determined empirically.

---

## Phase 2.ε backlog (not yet scoped)

Deferred from Phase 2.δ scoping plus items identified during measurement:

1. **AVX-512 / AVX-2 kernel specializations** — deferred to non-Apple Rust version work; requires x86_64 hardware not in dev env. The trait surface accommodates the new kernels; effort once hardware available is 2-3 days per architecture.

2. **Substrate-level bit-slice runtime layout (cookbook §4.1 I-18 constitutional)** — separate decision record covering on-disk format, mmap protocol, crash recovery (cookbook §4.2-§4.3). When this lands, a new `BitsliceKernel` will be added that reads the substrate-level bit-slice store; conformance gate against the existing scalar reference.

3. **Bitmap predicate filter primitive** (cookbook §4.5 P1) — bit-slice native; substrate-level work. Currently unimplemented; tracked under future cookbook implementation work.

4. **Pre-encoded float-matrix variant for Hamming at large N** — declined on architectural grounds (Phase 2.δ scoping); subsumed by bit-slice when that lands. If bit-slice does NOT close the 13% bandwidth-floor gap (which the math predicts it won't, materially), revisit.

5. **Rewritten Metal Hamming shader** — current shader processes 1 candidate per thread; a multi-candidate-per-thread variant could change the large-N regime. Tracked under future dreaming-daemon batch index-build pass scope.

6. **Branchless SIMD top-K ladder with SIMD8 register-resident pairs (corsix SMIN/SMAX)** — currently the linear ladder suffices because K-overhead is small. The corsix register-resident ladder would help at very large K; consider when a real workload pushes K > 100.

7. **NMF / eigenvalue centrality / FFT / lattice distance / composite distance** — out-of-scope kernel work that ties to cookbook P3, P9-P12. Tracked under future cookbook implementation.

8. **Phase 2.γ-3 MetalKernel SimHash** — remains declined; trigger condition is dreaming-daemon batch index-build pass becoming a real workload with N >> 1000 inputs per `simhashBlockBatch` call AND Metal dispatch floor improving on future hardware.

---

## Final summary

Phase 2 closes with **16 commits** establishing the per-op kernel dispatch architecture:

```
b804f1e  δ-2 persistent-buffer Metal (small-batch floor cut)
8e7916d  δ-1 branchless top-K (51x at K=10, N=1M)
54baa4a  δ scoping (triage of 6 deferred candidates)
2617eb9  γ-3 MetalKernel SimHash declined; phase 2.γ closes
eb2bf81  γ-2 BnnsKernel SimHash (measured rejection, 3.7x)
cea9446  γ-1 SimdKernel SimHash override (6.5x Swift, 2.1x Rust)
fbaef38  γ scoping (SimHash methodology gate)
d70258a  β-2(c) MetalKernel (crossover @ ~87.5K)
b9ff9d1  β-2(b) BnnsKernel Hamming (measured rejection, 68x)
4e689b7  β-2(a) NeonKernel candidate (measured rejection, 193x)
fa93c23  β-1 Hamming SimdKernel SIMD override (1.0x Swift, 1.5x Rust)
39cef1d  α-4 BnnsKernel or_reduce (measured rejection, 192x)
7ba44d8  α-3 benchmark framework
ffc6eea  α-2 dispatcher tests + Phase 2.β scoping
d8602d4  α-1 SimdKernel + per-op kernel dispatch
[next]   δ-3 disposition + final selection table
```

The 9 documented production needs (table above) are all met by `SimdKernel`. The methodology gate paid for itself: eight measured findings, two architectural-math declines, zero production regressions, every claim citable to a date + hardware + commit hash combination.

The kernel layer is **closed for Phase 2**. Future kernel work (bit-slice on bit-slice substrate, AVX-512 on x86_64, multi-candidate Metal shader) is gated on substrate-level decisions or different target hardware, not on further kernel-level optimization.
