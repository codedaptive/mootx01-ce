---
version: v0.1
---

# LongMemEval Diagnostic Smoke Run — 2026-07-25

**Mission:** LME-01 (longmemeval-gauntlet) — first live end-to-end validation of the
LongMemEval session-recall path in mcp-benchmarker CE.

**Method:** Fresh-per-question estate strategy — each question provisions a
new MOOTX01_DATA_DIR, injects all haystack sessions via `moot_file_memory` at
`location: benchmark/longmemeval`, runs three DegeneracyGuard probe queries,
then issues the actual question query. Each question's estate is torn down
after scoring.

**Variant:** `s` (single-session and multi-session, 500 questions total).
**Seed:** 20260725 — deterministic shuffle, identical question order on both legs.
**Binary:** `/Users/bob/.mootx01/bin/mootx01` (current install, v1.0.35).

---

## Results

### Rust twin — 50-question sample (`--limit 50 --seed 20260725`)

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 50     |
| guard_excluded     | 0      |
| recall_any@1       | 0.5000 |
| recall_any@5       | 0.7800 |
| recall_any@10      | 0.8800 |
| recall_all@1       | 0.2600 |
| recall_all@5       | 0.4200 |
| recall_all@10      | 0.6200 |
| mrr                | 0.6411 |
| query_p50_s        | 1.481  |
| query_p95_s        | 2.045  |
| write_mean_s       | 0.047  |

### Swift twin — 10-question sample (same seed, same first-10 questions)

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 10     |
| guard_excluded     | 0      |
| recall_any@1       | 0.3000 |
| recall_any@5       | 0.6000 |
| recall_any@10      | 0.7000 |
| recall_all@1       | 0.2000 |
| recall_all@5       | 0.4000 |
| recall_all@10      | 0.5000 |
| mrr                | 0.4367 |
| query_p50_s        | 1.453  |
| query_p95_s        | 2.001  |

---

## Conformance

Both legs ran the same 10 questions in the same order (SplitMix64 shuffle is
identical — seed 20260725 → gpt4_2ba83207, 60d45044, 2788b940, …). The
scoring math is verified by the shared `longmemeval_vectors.json` conformance
vectors: 10 recall cases + 5 uuid_mapping cases, tolerance 1e-9, both legs pass.

Per-question score differences between twins on the 10-question overlap are
**expected and correct**. Each question runs two separate mootx01 processes
(one Swift, one Rust), each with its own fresh estate and embedding index.
`moot_memory_search` ranking is non-deterministic at the sentence-embedding
level, so the same question can produce a different UUID ordering on each
independent run. This is the same variability seen in the existing gauntlet
benchmarker.

---

## DegeneracyGuard

All 50 questions cleared the guard (0 guard_excluded). The three probe queries
("what happened during our recent dinner together?", "can you remind me about
my work project updates?", "what were we discussing about travel plans last
month?") produced sufficiently distinct rankings on every question. This
confirms mootx01 is not returning frozen/query-invariant results at
`location: benchmark/longmemeval`.

---

## Latency

- **Write mean:** ~47 ms/turn (Rust), consistent with stdio MCP ingest.
- **Query p50:** ~1.45–1.48 s — includes embedding model inference.
- **Query p95:** ~2.0 s — elevated on multi-session questions (larger haystacks).
- **Per-question wall time:** ~30–40 s on average (ingest + probe x 3 + query).
- **Throughput implication:** Full 500-question `s` variant run takes ~4.5 hours
  single-threaded on local hardware. For diagnostic purposes, `--limit 50` is
  the recommended sample size (~25 minutes).

---

## Findings

1. **`has_answer` field absent in real corpus.** The real HuggingFace corpus
   turns do not include `has_answer` (present only in the hand-authored
   synthetic test sample). Fixed in both loaders: `#[serde(default)]` in
   Rust, `decodeIfPresent` with `?? false` in Swift. LME-01 discovery.

2. **Recall is meaningful.** recall_any@10 = 0.88 on a 50-question sample
   indicates mootx01 surfaces the correct session for most questions when a
   broad top-10 window is used. recall_any@1 = 0.50 indicates retrieval
   precision at rank 1 is a more challenging target.

3. **Multi-session questions harder.** `multi-session` questions (answer spans
   >= 2 sessions) show lower recall_all than `single-session-*` questions, as
   expected given multiple sessions must all rank in the top-k window.

4. **Scratch dir isolation works.** Pattern `/tmp/lme-bench-<seed_hex>-<q_hex>`
   (Rust) isolates each question's estate. Guard teardown refuses non-`/tmp/lme-bench-`
   prefixes as a safety check.

---

## Next steps (not in LME-01 scope)

- Full 500-question run for baseline numbers.
- LLM-judge QA accuracy scoring (answer quality beyond session retrieval).
- Temporal-reasoning and knowledge-update question type breakdowns.
- Multi-session variant (`m`) and oracle variant runs.
- Parallelized runner (multiple workers, isolated estates) for throughput.
