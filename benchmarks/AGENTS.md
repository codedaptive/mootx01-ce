# AI Knowledge for the MOOTx01 Benchmark Suite

This file is the dense operating context for an AI reading this directory.
Treat it as orientation, not as a replacement for the normative protocols.

## Authority and purpose

This directory is the released, reproducible benchmark product for MOOTx01
1.1. It measures retrieval, answer quality, payload economics, storage
behavior, timing, throughput, and Swift/Rust parity. It also carries the public
evidence pages used to interpret accepted results.

When statements conflict, use this authority order:

1. `docs/BENCHMARK_RUN_BOOK.md` for operator procedure and release gates;
2. `docs/BENCHMARK_PROTOCOL.md` and `docs/specs/*.md` for protocol semantics;
3. `docs/BENCHMARK_METHOD.md` for measurement and reporting rules;
4. `docs/BENCHMARK_ESTATES.md` for artifact identity and lifecycle;
5. lane documents in `docs/benchmarks/` for internal instrument details;
6. the Makefile and source for the executable realization.

`docs/BENCHMARKS_USED.md` is the identity and provenance catalog. Never infer
a benchmark's origin from its name.

## Non-negotiable filesystem model

The repository is immutable input. Every mutable artifact belongs beneath
`BENCH_WORK_ROOT`, an absolute path outside the repository. This includes:

- Swift and Rust build products and dependency caches;
- fetched datasets and tokenizer resources;
- generated seed projections and fleet manifests;
- estate artifacts, clones, wings, and snapshots;
- smoke receipts, raw reports, logs, and judge transcripts; and
- generated runtime configuration and temporary bundles.

Use Make targets from this directory. Do not run package managers, fetchers,
seeders, or benchmark binaries directly. `scripts/work-root.py` rejects a work
root inside the repository, a root that contains the repository, and a
filesystem root. `make clean` may empty only a directory bearing the harness's
work-root marker.

## Execution model

The Swift port is the measurement instrument. The Rust port is a required
behavioral twin used for conformance and drift gates. A public result is not a
claim of cross-port parity unless the applicable twin gate passes.

The normal order is:

1. `make fetch` — obtain and verify pinned public fixtures externally.
2. `make binaries` — build the product and both harness ports externally.
3. `make seeds` — construct deterministic source projections externally.
4. `make status` — inspect prerequisites and artifact readiness.
5. `make smoke-bench-all` — run the release smoke surface.
6. `make artifacts` — build complete reusable estates.
7. run the run book's measurement targets with the recorded parameters.
8. verify receipts, coverage, provenance, drift, and result-class rules.

Artifact construction and measurement are distinct phases. Measurement opens
settled artifacts through the required cache path and fails if an artifact is
missing. It must not silently construct a replacement.

## Benchmark families

External benchmark families are LoCoMo, LongMemEval-s, LMEB ConvoMem, and
MemBench. Internal instruments include supersession, journey, gauntlet,
storage matrix, payload economics, synthesis payload, artifact recall, latency,
and throughput. The payload-economics and synthesis-payload instruments use the
LongMemEval-s artifact and its answer annotations; their instrument design is
internal even though their measured corpus is external.

See `docs/BENCHMARKS_USED.md` for exact names, upstream sources, variants, and
license notes. See `docs/benchmarks/*.md` for internal lane definitions.

## Evidence and publication rules

Raw reports are external run artifacts, not release claims. Curated release
pages under `results/` identify the accepted result surfaces and the evidence
required beside each figure. Keep these result classes separate:

- retrieval quality;
- answer quality and judge agreement;
- latency;
- throughput;
- payload/token efficiency;
- storage behavior; and
- substrate or kernel timing.

Every published figure carries its run identity, UTC date, binary digest,
product and protocol versions, port, storage scale or run shape, coverage,
machine profile when relevant, model identities when relevant, and source
report/sidecar. Missing evidence means the figure is not publishable. Never
insert placeholders, projected values, best-so-far values, or progress prose.

`results/RESULTS.md` is the result-surface catalog. The companion
`apps/moot-math-speedtest/` surface measures substrate speed only. Do not
present its kernel timings as memory-system retrieval, answer, or throughput
figures.

## Change discipline

This directory is a generated release product. Do not hand-edit it in a public
checkout or copy runtime artifacts into it. Changes arrive through the release
workflow as a complete, verified tree. Preserve public self-containment: source,
commands, and documentation must not rely on private paths, unpublished tools,
or operator-only knowledge.

When modifying executable behavior, update the relevant protocol or run-book
statement in the same source change, add or update Swift/Rust conformance
coverage, and verify that `make clean` restores an unchanged checkout.
