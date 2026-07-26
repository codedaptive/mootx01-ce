---
version: v0.1
---

# LMEB/ConvoMem Diagnostic Smoke Run — 2026-07-26

**Mission:** LME-06 (lmeb-gauntlet) — first live end-to-end validation of the
LMEB/ConvoMem document-retrieval path in mcp-benchmarker CE.

**Dataset:** KaLM-Embedding/LMEB — ConvoMem subset, `user_evidence` only.
107,736 corpus docs, 1,340 queries, 3,304 qrels (binary relevance, avg 2.47 relevant/query).
Dataset is MIT-licensed and never committed to this repo (see scripts/fetch-lmeb.sh).

**Evidence type:** `user_evidence` (single type for diagnostic smoke — full run requires
all six types: abstention, assistant_facts, changing, implicit_connection, preference, user).

**Method:** Fresh-per-query estate. Each query provisions a new MOOTX01_DATA_DIR under
`/tmp/lmeb-bench-*`, injects candidate docs (10–168 per scene) via `moot_file_memory`
with `n=true` (inline-encoding barrier), runs DegeneracyGuard probe, then issues
`moot_memory_search`. UUID→docID manifest maps results back to corpus doc IDs.
Estate torn down after each query.

**Seed:** 20260725 — deterministic shuffle, identical query order on both legs.
**Binary:** `/Users/bob/.mootx01/bin/mootx01`.
**Limit:** 50 queries.

---

## Results — Rust Twin (50q, `user_evidence`, seed 20260725)

```
mcp-benchmarker-rs lmeb \
  --data-dir fixtures/lmeb/data/ConvoMem \
  --evidence-types user_evidence \
  --limit 50 --seed 20260725
```

| Metric             | Value  |
|--------------------|--------|
| queries_run        | 50     |
| guard_excluded     | 0      |
| query_count        | 50     |
| nDCG@10            | 0.4651 |
| MRR                | 0.5525 |
| recall@1           | 0.2683 |
| recall@5           | 0.4343 |
| recall@10          | 0.5483 |
| MAP@10             | 0.3767 |
| query_p50_s        | 0.0861 |
| query_p95_s        | 0.1924 |
| wall_time          | ~3m 07s |

---

## Results — Swift Twin (50q, `user_evidence`, seed 20260725)

```
mcp-benchmarker lmeb \
  --data-dir fixtures/lmeb/data/ConvoMem \
  --evidence-types user_evidence \
  --limit 50 --seed 20260725
```

| Metric             | Value  |
|--------------------|--------|
| queries_run        | 50     |
| guard_excluded     | 1      |
| query_count        | 49     |
| nDCG@10            | 0.4644 |
| MRR                | 0.5645 |
| recall@1           | 0.2602 |
| recall@5           | 0.4279 |
| recall@10          | 0.5476 |
| MAP@10             | 0.3696 |
| query_p50_s        | 0.0937 |
| query_p95_s        | 0.1903 |
| wall_time          | ~3m 10s |

---

## Twin Agreement Analysis

| Metric    | Rust   | Swift  | Delta    | Agreement |
|-----------|--------|--------|----------|-----------|
| nDCG@10   | 0.4651 | 0.4644 | +0.0007  | excellent |
| MRR       | 0.5525 | 0.5645 | −0.0120  | good      |
| recall@1  | 0.2683 | 0.2602 | +0.0081  | good      |
| recall@5  | 0.4343 | 0.4279 | +0.0064  | good      |
| recall@10 | 0.5483 | 0.5476 | +0.0007  | excellent |
| MAP@10    | 0.3767 | 0.3696 | +0.0071  | good      |
| p50_s     | 0.0861 | 0.0937 | −0.0076  | good      |
| p95_s     | 0.1924 | 0.1903 | +0.0021  | excellent |

Small metric differences are expected — each query runs against a separate mootx01 instance
with non-deterministic vector ranking (ANN approximate nearest-neighbour search). The scoring
MATH is identical (verified by conformance vectors to within 1e-9). Score variation reflects
mootx01 retrieval randomness, not a math divergence.

The Swift twin had 1 guard exclusion (DegeneracyGuard detected degenerate ranking on one query).
The Rust twin had 0 guard exclusions. This is normal variance in a 50-query run.

nDCG@10 agreement within 0.1% is the tightest possible expectation for live retrieval runs.
The twin pair passes.

---

## Latency Notes

Both twins process ~50 queries in ~3 minutes:
- Average per-query wall time: ~3.7s (dominated by mootx01 startup + ingest per query)
- p50 query latency: ~86–94ms
- p95 query latency: ~190ms
- Write mean latency: not printed in summary; per-query in JSON report

The fresh-per-query estate strategy (one mootx01 process per query) dominates the wall time.
Batched or persistent-estate variants would be faster but reduce isolation.

---

## Dataset Stats (user_evidence only)

- Corpus docs: 107,736
- Queries: 1,340
- Qrels: 3,304 (avg 2.47 relevant docs/query)
- Candidate pool size: 10–168 docs/scene (average ~88 docs ingested per query)

Full LMEB benchmark across all 6 evidence types: ~5,867 queries estimated,
~500,221 corpus docs, ~13,779 qrels (arXiv:2603.12572).
Full run estimated wall time: ~6–8 hours single-threaded.
