# Published performance evidence

This is the current evidence snapshot for `develop/1.0.x`, measured on
2026-07-22 local time (2026-07-23 UTC) at commit
`b3fcd1dc59b3fc022a55eda8ece54d1ac9135c99`.

Raw samples and provenance are in
[`results/2026-07-22-apple-m4-b3fcd1dc-evidence/`](results/2026-07-22-apple-m4-b3fcd1dc-evidence/).
The conditions and limitations are part of that bundle and are required when
citing a number from this page.

## What the evidence says

| Product/design claim | Verdict on this run | Evidence |
|---|---|---|
| Cookbook math is represented and cross-port conformant | **Supported** | 29/29 canonical primitives validated and timed in Swift and Rust |
| Capture stays under 100 ms | **Supported on this Mac workload only** | resident `file_memory`, P99 23.753 ms, 120 samples |
| Recall feels interactive on a small estate | **Supported** | precise recall P99 11.794 ms; relevance search P99 56.274 ms at 120 rows |
| Precise recall remains interactive under adversarial retrieval load | **Supported for most compositions at 1,040 records** | common precise compositions P95 37.0–52.9 ms; `text+mmr` is a 3,787.9 ms outlier |
| Retrieval quality improved from the historical MOOT gauntlet | **Supported for named compositions, not uniformly** | f@1/MRR improved for `text`, `text+temporal`, and `text+assembly`; `text+assembly` f@10 moved 0.86→0.85 |
| Hamming top-K K=10/N=1M is under 100 µs | **Not met** | Swift SIMD minimum 655.250 µs, 6.55× over budget |
| One-predicate bitmap filter is under 10 µs and a full scan is about 1 ms | **Unverified** | no 1M-row product bit-slice workload exists in this bundle |
| Capture P99 target is met on iPhone | **Unverified on iPhone** | this run is Apple M4/macOS, not an iPhone |
| Current classifier additions have measured cost | **Supported** | FDC v4 stages measured across five workload classes in both ports |

## Shipped product boundary

The release binary was `mootx01 1.0.34 (2026-07-20)`, SHA-256
`bc940718884951b1f4ec98779e8e3094b6d4993ca73ba97eb962c36d6817bb38`.
It ran as a resident HTTP daemon against a temporary estate that was deleted
afterward. Values below are complete loopback MCP round trips.

| Operation | Samples | P50 | P95 | P99 |
|---|---:|---:|---:|---:|
| Estate ping | 80 | 0.216 ms | 0.285 ms | 0.348 ms |
| File memory (`impatient=true`) | 120 | 16.247 ms | 22.794 ms | 23.753 ms |
| Relevance search, limit 10 | 80 | 53.120 ms | 54.730 ms | 56.274 ms |
| Precise recall, limit 10/pool 30 | 80 | 11.161 ms | 11.448 ms | 11.794 ms |
| Estate status | 80 | 2.159 ms | 2.308 ms | 2.342 ms |

Resident daemon startup was 114.503 ms. The estate contained one warmup write
and 120 measured writes; these values do not establish million-row scaling or
concurrent throughput.

## Historical retrieval gauntlet retest

The EE `tools/mcp-benchmarker` adversarial gauntlet was rerun on the MOOT side
against the same deterministic seed and workload: 200 queries, 1,040 records,
five difficulty tiers, and four distractors per needle. The full report's
DegeneracyGuard passed. See [`GAUNTLET.md`](GAUNTLET.md) for the tier definitions,
historical comparison, and limitations.

| Like-for-like strategy | Historical mean / P95 | 1.0.34 mean / P95 | Current quality |
|---|---:|---:|---|
| `precise:text` | 203.1 / 215.3 ms | 31.1 / 47.4 ms | f@1 0.21, f@10 0.71, MRR 0.331 |
| `precise:text+temporal` | 197.3 / 207.2 ms | 30.1 / 42.6 ms | f@1 0.23, f@10 0.71, MRR 0.341 |
| `precise:text+assembly` | 208.1 / 217.8 ms | 32.2 / 49.0 ms | f@1 0.21, f@10 0.85, MRR 0.369 |
| `mootx01:raw` | 148.6 / 168.2 ms | 146.7 / 181.6 ms | f@1 0.12, f@10 0.56, MRR 0.251 |

The common precise strategies are 6.46×–6.55× faster by mean latency and
4.44×–4.86× faster at P95 than the historical MOOT rows. This is not a blanket
latency claim: `precise:text+mmr` measured 1,634.1 ms mean / 3,787.9 ms P95.
Nor is it a current MemPalace comparison: MemPalace was not rerun, so the
source-native report correctly records superiority as `NOT EVALUABLE`.

## Exact-kernel results

Best observed steady-state time is reported, matching the existing gate
methodology. Swift exercised scalar, SIMD, NEON, and Metal registrations; Rust
was scalar-only because the pinned nightly portable-SIMD toolchain was not
installed on the host.

| Workload | Swift selected result | Rust scalar |
|---|---:|---:|
| Hamming batch, 256 candidates | SIMD 272 ns (1.062 ns/candidate) | 218 ns (0.852 ns/candidate) |
| SimHash block batch, 256 inputs | SIMD 18.458 µs (72.102 ns/input) | 38.125 µs (148.926 ns/input) |
| OR-reduce batch, 256 cohorts | SIMD 740 ns (2.891 ns/cohort) | 1.141 µs (4.457 ns/cohort) |
| Hamming top-K, K=10/N=1,048,576 | SIMD 655.250 µs | 1.089 ms |
| Hamming top-K, K=100/N=1,048,576 | SIMD 714.333 µs | 1.116 ms |

The current K=10 result is close to the cookbook's roughly 533 µs bandwidth
floor but does not satisfy the 100 µs budget. The correct conclusion is that
the existing full-fingerprint layout is fast but the budget requires fewer
bytes read or a materially different layout.

## Broad cookbook and cold-path math

Both ports first passed all 29 canonical primitive vectors. The catalog rows
time validation of a pre-parsed full vector batch, so they include
expected-output comparison and CRC overhead but not file I/O or JSON parsing.
Representative minimum per-case values:

| Primitive | Swift | Rust |
|---|---:|---:|
| Lattice distance | 0.477 µs | 0.103 µs |
| Hamming canonical case | 5.876 µs | 0.428 µs |
| Audit-log fold | 25.849 µs | 2.953 µs |
| Hamming NN | 47.145 µs | 4.098 µs |
| NMF canonical case | 83.497 µs | 24.534 µs |
| Merkle commitment | 3.590 µs | 0.694 µs |

The focused ML suite emitted all 86 expected cells. Representative minima:

| Workload | Swift | Rust |
|---|---:|---:|
| FFT, n=1,024 | 9.125 µs | 9.500 µs |
| Eigenvalue centrality, n=1,000 | 80.417 µs | 86.000 µs |
| Community detection, n=1,000 | 3.243 ms | 1.926 ms |
| NMF, 64×64 rank 8 | 1.302 ms | 1.538 ms |
| Temporal compression, 10,000 rows | 3.396 µs | 3.698 µs |

## Deterministic classifier v4

Both ports reported classifier `4.2.0`, deterministic data `2.0.0`, semantic
model `1.0.0`, and semantic-model SHA-256
`138e42f09478db92ca261ad544e1f3143ce4b168d0e9f726dedd80614739d227`.
Full encode includes classifier work and semantic resolution. Minimum times:

| Input | Swift full encode | Rust full encode | Swift candidates (8) | Rust candidates (8) |
|---|---:|---:|---:|---:|
| Short resolved | 2.934 ms | 1.415 ms | 32.416 µs | 35.083 µs |
| Medium resolved | 3.636 ms | 1.801 ms | 64.875 µs | 58.250 µs |
| Long mixed | 8.593 ms | 2.634 ms | 187.167 µs | 110.500 µs |
| Unresolved | 0.141 ms | 0.048 ms | 29.459 µs | 32.750 µs |
| Code | 0.207 ms | 0.667 µs | 34.125 µs | 35.834 µs |

First-use initialization was 474.266 ms in Swift and 215.744 ms in Rust.
The code fast path differs substantially between ports and should be retained
as a regression sentinel rather than generalized to natural-language input.

## Method limits

- This is one host and one run, not a device fleet or confidence interval.
- Minimum kernel timings are steady-state best case; product rows publish raw
  samples and percentiles instead.
- No load, concurrency, energy, thermal, or sustained-write test was run.
- Rust SIMD was not measured on this host.
- Catalog timing is validator-shaped and must not be cited as isolated
  arithmetic latency.
- The product dataset is intentionally small and disposable.
- The adversarial gauntlet is larger but still only 1,040 records, and its full
  run reuses a preloaded/dreamed estate; it does not measure ingest-to-ready time.
- Historical MemPalace values are context only and cannot establish current
  comparative superiority.
- Cross-generation hardware conclusions await the matched Mac mini M4 vs
  MacBook Pro M5 Max mission in
  `docs/engineering/MAC_M5_MAX_PERFORMANCE_COMPARISON_MISSION.md`.

These limits are part of the evidence. Claims outside them remain unverified.
