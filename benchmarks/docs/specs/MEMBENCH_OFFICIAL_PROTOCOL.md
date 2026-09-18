---
title: MemBench — Official Evaluation Protocol (verbatim extraction)
release: "1.1"
date: 2026-08-28
description: The documented MemBench evaluation protocol, extracted verbatim from import-myself/Membench benchmarks/ sources, for the membench-spec lane.
---

# MemBench — Official Evaluation Protocol

Source of truth: `import-myself/Membench` @ main —
`benchmarks/env/Membenenv.py`, `benchmarks/MembenchAgent.py`,
`benchmarks/memory/CommonMemory.py` (quoted verbatim). Paper: arXiv 2506.21605, ACL Findings 2025.

Three measured aspects: **effectiveness** (multiple-choice accuracy + memory
recall), **efficiency** (write/read wall time), **capacity** (accuracy as a
function of context tokens).

## 1. Dataset

`MemData/{FirstAgent,ThirdAgent}/<category>.json`. Top-level object of topic
keys → arrays of items `{tid, message_list, QA}`. Turns carry
`sid` (GLOBAL sequential turn id across the item's sessions),
`user_message`, `assistant_message`, `time`, `place`. QA carries `qid`,
`question`, `answer`, `target_step_id` (pairs `[global_sid, session_idx]`;
`session_idx` is redundant verification data — the global sid alone uniquely
identifies the evidence turn), `choices` (A/B/C/D), `ground_truth` (letter),
`time`.

## 2. Interaction protocol (verbatim)

Initial instruction (official constant name `INITIAL_INSTRUACTION`, typo and
all):

```
Please help me record the following information. If there are any questions within the information, please help me answer them.
```

Then one env step per `message_list` entry; the agent STORES each message
into memory with a step-prefix format:

- string message: `"{step}[|]{message}"`
- dict message: `"{step}[|]'user': {user}; 'agent': {agent}"`

where `step` is the env's 1-based `step_id` counter at the time of storage.
After the last message, the env emits the QA observation
`{question, time, choices}`.

## 3. Answer generation (verbatim prompts)

Memory context: `memory.recall('%s (%s)' % (question, time))` — the recall
query is the question text, space, `(time)`.

**FirstAgent (Participation):**

```
Please answer the following question based on past memories of your'conversation with the user.
Past memory: {memory}
Question: (current time is {time}) {question}
Choices:
A. {choice_A}
B. {choice_B}
C. {choice_C}
D. {choice_D}
Please output the correct option for the question, only one corresponding letter, without any other messages.
Example: D
```

**ThirdAgent (Observation):**

```
Please answer the following question based on past memories of the user's messages.
Past memory: {memory}
Question: (current time is {time}) {question}
Choices:
A. {choice_A}
B. {choice_B}
C. {choice_C}
D. {choice_D}
Please output the correct option for the question, only one corresponding letter, without any other messages.
Example: D
```

(The typo `your'conversation` is official — reproduce verbatim.)

The official answering call constrains output to a single letter via a JSON
schema `{"choice": enum ["A","B","C","D"]}` (strict), parsed as
`json.loads(res)['choice']`; the fallback path normalizes with
`s.replace(" ", "").replace("\n", "")`.

**Correctness:** `action['response'] == QA['ground_truth']` — exact string
equality of the letter. Reward 1/0 per item; accuracy = mean.

## 4. Memory recall metric (verbatim)

Retrieved indices: `memory.retri(query)` returns, per retrieved memory,
`int(stored_text.split('[|]')[0])` — the step id parsed from the §2 storage
prefix. Query format: `'{} ({})'.format(question, time)` (identical content
to the recall query).

```python
def get_recall(res, std):
    if res == None:
        return 0
    res = list(set(res))
    std_set = set(std)
    ct = 0
    for step_id in res:
        if step_id in std:
            ct += 1
    return ct/len(std_set)
```

Deduplicate retrieved ids; count how many are members of the target list;
divide by the number of DISTINCT targets. `std` is the item's
`target_step_id` list. **Shape note (mechanical resolution):** the official
comparison is int-vs-element membership; where the dataset stores pairs
`[global_sid, session_idx]`, the target flattens to its global sid (element
0) — the sid is the unique evidence-turn identifier and `session_idx` is
documented as redundant (§1). `step_cap` likewise uses
`target_step_id[-1]`'s sid as the last-evidence step.

## 5. Efficiency (verbatim semantics)

Per store: wall time around the `memory.store` call (`write_time` list).
Per question: wall time around the `memory.recall` call (`read_time` list).
`time.perf_counter()` deltas, reported as lists/means per run.

## 6. Capacity (verbatim semantics)

`step_cap` variant: messages ingest as §2 while a running token count
accumulates (official tokenizer: tiktoken `cl100k_base`, counting user +
agent strings per message). From the step AFTER the last evidence step
(`target_step_id[-1]`), the QA is asked at EVERY subsequent step; each
answer yields `(token_count_at_ask, correct)`; the item terminates at the
end of `message_list`. Result: accuracy as a function of accumulated
context tokens. The extended-length datasets (`data2test`, 0–10k and 100k)
drive this aspect.

## 7. Release 1.1 lane mapping

| Published contract | `membench-spec` contract | Deterministic `membench` lane |
|---|---|---|
| Answering model chooses a letter from the §3 prompt; exact-letter equality | Uses the prompt byte-exact through the BYOAI answer seam and parses the letter per §3 | Scores evidence retrieval without an answering model |
| Step-prefixed `{step}[|]...` ingest format | Stores the §2 format and preserves the sid-to-step mapping | Uses the estate projection defined for deterministic evidence retrieval |
| `get_recall` over retrieved step IDs | Applies §4 verbatim | Reports recall@k and MRR over ranked evidence IDs |
| Query format `question (time)` | Uses the official query format for recall and answer generation | Uses its declared retrieval query format |
| Store and recall wall-time metrics | Records §5 timers per run | Reports only the timing fields defined by its companion method |
| Capacity walk by `step_cap` and `cl100k_base` tokens | Applies §6 with the pinned `cl100k_base` vocabulary artifact through the token-counter seam | No capacity claim |
