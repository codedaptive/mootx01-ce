---
title: LongMemEval — Official Evaluation Protocol (verbatim extraction)
release: "1.1"
date: 2026-08-28
description: The documented LongMemEval QA evaluation protocol, extracted verbatim from xiaowu0162/LongMemEval src/evaluation, for the lme-spec lane.
---

# LongMemEval — Official Evaluation Protocol

Source of truth: `xiaowu0162/LongMemEval` @ main,
`src/evaluation/evaluate_qa.py` and `src/evaluation/print_qa_metrics.py`
(quoted verbatim, at quote-level fidelity).
Paper: arXiv 2410.10813 (ICLR 2025).

The official QA metric is **LLM-judged accuracy**: an external judge model
(officially `gpt-4o-2024-08-06`) grades each hypothesis with a per-type
"anscheck" prompt, yes/no.

## 1. Inputs

- **Reference file:** the dataset JSON; each entry carries `question_id`,
  `question_type`, `question`, `answer`. Variants: `longmemeval_s` (~40
  sessions), `longmemeval_m` (~500 sessions), `longmemeval_oracle`
  (evidence sessions only). 500 instances each.
- **Hypothesis file:** JSONL, one line per question:
  `{"question_id": ..., "hypothesis": ...}` — the system-under-test's
  answer text.
- **Abstention questions** carry `_abs` in `question_id` (question_type
  suffixed `_abs`). They ARE evaluated for QA accuracy (with the abstention
  prompt). They are skipped only in retrieval metrics.

## 2. Judge prompts (verbatim — reproduce byte-exact)

Selection: `abstention = '_abs' in question_id`. If not abstention, select on
`question_type`:

**single-session-user, single-session-assistant, multi-session:**

```
I will give you a question, a correct answer, and a response from a model. Please answer yes if the response contains the correct answer. Otherwise, answer no. If the response is equivalent to the correct answer or contains all the intermediate steps to get the correct answer, you should also answer yes. If the response only contains a subset of the information required by the answer, answer no. \n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only.
```

**temporal-reasoning:**

```
I will give you a question, a correct answer, and a response from a model. Please answer yes if the response contains the correct answer. Otherwise, answer no. If the response is equivalent to the correct answer or contains all the intermediate steps to get the correct answer, you should also answer yes. If the response only contains a subset of the information required by the answer, answer no. In addition, do not penalize off-by-one errors for the number of days. If the question asks for the number of days/weeks/months, etc., and the model makes off-by-one errors (e.g., predicting 19 days when the answer is 18), the model's response is still correct. \n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only.
```

**knowledge-update:**

```
I will give you a question, a correct answer, and a response from a model. Please answer yes if the response contains the correct answer. Otherwise, answer no. If the response contains some previous information along with an updated answer, the response should be considered as correct as long as the updated answer is the required answer.\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only.
```

**single-session-preference:**

```
I will give you a question, a rubric for desired personalized response, and a response from a model. Please answer yes if the response satisfies the desired response. Otherwise, answer no. The model does not need to reflect all the points in the rubric. The response is correct as long as it recalls and utilizes the user's personal information correctly.\n\nQuestion: {}\n\nRubric: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only.
```

**abstention (any type, `_abs` in question_id):**

```
I will give you an unanswerable question, an explanation, and a response from a model. Please answer yes if the model correctly identifies the question as unanswerable. The model could say that the information is incomplete, or some other information is given but the asked information is not.\n\nQuestion: {}\n\nExplanation: {}\n\nModel Response: {}\n\nDoes the model correctly identify the question as unanswerable? Answer yes or no only.
```

`{}` slots fill in order with (question, answer, hypothesis). The `\n` are
real newlines. Any other question_type raises an error
(`NotImplementedError` upstream).

## 3. Judge call parameters (verbatim)

```python
{'model': metric_model, 'messages': [{"role": "user", "content": prompt}],
 'n': 1, 'temperature': 0, 'max_tokens': 10}
```

Verdict parse: `label = 'yes' in eval_response.lower()` after
`.strip()`. Stored as
`entry['autoeval_label'] = {'model': metric_model, 'label': label}`.

## 4. Aggregation (verbatim semantics, print_qa_metrics.py)

Fixed type list:
`['single-session-user', 'single-session-preference', 'single-session-assistant', 'multi-session', 'temporal-reasoning', 'knowledge-update']`
(the reference's `question_type` — abstention instances aggregate under
their base type via the reference file's type field).

- Per-type accuracy: mean of binary labels, rounded 4 decimals, with count.
- **Task-averaged accuracy:** mean of the six per-type means.
- **Overall accuracy:** mean over all instances.
- **Abstention accuracy:** mean over instances with `_abs` in question_id,
  with count.
- The official aggregator asserts the judge model is `gpt-4o-2024-08-06`;
  the spec lane records judge model identity per verdict and reports it.

## 5. Retrieval metrics (paper protocol)

Recall@k / NDCG@k over the retrieval unit, **always skipping abstention
instances** (they have no ground-truth location).

## 6. Release 1.1 lane mapping

| Published contract | `lme-spec` contract | Deterministic `lme-s` lane |
|---|---|---|
| External yes/no judge with §2 prompts, temperature 0, and 10-token limit | Uses the prompts byte-exact through the BYOAI judge and batch seams; verdict follows §3 | No answer judge; scores evidence retrieval |
| All 500 questions, including `_abs` through the abstention prompt | Includes all 500 and records abstention and base-type mapping | Excludes `_abs` only from location metrics because no evidence location exists |
| Task-averaged and abstention aggregation in §4 | Reports the complete §4 aggregation | Reports recall@k and MRR separately |
| One `{question_id, hypothesis}` answer record per question | Emits the official hypothesis shape from the answer path | No hypothesis claim |
| Retrieval metrics omit `_abs` | Reports retrieval metrics with the same omission | Applies the same omission |
