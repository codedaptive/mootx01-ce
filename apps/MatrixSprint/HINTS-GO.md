# MatrixSprint port hints — Go

A one-shot guide to add a Go port of the MatrixSprint benchmarks.
Goal: a Go developer reading this file + `SCHEMA.md` has everything
needed to produce `topk-bench`, `stress-test`, and `ml-bench`
binaries (in Go) that emit byte-comparable JSON to the Rust and
Swift ports.

The three bench binaries cover three different parts of the
substrate:

- **`topk-bench`** — top-K nearest-neighbor scan over fingerprints
  (the hot-path recall primitive, with SIMD ladder).
- **`stress-test`** — bandwidth-bound bitmap kernel ops (hamming,
  simhash, or_reduce) across batch sizes.
- **`ml-bench`** — the 15 SubstrateML cold-path algorithms (NMF,
  FFT, eigenvalue centrality, anomaly detection, etc.) — the
  dreaming-daemon math. Schema `ml-1` (see SCHEMA.md).

> **Before you write any code**, read `SCHEMA.md` in this directory.
> The JSON output schema is the hard contract.

---

## Where the canonical primitives live

These are the algorithms your Go port must reimplement. The Rust
reference is in `../../packages/libs/`; treat that as the spec, not
just a sample.

| Primitive | Cookbook § | Rust reference | What it does |
|---|---|---|---|
| `Fingerprint256` (data type) | §3.1 | `SubstrateTypes/rust/src/fingerprint256.rs` | 256-bit value; a struct of four `u64` fields `block0..block3` (wire-equivalent to `[u64; 4]`; Go `[4]uint64` is fine) |
| `hamming_distance_256` | §8.2 | `SubstrateTypes/rust/src/hamming.rs` | XOR + popcount across 4 lanes |
| `hamming_top_k` | §11.2 | `SubstrateKernel/rust/src/kernel.rs::hamming_top_k` (scalar reference) and `kernel_simd.rs` (SIMD ladder) | Find the K nearest fingerprints to a query, by Hamming distance |
| `or_reduce_256` | §8.5 | `SubstrateTypes/rust/src/or_reduce.rs` | Element-wise OR-reduce a slice of fingerprints |
| `simhash_block` | §3.6 | `SubstrateTypes/rust/src/simhash.rs` | Compute one 64-bit block of a SimHash fingerprint |

The canonical engineering cookbook is
`docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md`.
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

In Go: `math/bits.OnesCount64`. Four-lane unroll wins on amd64; on
arm64, four `popcnt.16b` lanes plus a `uaddlv` are the floor.

### `hamming_top_k` (scalar reference) — §11.2

```
hamming_top_k(query: [u64;4], candidates: [][u64;4], k: int)
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
deviate — the conformance harness pins this.

The SIMD ladder (`kernel_simd.rs::hamming_top_k`) is a branchless
variant that maintains the heap as a flat array; you may implement
both or just the scalar reference. If you implement only scalar, your
output will only contain `kernel: "scalar"` entries — that's fine,
the project gains a Go data point at the scalar baseline.

### `or_reduce_256` — §8.5

```
or_reduce_256(xs: [[u64;4]]) -> [u64;4]:
    acc = [0, 0, 0, 0]
    for x in xs:
        acc[0] |= x[0]
        acc[1] |= x[1]
        acc[2] |= x[2]
        acc[3] |= x[3]
    return acc
```

Identity is `[0,0,0,0]`. Commutative and associative — fold order is
free. (See `ORReduce.swift` in `SubstrateTypes` for the algebraic
properties stated in code.)

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
`MatrixSprintRust/src/bin/stress_test.rs`). The bench uses
`density = 1.0`, `block_index = 0`, `input_bit_length = 192`.

### Random fingerprint generation (deterministic, cross-port)

The seed in the JSON output determines the input fingerprints. To
match Rust and Swift output, use the same PRNG. The bench binaries
import `harness::SplitMix64` from
`docs/validation/substrate_math_performance/test-harness/rust/src/harness/splitmix64.rs`
(the `state = seed` constructor). An identical copy lives at
`packages/libs/SubstrateML/rust/src/random_walks.rs`; either serves as
the spec, but the harness copy is what the bench actually uses. Confirm
your port with these cross-language vectors: `seed=42` produces
`0xBDD732262FEB6E95`, `0x28EFE333B266F103`, `0x47526757130F9F52`.

```
SplitMix64(state):
    state = state + 0x9E3779B97F4A7C15
    z = state
    z = (z XOR (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z XOR (z >> 27)) * 0x94D049BB133111EB
    return z XOR (z >> 31), state
```

To generate a fingerprint:

```
new_fingerprint(state) -> ([u64; 4], state):
    w0, state = SplitMix64(state)
    w1, state = SplitMix64(state)
    w2, state = SplitMix64(state)
    w3, state = SplitMix64(state)
    return [w0, w1, w2, w3], state
```

Initial state for the bench is the 64-bit seed parsed from the
`--seed` flag (default `0xcafebabedeadbeef`).

---

## SubstrateML algorithm reference (for `ml-bench`)

The 15 SubstrateML algorithms — the cold-path dreaming-daemon
math — must be reimplemented in Go for `ml-bench`. The Rust
reference is at `../../packages/libs/SubstrateML/rust/src/*.rs`;
the Swift reference at
`../../packages/libs/SubstrateML/Sources/SubstrateML/*.swift`.
Each Rust + Swift pair is conformance-gated where pinned (see
`primitive-catalog.md` in the test harness).

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

For each algorithm, two things must match the Rust / Swift ports:

1. **API shape.** Same inputs, same outputs, same types (within
   Go-natural translations: `[]float32` for `Vec<f32>`, `[][]float32`
   for matrices, etc.). The harness conformance gate uses byte-
   identical CRC32 over canonical binary serializations; ml-bench
   does not need to match the conformance gate, but downstream
   tooling will compare cell-by-cell.

2. **Sweep grid.** The 86 cells in SCHEMA.md §`ml-1` must all
   appear in your output with identical `(algorithm, params)`
   strings. The aggregator joins on these strings; if Go's
   `params` reads `"n=1024"` but Rust's reads `"n = 1024"`, the
   join fails.

A few of these algorithms have subtle numerical gotchas — see
the inline docblocks in the Rust source. The two most important:

- **EigenvalueCentrality** uses a Perron-Frobenius shift `SHIFT = 1.0`
  to avoid the bipartite ±λ oscillation. Pure power iteration
  oscillates on bipartite graphs; the shift breaks the symmetry.
  The Go port must apply the same shift.
- **HyperplaneFamily.generate** treats `density >= 1.0` as the
  degenerate "every bit active" case without round-tripping
  through `Double(u64::MAX) * density`. The conversion saturates
  in Rust, traps in Swift, and would also be undefined in Go
  without the special case.

---

## CLI contract

Both binaries accept these flags. Same names, same defaults, same
behavior on every port.

### `topk-bench` flags

| Flag | Default | Meaning |
|---|---|---|
| `--seed <0xhex>` | `0xcafebabedeadbeef` | RNG seed; identical runs reproduce |
| `--kernel <name>` | `(all available)` | one of `scalar`, `simd`, etc. |
| `--n <list>` | `256,1024,4096,16384,65536,262144,1048576` | comma-separated N values |
| `--k <list>` | `1,4,10,32,100` | comma-separated K values |
| `--out <path>` | (auto in `results/`) | output JSON path |
| `--quick` | false | shorter timing window (10ms warmup / 40ms measure); the N/K grid is unchanged |

### `ml-bench` flags

| Flag | Default | Meaning |
|---|---|---|
| `--seed <0xhex>` | `0xcafebabedeadbeef` | seed for the SplitMix64 generator |
| `--algorithm <name>` | `all` | run one algorithm (any from the 15+ canonical names) or `all` |
| `--out <path>` | `results/<date>-<hw>/substrate_ml-go.json` | output file or directory |
| `--quick` | off | small budget (10ms warmup, 40ms measure) for iteration |

Output: `ml-1` schema JSON. See SCHEMA.md.

### `stress-test` flags

| Flag | Default | Meaning |
|---|---|---|
| `--seed <0xhex>` | `0xcafebabedeadbeef` | RNG seed |
| `--op <name>` | `all` | one of `hamming`, `simhash`, `or_reduce`, or `all` (short CLI names; the emitted `op` field is the token form `hamming_distance_batch` / `simhash_block_batch` / `or_reduce_batch`) |
| `--kernel <name>` | (all available) | as above |
| `--out <path>` | (auto in `results/`) | output JSON path |
| `--quick` | false | smoke mode |

If `--out` is a directory, the binary names the file as
`<op>-<lang>.json` under the directory.

---

## Suggested file layout

```
apps/MatrixSprint/
└── MatrixSprintGo/
    ├── go.mod                       module matrix-sprint-go
    ├── cmd/
    │   ├── topk-bench/main.go
    │   └── stress-test/main.go
    └── internal/
        ├── primitives/
        │   ├── fingerprint.go        Fingerprint256 type + helpers
        │   ├── hamming.go            scalar Hamming distance + top-k
        │   ├── or_reduce.go
        │   └── simhash.go
        ├── prng/
        │   └── splitmix64.go         deterministic RNG matching the Rust port
        ├── kernel/
        │   ├── kernel.go             interface (Hamming, OrReduce, TopK, SimHashBlock)
        │   └── scalar.go             reference impl — required
        └── output/
            └── schema.go             JSON shapes from SCHEMA.md
```

Build:

```sh
cd apps/MatrixSprint/MatrixSprintGo
go build ./cmd/topk-bench
go build ./cmd/stress-test
```

Run:

```sh
./topk-bench --quick --out ../results/$(date +%Y-%m-%d)-$(uname -m)-go-topk.json
```

---

## Skeleton — `cmd/topk-bench/main.go`

```go
package main

import (
    "encoding/json"
    "flag"
    "fmt"
    "math"
    "math/bits"
    "os"
    "time"
)

// Fingerprint256 is the substrate's 256-bit value type. Layout
// matches Rust's `[u64; 4]` and Swift's `[UInt64]` (count == 4).
type Fingerprint256 [4]uint64

func hammingDistance256(a, b Fingerprint256) int {
    return bits.OnesCount64(a[0]^b[0]) +
        bits.OnesCount64(a[1]^b[1]) +
        bits.OnesCount64(a[2]^b[2]) +
        bits.OnesCount64(a[3]^b[3])
}

// SplitMix64 — must match
// packages/libs/SubstrateML/rust/src/random_walks.rs::SplitMix64.
type SplitMix64 struct{ state uint64 }

func (s *SplitMix64) Next() uint64 {
    s.state += 0x9E3779B97F4A7C15
    z := s.state
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    return z ^ (z >> 31)
}

func (s *SplitMix64) NewFingerprint() Fingerprint256 {
    return Fingerprint256{s.Next(), s.Next(), s.Next(), s.Next()}
}

// hammingTopKScalar — see HINTS-GO.md and the cookbook §11.2 spec.
// Tie-break: distance ascending, index ascending on ties.
func hammingTopKScalar(q Fingerprint256, xs []Fingerprint256, k int) []struct {
    Idx  int
    Dist int
} {
    // ... implementation here. Use container/heap for the max-heap;
    // sort the result by (dist, idx) ascending.
    panic("TODO")
}

// JSON output schema. Mirrors SCHEMA.md exactly. DO NOT add fields;
// DO NOT rename fields; types must match.
type Timing struct {
    WarmupMs  int  `json:"warmup_ms"`
    MeasureMs int  `json:"measure_ms"`
    QuickMode bool `json:"quick_mode"`
}

type TopKMeasurement struct {
    Kernel         string `json:"kernel"`
    N              int    `json:"n"`
    K              int    `json:"k"`
    Iterations     int    `json:"iterations"`
    NsPerCallMin   int64  `json:"ns_per_call_min"`
    NsPerCallMean  int64  `json:"ns_per_call_mean"`
    NsPerCallStdDev int64 `json:"ns_per_call_stddev"`
}

type TopKReport struct {
    SchemaVersion string            `json:"schema_version"`
    Language      string            `json:"language"`
    Op            string            `json:"op"`
    Date          string            `json:"date"`
    HardwareTag   string            `json:"hardware_tag"`
    Seed          string            `json:"seed"`
    Timing        Timing            `json:"timing"`
    Measurements  []TopKMeasurement `json:"measurements"`
}

// Run one (kernel, n, k) cell. Generates n fingerprints from the
// seeded PRNG, picks one as the query, then iterates the topK over
// `timing.measure_ms` and reports the timing.
func runCell(seed uint64, kernel string, n, k, warmupMs, measureMs int) TopKMeasurement {
    rng := &SplitMix64{state: seed}
    // Draw the probe FIRST, then the n candidates — this matches the
    // Rust bench's measure_top_k order. Drawing candidates first
    // produces a different input set from the same seed and breaks the
    // cross-language cell join.
    query := rng.NewFingerprint()
    candidates := make([]Fingerprint256, n)
    for i := range candidates {
        candidates[i] = rng.NewFingerprint()
    }

    // Warmup
    warmupEnd := time.Now().Add(time.Duration(warmupMs) * time.Millisecond)
    for time.Now().Before(warmupEnd) {
        _ = hammingTopKScalar(query, candidates, k)
    }

    // Measure
    measureEnd := time.Now().Add(time.Duration(measureMs) * time.Millisecond)
    samples := []int64{}
    for time.Now().Before(measureEnd) {
        t0 := time.Now()
        _ = hammingTopKScalar(query, candidates, k)
        samples = append(samples, time.Since(t0).Nanoseconds())
    }

    var min, sum int64 = math.MaxInt64, 0
    for _, s := range samples {
        if s < min {
            min = s
        }
        sum += s
    }
    mean := sum / int64(len(samples))
    var sd float64
    for _, s := range samples {
        d := float64(s - mean)
        sd += d * d
    }
    sd = math.Sqrt(sd / float64(len(samples)))

    return TopKMeasurement{
        Kernel:          kernel,
        N:               n,
        K:               k,
        Iterations:      len(samples),
        NsPerCallMin:    min,
        NsPerCallMean:   mean,
        NsPerCallStdDev: int64(sd),
    }
}

func main() {
    seedHex := flag.String("seed", "0xcafebabedeadbeef", "RNG seed")
    out := flag.String("out", "", "output JSON path")
    quick := flag.Bool("quick", false, "smoke mode")
    flag.Parse()

    var seed uint64
    fmt.Sscanf(*seedHex, "0x%x", &seed)

    ns := []int{256, 1024, 4096, 16384, 65536, 262144, 1048576}
    ks := []int{1, 4, 10, 32, 100}
    warmup, measure := 50, 200
    if *quick {
        // Quick mode shrinks the TIMING WINDOW only; the N/K grid is
        // unchanged. The Rust bench uses WARMUP_QUICK=10, MEASURE_QUICK=40
        // and the full grid, so its quick run still emits all 35 cells.
        // Reducing the grid here would make the cell shape diverge.
        warmup, measure = 10, 40
    }

    report := TopKReport{
        SchemaVersion: "topk-1",
        Language:      "go",
        Op:            "hamming_top_k",
        Date:          time.Now().UTC().Format("2006-01-02"),
        HardwareTag:   detectHardwareTag(),
        Seed:          *seedHex,
        Timing:        Timing{WarmupMs: warmup, MeasureMs: measure, QuickMode: *quick},
    }

    for _, n := range ns {
        for _, k := range ks {
            m := runCell(seed, "scalar", n, k, warmup, measure)
            report.Measurements = append(report.Measurements, m)
            fmt.Printf("scalar  N=%-7d K=%-3d  min=%dns iters=%d\n", n, k, m.NsPerCallMin, m.Iterations)
        }
    }

    f, _ := os.Create(*out)
    defer f.Close()
    enc := json.NewEncoder(f)
    enc.SetIndent("", "  ")
    enc.Encode(report)
}

func detectHardwareTag() string {
    // Match harness::hardware::tag() at
    // docs/validation/substrate_math_performance/test-harness/rust/src/harness/hardware.rs.
    // macOS: `sysctl -n machdep.cpu.brand_string`. Linux: the "model name"
    // field of /proc/cpuinfo. Then slugify(): lowercase all alphanumerics,
    // collapse every run of other characters to a single hyphen, and trim
    // trailing hyphens — e.g. "Apple M5 Max" -> "apple-m5-max".
    panic("TODO")
}
```

The skeleton is intentionally **incomplete** — `hammingTopKScalar`
and `detectHardwareTag` are TODOs. The cookbook §11.2 and the
Rust reference in `SubstrateKernel/rust/src/kernel.rs` are the
specs. Fill in, compile, and run `--quick` until the JSON output
validates against `SCHEMA.md`.

---

## Conformance check

Before you submit results, verify the JSON your Go port emits
matches the Rust port byte-for-byte on the same `(hardware,
seed)`. Field-by-field equality (modulo `language` and the timing
numbers themselves):

```sh
# Run Rust and Go on the same machine, with the same seed.
cargo run --release --bin topk-bench --quick --out /tmp/rust.json
./topk-bench --quick --out /tmp/go.json

# All non-timing fields must match.
jq 'del(.measurements, .language)' /tmp/rust.json > /tmp/rust-meta.json
jq 'del(.measurements, .language)' /tmp/go.json   > /tmp/go-meta.json
diff /tmp/rust-meta.json /tmp/go-meta.json    # should be empty

# Measurement shape must match — same kernel × N × K cells.
jq '.measurements | map({kernel, n, k}) | sort' /tmp/rust.json > /tmp/rust-cells.json
jq '.measurements | map({kernel, n, k}) | sort' /tmp/go.json   > /tmp/go-cells.json
diff /tmp/rust-cells.json /tmp/go-cells.json  # should be empty
```

If those diffs are non-empty, fix your port before submitting.

---

## Submitting results

After your port produces valid JSON:

1. Run it on real hardware (not `--quick`).
2. Drop the JSON in `apps/MatrixSprint/results/<date>-<hardware-tag>/`.
3. Open a PR with title `bench: <hardware-tag> <date> add Go port`.
4. Reference this hint file in the PR description so reviewers can
   spot any deviation from the contract.
