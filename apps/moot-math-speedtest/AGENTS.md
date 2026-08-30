# AI Knowledge for the MOOT Math Speed Test

This file is the dense operating context for an AI reading this directory.

## Purpose and boundary

This application measures substrate and kernel speed. It exercises the
GeniusLocus math primitives in maintained Swift and Rust implementations and
records comparable timing evidence. It does not measure end-to-end memory
retrieval or answer quality. Those product-level measurements belong to the
separate [`../../benchmarks/`](../../benchmarks/AGENTS.md) suite.

Do not combine figures from the two surfaces. A kernel timing from this
directory is not a retrieval-latency, throughput, or answer-quality result.

## Authority order

Use the following sources in order when interpreting or changing this app:

1. [`METHODOLOGY.md`](METHODOLOGY.md) for the experimental protocol and
   evidence layers;
2. [`SCHEMA.md`](SCHEMA.md) for the machine-readable result contracts;
3. [`COVERAGE.md`](COVERAGE.md) for operation coverage;
4. [`PERFORMANCE.md`](PERFORMANCE.md) and [`GAUNTLET.md`](GAUNTLET.md) for
   claim-by-claim interpretation of tracked evidence;
5. [`results/README.md`](results/README.md) for the result inventory; and
6. the Swift, Rust, Python, and shell sources for the executable realization.

## Directory map

- `swift-bench/` contains the maintained Swift executables.
- `rust-bench/` contains their maintained Rust twins.
- `product-bench.py` measures a built `mootx01` binary over resident loopback
  MCP against a disposable estate.
- `submit-results.sh` runs the maintained speed-test bundle and prepares a
  reviewable result directory.
- `results/` contains tracked, historical evidence. Preserve its original run
  contents and provenance.

The maintained executable set is `stress-test`, `topk-bench`, `ml-bench`,
`catalog-bench`, and `fdc-bench` in both Swift and Rust. `product-bench.py` is a
separate product-boundary latency probe.

## Measurement model

The evidence layers answer different questions:

- `catalog-bench` validates the canonical primitive catalog before timing it;
- `stress-test`, `topk-bench`, and `ml-bench` time operation-shaped math;
- `fdc-bench` times deterministic classifier and semantic stages;
- `product-bench.py` measures loopback product-boundary latency; and
- `../../benchmarks/` measures the complete memory system.

Conformance and speed are separate gates. A fast backend that fails the
canonical conformance vectors is rejected. Quick runs are smoke evidence only;
publishable timing uses the full protocol and records hardware, toolchain,
commit, seed, run shape, and raw samples required by the schema.

## Running and outputs

Run the maintained bundle from the repository root:

```sh
apps/moot-math-speedtest/submit-results.sh
```

Use `--quick` only for a smoke run. The script writes a result bundle under
`apps/moot-math-speedtest/results/`; review the generated `SUBMISSION.md`
before committing a result. Individual binaries accept explicit `--out`
paths, as documented in the README and methodology.

The output schema is a hard cross-language contract. Do not add
language-specific fields or normalize historical records in place. New ports
must reproduce the defined operations, deterministic inputs, timing phases,
and JSON shapes before their results can be compared with maintained ports.

## Change discipline

Keep Swift and Rust behavior in lockstep. Changes to an operation, seed,
timing budget, output field, or interpretation require corresponding protocol,
schema, and cross-port updates. Build products and disposable test outputs do
not belong in the repository. Preserve tracked result bundles as historical
evidence even when names or surrounding documentation change.
