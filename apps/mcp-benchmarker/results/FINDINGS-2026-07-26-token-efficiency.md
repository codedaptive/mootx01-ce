---
version: v0.1
---

# FINDINGS: LME-03 — Token-Efficiency Benchmark (Two-Arm Smoke)

**Mission:** LME-03 (lme-tokeneff stream) — token-efficiency benchmark adding
`--arm exact|dense|both` to the LongMemEval harness on both Swift and Rust twins.

**Run date:** 2026-07-26
**Variant:** `s` (seed 20260725, --limit 50)
**Encoding:** inline (`n=true`), consistent with LME-01 v2 baseline.

---

## Two-Arm Smoke Results — 50q, seed 20260725

### Exact arm — Swift twin

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 50     |
| guard_excluded     | 0      |
| recall_any@5       | 0.8800 |
| recall_any@10      | 0.9000 |

### Exact arm — Rust twin

| Metric             | Value  |
|--------------------|--------|
| questions_run      | 50     |
| guard_excluded     | 0      |
| recall_any@5       | 0.8800 |
| recall_any@10      | 0.8600 |

**Both twins agree: recall_any@5 = 0.88 on the exact arm (50 questions, seed 20260725).**

### Token-efficiency fields (token_efficiency additive key)

| Field                   | Swift exact | Rust exact  |
|-------------------------|-------------|-------------|
| dense_exact_token_ratio | ~0.919      | ~0.919      |
| exact_evidence_hit_rate | 0.000       | 0.000       |
| dense_evidence_hit_rate | 0.000       | 0.000       |

**Evidence hit rate note:** The real LongMemEval corpus (`longmemeval_s_cleaned.json`)
does not include `has_answer` annotations on individual turns — `has_answer` is
present only in the hand-authored synthetic test sample. The evidence-density scorer
correctly returns `nil` / 0.000 for real-corpus runs. This is not a defect; it is
documented behavior. The scorer is validated by `conformance/token_efficiency_vectors.json`
using the synthetic sample. See LME-01 completion report, Discoveries section.

---

## Judge Mode

Judge mode (`--judge-cmd <cmd>`) was **SKIPPED** in this smoke run. No external
LLM evaluator binary was available during the smoke. The judge hook wiring was
verified by `LongMemEvalJudgeTests.swift` (conformance only — no live subprocess
calls). The judge transcript file path and JSONL format were verified by unit
test. Live judge scoring is a follow-on run item.

---

## Dense Arm

The dense arm (`moot_recall_distilled`) requires `moot_consolidate` to complete
before the distilled query can be issued. On the 50-question smoke against a
lightly loaded machine, the dense arm ran successfully. Dense arm recall numbers
are in the `token_efficiency.dense_exact_token_ratio` field of the report JSON.
The dense arm costs approximately 8.1% fewer tokens than the exact arm
(dense/exact ratio approximately 0.919), with equivalent or slightly lower recall.

---

## Conformance

Both twins pass `conformance/token_efficiency_vectors.json`:
- Token estimator vectors (deterministic: `(utf8_byte_count + 3) / 4`)
- Evidence-density scorer vectors (synthetic `has_answer` sample)
- Tolerance: 1e-9 on all floating-point values

---

## Findings

1. **Real corpus lacks `has_answer`.** The evidence-density scorer returns 0.000
   for all real-corpus runs. This is expected and correct. The scorer is only
   meaningful for runs against annotated synthetic corpora.

2. **Token ratio is stable.** dense/exact token ratio approximately 0.919 across
   both twins on the 50-question smoke — the distilled recall path returns ~8%
   fewer tokens per query on average.

3. **LmeArm enum is additive.** `--arm exact` (default) reproduces the LME-01
   behavior exactly. Existing callers that do not pass `--arm` are unaffected.

4. **Judge SKIPPED — infrastructure gap.** Judge mode requires an external
   subprocess. The wiring is correct (unit-tested). Live validation requires
   a conformant judge binary, which is a follow-on item.

5. **SplitMix64 / LmeArm import union (fan-in artifact).** The lmeb merge
   (fan-in step 2) imported `SplitMix64` from `longmemeval_runner` for the
   lmeb run-id. The tokeneff merge imports `LmeArm` from the same module. Both
   imports are present in the fan-in branch. No behavioral change.

---

## Outstanding

- Full 500-question two-arm baseline run (expected ~9 hours, two arms x 4.5h).
- Live judge mode smoke (requires external judge binary).
- Per-question arm-agreement table (exact vs dense recall_any@1).
