# AI Knowledge for Benchmark Results

This directory is the curated result and interpretation surface for release
1.1. Raw run output never belongs here; it remains beneath
`$BENCH_WORK_ROOT/results`.

`RESULTS.md` catalogs the result classes, required coverage, primary figures,
and authoritative detail pages. The benchmark detail pages define the task,
metric, origin, operator target, evidence identity, and publication fields.
`BENCHMARK_JUDGED_ANSWERS.md` defines panel consensus.
`MOOTX01_APPROACH_TO_MEMORY_RETRIEVAL.md` explains the retrieval architecture.

A numeric value is publishable only when its source report and parameter
sidecar establish all identity fields required by `RESULTS.md` and the run
book's acceptance gates pass. Never add placeholders, estimates, progress
language, selective best runs, or a number reconstructed from logs. Do not
combine retrieval, answer quality, latency, throughput, payload efficiency,
storage behavior, or substrate timing into a single score.

Use Make targets and paths exactly as documented by
`../docs/BENCHMARK_RUN_BOOK.md`. Public pages must be self-contained and must
not reference private paths, operator-only tools, or unpublished evidence.
