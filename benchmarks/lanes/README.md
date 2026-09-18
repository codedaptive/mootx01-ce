# Lanes

AI systems should read [`AGENTS.md`](AGENTS.md) before changing a lane.

A **lane** is a benchmark this harness runs end-to-end: it provisions a
scratch estate, seeds it by bulk import from a generated seed file, brings
the estate to its measured state, queries, and scores. This directory documents the
bespoke lanes — the ones this project designed because no public benchmark
measures the behaviour in question. The public-dataset lanes (`longmemeval`,
`lmeb`, `locomo`) are documented in the top-level [README](../README.md) and
their upstream papers.

| Lane | Doc | What it measures |
|---|---|---|
| Supersession | [SUPERSESSION.md](SUPERSESSION.md) | Does the CURRENT version of a changed fact outrank its superseded versions — and how much stale material rides along in the top-k? |
| Contradiction | [CONTRADICTION.md](CONTRADICTION.md) | Are planted, recency-unresolvable contradictions surfaced as conflicts? |
| Deterministic replay | [DETERMINISTIC_REPLAY.md](DETERMINISTIC_REPLAY.md) | Does the same seed produce the same scored outcome, run after run — the property every other figure here leans on? |

## What makes a lane official

Every lane in this directory meets four requirements. A proposed lane that
cannot meet them stays experimental.

1. **Seed-deterministic test data.** The lane's seed data is a pure
   function of the run's `--seed`: same seed, same bytes, on both harness
   ports. The seed file is inspectable without our code (`--dump-seed
   <path>` writes it as sorted JSON and exits), and the dumped bytes are
   exactly the bytes the lane imports — see
   [`../docs/SEED_FORMAT.md`](../docs/SEED_FORMAT.md).
2. **Run protocol v3.** Bulk seed-file import (one `moot_json_import`
   call) → encode barrier → `moot_dream` (`associates: all`) → queries.
   Seeding is setup, not measurement; the bulk path is the default, and
   per-record live capture is retained only as the optional slow lane
   behind `--seed-path live`. The dream pass brings the estate to the
   state a deployed memory system actually runs in — matrix priors built,
   association sweep complete — before anything is measured. Lanes expose
   `--skip-dream` so the virgin-estate condition can be measured as its own
   cell; the estate state (`dreamed` / `virgin`) is named on every figure.
3. **Named axes.** Every reported figure names the axes that produced it:
   seed, estate mode (encrypted/unencrypted), estate state (dreamed/virgin),
   recall shape, and — for judged cells — judge model, quantization, grading
   mode, and hydration depth. Cells differing on any axis are different
   measurements.
4. **The fairness rule.** Every behaviour scored is achievable in principle
   by any competent keyword+vector system that tracks recency. Nothing is
   scored that requires a feature specific to this product. A benchmark only
   its author can pass is marketing, not measurement.

## Where the numbers live

Lane docs describe **method**: what is measured, how the seed data is built,
how to run it, and how to read the output. Accepted release figures live in
the applicable page under [`../results/`](../results/); raw run reports remain
beneath `$BENCH_WORK_ROOT/results`.
