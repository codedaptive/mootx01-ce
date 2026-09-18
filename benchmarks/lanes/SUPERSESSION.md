# Supersession lane

## What it measures

When a store holds three versions of the same fact — someone worked at A,
then B, now C — does the **current** version outrank the **superseded** ones
in recall results? And how many superseded versions still ride along inside
the top-k a consumer would paste into a prompt?

No public memory benchmark asks this, and none can: they provision a fresh
estate per question, so nothing ever supersedes anything. This lane ingests
a chronologically-ordered fact timeline into ONE persistent estate and
queries only after the whole history is in place.

## Seed data

Generated, not fetched — a pure function of `--seed` (default 20260725):

- `--entities N` version chains (default 40): the same attribute of the same
  entity restated `--versions` times (default 3), each restatement
  superseding the last. The final restatement is the chain's CURRENT fact;
  everything before it is stale.
- `--contradictions N` planted contradiction pairs (default 10), documented
  in [CONTRADICTION.md](CONTRADICTION.md) — they share this seed data and
  this import.

Records are written as a schema-v1 seed file in chronological order and
imported in one `moot_json_import` call (`--seed-path live` retains the
per-record slow lane). Inspect any seed's exact records without running
anything:

```bash
mcp-benchmarker supersession --seed 20260725 --dump-seed seed.json
```

## Protocol

Run protocol v3 (see [lanes/README.md](README.md)): bulk seed-file import
→ encode barrier
→ `moot_dream` (`associates: all`) → queries. `--skip-dream` measures the
virgin estate as a separate cell; the estate state is printed on the
scorecard because matrix-steering recall shapes only have signal on a
dreamed estate.

One query per chain. Ranking comes from plain `moot_memory_search`, or from
`moot_recall_shaped` when `--recall-shape <preset>` is given — the preset is
one of the report's named axes.

## Scoring (DETERMINISTIC — no judge)

| Figure | Meaning |
|---|---|
| CURRENT-OVER-STALE rate | Fraction of chains where the current version outranked every superseded version. The headline: 1.0 means the store never surfaced an outdated fact above the truth. |
| current found rate | Fraction of chains whose current version was retrieved at all. |
| mean stale in top-k | Superseded versions inside the top-k window (`--k`, default 10). The number nobody reports: a consumer pasting top-k into a prompt hands the model every stale version that rides along. |
| mean rank of current | Among queries that found the current version. |
| query p50 | Latency context, not a scored figure. |

## Estate modes

`--estate-mode unencrypted|encrypted|both`. Default is encrypted under an
ephemeral key minted in process memory — zero key file, zero keychain entry,
zero residue after teardown. `both` runs the lane twice on the identical
seed data (one scratch estate per posture) and prints an
`estate-mode delta (encrypted − unencrypted)` section — the encryption cost
is a first-class measurement.

## Running it

```bash
mcp-benchmarker supersession --seed 20260725 --recall-shape conceptual
mcp-benchmarker supersession --seed 20260725 --estate-mode both
```

The fairness rule applies (see [lanes/README.md](README.md)): current-fact
ranking, staleness contamination, and recency tracking are achievable by any
competent keyword+vector system. Current figures: the Supersession section
of the accepted [`supersession result page`](../results/BENCHMARK_SUPERSESSION.md), including the full recall-shape
ablation — losers stay in the table.
