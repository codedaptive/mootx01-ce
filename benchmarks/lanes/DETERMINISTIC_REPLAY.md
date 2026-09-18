# Deterministic-replay lane

## What it measures

Every DETERMINISTIC figure this project publishes leans on one property:
**same seed, same scored outcome**. This lane measures that property itself,
end to end, instead of assuming it. It runs the full supersession lane N
times (default 2) with the same seed — each run regenerating the seed data,
provisioning a fresh scratch estate, importing, encoding, dreaming, querying,
and scoring from nothing — then compares the scored outcomes field by field.

The replayed surface is the whole pipeline: seed generation, the seed-file
emit, the bulk `moot_json_import` lane, the encode barrier, the `moot_dream`
pass, recall ranking, and the scorers. A drift anywhere in that chain — a nondeterministic
tie-break in ranking, an encoding race the barrier misses, a sweep that
depends on wall-clock — lands in the table as a named field with both values.

Why it matters beyond self-audit: retrieval encoding on a live estate has
measurably imperfect determinism (repeats moved retrieval by up to ±0.04 at
N=50 on the conversational lanes — see "which numbers are trustworthy" in
[`results register`](../results/RESULTS.md)). This lane is the instrument that
bounds that wobble on the bespoke seed data: it reports exactly which scored
fields replay bit-identically and which do not.

## What is compared

Only determinism-eligible fields. Wall-clock figures (query p50, sweep and
tier wall times) are excluded by construction — they legitimately vary.

- Ranking scores: chains scored, CURRENT-OVER-STALE rate, current found
  rate, mean stale in top-k, mean rank of current.
- Conflict sweep (when it ran): planted count, detected any-tier, detected
  as PROPOSED, flagged outside planted.
- Typed proving tier (when `--structured-tier`): planted count, proven
  planted, proven outside planted, and the report's proven / historical /
  coverage counts.

Floating-point fields are compared with exact equality on purpose: the claim
under test is bit-identical replay, not approximate stability. A section
present in one run and absent in another is itself drift.

## Protocol

Run protocol v3 on every iteration: bulk seed-file import over
`moot_json_import`, then the encode barrier, the dream pass, and the
queries (dream on by default; `--skip-dream` replays the virgin-estate
cell instead). `--seed-path live` replays the retained per-record slow
lane instead of the bulk default. Single estate posture per invocation —
`--estate-mode unencrypted|encrypted` (default encrypted; `both` is
rejected: replay compares runs, not postures).

## Running it

```bash
mcp-benchmarker replay --seed 20260725                      # 2 runs, compare
mcp-benchmarker replay --seed 20260725 --runs 3             # more runs, same contract
mcp-benchmarker replay --seed 20260725 --structured-tier    # include the typed tier
```

Output: one summary line per run, then a field-by-field table — every
checked field with its run values and MATCH/DRIFT — and a verdict line.

Exit code contract: **0** = every compared field identical across all runs
(`verdict: DETERMINISTIC`); **1** = any field drifted (`verdict: DRIFT`),
with the drifting fields and both values in the table. The exit code makes
the lane usable as a gate: a harness change that breaks replay determinism
fails loudly instead of shipping a quietly wobbling number.
