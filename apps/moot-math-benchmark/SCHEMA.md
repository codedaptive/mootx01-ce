# moot-math-benchmark output schema

Every moot-math-benchmark port — Rust, Swift, Go, Python, anything else
— emits results in **one of two JSON schemas**. Tooling that ingests
results (`results/AGGREGATED.md` generator, decision-doc citations,
default-kernel-selection scripts) treats these as a hard contract:
*every field is required*, *no unknown fields*, *types must match
exactly*. If your new port can't produce these shapes byte-for-byte,
the result file will be rejected.

---

## Schema `topk-1` — `topk-bench` output

Produced by the `topk-bench` binary. Sweeps `hamming_top_k` across
K ∈ {1, 4, 10, 32, 100} × N ∈ {256, 1024, 4096, 16384, 65536, 262144,
1048576} for every available kernel.

```json
{
  "schema_version": "topk-1",
  "language": "rust",
  "op": "hamming_top_k",
  "date": "2026-05-22",
  "hardware_tag": "apple-m5-max",
  "seed": "0xcafebabedeadbeef",
  "timing": {
    "warmup_ms": 50,
    "measure_ms": 200,
    "quick_mode": false
  },
  "measurements": [
    {
      "kernel": "scalar",
      "n": 256,
      "k": 1,
      "iterations": 122587,
      "ns_per_call_min": 1458,
      "ns_per_call_mean": 1599,
      "ns_per_call_stddev": 357
    }
    /* ... one entry per (kernel, n, k) cell */
  ]
}
```

### Field-by-field

| Field | Type | Required | Constraint |
|---|---|---|---|
| `schema_version` | string | yes | exactly `"topk-1"` |
| `language` | string | yes | implementer chooses (`"rust"`, `"swift"`, `"go"`, `"python"`, etc.) |
| `op` | string | yes | exactly `"hamming_top_k"` |
| `date` | string | yes | `YYYY-MM-DD` of the run |
| `hardware_tag` | string | yes | short identifier, e.g. `"apple-m5-max"`, `"graviton4-c8g"`. No spaces. |
| `seed` | string | yes | hex with `0x` prefix, e.g. `"0xcafebabedeadbeef"`. Determines random-input generation. |
| `timing.warmup_ms` | int | yes | warmup window before measurement begins (ms) |
| `timing.measure_ms` | int | yes | measurement window (ms) |
| `timing.quick_mode` | bool | yes | true if `--quick` flag was passed |
| `measurements` | array | yes | one object per (kernel, n, k) cell |
| `.kernel` | string | yes | e.g. `"scalar"`, `"simd"`, `"neon"`, `"bnns"`, `"metal"` — see [Kernel naming](#kernel-naming) |
| `.n` | int | yes | dataset size |
| `.k` | int | yes | top-K |
| `.iterations` | int | yes | how many calls were averaged |
| `.ns_per_call_min` | int | yes | minimum observed wall-clock time in nanoseconds |
| `.ns_per_call_mean` | int | yes | mean observed wall-clock time in nanoseconds |
| `.ns_per_call_stddev` | int | yes | std-dev of observed times in nanoseconds |

### Default sweep grid

| Parameter | Values |
|---|---|
| `n` | 256, 1024, 4096, 16384, 65536, 262144, 1048576 |
| `k` | 1, 4, 10, 32, 100 |

`--quick` mode shortens the timing window only (10ms warmup / 40ms
measure); the N/K grid above is swept in both quick and full mode. Do not
shrink the grid for `--quick` — doing so changes the cell set and breaks
the cross-language join.

---

## Schema `2` — `stress-test` output

Produced by the `stress-test` binary. Sweeps a single op
across batch sizes and modes for every available kernel.

```json
{
  "schema_version": "2",
  "language": "rust",
  "op": "hamming_distance_batch",
  "date": "2026-05-18",
  "generated_at": "2026-05-18T03:11:13Z",
  "hardware_tag": "apple-m5-max",
  "commit_sha": "39cef1d",
  "seed": "0xcafebabedeadbeef",
  "timing": {
    "warmup_ms": 50,
    "measure_ms": 200,
    "quick_mode": false
  },
  "platform": {
    "arch": "aarch64",
    "os": "macos"
  },
  "measurements": [
    {
      "kernel": "scalar",
      "batch_size": 1,
      "mode": "batched",
      "iterations": 4378250,
      "ns_per_call_min": 0,
      "ns_per_call_mean": 14,
      "ns_per_call_stddev": 33,
      "ns_per_element_min": 0.0
    }
    /* ... one entry per (kernel, batch_size, mode) cell */
  ]
}
```

### Field-by-field

Same as `topk-1` for the common fields. Differences:

| Field | Type | Required | Constraint |
|---|---|---|---|
| `schema_version` | string | yes | exactly `"2"` |
| `op` | string | yes | one of: `"hamming_distance_batch"`, `"simhash_block_batch"`, `"or_reduce_batch"` (the emitted op-field token; the `--op` CLI flag accepts the short forms `hamming`, `simhash`, `or_reduce`) |
| `generated_at` | string | yes | ISO-8601 UTC timestamp |
| `commit_sha` | string | yes | git SHA (short form: 7 chars OK) of the repo at run time |
| `platform.arch` | string | yes | `"aarch64"` or `"x86_64"`. Lower-case, no underscores other than what's shown. |
| `platform.os` | string | yes | `"macos"`, `"linux"`, `"windows"` |
| `measurements[].batch_size` | int | yes | dataset size for this cell |
| `measurements[].mode` | string | yes | `"batched"` (the trait's batched method) or `"sequential"` (an explicit N-call loop of the pair-at-a-time op) |
| `measurements[].ns_per_element_min` | float | yes | min observed time per element (ns); for `mode == "sequential"` this MAY equal `ns_per_call_min` |

### Default batch grid

| Parameter | Values |
|---|---|
| `batch_size` | 1, 2, 4, 8, 16, 32, 64, 128, 256 |
| `mode` | `"batched"`, `"sequential"` |

---

## Schema `ml-1` — `ml-bench` output

Produced by the `ml-bench` binary. Sweeps all 15 **SubstrateML**
cold-path / dreaming-daemon algorithms across realistic input
sizes. This is the methodology-data-manipulator-gate evidence
for cold-path algorithms — measured, not calculated — that
informs the dreaming-daemon schedule and default-backend
selection (see the performance methodology gate).

```json
{
  "schema_version": "ml-1",
  "language": "rust",
  "op": "substrate_ml",
  "date": "2026-05-29",
  "hardware_tag": "apple-m5-max",
  "seed": "0xcafebabedeadbeef",
  "timing": {
    "warmup_ms": 50,
    "measure_ms": 200,
    "quick_mode": false
  },
  "measurements": [
    {
      "algorithm": "nmf_factorize",
      "params": "m=64,n=64,rank=8",
      "iterations": 14,
      "ns_per_call_min": 1400916,
      "ns_per_call_mean": 1450000,
      "ns_per_call_stddev": 35000
    }
    /* ... one entry per (algorithm, params) cell, 86 total */
  ]
}
```

### Field-by-field

| Field | Type | Required | Constraint |
|---|---|---|---|
| `schema_version` | string | yes | exactly `"ml-1"` |
| `language` | string | yes | `"rust"`, `"swift"`, `"go"`, `"python"`, or `"<your-port>"` |
| `op` | string | yes | exactly `"substrate_ml"` (literal — distinguishes from topk-1/stress-2) |
| `date` | string | yes | ISO date `YYYY-MM-DD` UTC of the run |
| `hardware_tag` | string | yes | see Kernel naming → Hardware tag below |
| `seed` | string | yes | hex `0x...` 16 chars, matches `--seed` argument |
| `timing.warmup_ms` | int | yes | `50` for normal, `10` for `--quick` |
| `timing.measure_ms` | int | yes | `200` for normal, `40` for `--quick` |
| `timing.quick_mode` | bool | yes | `true` ↔ `--quick` was passed |
| `measurements` | array | yes | exactly one entry per `(algorithm, params)` cell |
| `measurements[].algorithm` | string | yes | one of the 15+ canonical names (see grid below) |
| `measurements[].params` | string | yes | free-form size/params tag, e.g. `"n=1024"`, `"m=64,n=64,rank=8"` |
| `measurements[].iterations` | int | yes | how many calls fit in the measurement window |
| `measurements[].ns_per_call_min` | int | yes | minimum wall-ns/call seen |
| `measurements[].ns_per_call_mean` | int | yes | mean wall-ns/call |
| `measurements[].ns_per_call_stddev` | int | yes | stddev of wall-ns/call |

### Canonical sweep grid (15 algorithms, 86 cells)

| Algorithm name(s) | Sweep axis | Cells |
|---|---|---|
| `anomaly_z_score`, `anomaly_modified_z_score` | `n ∈ {100, 1k, 10k, 100k}` | 8 |
| `bradley_terry_observe`, `bradley_terry_observe_batch` | `items ∈ {10, 100, 1000}` | 6 |
| `community_detection` | `n ∈ {50, 200, 1000}` | 3 |
| `composite_distance` | `single_call` | 1 |
| `eigenvalue_centrality` | `n ∈ {50, 200, 1000}` | 3 |
| `feature_extractor_healthkit`, `feature_extractor_corelocation` | `single_sample` | 2 |
| `fft_forward`, `fft_magnitude_spectrum` | `n ∈ {64, 256, 1024, 4096, 16384}` | 10 |
| `float_simhash_project` | `dim ∈ {128, 384, 768, 1536}` | 4 |
| `info_theory_entropy`, `info_theory_kl`, `info_theory_cross_entropy`, `info_theory_mi` | `k ∈ {64, 256, 1024}` | 12 |
| `lattice_distance_udc` | `len ∈ {3, 6, 10, 18}` | 4 |
| `llm_calibration_observe`, `llm_calibration_ece`, `llm_calibration_brier` | `warm_obs ∈ {100, 1000, 10000}` | 9 |
| `moment_summary` | `rows ∈ {100, 1k, 10k, 100k}` | 4 |
| `nmf_factorize` | `(m, n) × rank` (rank < min(m,n)) | 11 |
| `random_walks_walk` | `n × length` | 6 |
| `temporal_compression_compress` | `rows ∈ {100, 1k, 10k}` | 3 |
| **Total** |   | **86** |

The `params` string within each cell is **free-form key=value pairs
joined by commas**. Both the Rust and Swift reference ports emit
identical `params` strings for identical sweep points, and the
aggregator joins on `(hardware_tag, algorithm, params)`. New ports
MUST emit identical strings for the same cells; if a port adds a
new sweep point, it gets a new params value (it doesn't reformat
the existing ones).

### Why this matters

Methodology gate: every algorithm in this sweep produced numbers
that look "obviously slow" or "obviously fine" before they were
measured. Several were surprising — modified-z-score is ~20× the
plain z-score because of the sort; NMF scales as expected with
m·n·rank·iterations; FFT shows the textbook N log N; FloatSimHash
is linear in dim; MI is ~2× entropy because of the joint matrix.
None of these numbers come from a calculation. All come from this
file. Decision docs cite specific `(date, hardware_tag, commit)`
triples from this schema.

---

## Kernel naming

The `kernel` string identifies which backend was used. Stable values:

| Name | Meaning | Required? |
|---|---|---|
| `scalar` | The scalar reference. The substrate's oracle — bit-identical output is gated against this. | **Required.** Every port MUST implement and emit this. |
| `simd` | Generic portable SIMD (e.g. Rust `std::simd::u64x4`, Swift `import simd`, Go SIMD package). | Optional. Emit only if you implemented it. |
| `neon` | ARM NEON intrinsics — aarch64 only. | Optional. |
| `avx2`, `avx512` | x86_64 vector kernels. | Optional. |
| `bnns` | Apple BNNS framework (Apple-only). | Optional. |
| `metal` | Apple Metal GPU compute (Apple-only). | Optional. |

If you implement a kernel under a new name (e.g. `riscv-vector`), add it
to this table in your PR. The aggregation tooling tolerates unknown
kernel names — they just don't get a column in `AGGREGATED.md` until
named here.

---

## Reproducibility

Each entry in `measurements` is the result of:

1. Generate inputs from `seed` (same seed → same inputs across all ports).
2. Run a warmup loop for `timing.warmup_ms` milliseconds without recording.
3. Run a measurement loop for `timing.measure_ms` milliseconds, recording
   wall-clock nanoseconds per call.
4. Report `iterations` (call count), `ns_per_call_min`,
   `ns_per_call_mean`, `ns_per_call_stddev`.

Wall-clock time is `std::time::Instant` (Rust), `ContinuousClock`
(Swift), `time.Now()` (Go), `time.perf_counter_ns()` (Python).
*Not* CPU time. We're measuring what the kernel actually delivers
to the user.

## Naming the output file

Format: `<op>-<language>.json` placed in
`apps/moot-math-benchmark/results/<date>-<hardware-tag>/`.

Examples:

- `apps/moot-math-benchmark/results/2026-05-22-apple-m5-max/hamming_topk-rust.json`
- `apps/moot-math-benchmark/results/2026-05-22-apple-m5-max/hamming_topk-swift.json`
- `apps/moot-math-benchmark/results/2026-05-22-apple-m5-max/hamming_topk-go.json` ← *your contribution*

A single hardware/date directory may contain results from many languages;
the aggregator joins them on `(hardware_tag, op, kernel, n, k)`.
