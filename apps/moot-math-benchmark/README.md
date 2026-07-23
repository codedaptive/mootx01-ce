# MOOT benchmark

`apps/moot-math-benchmark` is the repository's reproducible performance-data
program for substrate kernels and cold-path learning algorithms. It records
what ran, on which hardware, from which commit, under which timing budget.

The current harness measures implementation performance. It is not yet a
product-level memory-quality benchmark and its results must not be presented as
recall-quality, usefulness, or competitor-comparison scores.

## Current evidence

The tracked result sets are indexed in [`results/README.md`](results/README.md).
They currently cover:

- Swift and Rust kernel sweeps on Apple M5 Max;
- Swift and Rust top-K sweeps;
- Swift and Rust SubstrateML sweeps;
- a Rust, Go, and Python cross-language kernel set.

Benchmark data remains an active program. A missing language, platform, or
operation is an unmeasured cell, not evidence of equal or worse performance.

## What it measures

| Binary | Scope | Schema |
|---|---|---|
| `stress-test` | Hamming, SimHash, and OR-reduce across kernels, batch sizes, and call modes | `2` |
| `topk-bench` | `hamming_top_k` across K ∈ {1, 4, 10, 32, 100} and N ∈ {256 … 1M} | `topk-1` |
| `ml-bench` | SubstrateML cold-path algorithms used by maintenance and dreaming work | `ml-1` |

Every optimized kernel must separately pass bit-identity conformance against
the scalar reference. A fast result cannot override a conformance failure.

## Quick start

From the repository root:

```sh
apps/moot-math-benchmark/submit-results.sh
```

For a build-and-run smoke test:

```sh
apps/moot-math-benchmark/submit-results.sh --quick
```

The script runs the six Swift/Rust binaries, captures a system report, and
creates:

```text
apps/moot-math-benchmark/results/<date>-<hardware-tag>/
```

Review the generated `SUBMISSION.md` before committing the result bundle.
Quick-mode results are diagnostic and should not be used for published
performance claims.

## Run one language

Swift:

```sh
cd apps/moot-math-benchmark/swift-bench
swift build -c release
.build/release/stress-test --out ../results/local-swift/
.build/release/topk-bench --out ../results/local-swift/hamming_topk-swift.json
.build/release/ml-bench --out ../results/local-swift/substrate_ml-swift.json
```

Rust:

```sh
cd apps/moot-math-benchmark/rust-bench
cargo run --release --bin stress-test -- --out ../results/local-rust/
cargo run --release --bin topk-bench -- --out ../results/local-rust/hamming_topk-rust.json
cargo run --release --bin ml-bench -- --out ../results/local-rust/substrate_ml-rust.json
```

Use a dated hardware tag instead of `local-*` for a submission.

## Reproducibility contract

A publishable result set must include:

| Evidence | Requirement |
|---|---|
| Source | Exact Git commit |
| Hardware | CPU/architecture, core count, RAM, and hardware tag |
| Software | OS plus Swift/Rust or other language toolchain |
| Timing | Warmup, measurement window, and whether quick mode was used |
| Input | Canonical seed and complete sweep grid |
| Output | JSON conforming to [`SCHEMA.md`](SCHEMA.md) |
| Conditions | Power/thermal state and material background load |

Do not compare files from different hardware or run conditions as if language
alone caused the difference. Prefer repeated full runs when the measured
margin is small.

## Add another language

Swift and Rust are the maintained reference ports. Go and Python evidence is
present in the tracked cross-language result set, but those ports are not
maintained in this directory.

- Schema and canonical field names: [`SCHEMA.md`](SCHEMA.md)
- Experimental protocol and caveats: [`METHODOLOGY.md`](METHODOLOGY.md)
- Maintained executable references: `swift-bench/` and `rust-bench/`

New ports must emit the same schema, operation names, parameter strings, seeds,
and sweep cells. Cross-language aggregation is a join over those stable fields,
not a hand-normalized spreadsheet.

## Submit results

1. Run the full sweep on an otherwise quiet machine.
2. Complete the generated `SUBMISSION.md`.
3. Confirm every JSON file parses and uses the expected schema.
4. Place all files under one dated hardware directory.
5. Open a PR titled `bench: <hardware-tag> <date>`.

Maintainers should review provenance and coverage before adding a result to an
aggregate. The repository does not currently publish a single headline score.

## Conformance is separate

Performance results live here. Cross-port correctness lives under
[`../../docs/validation/substrate_math_performance/`](../../docs/validation/substrate_math_performance/).
The release gates check catalog drift, Swift/Rust lockstep, test placement, and
clean harness builds. Optimized output must remain byte-identical to the scalar
reference.

## Relationship to future memory benchmarks

Product-level memory evaluation needs a different layer: a fixed corpus,
task/query set, expected evidence, scoring rules, latency/cost reporting, and
versioned result provenance. That work may reuse this directory's evidence
discipline, but kernel nanoseconds and memory usefulness must remain separate
datasets.
