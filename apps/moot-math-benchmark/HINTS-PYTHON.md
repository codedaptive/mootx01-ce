# moot-math-benchmark port hints — Python

A one-shot guide to add a Python port of the moot-math-benchmark benchmarks.
Goal: a Python developer reading this file + `SCHEMA.md` has everything
needed to produce `topk-bench.py`, `stress-test.py`, and `ml-bench.py` scripts that
emit byte-comparable JSON to the Rust and Swift ports.

> **Before you write any code**, read `SCHEMA.md` in this directory.
> The JSON output schema is the hard contract.

---

## Where the canonical primitives live

These are the algorithms your Python port must reimplement. The Rust
reference is in `../../packages/libs/`; treat that as the spec, not
just a sample.

| Primitive | Cookbook § | Rust reference | What it does |
|---|---|---|---|
| `Fingerprint256` (data type) | §3.1 | `SubstrateTypes/rust/src/fingerprint256.rs` | 256-bit value; a struct of four `u64` fields `block0..block3` (wire-equivalent to `[u64; 4]`; a 4-tuple of masked ints is fine in Python) |
| `hamming_distance_256` | §8.2 | `SubstrateTypes/rust/src/hamming.rs` | XOR + popcount across 4 lanes |
| `hamming_top_k` | §11.2 | `SubstrateKernel/rust/src/kernel.rs::hamming_top_k` (scalar) and `kernel_simd.rs` (SIMD) | Find the K nearest fingerprints to a query, by Hamming distance |
| `or_reduce_256` | §8.5 | `SubstrateTypes/rust/src/or_reduce.rs` | Element-wise OR-reduce a slice of fingerprints |
| `simhash_block` | §3.6 | `SubstrateTypes/rust/src/simhash.rs` | Compute one 64-bit block of a SimHash fingerprint |

The canonical engineering cookbook is
`docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md`.
Read the cited sections before implementing.

---

## Hot algorithm reference (pseudocode)

### `hamming_distance_256` — §8.2

```
hamming_distance_256(a: [u64;4], b: [u64;4]) -> uint:
    sum = 0
    for i in 0..4:
        sum += popcount(a[i] XOR b[i])
    return sum
```

In Python: `int.bit_count()` (Python 3.10+) or `bin(x).count('1')`.
For the `numpy` kernel, use `numpy.bitwise_count` (numpy 2.0+) over
a `(N, 4)` `uint64` array — that's where the speedup lives.

### `hamming_top_k` (scalar reference) — §11.2

```
hamming_top_k(query: [u64;4], candidates: [[u64;4]], k: int)
        -> [(idx: int, distance: uint); k]:

    # K-element max-heap keyed on distance. Smaller distance is better;
    # we keep the K smallest, so we pop the LARGEST when full.
    heap = max_heap()
    for i, c in enumerate(candidates):
        d = hamming_distance_256(query, c)
        if len(heap) < k:
            heap.push((d, i))
        elif d < heap.top().distance:
            heap.pop()
            heap.push((d, i))

    # Tie-breaking: when multiple candidates have the same distance,
    # ascending index. See HammingTopKTieBreakTests.swift for the
    # spec-pinned fixture.
    return heap.sorted_ascending_by_distance_then_index()
```

Two-stable-sort: distance ascending, index ascending on ties. Don't
deviate — the conformance harness pins this. Python's `heapq` is a
min-heap, so push `(-distance, -index)` to fake a max-heap, or use
`heapq.nlargest`/`nsmallest` with a custom key.

The SIMD ladder is in `kernel_simd.rs::hamming_top_k`. The "numpy"
kernel using vectorized `bitwise_count` plus `numpy.argpartition` is
the closest Python equivalent. If you implement only scalar, your
output will only contain `kernel: "scalar"` entries — that's fine,
the project gains a Python data point at the scalar baseline.

### `or_reduce_256` — §8.5

```
or_reduce_256(xs: [[u64;4]]) -> [u64;4]:
    acc = [0, 0, 0, 0]
    for x in xs:
        for i in 0..4:
            acc[i] |= x[i]
    return acc
```

Identity is `[0,0,0,0]`. Commutative and associative — fold order is
free. In numpy: `np.bitwise_or.reduce(xs, axis=0)`.

### `simhash_block` and hyperplane generation (for `stress-test`) — §3.6

`stress-test`'s simhash op needs more than `simhash_block`: it must
first build a `HyperplaneFamily`. The bench seeds it with
`expand_seed_to_32(rng.next())`, where `expand_seed_to_32` applies four
rounds of the bench-level SplitMix64 and writes little-endian bytes. The
`HyperplaneFamily` then has its OWN internal PRNG, seeded from those 32
bytes differently than the bench SplitMix64 (it XOR-mixes the four
8-byte LE chunks — see `SplitMix64::new` in
`packages/libs/SubstrateTypes/rust/src/hyperplane.rs`,
`HyperplaneFamily::generate`, and `expand_seed_to_32` in
`rust/src/bin/stress_test.rs`). The bench uses
`density = 1.0`, `block_index = 0`, `input_bit_length = 192`. Do not use
NumPy for this integer path; masked Python ints are required to match
Rust `u64` wrapping.

### Random fingerprint generation (deterministic, cross-port)

The seed in the JSON output determines the input fingerprints. To
match Rust and Swift output, use the same PRNG. The reference is
The bench binaries import `harness::SplitMix64` from
`docs/validation/substrate_math_performance/test-harness/rust/src/harness/splitmix64.rs`
(the `state = seed` constructor). An identical copy lives at
`packages/libs/SubstrateML/rust/src/random_walks.rs`; either serves as
the spec, but the harness copy is what the bench actually uses. Confirm
your port with these cross-language vectors: `seed=42` produces
`0xBDD732262FEB6E95`, `0x28EFE333B266F103`, `0x47526757130F9F52`.

SplitMix64:

```python
MASK64 = (1 << 64) - 1

class SplitMix64:
    def __init__(self, seed: int):
        self.state = seed & MASK64

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return (z ^ (z >> 31)) & MASK64

    def new_fingerprint(self) -> tuple[int, int, int, int]:
        return (self.next(), self.next(), self.next(), self.next())
```

Initial state is the 64-bit seed parsed from the `--seed` flag
(default `0xcafebabedeadbeef`). The `MASK64` wraparound is critical
— Python ints are unbounded so you MUST mask after every operation
to mirror Rust's u64 wrapping semantics.

Cross-port verification: with `seed=0xcafebabedeadbeef`, the first
output from `SplitMix64.next()` must equal the Rust port's first
output for the same seed.

---

## SubstrateML algorithm reference (for `ml-bench`)

The 15 SubstrateML algorithms — the cold-path dreaming-daemon
math — must be reimplemented for the Python `ml-bench` script.
The Rust reference is at
`../../packages/libs/SubstrateML/rust/src/*.rs`; the Swift
reference at `../../packages/libs/SubstrateML/Sources/SubstrateML/*.swift`.

| Algorithm | Cookbook § | Rust reference |
|---|---|---|
| `anomaly_z_score`, `anomaly_modified_z_score` | §8.13 | `anomaly.rs` |
| `bradley_terry_observe`, `bradley_terry_observe_batch` | §8.12 | `bradley_terry.rs` |
| `community_detection` (Louvain phase 1) | §7.3 | `community_detection.rs` |
| `composite_distance` | §8.3 | `composite_distance.rs` |
| `eigenvalue_centrality` (power iteration + Perron shift) | §7.2 | `eigenvalue_centrality.rs` |
| `feature_extractor_*` (HealthKit, CoreLocation) | §3.9 | `feature_extractors.rs` |
| `fft_forward`, `fft_magnitude_spectrum` (Cooley-Tukey radix-2) | §8.10 | `fft.rs` |
| `float_simhash_project` | §3.6 | `float_simhash.rs` |
| `info_theory_entropy`, `info_theory_kl`, `info_theory_cross_entropy`, `info_theory_mi` | §8.11 | `info_theory.rs` |
| `lattice_distance_udc` | §8.3 | `lattice_distance.rs` |
| `llm_calibration_observe`, `llm_calibration_ece`, `llm_calibration_brier` | §15.2 | `calibration.rs` |
| `moment_summary` (OR-reduce over a window) | §8.7 | `moment_summary.rs` |
| `nmf_factorize` (alternating least squares) | §6.9 | `nmf.rs` |
| `random_walks_walk` (with restart) | §7.4 | `random_walks.rs` |
| `temporal_compression_compress` (hour windows) | §8.14 | `temporal_compression.rs` |

**Python implementation notes:**

- Pure-Python loops over 100k-element arrays are 50-100× slower
  than the same work in Rust or Swift; that's expected and part
  of the methodology-gate evidence. **Do not reach for NumPy** to
  paper over this — the goal of the Python port is to show the
  scaling shape and the algorithm correctness, not to win the
  performance trophy. The decision protocol cites Rust and Swift
  numbers for production characterization.
- The exception: `fft_forward` may use a hand-written Cooley-Tukey
  recursion (matches Rust line-for-line) rather than NumPy's FFT.
  The point is to measure Python's loop overhead, not NumPy's
  highly-tuned C kernel.
- **Match the sweep grid in SCHEMA.md §`ml-1` exactly.** Same 86
  cells, same `params` strings. The aggregator joins on those.

The two most important numerical gotchas, lifted from the Rust
docblocks:

- **EigenvalueCentrality** uses a Perron-Frobenius shift
  `SHIFT = 1.0` to avoid the bipartite ±λ oscillation.
- **HyperplaneFamily.generate** treats `density >= 1.0` as
  "every bit active" without round-tripping through
  `float(2**64) * density`.

---

## CLI contract

Both scripts accept these flags. Same names, same defaults, same
behavior on every port.

### `topk-bench.py` flags

| Flag | Default | Meaning |
|---|---|---|
| `--seed <0xhex>` | `0xcafebabedeadbeef` | RNG seed; identical runs reproduce |
| `--kernel <name>` | `(all available)` | one of `scalar`, `numpy`, etc. |
| `--n <list>` | `256,1024,4096,16384,65536,262144,1048576` | comma-separated N values |
| `--k <list>` | `1,4,10,32,100` | comma-separated K values |
| `--out <path>` | (auto in `results/`) | output JSON path |
| `--quick` | false | shorter timing window (10ms warmup / 40ms measure); the N/K grid is unchanged |

### `ml-bench.py` flags

| Flag | Default | Meaning |
|---|---|---|
| `--seed <0xhex>` | `0xcafebabedeadbeef` | seed for the SplitMix64 generator |
| `--algorithm <name>` | `all` | run one algorithm (any from the 15+ canonical names) or `all` |
| `--out <path>` | `results/<date>-<hw>/substrate_ml-python.json` | output file or directory |
| `--quick` | off | small budget (10ms warmup, 40ms measure) for iteration |

Output: `ml-1` schema JSON. See SCHEMA.md.

### `stress-test.py` flags

| Flag | Default | Meaning |
|---|---|---|
| `--seed <0xhex>` | `0xcafebabedeadbeef` | RNG seed |
| `--op <name>` | `all` | one of `hamming`, `simhash`, `or_reduce`, or `all` (short CLI names; the emitted `op` field is the token form `hamming_distance_batch` / `simhash_block_batch` / `or_reduce_batch`) |
| `--kernel <name>` | (all available) | as above |
| `--out <path>` | (auto in `results/`) | output JSON path |
| `--quick` | false | smoke mode |

If `--out` is a directory, the script names the file as
`<op>-<lang>.json` under the directory.

---

## Suggested file layout

```
apps/moot-math-benchmark/
└── python/
    ├── pyproject.toml                 (or requirements.txt)
    ├── moot_math_benchmark/
    │   ├── __init__.py
    │   ├── primitives.py              Fingerprint256, hamming, or_reduce, simhash
    │   ├── prng.py                    SplitMix64
    │   ├── kernels.py                 scalar (required) + numpy (optional)
    │   └── schema.py                  dataclasses for the JSON shapes
    └── bin/
        ├── topk_bench.py
        └── stress_test.py
```

Run:

```sh
cd apps/moot-math-benchmark/python
python3 -m moot_math_benchmark.bin.topk_bench --quick \
    --out ../results/$(date +%Y-%m-%d)-$(uname -m)-py-topk.json
```

Dependencies: stdlib only for the scalar kernel; `numpy >= 2.0` for
the vectorized kernel.

---

## Skeleton — `bin/topk_bench.py`

```python
#!/usr/bin/env python3
"""moot-math-benchmark topk-bench, Python port.

Sweeps hamming_top_k across K x N for every kernel. Emits
schema topk-1 (see ../SCHEMA.md). Reference port: Rust
apps/moot-math-benchmark/rust/src/bin/topk_bench.rs.
"""
from __future__ import annotations
import argparse
import json
import math
import platform
import subprocess
import time
from dataclasses import dataclass, field, asdict
from typing import Iterable

MASK64 = (1 << 64) - 1

# ---------- PRNG ----------

class SplitMix64:
    """Must match packages/libs/SubstrateML/rust/src/random_walks.rs."""
    __slots__ = ("state",)
    def __init__(self, seed: int):
        self.state = seed & MASK64

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return (z ^ (z >> 31)) & MASK64

    def new_fp(self) -> tuple[int, int, int, int]:
        return (self.next(), self.next(), self.next(), self.next())

# ---------- primitives (scalar) ----------

def hamming_distance_256(a: tuple, b: tuple) -> int:
    """XOR + popcount across 4 lanes. See cookbook §8.2."""
    return ((a[0] ^ b[0]).bit_count() +
            (a[1] ^ b[1]).bit_count() +
            (a[2] ^ b[2]).bit_count() +
            (a[3] ^ b[3]).bit_count())

def hamming_top_k_scalar(query: tuple, xs: list, k: int) -> list[tuple[int, int]]:
    """Top-K nearest by Hamming distance. Tie-break: distance asc, index asc.
    See cookbook §11.2 and HammingTopKTieBreakTests.swift."""
    # TODO: implement using heapq. Push (-distance, -index) to simulate
    # a max-heap; pop the worst (largest distance, then largest index)
    # when full and the new entry is better. Final sort: (distance, index)
    # both ascending.
    raise NotImplementedError("TODO: see HammingTopKTieBreakTests.swift")

# ---------- output schema (mirrors SCHEMA.md exactly) ----------

@dataclass
class Timing:
    warmup_ms: int
    measure_ms: int
    quick_mode: bool

@dataclass
class TopKMeasurement:
    kernel: str
    n: int
    k: int
    iterations: int
    ns_per_call_min: int
    ns_per_call_mean: int
    ns_per_call_stddev: int

@dataclass
class TopKReport:
    schema_version: str
    language: str
    op: str
    date: str
    hardware_tag: str
    seed: str
    timing: Timing
    measurements: list[TopKMeasurement] = field(default_factory=list)

# ---------- bench loop ----------

def run_cell(seed: int, kernel: str, n: int, k: int,
             warmup_ms: int, measure_ms: int) -> TopKMeasurement:
    rng = SplitMix64(seed)
    # Draw the probe FIRST, then the n candidates — matches the Rust
    # bench's measure_top_k order. Drawing candidates first produces a
    # different input set from the same seed and breaks the cross-language
    # cell join.
    query = rng.new_fp()
    candidates = [rng.new_fp() for _ in range(n)]

    fn = {"scalar": hamming_top_k_scalar,
          # "numpy": hamming_top_k_numpy,  # TODO
         }[kernel]

    # Warmup
    deadline = time.perf_counter_ns() + warmup_ms * 1_000_000
    while time.perf_counter_ns() < deadline:
        fn(query, candidates, k)

    # Measure
    samples = []
    deadline = time.perf_counter_ns() + measure_ms * 1_000_000
    while time.perf_counter_ns() < deadline:
        t0 = time.perf_counter_ns()
        fn(query, candidates, k)
        samples.append(time.perf_counter_ns() - t0)

    mn = min(samples)
    mean = sum(samples) // len(samples)
    var = sum((s - mean) ** 2 for s in samples) / len(samples)
    sd = int(math.sqrt(var))
    return TopKMeasurement(
        kernel=kernel, n=n, k=k,
        iterations=len(samples),
        ns_per_call_min=mn,
        ns_per_call_mean=mean,
        ns_per_call_stddev=sd,
    )

def detect_hardware_tag() -> str:
    """Best-effort hardware identifier matching Rust's style. e.g.
    "apple-m5-max", "graviton4-c8g", "intel-i7-13700k"."""
    # TODO: implement. Match harness::hardware::tag() at
    # docs/validation/substrate_math_performance/test-harness/rust/src/harness/hardware.rs.
    # macOS: `sysctl -n machdep.cpu.brand_string`. Linux: the "model name"
    # field of /proc/cpuinfo. Then slugify(): lowercase all alphanumerics,
    # collapse every run of other characters to a single hyphen, and trim
    # trailing hyphens -- e.g. "Apple M5 Max" -> "apple-m5-max".
    raise NotImplementedError("TODO")

# ---------- CLI ----------

def parse_seed(s: str) -> int:
    return int(s, 0)

def parse_int_list(s: str) -> list[int]:
    return [int(x) for x in s.split(",") if x]

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--seed", type=parse_seed, default=parse_seed("0xcafebabedeadbeef"))
    p.add_argument("--kernel", default=None)
    p.add_argument("--n", type=parse_int_list,
                   default=[256, 1024, 4096, 16384, 65536, 262144, 1048576])
    p.add_argument("--k", type=parse_int_list,
                   default=[1, 4, 10, 32, 100])
    p.add_argument("--out", required=True)
    p.add_argument("--quick", action="store_true")
    args = p.parse_args()

    warmup, measure = 50, 200
    if args.quick:
        # Quick mode shrinks the TIMING WINDOW only; the N/K grid is
        # unchanged. The Rust bench uses WARMUP_QUICK=10, MEASURE_QUICK=40
        # and the full grid, so its quick run still emits all 35 cells.
        # Reducing the grid here would make the cell shape diverge.
        warmup, measure = 10, 40

    kernels = [args.kernel] if args.kernel else ["scalar"]  # add "numpy" when implemented

    report = TopKReport(
        schema_version="topk-1",
        language="python",
        op="hamming_top_k",
        date=time.strftime("%Y-%m-%d", time.gmtime()),
        hardware_tag=detect_hardware_tag(),
        seed=f"0x{args.seed:016x}",
        timing=Timing(warmup_ms=warmup, measure_ms=measure, quick_mode=args.quick),
    )

    for kn in kernels:
        for n in args.n:
            for k in args.k:
                m = run_cell(args.seed, kn, n, k, warmup, measure)
                report.measurements.append(m)
                print(f"{kn:8s}  N={n:<7d} K={k:<3d}  min={m.ns_per_call_min}ns iters={m.iterations}")

    with open(args.out, "w") as f:
        json.dump(asdict(report), f, indent=2)
    print(f"\n  wrote {args.out}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

The skeleton is intentionally **incomplete** —
`hamming_top_k_scalar` and `detect_hardware_tag` are TODOs. The
cookbook §11.2 and the Rust reference in
`SubstrateKernel/rust/src/kernel.rs` are the specs. Fill in, run
`--quick`, and verify against `SCHEMA.md`.

---

## Conformance check

Same protocol as the Go port. Run Rust and Python on the same
machine with the same seed, then diff non-timing fields:

```sh
cargo run --release --bin topk-bench --quick --out /tmp/rust.json
python3 -m moot_math_benchmark.bin.topk_bench --quick --out /tmp/py.json

jq 'del(.measurements, .language)' /tmp/rust.json > /tmp/rust-meta.json
jq 'del(.measurements, .language)' /tmp/py.json   > /tmp/py-meta.json
diff /tmp/rust-meta.json /tmp/py-meta.json    # should be empty (modulo `date`)

jq '.measurements | map({kernel, n, k}) | sort' /tmp/rust.json > /tmp/rust-cells.json
jq '.measurements | map({kernel, n, k}) | sort' /tmp/py.json   > /tmp/py-cells.json
diff /tmp/rust-cells.json /tmp/py-cells.json  # should be empty
```

Also verify the PRNG cross-port: print the first 10 SplitMix64
outputs from both ports with `seed=0xcafebabedeadbeef` and check
they match.

---

## Submitting results

After your port produces valid JSON:

1. Run it on real hardware (not `--quick`).
2. Drop the JSON in `apps/moot-math-benchmark/results/<date>-<hardware-tag>/`.
3. Open a PR with title `bench: <hardware-tag> <date> add Python port`.
4. Reference this hint file in the PR description so reviewers can
   spot any deviation from the contract.
