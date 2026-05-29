# Benchmark Framework

Empirical kernel benchmark sweep for the GeniusLocus substrate. Every
candidate kernel that's compiled in gets measured here, across every
(op, batch_size, mode) cell. Decision docs cite specific runs of this
framework instead of paper estimates.

## Why this exists

The methodology gate (see
`docs/decisions/METHODOLOGY_DATA_MANIPULATOR_GATE_2026-05-17.md`)
requires every kernel candidate to be implemented and measured, not
rejected on paper. The first OR-reduce decision record contained a
line like "rejected for 8x bandwidth amplification" that was a
calculation, not a measurement. This framework turns that line into
"measured at N ns/call on `<hardware>` `<date>`, commit `<sha>`,
M times slower than SimdKernel."

When a future engineer proposes a new candidate, the protocol is:

1. Implement the candidate as a new `SubstrateKernel` conformer.
2. Register it in `kernel_registry` (Rust:
   `test-harness/rust/src/harness/kernel_registry.rs`; Swift:
   `test-harness/swift/Sources/Harness/Core/KernelRegistry.swift`).
3. Run `stress-test --all` on the dev hardware.
4. Attach the resulting JSON files to the decision-doc PR.
5. The decision doc cites the JSON file path + commit hash + hardware
   tag in its "measured at" line.

No more "I calculated that X would be slower." The wallet has spoken.

## Running

From `test-harness/rust/`:

```
cargo run --release --bin stress-test -- [flags]
```

From `test-harness/swift/`:

```
swift run -c release stress-test [flags]
```

### Flags

| Flag | Default | Meaning |
|---|---|---|
| `--seed <0xhex>` | `0xcafebabedeadbeef` | RNG seed; identical runs reproduce |
| `--op <name>` | `all` | `hamming`, `simhash`, `or_reduce`, or `all` |
| `--kernel <name>` | (uses `--all`) | Single-kernel run; mutually exclusive with `--all` |
| `--all` | implicit when `--kernel` absent | Iterate every kernel in the registry |
| `--out <path>` | standard location | Either a directory or a `.json` path |
| `--quick` | full budget | 10ms warmup + 40ms measure per cell (use for iteration, not for publishable numbers) |

### Output location

When `--out` is omitted, the binary writes to:

```
apps/MatrixSprint/results/{YYYY-MM-DD}-{hardware-slug}/
  {op}-{language}.json
```

`{hardware-slug}` is generated from `sysctl machdep.cpu.brand_string`
on macOS, `/proc/cpuinfo` on Linux. Examples: `apple-m3-max`,
`apple-m5-max`, `arm-neoverse-n2`, `intel-xeon-platinum-8480cl`.

The `results/` directory is tracked in git for known-hardware
reference snapshots; individual contributors' submissions land
under `apps/MatrixSprint/results/{date}-{hardware-tag}/`. The
expectation is small files (one JSON per (op, language)), not
binary dumps. Specific numbers that matter end up cited in
decision docs.

### Time budget

A full sweep at default timing (50ms warmup + 200ms measure per cell)
runs in roughly:

```
ops * batch_sizes * modes * kernels * (warmup + measure)
= 3 * 9 * 2 * N * 250ms
= 13.5 * N seconds
```

For N=2 (scalar + simd) that's ~27 seconds per language, ~55 seconds
total. Each new kernel adds ~14 seconds.

Use `--quick` for ~5x faster iteration when developing a candidate;
switch back to full timing for the run cited in the decision doc.

## Output schema (v2)

One JSON file per (op, language). All kernels for that op are in the
`measurements` array. Top-level fields capture provenance:

```json
{
  "schema_version": "2",
  "language": "rust",
  "op": "or_reduce_batch",
  "date": "2026-05-18",
  "generated_at": "2026-05-18T02:04:26Z",
  "hardware_tag": "apple-m5-max",
  "commit_sha": "ffc6eea",
  "seed": "0xcafebabedeadbeef",
  "timing": {
    "warmup_ms": 50,
    "measure_ms": 200,
    "quick_mode": false
  },
  "platform": { "arch": "aarch64", "os": "macos" },
  "measurements": [
    {
      "kernel": "scalar",
      "batch_size": 256,
      "mode": "batched",
      "iterations": 35272,
      "ns_per_call_min": 1000,
      "ns_per_call_mean": 1103,
      "ns_per_call_stddev": 451,
      "ns_per_element_min": 3.906
    },
    ...
  ]
}
```

### Key fields

- `ns_per_call_min` — best observed wall-clock for one call. The
  most useful "is this kernel fast" number; tail noise gets filtered
  to the mean+stddev.
- `ns_per_call_mean`, `ns_per_call_stddev` — distribution of
  samples; large stddev means the measurement is noisy and worth
  re-running.
- `ns_per_element_min` — `ns_per_call_min / batch_size`. The cross-
  over point between two kernels is where this number is equal;
  below that point, the higher per-call-overhead kernel loses.
- `iterations` — how many samples the measurement loop collected.
  Low iterations (< 100) on a slow op means the measure window
  was too short.

## Adding a new candidate kernel

The candidate matrix (current at Phase 2.α-3):

| Candidate | Swift | Rust | Status |
|---|---|---|---|
| Scalar | ✓ | ✓ | Always-on reference |
| SimdKernel (portable SIMD) | ✓ | ✓ | Default for aarch64 |
| Direct NEON intrinsics (Mula wide-accumulator) | planned | n/a | Phase 2.β-2 |
| BNNS bit-as-byte (OR-reduce) | planned | n/a | Phase 2.α-4 |
| BNNS float-encoded (Hamming) | planned | n/a | Phase 2.β-2 |
| Metal compute kernel | planned | n/a | Phase 2.β-2 |

Rust is for non-Apple ports. Apple-specific kernels (BNNS, Accelerate,
Metal) are Swift-only; Rust skips them with a clear note in the
registry rather than shimming through bindgen.

To add a new candidate (call it `FooKernel`):

1. Add the implementation file alongside
   `packages/libs/SubstrateKernel/rust/src/kernel_simd.rs` and
   `packages/libs/SubstrateKernel/Sources/SubstrateKernel/PortableKernel-SIMD.swift`.
   Make it a `SubstrateKernel` conformer (Phase 6.9b moved
   kernels from SubstrateLib to their own package).
2. Add a `KernelKind` variant for it (Rust:
   `packages/libs/SubstrateKernel/rust/src/kernel.rs` enum +
   `parse()` + `as_str()`; Swift:
   `packages/libs/SubstrateKernel/Sources/SubstrateKernel/PortableKernel.swift`
   enum).
3. Wire it in `PortableKernel::of_kind` (Rust) and
   `PortableKernel.kernel(of:)` (Swift) — return the new kernel when
   asked by kind, fall through to ScalarKernel on platforms that
   don't have it.
4. Register it in `kernel_registry::available()` (Rust) or
   `KernelRegistry.available()` (Swift). Gate on `#cfg(feature = ...)`
   or `#if` predicates if the kernel isn't unconditionally available.
5. Add it to the dispatcher selection tests (one per language) —
   assert that `kernel(of: .foo).kind == .foo`.
6. Pass conformance: every kernel must produce byte-identical output
   to ScalarKernel for the existing test vectors. The harness
   `validate-vectors --kernel foo <vectors>.json` runs the
   conformance gate.
7. Run `stress-test --all` and commit the resulting JSON snapshot
   reference in the decision doc.

That's it. The framework picks up the new kernel automatically. No
stress-test changes needed; no special-casing.

## How decision docs cite results

Inside a decision record, a citation looks like:

```
Measured at apple-m5-max on 2026-05-18, commit ffc6eea:
- ScalarKernel or_reduce_batch bs=256: 1000 ns/call
- SimdKernel  or_reduce_batch bs=256: 458 ns/call (2.2x faster)

Full sweep: apps/MatrixSprint/results/2026-05-18-apple-m5-max/
            or_reduce-rust.json
```

The JSON file path is gitignored locally but recoverable: anyone with
the same hardware can re-run `stress-test --seed 0xcafebabedeadbeef
--op or_reduce` at the same commit and produce a byte-identical
output (modulo timing noise). The reproducibility is the point.

## Top-K benchmark

A parallel binary, `topk-bench`, writes to the same
`benchmarks/results/{date}-{hw}/` directory but emits a
distinct schema (`topk-1`) and is not part of the recurring
stress-test sweep. It is the historical Phase 2.delta-1
instrument for `hamming_top_k` latency; see the parent harness
`README.md` section "Top-K benchmark (historical Phase 2.delta-1
instrument)" for usage, the cited Phase 2.delta-1 number, and
the 2026-05-22 cross-language baseline.

## Caveats

**Timing noise is real.** On a busy macOS machine with Slack and
Chrome running, ns_per_call_min can swing 20-30%. For decision-doc
citations, run the sweep on a quiet machine, prefer ns_per_call_min,
and confirm with a second run if the speedup margin is under 1.5x.

**Per-element timing is best-case.** `ns_per_element_min` divides the
min observed call by the batch size. It's the right metric for
"what is the asymptotic per-element cost when the kernel is hot,"
but it ignores per-call overhead. For the crossover question
(at what batch size does kernel A beat kernel B), compare
`ns_per_call_min` curves across batch sizes.

**Cargo incremental cache can confuse negative tests.** If a test
starts failing mysteriously after you've been swapping kernel code
in and out for negative-testing the dispatcher, run `cargo clean`
before assuming the test is wrong. See the dispatcher-tests commit
for the original encounter.

**The harness always picks SimdKernel on aarch64 unless overridden.**
The dispatcher policy is "SimdKernel strictly dominates on aarch64";
benchmarking confirms this is true for the SIMD-implemented ops.
When adding a new candidate, the dispatcher policy doesn't change —
the new kernel is reachable via `--kernel <name>` for benchmarking,
but production still goes through `kernelForCurrentPlatform()` which
returns SimdKernel.
