---
version: v0.1
---

# LoCoMo Diagnostic Smoke Run — 2026-07-26

**Mission:** LME-04 — LoCoMo Loader + Recall Benchmark (Both Twins).

**Method:** Per-conversation estate strategy — each of the 10 conversations in
locomo10.json provisions one fresh scratch estate. All turns are ingested with
`moot_file_memory` at `location: benchmark/locomo` and `n=true` (inline encoding).
After full ingest, a DegeneracyGuard probe runs once per estate. All selected questions
for that conversation are then queried against its estate. The estate is torn down before
the next conversation begins.

**Dataset:** LoCoMo (Snap Research, ACL 2024). 10 conversations, 1,986 total questions,
450 adversarial excluded = 1,536 scoreable. License: CC BY-NC 4.0 — internal diagnostic
use only, never committed to version control.

**Variant:** seed 20260725, limit 50 questions, both twins.

**Key difference from LME-01:** LoCoMo uses O(10) estate provisions per run (one per
conversation) vs LME's O(q) (one per question). The 10 selected conversations cover all
50 questions; per-question estates would require ~600–700 turn ingests × 50 = ~33,000
total ingest calls vs ~5,882 here.

---

## Results — Rust twin

Two runs, same seed 20260725, limit 50.

### Rust run 1

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 50     |
| guard_excluded     | 0      |
| recall_any@5       | 0.2000 |
| recall_all@5       | 0.1800 |
| recall_any@10      | 0.2600 |
| mrr                | 0.2001 |
| query_p50_ms       | 257    |
| query_p95_ms       | 311    |

### Rust run 2

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 50     |
| guard_excluded     | 0      |
| recall_any@5       | 0.2000 |
| recall_all@5       | 0.1800 |
| recall_any@10      | 0.2400 |
| mrr                | 0.1767 |
| query_p50_ms       | 250    |
| query_p95_ms       | 298    |

### Rust category breakdown (run 1)

| Category     | n  | any@5  | all@5  | mrr    |
|--------------|----|--------|--------|--------|
| single_hop   |  8 | 0.2500 | 0.1250 | 0.2782 |
| temporal     | 12 | 0.3333 | 0.3333 | 0.2917 |
| multi_hop    |  2 | 0.0000 | 0.0000 | 0.0833 |
| open_domain  | 28 | 0.1429 | 0.1429 | 0.1468 |

---

## Results — Swift twin

Two runs, same seed 20260725, limit 50.

### Swift run 1

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 50     |
| guard_excluded     | 0      |
| recall_any@5       | 0.1600 |
| recall_all@5       | 0.1400 |
| recall_any@10      | 0.2200 |
| mrr                | 0.1729 |
| query_p50_ms       | 266    |
| query_p95_ms       | 306    |

### Swift run 2

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 50     |
| guard_excluded     | 0      |
| recall_any@5       | 0.2800 |
| recall_all@5       | 0.2400 |
| recall_any@10      | 0.3200 |
| mrr                | 0.2129 |
| query_p50_ms       | 245    |
| query_p95_ms       | 304    |

### Swift category breakdown (run 2)

| Category     | n  | any@5  | all@5  | mrr    |
|--------------|----|--------|--------|--------|
| single_hop   |  8 | 0.3750 | 0.1250 | 0.2750 |
| temporal     | 12 | 0.4167 | 0.4167 | 0.3794 |
| multi_hop    |  2 | 0.0000 | 0.0000 | 0.0625 |
| open_domain  | 28 | 0.2143 | 0.2143 | 0.1345 |

---

## Non-Determinism Observation

Across four 50-question runs (2 Rust, 2 Swift), recall metrics show significant
run-to-run variance:

| Metric      | Min    | Max    | Range  |
|-------------|--------|--------|--------|
| any@5       | 0.1600 | 0.2800 | 0.1200 |
| all@5       | 0.1400 | 0.2400 | 0.1000 |
| any@10      | 0.2200 | 0.3200 | 0.1000 |
| mrr         | 0.1729 | 0.2129 | 0.0400 |

The moot binary's approximate nearest-neighbor search is non-deterministic. Identical
question text against an identical estate can rank different turns in the top-k window
across separate runs. This is expected behavior for ANN search.

Consequence: the numbers in this document are a diagnostic sample, not a reproducible
fixed baseline. Authoritative LoCoMo benchmarking requires either deterministic search
configuration or averaging over multiple full-corpus runs.

Rust run 1 and run 2 happen to agree at @5 (0.2000/0.1800 both times) while @10 and MRR
diverge — this is likely coincidence in the 50-question sample, not evidence that @5 is
more deterministic.

---

## Twin Agreement

Category n-counts match exactly across all four runs (single_hop=8, temporal=12,
multi_hop=2, open_domain=28), confirming the SplitMix64 shuffle (seed 20260725) produces
identical question selection in both twins.

**Agreement@5 (Rust run 1 vs Swift run 2): 46/50 = 92%**

The 4 disagreements are all Swift-only hits (Rust misses, Swift hits at @5). Given the
non-determinism documented above, these disagreements are consistent with expected
run-to-run variance rather than a systematic scoring defect.

**Mathematical agreement** is established by the conformance vector tests: both twins
pass `locomo_vectors.json` tolerance 1e-9 on all recall and MRR cases. The scoring MATH
is identical. Live recall scores vary independently because each twin provisions a separate
mootx01 estate per conversation, with independent embedding ranking.

### Per-question comparison (Rust run 1 vs Swift run 2)

| Question ID    | Category     | R any@5 | S any@5 | R MRR | S MRR | agree@5 |
|----------------|--------------|---------|---------|-------|-------|---------|
| conv-26_q129   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-26_q76    | single_hop   | 1       | 1       | 1.000 | 1.000 | Y |
| conv-26_q99    | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-30_q68    | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-30_q64    | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-30_q10    | temporal     | 1       | 1       | 1.000 | 1.000 | Y |
| conv-41_q101   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-41_q121   | open_domain  | 1       | 1       | 1.000 | 1.000 | Y |
| conv-41_q86    | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-41_q100   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-42_q70    | single_hop   | 0       | 0       | 0.000 | 0.000 | Y |
| conv-42_q24    | temporal     | 1       | 1       | 1.000 | 1.000 | Y |
| conv-42_q54    | temporal     | 0       | 0       | 0.000 | 0.000 | Y |
| conv-42_q143   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-42_q40    | temporal     | 1       | 1       | 0.500 | 0.500 | Y |
| conv-42_q186   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-43_q0     | single_hop   | 0       | 0       | 0.000 | 0.000 | Y |
| conv-43_q26    | single_hop   | 0       | 0       | 0.059 | 0.000 | Y |
| conv-43_q85    | open_domain  | 0       | 1       | 0.000 | 0.333 | N |
| conv-43_q151   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-43_q42    | single_hop   | 0       | 0       | 0.000 | 0.000 | Y |
| conv-43_q88    | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-43_q126   | open_domain  | 0       | 1       | 0.000 | 0.500 | N |
| conv-44_q112   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-44_q16    | temporal     | 0       | 0       | 0.000 | 0.000 | Y |
| conv-44_q91    | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-44_q36    | single_hop   | 0       | 0       | 0.000 | 0.000 | Y |
| conv-44_q1     | temporal     | 1       | 1       | 1.000 | 1.000 | Y |
| conv-44_q85    | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-44_q66    | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-44_q79    | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-47_q136   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-47_q21    | temporal     | 0       | 0       | 0.000 | 0.000 | Y |
| conv-48_q190   | open_domain  | 1       | 1       | 1.000 | 1.000 | Y |
| conv-48_q120   | open_domain  | 0       | 0       | 0.000 | 0.059 | Y |
| conv-48_q2     | temporal     | 0       | 0       | 0.000 | 0.053 | Y |
| conv-48_q146   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-48_q174   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-48_q86    | single_hop   | 1       | 1       | 1.000 | 1.000 | Y |
| conv-48_q32    | temporal     | 0       | 0       | 0.000 | 0.000 | Y |
| conv-49_q25    | temporal     | 0       | 0       | 0.000 | 0.000 | Y |
| conv-49_q109   | open_domain  | 0       | 0       | 0.000 | 0.000 | Y |
| conv-49_q27    | multi_hop    | 0       | 0       | 0.000 | 0.000 | Y |
| conv-49_q76    | temporal     | 0       | 0       | 0.000 | 0.000 | Y |
| conv-49_q136   | open_domain  | 1       | 1       | 1.000 | 0.500 | Y |
| conv-49_q20    | multi_hop    | 0       | 0       | 0.167 | 0.125 | Y |
| conv-49_q14    | single_hop   | 0       | 1       | 0.167 | 0.200 | N |
| conv-49_q116   | open_domain  | 0       | 0       | 0.111 | 0.125 | Y |
| conv-50_q136   | open_domain  | 1       | 1       | 1.000 | 0.250 | Y |
| conv-50_q14    | temporal     | 0       | 1       | 0.000 | 1.000 | N |

---

## DegeneracyGuard

All 50 questions cleared the guard on every run (0 guard_excluded across all 4 runs).
One DegeneracyGuard probe per conversation estate; probe used the standard three queries
from the LME-01 harness. The per-conversation estate model is validated.

---

## Latency

LoCoMo query latency is substantially faster than LME-01 (~250–310 ms vs ~1,500 ms).
The difference is expected: LME-01 haystacks contain hundreds of sessions spanning
thousands of turns, while LoCoMo conversations have 350–700 turns each — a much smaller
estate per query.

| Metric         | Rust run 1 | Rust run 2 | Swift run 1 | Swift run 2 |
|----------------|-----------|-----------|------------|------------|
| query_p50_ms   | 257       | 250       | 266        | 245        |
| query_p95_ms   | 311       | 298       | 306        | 304        |

---

## Findings

1. **Swift SIGSEGV fix (%-14s → %-14@).** The `runLoCoMo` summary loop in main.swift
   used `%-14s` format specifier with a Swift `String` argument for the category label.
   `%s` expects a C string pointer (`UnsafePointer<CChar>`); passing a Swift `String`
   results in `_platform_strlen` dereferencing a garbage pointer → SIGSEGV. Fixed to
   `%-14@` with `cat.label as NSString`. The crash report (IPS, bug_type 309) confirmed
   the crash frame at main.swift:935 in the per-category formatting loop. This crash was
   present in the Part 3 commit and was introduced in Part 5 when the display code was
   written for this format specifier.

2. **Display bug: "conversations used: 1".** The `conversationsUsed` summary field is
   computed as `Set(corpus.questions.prefix(results.count).map(\.conversationIndex)).count`
   — it takes the first `results.count` questions from the UNSHUFFLED corpus, not from the
   actual selected question set. The first 50 questions in the original question array
   may all come from one conversation, producing `conversations used: 1` even when all
   10 conversations were provisioned. Scoring is unaffected; this is a display-only bug.

3. **Display bug: "turns ingested total" over-counts.** `LoCoMoQuestionResult.turnsIngested`
   stores the conversation's full manifest size (e.g. 419 for conv-26). For a conversation
   with 3 questions, all 3 results store `turnsIngested = 419`, and summing them gives
   3 × 419 = 1,257 for that conversation rather than 419. Across 50 questions, the total
   reads 30,303 when the actual unique turns ingested is ~5,882. Scoring is unaffected.

4. **Non-determinism in moot binary search.** Recall metrics vary significantly across
   runs. This is expected for approximate nearest-neighbor search. Any authoritative LoCoMo
   baseline requires multiple full-corpus runs or deterministic search configuration.

5. **Per-conversation estate strategy is correct.** All 10 conversations were successfully
   provisioned and torn down in every run. The O(10) provision count vs O(1,536) for
   per-question estates is validated. The guarded teardown (`/tmp/locomo-bench-` prefix)
   prevented any accidental deletion of real data directories.

6. **Rust report `questions_loaded` includes adversarial.** The Rust report fields
   `questions_loaded: 1986` (total including adversarial) while Swift reports
   `questions_loaded: 1536` (scoreable only). Both report `adversarial_excluded: 450`.
   Minor schema divergence in report metadata; scoring is unaffected.

---

## Conformance

Both twins pass `fixtures/conformance/locomo_vectors.json` tolerance 1e-9 on all recall
cases (lme_recall_any, lme_recall_all, lme_session_mrr) and uuid_mapping cases
(locomo_manifest_as_lme → lme_ranked_sessions). The scoring math is bit-for-bit identical.

The locomo_vectors.json test uses `ranked_dia_ids` / `evidence_dia_ids` / `dia_id`
field names (not `session_id`) — the bridge function `locomo_manifest_as_lme` /
`loCoMoManifestAsLme` maps dia_id into the session_id slot used by the LME scoring
functions, and this mapping is tested end-to-end in the conformance vectors.

---

## Smythe and Adams Verdicts

Recorded in COMPLETION_LME-04.md after post-flight completes.
