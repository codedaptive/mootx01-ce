# Documentation Index

The documents of the MOOTx01 1.1 benchmark suite.

## Start here

| Document | Purpose |
|---|---|
| [`README.md`](README.md) | What the suite is, where its work goes, and the first commands. |
| [`AGENTS.md`](AGENTS.md) | Orientation for AI agents reading this directory. |
| [`docs/BENCHMARK_RUN_BOOK.md`](docs/BENCHMARK_RUN_BOOK.md) | The operator procedure: gates, receipts, and what to do when a step fails. |
| [`results/RESULTS.md`](results/RESULTS.md) | The released result pages and the evidence each figure carries. |

## Suite-wide specifications

| Document | Purpose |
|---|---|
| [`docs/BENCHMARKS_USED.md`](docs/BENCHMARKS_USED.md) | Benchmark names, origins, variants, and provenance. |
| [`docs/BENCHMARK_PROTOCOL.md`](docs/BENCHMARK_PROTOCOL.md) | Shared protocol and result-validity requirements. |
| [`docs/BENCHMARK_METHOD.md`](docs/BENCHMARK_METHOD.md) | Measurement, scoring, comparison, and reporting method. |
| [`docs/BENCHMARK_ESTATES.md`](docs/BENCHMARK_ESTATES.md) | Estate artifact identity, construction, validation, and reuse. |
| [`docs/JUDGE_PHASE.md`](docs/JUDGE_PHASE.md) | Answering and judging phase contract. |
| [`docs/NEW_BENCHMARKS.md`](docs/NEW_BENCHMARKS.md) | Admission requirements for adding a benchmark family. |
| [`docs/SEED_FORMAT.md`](docs/SEED_FORMAT.md) | Benchmark use of the versioned bulk-import seed format. |

## Benchmark protocols

`docs/specs/` contains the official-protocol adaptations for LoCoMo,
LongMemEval, LMEB ConvoMem, and MemBench. `docs/benchmarks/` contains the
definitions of the internal benchmarks: deterministic alternatives, gauntlet,
journey, payload economics, posture matrix, supersession, synthesis payload,
and timing.

## Results and interpretation

`results/` contains one release page per result surface, including LoCoMo,
LongMemEval, LMEB, MemBench, judged answers, supersession, journey, gauntlet,
storage matrix, timing/throughput, substrate math, and the architectural
interpretation of MOOTx01 memory retrieval. `results/RESULTS_TEMPLATE.md`
defines the required shape for a new accepted result page.

## Source orientation

`lanes/README.md` maps executable lanes. `conformance/README.md` describes the
cross-port vectors. Each subdirectory carries an `AGENTS.md` describing
the source, tests, fixtures, judge adapters, seed tools, and result pages in
their respective subdirectories.
