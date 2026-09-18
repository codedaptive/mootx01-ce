#!/usr/bin/env bash
# judge-omlx.sh — a --judge-cmd backend backed by a LOCAL OpenAI-compatible
# model server (oMLX on Apple Silicon by default).
#
# Contract (see LongMemEvalJudge.swift): read a prompt on stdin, write the
# model's reply on stdout, exit 0. Any command satisfying that contract works
# as a judge; this one exists so judged runs are reproducible and cost
# nothing, and so no vendor AI SDK enters the repo (BYOAI posture).
#
# Usage:
#   judges/judge-omlx.sh                       # reads prompt on stdin
#   JUDGE_MODEL=gemma-4-12B-it-qat-mxfp8 judges/judge-omlx.sh
#
# With the harness:
#   mcp-benchmarker longmemeval ... \
#     --judge-cmd "benchmarks/judges/judge-omlx.sh" \
#     --judge-grading verdict
#
# Environment:
#   JUDGE_URL    OpenAI-compatible chat-completions endpoint.
#                Default http://localhost:8000/v1/chat/completions
#   JUDGE_MODEL  Model id as the server names it. Default gemma-4-12B-it-mxfp4.
#   JUDGE_TEMP   Sampling temperature. Default 0 — a judge must be as close to
#                deterministic as the server allows, or the same run scores
#                differently on replay.
#   JUDGE_MAX_TOKENS  Reply cap. Default 256: answers are short, and the
#                verdict step needs exactly one word.
#
# The model identity IS part of the measurement. Record JUDGE_MODEL in any
# result that carries a judged number — a cell judged by a different model is
# a different cell.

set -euo pipefail

URL="${JUDGE_URL:-http://localhost:8000/v1/chat/completions}"
MODEL="${JUDGE_MODEL:-gemma-4-12B-it-mxfp4}"
TEMP="${JUDGE_TEMP:-0}"
MAX_TOKENS="${JUDGE_MAX_TOKENS:-256}"

PROMPT="$(cat)"

# Build the request with a JSON parser, never string interpolation: prompts
# carry quotes, newlines, and backslashes verbatim from the dataset.
REQUEST="$(PROMPT="$PROMPT" MODEL="$MODEL" TEMP="$TEMP" MAX_TOKENS="$MAX_TOKENS" \
  python3 -c '
import json, os
print(json.dumps({
    "model": os.environ["MODEL"],
    "messages": [{"role": "user", "content": os.environ["PROMPT"]}],
    "temperature": float(os.environ["TEMP"]),
    "max_tokens": int(os.environ["MAX_TOKENS"]),
}))')"

RESPONSE="$(curl -sS -X POST "$URL" \
  -H "Content-Type: application/json" \
  ${OMLX_API_KEY:+-H "Authorization: Bearer $OMLX_API_KEY"} \
  --data-binary "$REQUEST")"

# Extract the reply. A malformed or error response exits non-zero so the
# harness records a judge failure for that question instead of scoring the
# error text as an answer.
RESPONSE="$RESPONSE" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ["RESPONSE"])
except json.JSONDecodeError:
    sys.stderr.write("judge-omlx: non-JSON response: "
                     + os.environ["RESPONSE"][:200] + "\n")
    sys.exit(1)
if "error" in d:
    sys.stderr.write("judge-omlx: server error: " + json.dumps(d["error"])[:200] + "\n")
    sys.exit(1)
try:
    sys.stdout.write(d["choices"][0]["message"]["content"].strip())
except (KeyError, IndexError, TypeError):
    sys.stderr.write("judge-omlx: unexpected response shape: "
                     + json.dumps(d)[:200] + "\n")
    sys.exit(1)
'
