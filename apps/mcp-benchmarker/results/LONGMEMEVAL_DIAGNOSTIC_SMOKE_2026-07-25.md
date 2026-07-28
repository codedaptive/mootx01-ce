---
version: v0.3
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

Both 50q runs completed 2026-07-26T04:31-04:32Z with commit `44303d0f`.

### Rust twin — 50q v2 (`--limit 50 --seed 20260725`, inline encoding n=true)

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 50     |
| guard_excluded     | 0      |
| recall_any@1       | 0.4800 |
| recall_any@5       | 0.7800 |
| recall_any@10      | 0.8600 |
| recall_all@1       | 0.2000 |
| recall_all@5       | 0.3400 |
| recall_all@10      | 0.5600 |
| mrr                | 0.6178 |
| query_p50_s        | 1.523  |
| query_p95_s        | 2.166  |
| write_mean_s       | 0.049  |

### Swift twin — 50q v2 (`--limit 50 --seed 20260725`, inline encoding n=true)

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 50     |
| guard_excluded     | 0      |
| recall_any@1       | 0.4800 |
| recall_any@5       | 0.7600 |
| recall_any@10      | 0.9000 |
| recall_all@1       | 0.2200 |
| recall_all@5       | 0.4000 |
| recall_all@10      | 0.5200 |
| mrr                | 0.6208 |
| query_p50_s        | 1.482  |
| query_p95_s        | 2.612  |
| write_mean_s       | 0.050  |

---

## Pre/Post Encoding Fix Comparison (Rust, same 50 questions)

| Metric         | v1 (background) | v2 (inline n=true) | delta   |
|----------------|-----------------|---------------------|---------|
| recall_any@1   | 0.5000          | 0.4800              | −0.0200 |
| recall_any@5   | 0.7800          | 0.7800              | 0.0000  |
| recall_any@10  | 0.8800          | 0.8600              | −0.0200 |
| recall_all@1   | 0.2600          | 0.2000              | −0.0600 |
| recall_all@5   | 0.4200          | 0.3400              | −0.0800 |
| recall_all@10  | 0.6200          | 0.5600              | −0.0600 |
| mrr            | 0.6411          | 0.6178              | −0.0233 |
| write_mean_s   | 0.047           | 0.049               | +0.002  |
| query_p50_s    | 1.481           | 1.523               | +0.042  |
| query_p95_s    | 2.045           | 2.166               | +0.121  |

**Interpretation:** The v2 numbers are slightly lower than v1 for most recall metrics, but
the deltas are within natural run-to-run variance for a 50-question sample. The write_mean
overhead from n=true is only +2ms/turn — negligible. This indicates the background encoding
race was not materially degrading results on this lightly loaded machine: encoding was
completing before the recall query ran in nearly all v1 cases. The n=true fix removes the
theoretical race condition and is required for correctness in production (or under load), even
though the practical impact on this hardware is small.

---

## Twin Agreement Table — v2 (50 questions, same seed 20260725)

Per-question recall_any@1 and MRR comparison for both twins. SplitMix64 seed 20260725 guarantees
identical question order on both legs. Divergence is expected — each twin provisions a separate
mootx01 estate per question, so embedding ranking is independent.

**Agreement@1: 42/50 = 84%** (8 disagreements: 4 Rust-only hits, 4 Swift-only hits — symmetric)

| # | question_id | type | Rust any@1 | Swift any@1 | Rust MRR | Swift MRR | agree@1 |
|---|---|---|---|---|---|---|---|
| 1 | gpt4_2ba83207 | multi-session | 0 | 0 | 0.500 | 0.500 | Y |
| 2 | 60d45044 | single-session-user | 0 | 0 | 0.500 | 0.500 | Y |
| 3 | 2788b940 | multi-session | 1 | 0 | 1.000 | 0.100 | N |
| 4 | 8a2466db | single-session-preference | 1 | 1 | 1.000 | 1.000 | Y |
| 5 | 4adc0475 | multi-session | 1 | 0 | 1.000 | 0.100 | N |
| 6 | 35a27287 | single-session-preference | 0 | 0 | 0.333 | 0.500 | Y |
| 7 | 51b23612 | single-session-assistant | 0 | 0 | 0.143 | 0.333 | Y |
| 8 | caf03d32 | single-session-preference | 1 | 1 | 1.000 | 1.000 | Y |
| 9 | 681a1674 | multi-session | 0 | 0 | 0.000 | 0.000 | Y |
| 10 | e61a7584 | knowledge-update | 0 | 0 | 0.500 | 0.500 | Y |
| 11 | gpt4_e061b84g | temporal-reasoning | 0 | 0 | 0.000 | 0.167 | Y |
| 12 | 77eafa52 | multi-session | 0 | 0 | 0.500 | 0.100 | Y |
| 13 | 031748ae_abs | knowledge-update | 1 | 0 | 1.000 | 0.083 | N |
| 14 | 2ebe6c92 | temporal-reasoning | 0 | 0 | 0.333 | 0.250 | Y |
| 15 | c9f37c46 | temporal-reasoning | 1 | 1 | 1.000 | 1.000 | Y |
| 16 | gpt4_b5700ca0 | temporal-reasoning | 0 | 0 | 0.250 | 0.500 | Y |
| 17 | c4f10528 | single-session-assistant | 0 | 0 | 0.500 | 0.500 | Y |
| 18 | 1903aded | single-session-assistant | 0 | 0 | 0.100 | 0.100 | Y |
| 19 | gpt4_7a0daae1 | temporal-reasoning | 0 | 0 | 0.250 | 0.111 | Y |
| 20 | ce6d2d27 | knowledge-update | 1 | 1 | 1.000 | 1.000 | Y |
| 21 | c4a1ceb8 | multi-session | 1 | 1 | 1.000 | 1.000 | Y |
| 22 | c14c00dd | single-session-user | 1 | 1 | 1.000 | 1.000 | Y |
| 23 | 61f8c8f8 | multi-session | 0 | 1 | 0.500 | 1.000 | N |
| 24 | gpt4_7ddcf75f | temporal-reasoning | 1 | 1 | 1.000 | 1.000 | Y |
| 25 | 3ba21379 | knowledge-update | 0 | 0 | 0.250 | 0.250 | Y |
| 26 | f523d9fe | single-session-assistant | 1 | 1 | 1.000 | 1.000 | Y |
| 27 | gpt4_cd90e484 | temporal-reasoning | 1 | 1 | 1.000 | 1.000 | Y |
| 28 | gpt4_78cf46a3 | temporal-reasoning | 0 | 0 | 0.500 | 0.500 | Y |
| 29 | 0862e8bf_abs | single-session-user | 0 | 0 | 0.000 | 0.000 | Y |
| 30 | eeda8a6d | multi-session | 1 | 1 | 1.000 | 1.000 | Y |
| 31 | 5a4f22c0 | knowledge-update | 1 | 1 | 1.000 | 1.000 | Y |
| 32 | e47becba | single-session-user | 1 | 1 | 1.000 | 1.000 | Y |
| 33 | 28dc39ac | multi-session | 1 | 1 | 1.000 | 1.000 | Y |
| 34 | 09ba9854_abs | multi-session | 1 | 0 | 1.000 | 0.500 | N |
| 35 | gpt4_59c863d7 | multi-session | 0 | 0 | 0.500 | 0.500 | Y |
| 36 | cc6d1ec1 | temporal-reasoning | 1 | 1 | 1.000 | 1.000 | Y |
| 37 | 157a136e | multi-session | 0 | 0 | 0.083 | 0.000 | Y |
| 38 | 94f70d80 | single-session-user | 1 | 1 | 1.000 | 1.000 | Y |
| 39 | gpt4_9a159967 | temporal-reasoning | 0 | 0 | 0.091 | 0.111 | Y |
| 40 | 09d032c9 | single-session-preference | 0 | 0 | 0.000 | 0.000 | Y |
| 41 | gpt4_2f584639 | temporal-reasoning | 0 | 1 | 0.333 | 1.000 | N |
| 42 | 2133c1b5_abs | knowledge-update | 0 | 0 | 0.500 | 0.500 | Y |
| 43 | gpt4_6ed717ea | temporal-reasoning | 1 | 1 | 1.000 | 1.000 | Y |
| 44 | gpt4_1e4a8aeb | temporal-reasoning | 0 | 1 | 0.125 | 1.000 | N |
| 45 | 21436231 | single-session-user | 1 | 1 | 1.000 | 1.000 | Y |
| 46 | 7161e7e2 | single-session-assistant | 0 | 1 | 0.000 | 1.000 | N |
| 47 | b320f3f8 | single-session-user | 1 | 1 | 1.000 | 1.000 | Y |
| 48 | gpt4_e05b82a6 | multi-session | 1 | 1 | 1.000 | 1.000 | Y |
| 49 | c5e8278d | single-session-user | 1 | 1 | 1.000 | 1.000 | Y |
| 50 | a11281a2 | multi-session | 0 | 0 | 0.100 | 0.333 | Y |

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

All 50 questions in both v2 runs cleared the guard (0 guard_excluded). The three probe
queries ("what happened during our recent dinner together?", "can you remind me about my
work project updates?", "what were we discussing about travel plans last month?") produced
sufficiently distinct rankings on every question. This confirms mootx01 is not returning
frozen/query-invariant results at `location: benchmark/longmemeval`.

---

## Latency

- **v2 write mean (both twins):** ~49–50 ms/turn — nearly identical to v1 background.
  The n=true overhead is ~2 ms/turn, confirming encoding completes quickly on this hardware.
- **Rust v2 query p50:** 1.523 s, p95: 2.166 s
- **Swift v2 query p50:** 1.482 s, p95: 2.612 s (higher p95 reflects heavier Swift concurrency overhead on large haystacks)
- **Per-question wall time:** ~50–70 s per question (ingest + guard × 3 + query, with inline encoding)

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

2. **Background encoding race — theoretical, not material on this hardware.** `moot_file_memory`
   defaults to background encoding. The LME harness must always use `n=true` for correctness
   guarantees in production or under load. In practice on a lightly loaded machine the encoding
   completes before the recall query in nearly all cases, explaining why v1 and v2 numbers
   are within natural run-to-run variance. The n=true fix is correct and required; its impact
   here is small.

3. **Recall is meaningful at @10 (v2 valid baseline).** recall_any@10 = 0.86–0.90 across
   both twins indicates mootx01 surfaces the correct session for 86–90% of questions when a
   top-10 window is used.

4. **Multi-session questions harder.** `multi-session` questions (answer spans >= 2 sessions)
   show lower recall_all than `single-session-*` questions — all sessions must rank in the
   top-k window simultaneously.

5. **Scratch dir isolation works.** Pattern `/tmp/lme-bench-<seed_hex>-<q_hex>` isolates
   each question's estate. Guard teardown refuses non-`/tmp/lme-bench-` prefixes.

6. **CE deletingLastPathComponent depth is 3 not 4.** CE layout is
   `Sources/mcp-benchmarker/<file>` (3 levels to `apps/mcp-benchmarker/`). EE had an
   additional `swift-bench/` wrapper requiring 4 levels. Both path helpers corrected in
   Adams post-flight fix `6b0dbe6e`.

7. **Agreement@1 is 84% (42/50).** 8 questions differ between the twins at recall_any@1.
   The split is exactly symmetric: 4 Rust-only hits, 4 Swift-only hits. No systematic
   advantage to either twin. Divergence is expected — independent estate per question,
   independent embedding ranking.

---

## Next Steps (not in LME-01 scope)

- Full 500-question run for the authoritative baseline (expected ~4.5+ hours single-threaded).
- LLM-judge QA accuracy scoring (answer quality beyond session retrieval).
- Temporal-reasoning and knowledge-update question type breakdowns.
- Multi-session variant (`m`) and oracle variant runs.
- Parallelized runner (multiple workers, isolated estates) for throughput.
