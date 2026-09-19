---
title: Judge Phase Operations
release: "1.1"
date: 2026-08-28
description: Deferred-judge procedure, batching contract, resume behavior, and self-test for official benchmark protocols.
---

# Judge Phase Operations

The judge phase turns a protocol dump into scored verdicts. The supported
operator surface is the deferred-judging sequence in `BENCHMARK_RUN_BOOK.md`
§3.6 and §8. This document defines batching, canary sizing, resume behavior,
and the low-level script interface used by that sequence.

Run commands from `benchmarks/`.

---

## Cost model: sessions, not questions

Every judge-cmd invocation is a CLI session — one context window, one tool
startup cost, one connection overhead. Judging 500 questions one at a time
means 500 sessions. Batching 25 questions per session means 20 sessions.

`judge-sessions.py` opens **one session per batch**, never one per question.
With the default batch size of 25, a 500-question dump runs 20 sessions
regardless of which judge model you use. Run `--canary` first to measure
how long one batch takes and project the full run before committing.

---

## Step 1: Dump judge inputs

Run the required spec lane with deferred judging enabled:

```sh
MOOT_BENCH_ANSWER_CMD="…" make measure-<protocol>-spec SCALE=<scale> DUMP=1
```

The target writes section-formatted JSONL under
`results/judge-dumps/<run-id>/`. Each file begins with a `type:header` record;
question records carry `question_id` and either `anscheck_prompt` or
`judge_prompt`. Preserve the dump directory with the run evidence.

For direct script operation, select the JSONL file for the protocol section
and pass it as `--inputs` in Steps 2 and 3.

---

## Step 2: Canary

Always run canary before a full judging pass. Canary runs exactly one batch,
measures throughput, and exits without writing any verdicts.

```
python3 scripts/judge-sessions.py \
    --inputs results/judge-dumps/<run-id>/<section>.jsonl \
    --judge-id my-judge \
    --judge-cmd "claude -p --model claude-sonnet-4-6" \
    --out ./judged \
    --canary
```

Example output:

```
--- Canary result for judge-id=my-judge ---
  Batch size       : 25 questions
  Batch payload    : 42,817 bytes
  Verdicts found   : 25
  Batch elapsed    : 47.2s
  Throughput       : 0.53 questions/sec

  Total questions  : 500
  Total batches    : 20
  Est. input size  : 856,340 bytes (0.8 MB)
  Projected runtime: 15.7 min (944s)
```

Adjust `--batch-size` if the projected time is too long or if a judge model
has a context-window limit that forces smaller batches.

---

## Step 3: Judge

Run the full judging pass for each judge-input section. Write the outputs into
the originating dump directory so the consume step can discover them:

- `verdicts-<judge-id>.jsonl` — one JSON line per answered question
- `misses-<judge-id>.jsonl` — question lines not answered (valid as a new
  `--inputs` for a follow-up pass targeting the missed questions only)
- `judge-<judge-id>.log` — per-batch timing and retry log

```
python3 scripts/judge-sessions.py \
    --inputs results/judge-dumps/<run-id>/<section>.jsonl \
    --judge-id my-judge \
    --judge-cmd "claude -p --model claude-sonnet-4-6" \
    --out results/judge-dumps/<run-id>
```

The script retries each batch once if it yields fewer than 80 % of expected
verdicts. Stragglers go to `misses-<judge-id>.jsonl` for a targeted re-run.

Verdict schema (feeds the benchmarker consume path directly):

```json
{
  "question_id": "gpt4_2ba83207",
  "verdict": "yes",
  "judge_id": "my-judge",
  "batch": "batch-00",
  "command": "claude -p --model claude-sonnet-4-6",
  "attempts": 1,
  "timestamp": "2026-08-21T17:30:00Z"
}
```

### judge-cmd examples

The judge-cmd reads the full batch payload on stdin and writes text on
stdout. The script extracts JSON objects from the output leniently, so prose
around the JSON is tolerated.

**Claude via claude CLI:**
```
--judge-cmd "claude -p --model claude-sonnet-4-6"
```

**OpenAI Codex CLI:**
```
--judge-cmd "codex exec --skip-git-repo-check -m gpt-5.6-sol -"
```

**Grok via a stdin wrapper script** (the wrapper reads stdin, calls the Grok
API, writes the response to stdout):
```
--judge-cmd "/path/to/grok-stdin.sh"
```

**Local model via Ollama:**
```
--judge-cmd "ollama run llama3"
```

Any command that reads a text prompt on stdin and writes text on stdout
works. The model does not need to output clean JSON; the extractor finds
JSON objects anywhere in the output.

### Resuming a partial run

The script appends to `verdicts-<judge-id>.jsonl` and skips any
`question_id` already present. To resume after an interruption, re-run the
same command without changes. To target only missed questions, pass the
misses file:

```
python3 scripts/judge-sessions.py \
    --inputs results/judge-dumps/<run-id>/misses-my-judge.jsonl \
    --judge-id my-judge \
    --judge-cmd "claude -p --model claude-sonnet-4-6" \
    --out results/judge-dumps/<run-id>
```

---

## Step 4: Consume

Consume the dump directory and fold its verdicts into the originating report:

```sh
MOOT_BENCH_JUDGE_CMD="…" \
make judge-batch DUMPS=results/judge-dumps/<run-id>
```

`judge-batch` writes verdicts beside the dumps, writes per-question scores and
aggregate metrics, and updates the report's `judged_count`.

---

## Self-test

Verify the script without any model calls:

```
python3 scripts/judge-sessions.py self-test
```

The self-test runs a 5-question synthetic fixture through a mock judge
(a small inline Python script that returns valid verdict JSON) and asserts
the full verdict schema is correct. Output: `self-test PASSED`.

---

## Reference

- Operator commands: `BENCHMARK_RUN_BOOK.md` §8
- Script: `scripts/judge-sessions.py`
- Dump format: JSONL, type:header first line, question lines with
  `anscheck_prompt` or `judge_prompt` and `question_id`
- Verdict schema fields: `question_id`, `verdict`, `judge_id`, `batch`,
  `command`, `attempts`, `timestamp`
- Default batch size: 25 (one session per 25 questions)
- Default per-batch timeout: 600 s
- Retry threshold: fewer than 80 % verdicts in the first attempt triggers
  one retry; remaining misses go to the misses file
