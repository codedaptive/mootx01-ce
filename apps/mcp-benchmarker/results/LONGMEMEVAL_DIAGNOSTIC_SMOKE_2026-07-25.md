---
version: v0.2
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

**Encoding correctness note:** Initial runs (v1, pre-fix) used background encoding
(`n=false`, the default for `moot_file_memory`). Fix `44303d0f` wired `n=true`
(inline encoding) in both runners so the correctness invariant holds: ingest →
encode → query, with no race between background encoding and the recall query. The
**v2 numbers below (n=true)** are the valid baseline; v1 numbers are preserved for
before/after comparison only.

---

## Results — v1 (pre-fix, background encoding, NOT the valid baseline)

### Rust twin — 50q v1 (`--limit 50 --seed 20260725`, background encoding)

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

### Swift twin — 10q v1 (`--limit 10 --seed 20260725`, background encoding)

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

## Results — v2 (post-fix, inline encoding, n=true — VALID BASELINE)

Both 50q runs launched 2026-07-25 with commit `44303d0f`. Results to be filled in
when background runs complete (background task IDs: bs271akxs [Rust], bke552b94 [Swift]).

### Rust twin — 50q v2 (`--limit 50 --seed 20260725`, inline encoding n=true)

| Metric             | Value  |
|--------------------|--------|
| questions_run      | —      |
| guard_excluded     | —      |
| recall_any@1       | —      |
| recall_any@5       | —      |
| recall_any@10      | —      |
| recall_all@1       | —      |
| recall_all@5       | —      |
| recall_all@10      | —      |
| mrr                | —      |
| query_p50_s        | —      |
| query_p95_s        | —      |
| write_mean_s       | —      |

### Swift twin — 50q v2 (`--limit 50 --seed 20260725`, inline encoding n=true)

| Metric             | Value  |
|--------------------|--------|
| questions_run      | —      |
| guard_excluded     | —      |
| recall_any@1       | —      |
| recall_any@5       | —      |
| recall_any@10      | —      |
| recall_all@1       | —      |
| recall_all@5       | —      |
| recall_all@10      | —      |
| mrr                | —      |
| query_p50_s        | —      |
| query_p95_s        | —      |
| write_mean_s       | —      |

---

## Pre/Post Encoding Fix Comparison (Rust, same 50 questions)

| Metric         | v1 (background) | v2 (inline n=true) | delta   |
|----------------|-----------------|---------------------|---------|
| recall_any@1   | 0.5000          | —                   | —       |
| recall_any@5   | 0.7800          | —                   | —       |
| recall_any@10  | 0.8800          | —                   | —       |
| recall_all@1   | 0.2600          | —                   | —       |
| recall_all@5   | 0.4200          | —                   | —       |
| recall_all@10  | 0.6200          | —                   | —       |
| mrr            | 0.6411          | —                   | —       |
| write_mean_s   | 0.047           | —                   | —       |
| query_p50_s    | 1.481           | —                   | —       |
| query_p95_s    | 2.045           | —                   | —       |

---

## Twin Agreement Table — v2 (50 questions, same seed)

Per-question recall_any@1 and MRR comparison for both twins on the same 50 questions
(SplitMix64 seed 20260725 guarantees identical question order on both legs). Divergence
is expected and correct — each twin provisions a separate mootx01 estate per question,
so embedding ranking is independent. The table shows how often two independent runs
agree on correct top-1 recall.

| question_id  | type               | Swift recall_any@1 | Rust recall_any@1 | Swift mrr | Rust mrr | agree@1? |
|--------------|--------------------|--------------------|-------------------|-----------|----------|----------|
| (pending)    | …                  | —                  | —                 | —         | —        | —        |

Full table will be populated when both v2 runs complete.

---

## Conformance

Both legs share `longmemeval_vectors.json` conformance vectors: 10 recall cases + 5
uuid_mapping cases, tolerance 1e-9. Both legs pass. The scoring MATH is identical;
live recall scores vary because each twin provisions a separate mootx01 estate per
question — independent embedding ranking.

**SplitMix64 shuffle:** same seed (20260725) produces identical question order on both
legs — confirmed on the 10-question overlap (gpt4_2ba83207, 60d45044, 2788b940, …).
Question order is guaranteed identical for the full 50-question run.

---

## Encoding Correctness — n=true vs Background

`moot_file_memory` accepts `n: bool` (source: `AriaMcpKit/Sources/AriaMCP/ToolProjection.swift`).
When `n=true`, encoding is inline and the memory is immediately recallable on return.
When `n=false` (the default), encoding is background — a recall query issued after full
ingest may execute before the encoding queue drains, underreporting recall.

Both runners initially omitted `n=true`. Fix `44303d0f` added it to both the Swift and
Rust write loops:
- **Swift** (`LongMemEvalRunner.swift`): `writeArgs["n"] = .bool(true)` after the
  `constantArgs` loop.
- **Rust** (`longmemeval_runner.rs`, `ingest_turn()`): `args.insert("n", JsonValue::Bool(true))`
  after the `constant_args` loop.

Trade-off: write latency per turn increases (blocking on embedding model inference for
each turn), but the correctness invariant is guaranteed. The v2 50q smokes are the first
valid LME baseline.

Note: `constantArgs` (Swift) / `constant_args` (Rust) is typed as `[String: String]` / 
`BTreeMap<String, String>` — it cannot hold boolean values. The `n=true` argument is
injected directly into the call-site args dict AFTER the constantArgs loop, bypassing the
string-only restriction.

---

## DegeneracyGuard

All 50 questions in the v1 Rust run cleared the guard (0 guard_excluded). The three probe
queries ("what happened during our recent dinner together?", "can you remind me about my
work project updates?", "what were we discussing about travel plans last month?") produced
sufficiently distinct rankings on every question. This confirms mootx01 is not returning
frozen/query-invariant results at `location: benchmark/longmemeval`.

v2 guard results to be confirmed when both runs complete.

---

## Latency

- **v1 write mean:** ~47 ms/turn (background encoding, immediate return).
- **v2 write mean:** expected significantly higher (blocking on inline embedding encoding).
- **v1 query p50:** ~1.45–1.48 s — includes embedding model inference for the recall query.
- **v1 query p95:** ~2.0 s — elevated on multi-session questions (larger haystacks).
- **v1 per-question wall time:** ~30–40 s (ingest + probe × 3 + query, background encoding).
- **v2 per-question wall time:** higher; encoding is front-loaded into the write phase.

---

## Smythe and Adams Verdicts

- **Smythe (pre-flight):** GREEN — Tier 3 net-new. No existing CE symbols changed, renamed,
  removed, or deprecated. BRR confirmed at `docs/blast_radius/LME-01_BLAST_RADIUS.md`.
  MUST_UPDATE: `.gitignore`, `CHANGELOG.md`. RESCOPE_REQUIRED: none.

- **Adams (post-flight):** CLEAN-WITH-FOLLOWUPS — 0 CRITICALs, 2 WARNINGs. Both addressed
  in commit `6b0dbe6e`:
  - WARNING 1: `defaultResultsRoot()` (GauntletIO.swift) had 4× `deletingLastPathComponent()`
    (EE layout). CE has no `swift-bench/` wrapper; 3× is correct.
  - WARNING 2: `defaultFixturesRoot()` (main.swift) same depth mismatch. Fixed.

---

## Findings

1. **`has_answer` field absent in real corpus.** The real HuggingFace corpus turns do not
   include `has_answer` (present only in the hand-authored synthetic test sample). Fixed
   in both loaders: `#[serde(default)]` in Rust, `decodeIfPresent` with `?? false` in Swift.

2. **Background encoding race — all v1 numbers suspect.** `moot_file_memory` defaults to
   background encoding. The LME harness must always use `n=true` to guarantee the
   ingest → encode → query invariant. v1 numbers are a lower bound; v2 numbers with n=true
   are the valid baseline.

3. **Recall is meaningful (v1 lower bound).** recall_any@10 = 0.88 in the Rust v1 run
   indicates mootx01 surfaces the correct session for most questions when a top-10 window
   is used. v2 may be higher.

4. **Multi-session questions harder.** `multi-session` questions (answer spans >= 2 sessions)
   show lower recall_all than `single-session-*` questions — all sessions must rank in the
   top-k window.

5. **Scratch dir isolation works.** Pattern `/tmp/lme-bench-<seed_hex>-<q_hex>` isolates
   each question's estate. Guard teardown refuses non-`/tmp/lme-bench-` prefixes.

6. **CE deletingLastPathComponent depth is 3 not 4.** CE layout is
   `Sources/mcp-benchmarker/<file>` (3 levels to `apps/mcp-benchmarker/`). EE had an
   additional `swift-bench/` wrapper requiring 4 levels. Both path helpers corrected in
   Adams post-flight fix `6b0dbe6e`.

---

## Next Steps (not in LME-01 scope)

- Fill in v2 numbers when both 50q runs complete.
- Full 500-question run for the authoritative baseline (expected ~4.5+ hours single-threaded).
- LLM-judge QA accuracy scoring (answer quality beyond session retrieval).
- Temporal-reasoning and knowledge-update question type breakdowns.
- Multi-session variant (`m`) and oracle variant runs.
- Parallelized runner (multiple workers, isolated estates) for throughput.
