---
title: LoCoMo — Official Evaluation Protocol (verbatim extraction)
release: "1.1"
date: 2026-08-28
description: The documented LoCoMo QA evaluation protocol, extracted verbatim from snap-research/locomo task_eval, for the locomo-spec lane.
---

# LoCoMo — Official Evaluation Protocol

Source of truth: `snap-research/locomo` @ main, `task_eval/evaluation.py`,
`task_eval/evaluate_qa.py`, `task_eval/evaluation_stats.py`,
`task_eval/gpt_utils.py`. Paper: arXiv 2402.17753 (ACL 2024).

The official QA evaluation is **rule-based**. There is no LLM judge anywhere
in the official scoring path.

## 1. Answer normalization (verbatim)

```python
def normalize_answer(s):
    s = s.replace(',', "")
    def remove_articles(text):
        return regex.sub(r'\b(a|an|the|and)\b', ' ', text)
    def white_space_fix(text):
        return ' '.join(text.split())
    def remove_punc(text):
        exclude = set(string.punctuation)
        return ''.join(ch for ch in text if ch not in exclude)
    def lower(text):
        return text.lower()
    return white_space_fix(remove_articles(remove_punc(lower(s))))
```

Order of operations: strip commas from the raw string, lowercase, remove
punctuation (Python `string.punctuation` set, i.e. `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`),
remove the articles `a`, `an`, `the`, `and` as whole words, collapse
whitespace.

## 2. Token metrics (verbatim semantics)

All token metrics run over **Porter-stemmed** tokens of the normalized
strings. The upstream code constructs `ps = PorterStemmer()` without a mode,
so the spec lane implements NLTK's default `NLTK_EXTENSIONS` behavior in both
ports rather than the deprecated original-paper mode. Shared conformance
vectors are generated and checked against NLTK 3.9.2.

**Single-answer F1:**

```python
def f1_score(prediction, ground_truth):
    prediction_tokens = [ps.stem(w) for w in normalize_answer(prediction).split()]
    ground_truth_tokens = [ps.stem(w) for w in normalize_answer(ground_truth).split()]
    common = Counter(prediction_tokens) & Counter(ground_truth_tokens)
    num_same = sum(common.values())
    # precision = num_same / len(prediction_tokens)
    # recall    = num_same / len(ground_truth_tokens)
    # f1 = 2*p*r/(p+r), 0 when num_same == 0
```

Multiset intersection (Counter &), not set intersection.

**Multi-answer F1 (category 1):** the prediction is split on commas into
candidate answers, the ground truth on commas into gold parts; score is the
mean over gold parts of the max F1 of any prediction part against that gold
part:

```python
def f1(prediction, ground_truths):
    predictions = [p.strip() for p in prediction.split(',')]
    ground_truths = [g.strip() for g in str(ground_truths).split(',')]
    return np.mean([max([f1_score(prediction, gt) for prediction in predictions])
     for gt in ground_truths])
```

**Exact match:** `set(prediction.split()) == set(ground_truth.split())` over
normalized strings (order-independent token-set equality).

**ROUGE (secondary):** stemmed-normalized strings; the official function
returns `scores["rouge-1"]["f"]` (unigram F).

## 3. Per-question scoring (verbatim)

```python
if type(line[eval_key]) == list:
    answer = line['answer']
else:
    answer = str(line['answer'])
if line['category'] == 3:
    answer = answer.split(';')[0].strip()

output = line[eval_key]

if line['category'] in [2, 3, 4]:
    all_ems.append(f1_score(output, answer))
elif line['category'] in [1]:
    all_ems.append(f1(output, answer))
elif line['category'] in [5]:
    if 'no information available' in output.lower() or 'not mentioned' in output.lower():
        all_ems.append(1)
    else:
        all_ems.append(0)
else:
    raise ValueError
```

- Category 3 (temporal): only the first `;`-separated segment of the gold
  answer is scored.
- Category 5 (adversarial): binary — 1 iff the model output contains the
  substring `no information available` or `not mentioned` (case-insensitive).
  **Category 5 is scored, not excluded.** All 1,986 questions are in scope.

## 4. Evidence recall (verbatim)

Computed per question when the record carries a retrieved-context field and
the question has evidence:

```python
if eval_key + '_context' in line and len(line['evidence']) > 0:
    if line[eval_key + '_context'][0].startswith('S'):
        sessions = [e[1:] for e in line[eval_key + '_context']]
        recall_acc = float(sum([ev.split(':')[0][1:] in sessions for ev in line["evidence"]]))/len(line['evidence'])
    else:
        recall_acc = float(sum([ev in line[eval_key + '_context'] for ev in line["evidence"]]))/len(line['evidence'])
    all_recall.append(recall_acc)
else:
    all_recall.append(1)
```

Two official forms, keyed by whether context entries start with `S`:
- **Session form:** context entries like `S3`; an evidence item `D3:12`
  counts if its session number (`3`) is among the retrieved session numbers.
- **Dia form:** membership of the evidence `dia_id` in the retrieved list.

A question with no evidence, or a record with no context field, appends
recall 1.

## 5. Aggregation (verbatim semantics)

Per category: `acc_counts[category] += metric_value`, accuracy per category
= `round(acc_counts[k]/total_counts[k], 3)`, reported in category order
`[4, 1, 2, 3, 5]`. Overall = `round(total_correct/total_questions, 3)` over
all categories. When RAG mode is on, mean recall per category is reported
the same way.

## 6. Answer generation (verbatim prompts)

Conversation preamble:

```
Below is a conversation between two people: {} and {}. The conversation takes place over multiple days and the date of each conversation is wriiten at the beginning of the conversation.
```

(the typo `wriiten` is in the official prompt — reproduce verbatim.)

Context format: sessions in chronological order, each headed
`DATE: [timestamp] CONVERSATION:`, turns rendered as
`[speaker] said, "[text]"` with `and shared [caption]` appended for images.

Per-question prompts:

- Categories 1–4:
  `Based on the above context, write an answer in the form of a short phrase for the following question. Answer with exact words from the context whenever possible. Question: {} Short answer:`
- Category 5:
  `Based on the above context, answer the following question. Question: {} Short answer:`

## 7. Release 1.1 lane mapping

| Published contract | `locomo-spec` contract | Deterministic `locomo` lane |
|---|---|---|
| Generated short answers scored by per-category F1 | Produces one answer per question and scores it with §§2–3 | Scores ranked evidence turns only |
| All 1,986 questions; category 5 uses the abstention rule | Includes all questions and applies the category-5 rule | Covers the 1,536 questions with labeled retrievable evidence |
| Evidence recall in session or dialogue form | Reports §4 evidence recall beside answer F1 | Reports recall@k and MRR over ranked dialogue IDs |
| Category-3 semicolon truncation and category-1 multi-answer F1 | Applies both §3 rules | No answer scoring |
| Porter stemming and article-stripped normalization | Implements §§1–2 in both ports with conformance vectors | No answer normalization |
