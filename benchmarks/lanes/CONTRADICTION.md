# Contradiction lane

## What it measures

A memory store that tracks recency can resolve most conflicts by time: the
newer statement supersedes the older one. This lane measures the conflicts
recency **cannot** resolve — two mutually-exclusive claims sharing one event
instant — where the correct behaviour is to *surface the conflict*, not to
silently pick a winner.

## Seed data

The contradiction pairs ride the supersession seed data (same seed, same
import — see [SUPERSESSION.md](SUPERSESSION.md)): `--contradictions N`
planted pairs (default 10), each pair two records asserting incompatible
values for the same attribute with the **same event timestamp**. The rest
of the seed data — the supersession version chains — doubles as structured
noise: chain versions genuinely conflict too, but those conflicts are
resolvable by recency, and a detector that flags them is not wrong, just
not detecting the planted class.

## Protocol

Run protocol v3 (bulk seed-file import → encode barrier → `moot_dream`
with `associates: all` → measurement). Two cells, both DETERMINISTIC (scored by
drawer/fact identity, no judge):

### Cell 1 — conflict sweep (default)

After the ranking queries, the lane calls `moot_hunt_contradictions` and
scores the report against the planted pairs by drawer id:

| Figure | Meaning |
|---|---|
| detected (any tier) | Planted pairs surfaced at any tier, either drawer order. |
| detected as PROPOSED | Planted pairs surfaced at the auto-recorded tier. |
| flagged outside planted | Context, not error: superseded-chain conflicts are real, just recency-resolvable. |

`--skip-contradictions` omits the sweep when only the ranking cell is
wanted.

### Cell 2 — typed proving (`--structured-tier`)

The lane files one typed fact per seeded record (anchored to its ingest
drawer) and scores the typed conflict-projection surface:

| Figure | Meaning |
|---|---|
| planted pairs proven | The planted, recency-unresolvable pairs must surface as PROVEN conflict blocks. |
| proven outside planted | Must be **zero**. The supersession chains (same attribute, different event times) must resolve as historical succession — a proof there is a false proof. |
| proven / historical / coverage counts | The report's own accounting, cross-checked against the parsed blocks. |

The two cells answer different questions: the sweep measures *discovery*
(does an untyped estate notice?), the typed tier measures *proof* (given
typed facts, does the projection separate genuine mutual exclusion from
historical succession?).

## Running it

```bash
mcp-benchmarker supersession --seed 20260725                    # cell 1 rides every run
mcp-benchmarker supersession --seed 20260725 --structured-tier  # adds cell 2
```

## Reading the results

Current figures live in the Contradiction section of
[`supersession result page`](../results/BENCHMARK_SUPERSESSION.md). This lane exists to produce exactly the
kind of number that is unflattering and actionable — a detection rate that
was invisible before the lane existed gets published, because it is real and
reproducible. The fairness rule applies to the sweep cell: surfacing
same-instant value conflicts is achievable by any system that indexes
attribute-value assertions with their timestamps.
