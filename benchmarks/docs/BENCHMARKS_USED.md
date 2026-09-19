---
release: "1.1"
version: v0.2
date: 2026-09-09
description: >
  Benchmarks Used — for each benchmark in the suite: its published origin
  and corpus source, what it measures, the role mootx01 plays in delivering
  the pass/fail, and how mootx01 effectiveness is measured for the portion
  of the result it is accountable for. Companion to BENCHMARK_PROTOCOL.md.
changelog:
  - version: v0.2
    date: 2026-09-09
    description: "Remove stale adornment-minter/adornment table references from payload-economics section (schema 19); use activation-arm vocabulary."
  - version: v0.1
    date: 2026-08-28
    description: "Initial document."
---

# Benchmarks Used

A score produced with an answering model measures the full pipeline. The
result names every answering and judging model. A score with no model in the
scoring path measures MOOTx01 retrieval directly. Suite-native turn-efficiency
and context-efficiency metrics are reported beside official metrics and are
never merged with them.

## External dataset keys and provenance

The benchmark commands use four external dataset keys. Each key maps to a published benchmark and its upstream corpus.

### `lme-s` — LongMemEval-s

LongMemEval-s is the small-haystack variant of **LongMemEval**. Wu et al. introduced the benchmark in *LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory* (arXiv:2410.10813, ICLR 2025).

- Benchmark code and original data: `github.com/xiaowu0162/LongMemEval`
- Corpus used here: `xiaowu0162/longmemeval-cleaned` on Hugging Face
- Fetch command: `scripts/fetch-longmemeval.sh`
- Local fixture: `benchmarks/fixtures/longmemeval/data/`

### `locomo` — LoCoMo

**LoCoMo** stands for **Long Conversational Memory**. Jang et al. released it with *CONVERSATION CHRONICLES: Towards Rich and Consistent Conversational Agents* (arXiv:2402.17753, ACL 2024).

- Corpus and evaluation code: `github.com/snap-research/locomo`
- Fetch command: `scripts/fetch-locomo.sh`
- Local fixture: `benchmarks/fixtures/locomo/data/locomo10.json`

### `convomem` — ConvoMem, with LMEB and judged-QA protocols

**ConvoMem** is the conversation corpus. This benchmark key supports two published protocols over that corpus:

- **LMEB retrieval.** Chen et al. published LMEB with *KaLM-Embedding: Superior Training Data Brings A Stronger Embedding Model* (arXiv:2603.12572). The ConvoMem subset and retrieval evaluation code are in `github.com/KaLM-Embedding/LMEB`, under `Dialogue/ConvoMem`. The benchmark is also hosted on Hugging Face as `KaLM-Embedding/LMEB`.
- **ConvoMem judged QA.** Yoon et al. published the answer-generation protocol with *ConvoMem: Benchmarking Conversational Memory Agents* (arXiv:2511.10523). Its evaluation code is in `github.com/SalesforceAIResearch/ConvoMem`.
- Fetch command: `scripts/fetch-lmeb.sh`
- Local fixture: `benchmarks/fixtures/lmeb/data/ConvoMem/`

### `membench` — MemBench

Li et al. introduced **MemBench** in *MemBench: Evaluating LLM Memory Systems* (arXiv:2506.21605, ACL Findings 2025).

- Corpus and evaluation code: `github.com/import-myself/Membench`
- Fetch command: `scripts/fetch-membench.sh`
- Local fixture: `benchmarks/fixtures/membench/MemData/`

---

## LMEB

**Measures:** retrieval accuracy — were the gold documents in the top-K
results for each query (recall@k against the official qrels answer key).
Fully deterministic; no AI in the loop.

**moot's role in pass/fail:** total. moot ingests the corpus and answers
each query with its ranked candidates; the score is a direct read of
whether moot located the correct memories.

**mootx01 effectiveness measure:** official recall@k, attributable to the
retrieval system.

---

## LoCoMo

**Measures:** answer generation over conversational history, scored by the
published stemmed token-F1 procedure for each official QA category.

**moot's role in pass/fail:** enabler. MOOTx01 ingests the two-speaker
sessions and retrieves context; the named answering model produces the answer,
and the scorer is mechanical.

**mootx01 effectiveness measure:** the official per-category token-F1 with the
answering model named, plus the deterministic evidence-retrieval guard defined
in `BENCHMARK_METHOD.md` §7.3.

---

## LongMemEval

**Measures:** end-to-end question answering over long chat histories —
multi-session, temporal-reasoning, and knowledge-update questions. An
answering AI produces a short answer; the official judge checks whether
the gold answer is contained in it.

**moot's role in pass/fail:** enabler. moot holds the seeded history and
serves the candidate surface the answering AI uses to locate evidence
across memories (multiple calls permitted), then hydrates only the
records the AI picks. moot never answers; it determines how quickly and
cheaply the right evidence can be assembled.

**mootx01 effectiveness measure:** three-part, reported together —
1. pipeline accuracy (official metric) WITH the answering model named;
2. calls per question (suite-native turn efficiency); and
3. tokens per question consumed from MOOTx01 payloads (suite-native context
   efficiency).
Moot-attributable movement is isolated by A/B on the moot side only:
same answering model, same questions, candidate-surface variants (e.g.
zero active arms vs a named active-arm set) — any delta belongs to moot.

---

## ConvoMem

**Measures:** one-shot answering over accumulated conversations — the
answering AI gets ONE broad pull from the memory system (or, in the
comparison arm, the entire raw history) and answers; a judge model
grades against the gold evidence per the official rubric.

**moot's role in pass/fail:** enabler, single-shot. The whole memory-arm
outcome rides on the one payload moot returns for the question. The
official full-context arm is the built-in control: the same answering
model with everything.

**mootx01 effectiveness measure:** the accuracy difference between the memory
arm and full-context control, reported with their token ratio. Answering and
judge models are named beside every figure.

---

## MemBench

**Measures:** agent-memory questioning with a BYOAI answering model and
mechanical (no-judge) grading; the official §6 capacity walk re-scores
under stepped token budgets.

**moot's role in pass/fail:** enabler. Fresh per-item estates (spec
forbids cache reuse), retrieval per question; the answering model reads
moot's payload; grading is mechanical.

**mootx01 effectiveness measure:** pipeline accuracy with the answering
model named, plus the §6 capacity curve — score as a function of token
budget — which is the one OFFICIAL surface that prices moot's context
efficiency directly. Moot-side A/B (candidate-surface variants, same
answerer) isolates moot-attributable deltas.

---

## MOOTx01-authored benchmarks

Each benchmark has a standalone definition under `benchmarks/` containing the
contract required to implement it against another product.

### Supersession — [definition](benchmarks/supersession.md)

**Measures:** whether the current version of a changed fact outranks its
superseded versions, on one database holding the accumulated history.
Deterministic.

**moot's role in pass/fail:** total — filing, supersession lifecycle,
and ranking are all moot.

**mootx01 effectiveness measure:** the per-row current-over-superseded
rank score, unshared.

### Gauntlet — [definition](benchmarks/gauntlet.md)

**Measures:** retrieval of known rows buried under five named classes of
adversarial distractor, scored per row. Deterministic.

**moot's role in pass/fail:** total — retrieval quality under authored
adversarial pressure.

**mootx01 effectiveness measure:** per-row retrieval score by distractor
class, unshared; class deltas localize which distractor defeats recall.

### Journey — [definition](benchmarks/journey.md)

**Measures:** the cost of reaching a correct answer across a multi-step
agent sequence, as four integer counts. The suite's native
cycle-efficiency (axis C) instrument.

**moot's role in pass/fail:** enabler — each step consumes a moot
payload; the counts price how many steps/calls moot's surfaces require.

**mootx01 effectiveness measure:** the four counts themselves; deltas
across candidate-surface variants (same sequence) are moot-attributable.

### Timing — [definition](benchmarks/timing.md)

**Measures:** read, write, ingest, and cycle latency on a single
database at fixed row count, with and without encryption at rest.

**moot's role in pass/fail:** total — pure product latency.

**mootx01 effectiveness measure:** the latency figures, unshared.

### Storage Matrix — [definition](benchmarks/posture-matrix.md)

**Measures:** retrieval across encryption-at-rest and storage-backend
postures, data byte-identical, one database at a time.

**moot's role in pass/fail:** total.

**mootx01 effectiveness measure:** retrieval parity across postures —
any delta is a posture cost, unshared.

### Payload Economics — [definition](benchmarks/payload-economics.md)

**Measures:** the effect of payload shape and activation-arm choice on
evidence carriage and token cost with questions and retrieval held fixed.
Alternative arms use runtime activation over one frozen retrieval result.
The suite's native context-efficiency (axis D) instrument.

**Source corpus:** the frozen `lme-s` questions, gold answers, and
`has_answer` turn annotations. The instrument reuses the selected port's
Form-2 `lme-s` artifact.

**moot's role in pass/fail:** total for the shape under test — the only
variable is what moot renders.

**mootx01 effectiveness measure:** gold-answer presence, evidence hit rate,
and their per-1000-token figures across payload shapes. Evidence figures use
the questions carrying `has_answer` annotations; questions without an
annotation are counted separately and are never converted into misses. This
instrument prices the canonical candidate row (ARIA_MCP_SPEC § 9) and the
active arm context.

### Synthesis Payload — [definition](benchmarks/synthesis-payload.md)

**Measures:** the store-generated digest scored as a fourth payload
shape, on the same figures as Payload Economics.

**Source corpus:** the same frozen `lme-s` questions, gold answers,
`has_answer` turn annotations, and selected port's Form-2 artifact used by
Payload Economics.

**moot's role in pass/fail:** total — the digest is entirely
moot-generated.

**mootx01 effectiveness measure:** the same gold-answer-presence,
evidence-hit, and per-1000-token figures, comparable cell-for-cell with the
other payload shapes.

### Deterministic Alternatives — [definition](benchmarks/deterministic-alternatives.md)

**Measures:** the four judge-free deterministic methods over the public
data sets — each defined beside the published protocol it parallels.

**moot's role in pass/fail:** total — no model anywhere in scoring.

**mootx01 effectiveness measure:** the deterministic scores, unshared;
they exist so movement can be measured without judge cost or judge
noise between official runs.
