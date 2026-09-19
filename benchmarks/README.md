# MOOTx01 Benchmark Suite

This directory is the benchmark suite for MOOTx01 1.1: the Swift and Rust
benchmarkers, the public protocols, the dataset fetchers, the artifact
builder, and the result pages. Everything runs through the Makefile in this
directory, and anyone with a clone of the repository can reproduce the
published numbers with it.

Start with [`docs/BENCHMARK_RUN_BOOK.md`](docs/BENCHMARK_RUN_BOOK.md) for the
operator procedure. [`DOC_INDEX.md`](DOC_INDEX.md) lists every document.
AI agents start with [`AGENTS.md`](AGENTS.md).

## Where the work goes

Nothing is written into the repository. Builds, downloaded datasets, seed
projections, estates, caches, reports, and receipts go under the work root,
which defaults to a visible folder beside the repository:
`<repository-parent>/benchmark-work/<repository-name>`. It is never a hidden
folder and never a system cache, so the disk it uses is easy to see and the
operating system does not purge it. Set `BENCH_WORK_ROOT` to an absolute path
outside the repository to put it elsewhere; the Makefile refuses a root inside
the repository.

The work root is created by `make setup` and removed by `make teardown`.
Nothing in it is made by hand, so a run after `make teardown setup` is the
proof that the suite reproduces.

Artifact storage is one configuration file beside the work root,
`benchmark-config/storage.json`, written by `make config`. It names three
folders: the internal primary, where every artifact is built and served from,
and two external stores that finished artifacts are moved to and back from.
It survives teardown.

Run every command through `make`. Do not run SwiftPM, Cargo, the fetch
scripts, or the benchmark binaries directly: the Makefile supplies the paths
and settings that make one run comparable with another.

## Reproduce the suite

```bash
make setup           # fetch the datasets, build both product binaries and both benchmarkers, write the seeds
make config          # write the storage configuration; edit it to name your external volumes
make status          # the artifact board: everything reports MISSING and nothing errors
make smoke-bench-all # one short pass through every benchmark
```

Build the reusable estates before measuring:

```bash
make artifacts PORT=swift
make artifacts PORT=rust
```

Then run the measurement targets the run book names. A run writes its results
to `$BENCH_WORK_ROOT/results`. The accepted figures for the release, with the
evidence behind each, are the pages under [`results/`](results/).

`make release-qualification PORT=…` is the final pass before a version ships:
it verifies setup, runs the smokes, builds and settles one real estate, and
fires every tool in the memory interface once against it with each outcome
checked.

## What is measured

- LoCoMo conversational retrieval and question answering;
- LongMemEval-s long-history retrieval and judged answers;
- LMEB ConvoMem retrieval and judged answers;
- MemBench retrieval and the published-protocol behaviour;
- supersession, journey, gauntlet, storage matrix, payload economics,
  synthesis, artifact recall, latency and throughput;
- Swift and Rust conformance and drift.

The benchmarks and where they come from are listed in
[`docs/BENCHMARKS_USED.md`](docs/BENCHMARKS_USED.md). The run book carries the
protocol authority, the required coverage, the smoke gates, the measurement
order, the receipts, and the failure rules.

`apps/moot-math-speedtest/` measures substrate and kernel speed on its own.
It is not a memory benchmark and its figures are not combined with the
retrieval or answer-quality results here.

## Requirements

- Swift measurements: macOS on Apple Silicon.
- Rust conformance: Linux, Windows, or macOS on a supported architecture.
- Retrieval-only lanes: no model service and no API key.
- Judged lanes: the judge configuration selected and recorded for the run.
- External datasets: network access for the pinned fetch step.

Dataset licences stay with their publishers. Read the benchmark identity and
method documents before redistributing source data or reports.
