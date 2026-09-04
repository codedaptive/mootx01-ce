# MOOT Math Speed Test

This application measures the speed of GeniusLocus substrate primitives and
kernel backends across Swift and Rust. It is a focused substrate speed test,
not the end-to-end memory benchmark suite published under
[`benchmarks/`](../../benchmarks/README.md).

AI systems and coding agents should begin with [`AGENTS.md`](AGENTS.md).

## Quick start: run + submit on your hardware

```sh
apps/moot-math-speedtest/submit-results.sh
```

That runs the ten math binaries (Rust + Swift × stress + top-K + ML +
catalog + FDC) on your machine, gathers a system report, and bundles everything in
`apps/moot-math-speedtest/results/<date>-<hardware-tag>/` ready to `git add`
and PR. If a release `mootx01` binary is already built, the script also runs
the isolated product-boundary benchmark. Add `--quick` for a smoke test. See the generated
`SUBMISSION.md` inside the bundle for the next steps.

The current published evidence and its claim-by-claim interpretation are in
[`PERFORMANCE.md`](PERFORMANCE.md). Coverage of the cookbook math is recorded
in [`COVERAGE.md`](COVERAGE.md). The 1.0.34 retest of the adversarial retrieval
gauntlet is documented in [`GAUNTLET.md`](GAUNTLET.md).

## Add a new language port

Rust and Swift are the maintained reference ports. A new port must implement
the same operations, inputs, deterministic seeds, timing phases, and output
fields defined in [`METHODOLOGY.md`](METHODOLOGY.md) and
[`SCHEMA.md`](SCHEMA.md). Validate the port against the canonical vectors
before submitting its results. Every port must emit byte-comparable JSON so
the aggregator can join cross-language data without language-specific rules.

## Why this exists

The substrate has multiple kernel backends per platform:

- **Swift:** ScalarKernel, SimdKernel (`import simd`), NeonKernel
  (aarch64 only), BnnsKernel (Apple platforms), MetalKernel (GPU)
- **Rust:** ScalarKernel, plus a nightly portable-SIMD kernel
  (`std::simd::u64x4`, gated on `simd-nightly`)

All backends are conformance-gated to be **bit-identical** to the scalar
reference (see `docs/validation/substrate_math_performance/`). The
question this tool answers is *which is the fastest on your hardware*.

Results from the community become the inputs to platform-specific
`#if arch(...)` / `#[cfg(target_feature = ...)]` gates in the kernel
dispatch path, so the default backend on each platform is the one that
actually won on real hardware — not the one someone calculated should
win.

## What it measures

| Bin           | What it sweeps                                       |
| ------------- | ---------------------------------------------------- |
| `stress-test` | Every (op, batch_size, mode) cell across all kernels |
| `topk-bench`  | `hamming_top_k` across K ∈ {1, 4, 10, 32, 100} × N ∈ {256 … 1M} |
| `ml-bench`    | The 15 SubstrateML cold-path algorithms (NMF, FFT, eigenvalue centrality, anomaly detection, …) — the dreaming-daemon math (schema `ml-1`) |
| `catalog-bench` | All 31 canonical cookbook/conformance primitives, after a mandatory conformance pass (schema `catalog-1`) |
| `fdc-bench` | Deterministic classifier v4 encode and semantic stages across resolved, unresolved, long, and code inputs (schema `fdc-1`) |
| `product-bench.py` | Resident `mootx01` loopback MCP calls against a disposable estate (schema `product-1`) |
| [`benchmarks/`](../../benchmarks/README.md) | Separate end-to-end suite for retrieval, answer quality, payload economics, storage behavior, latency, and throughput |

Each run produces a structured JSON file with:

- Hardware identification (CPU model, core count, RAM, OS)
- Software identification (commit SHA, Swift/Rust toolchain version)
- Per-cell timing (median, p50, p90, p99 from N iterations)

## Running

### Swift

```sh
cd apps/moot-math-speedtest/swift-bench
swift run -c release stress-test --out ../results/$(date +%Y-%m-%d)-$(uname -m)-swift-stress.json
swift run -c release topk-bench   --out ../results/$(date +%Y-%m-%d)-$(uname -m)-swift-topk.json
swift run -c release ml-bench     --out ../results/$(date +%Y-%m-%d)-$(uname -m)-swift-ml.json
swift run -c release catalog-bench --vectors ../../../docs/validation/substrate_math_performance/test-harness/vectors --out ../results/$(date +%Y-%m-%d)-$(uname -m)-swift-catalog.json
swift run -c release fdc-bench --out ../results/$(date +%Y-%m-%d)-$(uname -m)-swift-fdc.json
```

### Rust

```sh
cd apps/moot-math-speedtest/rust-bench
# Stable/scalar run. Use the pinned nightly toolchain and omit
# --no-default-features when collecting Rust portable-SIMD data.
cargo run --release --no-default-features --bin stress-test -- --out ../results/$(date +%Y-%m-%d)-$(uname -m)-rust-stress.json
cargo run --release --no-default-features --bin topk-bench  -- --out ../results/$(date +%Y-%m-%d)-$(uname -m)-rust-topk.json
cargo run --release --no-default-features --bin ml-bench    -- --out ../results/$(date +%Y-%m-%d)-$(uname -m)-rust-ml.json
cargo run --release --no-default-features --bin catalog-bench -- --vectors ../../../docs/validation/substrate_math_performance/test-harness/vectors --out ../results/$(date +%Y-%m-%d)-$(uname -m)-rust-catalog.json
cargo run --release --no-default-features --bin fdc-bench -- --out ../results/$(date +%Y-%m-%d)-$(uname -m)-rust-fdc.json
```

### `--quick` mode

Add `--quick` to skip the long sweeps (good for sanity-checking that the
binaries build + run; full sweeps take a few minutes).

## Submitting results

1. Run all ten math binaries on
   a single piece of hardware in one session.
2. Add the JSON files and run conditions to `results/<hostname>-<date>/`.
3. Open a PR with title `bench: <hardware-tag> <date>` (e.g.
   `bench: apple-m3-max 2026-05-29`).
4. Maintainers review submissions against `results/README.md`, the
   inventory of tracked evidence, and cite specific runs when a default
   kernel changes.

## Conformance is separate

The operation-specific suites measure speed only. `catalog-bench` first
requires every canonical vector to pass, then times the real validator path.
Bit-identity of every backend against the scalar reference is verified by the
conformance harness at
`docs/validation/substrate_math_performance/test-harness/`, with four
release-blocking scripts:

- `check-catalog-drift.py`        — CRC docs match vector files
- `check-lockstep.py`              — Swift/Rust 1:1 type parity
- `check-test-locations.py`        — tests live with their source
- `check-harness-builds-clean.sh`  — harness rebuilds clean +
                                     31/31 primitives conformance

A backend that wins the benchmark but fails conformance is rejected.

## Decision-doc protocol

When a new kernel backend is proposed, the protocol per
`docs/engineering/SUBSTRATE_PERFORMANCE_GATE.md`:

1. Implement the candidate as a new `SubstrateKernel` conformer.
2. Register it in `kernel_registry` on both ports.
3. Run the catalog prerequisite and all operation-specific suites above on the
   development hardware; include the product boundary when the claim concerns
   user-visible latency.
4. Attach the resulting JSON files to the decision-doc PR.
5. The decision doc cites the JSON file path + commit hash + hardware
   tag in its "measured at" line.

No more "I calculated that X would be slower."
