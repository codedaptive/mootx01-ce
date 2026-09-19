---
title: LMEB + ConvoMem — Official Evaluation Protocols (verbatim extraction)
release: "1.1"
date: 2026-08-28
description: The two documented protocols over the ConvoMem data — LMEB embedding-retrieval scoring and ConvoMem's own judged-QA — extracted verbatim from KaLM-Embedding/LMEB and SalesforceAIResearch/ConvoMem, for the lmeb-spec and convomem-spec lanes.
---

# LMEB + ConvoMem — Official Evaluation Protocols

Two published protocols run over the same data set:

- **LMEB** (`KaLM-Embedding/LMEB` @ main — `metric.py`,
  `src/abstasks/SubsetRetrieval.py`, `src/tasks/ConvoMem.py`,
  `task_instructions.json`; paper arXiv 2603.12572): retrieval scoring,
  main metric **nDCG@10**.
- **ConvoMem** (`SalesforceAIResearch/ConvoMem` @ main — Scala harness,
  `evaluation/EvaluationUtils.scala`,
  `questions/evidence/generation/AnsweringEvaluation.scala`,
  `evaluation/memory/MemoryPromptUtils.scala`; paper arXiv 2511.10523):
  judged answer accuracy, RIGHT/WRONG verdicts.

Source files quoted verbatim
(`lmeb_*.py`, `cm_*.scala`).

## A. LMEB retrieval protocol

### A1. Task shape (verbatim from src/tasks/ConvoMem.py)

Six subsets (eval_langs): `abstention_evidence`, `assistant_facts_evidence`,
`changing_evidence`, `implicit_connection_evidence`, `preference_evidence`,
`user_evidence`. Files per subset: `queries.jsonl` (id/text),
`corpus.jsonl` (id/title/text), `qrels.tsv`, `candidates.jsonl`
(scene_id → candidate_doc_ids). `main_score="ndcg_at_10"`,
`k_values = [1, 5, 10, 25, 50]`.

### A2. Candidate restriction (SubsetRetrieval.py semantics)

Retrieval scores are computed, then results are FILTERED per query to that
query's scene candidate pool (`candidate_doc_ids`); documents outside the
pool are dropped from the ranking before metrics. Queries with empty
candidate lists are warned and skipped. (Our lane achieves the same
restriction by physically seeding only the pool — an equivalent mechanism;
the spec lane keeps per-unit seeding and documents the equivalence.)

### A3. Metrics

Standard MTEB/pytrec_eval retrieval metrics at each k in
`[1, 5, 10, 25, 50]`: nDCG@k, MAP@k, Recall@k, Precision@k, MRR@k —
macro-averaged over queries per subset, subset scores averaged for the
task score, `ndcg_at_10` is the headline. Binary qrels here, so
DCG = Σ 1/log2(rank+1) over relevant hits in top-k and IDCG over
min(k, |relevant|) — matching pytrec_eval on binary relevance.

Plus the LMEB-specific capped recall (metric.py, verbatim semantics):

```python
# R_cap@k = (# relevant in top-k) / min(#total_relevant, k)
# None when the query has no relevant documents (denominator = 0)
denom = min(num_relevant_total, k)
capped = hits / denom
# macro average ignores None; rounded to 5 decimals
```

`skip_first_result` (drop rank 1 before the cutoff) exists as an option and
defaults off. `ignore_identical_ids` removes a result document whose ID equals
the query ID; the switch remains available although this data does not require
it.

### A4. Instruction settings

Two published settings: **without instruction** and **with instruction**.
With-instruction prepends the per-subset instruction to the query
(task_instructions.json, verbatim):

| Subset | Instruction |
|---|---|
| abstention_evidence | Given a query, retrieve documents that answer the query |
| assistant_facts_evidence | Given a query, retrieve assistant messages that answer the query |
| changing_evidence | Given a question, retrieve the latest information to answer the question |
| implicit_connection_evidence | Given a query, retrieve documents that answer the query |
| preference_evidence | Given a query, retrieve the user's stated preferences that can help answer the query |
| user_evidence | Given a query, retrieve documents that answer the query |

## B. ConvoMem judged-QA protocol

### B1. Answer generation (verbatim)

Full-context form (`EvaluationUtils.getModelAnswerPrompt`):

```
Answer the question based on the conversations below. If the User in the conversation refers to themselves ("I", "me", "my"), they are the person being asked about. Be direct and factual.

{conversationContext}

Question: {question}

Answer:
```

`conversationContext` = conversations numbered `Conversation N:` with turns
rendered `{speaker}: {text}`, conversations separated by blank lines.

Memory-based form (`MemoryPromptUtils.buildMemoryBasedPrompt`) — the form a
retrieval-backed memory system uses: a preamble
("You are an assistant helping to answer questions based on retrieved
memories. …"), then the full `getJudgeEvaluationCriteria` block VERBATIM
(the five-point evaluation-criteria text including the good-partial-response
examples and the "I don't know" guidance), then the memories as a numbered
list, then `Question: {question}` / `Answer:`. Empty-memories variant says
"No relevant memories were found for this question. If you cannot answer
based on the available information, please say \"I don't know.\"". Copy all
three blocks byte-exact from `cm_MemoryPromptUtils.scala`.

### B2. Judge templates (verbatim, by evidence type)

Five templates in `AnsweringEvaluation.scala`, selected by evidence type —
copy each byte-exact from `cm_AnsweringEvaluation.scala`:

1. **DefaultAnsweringEvaluation** (factual): "I will provide you with a
   **Question**, a **Correct Answer**, and a **Model's Response**…" with the
   five Crucial Guidelines; ends `Answer (RIGHT/WRONG):`.
2. **RubricBasedAnsweringEvaluation** (preference / implicit connection):
   rubric satisfaction; ALL criteria required.
3. **TemporalAnsweringEvaluation** (changing/temporal): equivalent time
   expressions accepted; "Off-by-one errors in day counts are NOT
   acceptable".
4. **UserFactsAnsweringEvaluation(evidenceCount)**: single-evidence and
   multi-evidence variants, evidence messages embedded in the prompt.
5. **AbstentionAnsweringEvaluation**: abstention is success; hallucination
   is failure.

### B3. Verdict rule (verbatim semantics)

Judge response → trim → lowercase. Contains "right" AND "wrong" → ambiguous
→ **false** (with a warning). Contains "right" only → true. Contains
"wrong" only → false. Neither → invalid response → retry (bounded); a run
out of retries yields no verdict (question unscored, counted as such).
Official default judge model: Gemini Flash; the judge identity is recorded.

### B4. Accuracy

Per-question binary from the verdict. Aggregate: accuracy per evidence type,
per evidence count (the official results are reported per
`<n>_evidence` file), and overall; counts alongside every mean.

## C. Release 1.1 lane mapping

| Published contract | Spec-lane contract | Deterministic companion lane |
|---|---|---|
| k = 1, 5, 10, 25, 50 for nDCG, MAP, Recall, Precision, and MRR; macro by subset and then across subsets | `lmeb-spec` computes the complete grid and both aggregation levels | `convomem` reports its fixed retrieval guard separately |
| R_cap@k with `None` propagation and five-decimal macro average | `lmeb-spec` applies §A3 verbatim | Not part of the companion metric set |
| With-instruction and without-instruction settings | `lmeb-spec` runs both verbatim strings and records the setting | No instruction axis |
| ConvoMem answer and judge rules in §§B1–B4 | `convomem-spec` uses the memory-answer prompt, evidence-type judge template, and verdict rule through the BYOAI seams | Retrieval evidence only; no judged-answer claim |
| `skip_first_result` and `ignore_identical_ids` switches | Exposed as options and defaulted off | Not part of the companion lane |
