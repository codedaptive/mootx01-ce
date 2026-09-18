---
title: Decision — Search Strategy Recipes and Lanes
version: v0.1
status: proposed
date: 2026-08-19
description: Four gated product changes distilled from the door, combo, miss, cascade, and event-time studies. Each item is independently accept/reject.
---

# Decision — Search Strategy Recipes and Lanes

Evidence base: the DOOR_MATRIX, COMBO_MATRIX, MISS_AUTOPSY, CASCADE_STUDY,
and EVENT_TIME_STUDY maintainer records (all 2026-08-19), measured on pinned
debug subsets over restored artifacts, with no LLM involved.

## Item 1 — Recipe `moot_recall_consensus`

Three fixed complementary doors fused by RRF in one call:
session-hybrid keeper + temporal/structural keeper + lexical bm25.
Blind (no knowledge of the query), it matches or beats the best
informed single door on all four benchmark families:

| Family | search | best informed single | consensus (simulated) |
|---|---|---|---|
| lme MRR | 0.681 | 0.902 | 0.903 |
| locomo MRR | 0.132 | 0.396 | 0.392 |
| lmeb nDCG-family MRR | 0.453 | 0.565 | 0.604 |
| membench MRR | 0.787 | 0.798 | 0.841 |

Prior art: ConnectedRecall is already a two-door RRF recipe; this is
the three-door form. Cost: three coarse grabs (~1.8 s serial today,
less in parallel). Registration: CognitionKit + catalog + RecipeTools +
Rust twins + spec bumps (checklist mapped).

## Item 2 — Recipe `moot_recall_walk`

Staged cascade: stage-1 keeper (pool 20) → exit when topGap ≥ 0.25 (the
existing discrimination signal) → stage-2 discriminator by query shape
→ exit → stage-3 escalation (neural dense lane when the estate carries
one, else weighted-all). Simulated two-stage results: lme 0.993
recall@10 / 0.899 MRR; membench 1.000 / 0.853; lmeb 0.927 / 0.632.
Quality gains land immediately; cost gains require Item 3.

## Item 3 — Single-lane stage-1 modes

Expose GLKRecallMode locusOnly / corpusOnly as recall options. Today
every door pays the identical all-lanes coarse grab (measured flat
~0.6 s across all 15 doors), so a "cheap first stage" is not
mechanically cheap. This exposure is what makes the walk's economics
real. Engine internals stay dark (index/kernel selection excluded).

## Item 4 — Query-date window lane

From the event-time study: real dates now sit in the estates, and the
retrieval delta was NULL because no lane reads the QUERY's date —
temporalState scores the state bitmap, temporalText scans currency
markers, matrixTemporal is inter-drawer lag decay. Proposed lane:
deterministic parse of explicit date expressions in the query (month
names, day-month-year forms; no model), then a window filter/boost on
drawer event_time. Expected reach: most of locomo's 15 hard temporal
misses (a July-2023 window collapses the candidate set to one session)
and every date-anchored workload the product meets. Also implies the
filing steering text tells the filing AI to pass event_time.

## Sequencing if accepted

Specs and registration per item; lab sweeps on pinned subsets validate
each against its simulated figures before any full-corpus run;
steering text last, after confirmations.
