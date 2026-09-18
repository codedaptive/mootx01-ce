---
title: Journey Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing purpose, scenario construction, metrics, reproduction, and evidence contract for the Journey benchmark.
---

# Journey

## What it measures

Journey measures the work required for an AI agent to reach a correct answer
through a sequence of retrieval and hydration steps. It covers two scenario
families:

- precise misses, where an exact-looking cue does not identify the target; and
- vague narrowing, where the agent must reduce a plausible cluster to the
  correct member.

The benchmark records four integer metrics per journey:

- hops: total tool calls;
- token-turn integral: payload tokens accumulated across the sequence;
- pre-terminal full-content tokens: full-body tokens fetched before the final
  answer step; and
- total payload tokens.

The recorded step sequence makes every metric recomputable. Results are filed
per participating agent and are not averaged across different agents. The full
construction and scoring contract is in `../benchmarks/journey.md`.

## Run procedure

Run from `benchmarks/`:

```sh
make seeds
make smoke-measure-journey PORT=<swift|rust>
make measure-journey PORT=<swift|rust> [LIMIT=<n>]
```

The wide target requires the selected port's smoke stamp. Live agent identity
and every tool step are captured in the report. `LIMIT` produces explicitly
limited coverage.

## Evidence and publication

The report contains the agent identity, seed, scenario shape, step trace, four
metrics, binary identity, protocol version, estate schema, port, and coverage.
Copy only human-accepted figures from `../RESULTS_RECORD.md` into a public
result register.
