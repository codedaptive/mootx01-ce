#!/usr/bin/env bash
# judge-codex.sh — --judge-cmd backend over the Codex CLI, non-interactive.
# Contract: prompt on stdin, reply on stdout, exit 0. The sandbox is
# read-only and cwd is neutral so the "agent" is reduced to a Q&A model;
# judging must never execute model-suggested commands with side effects.
# Judge identity: `codex --version` + JUDGE_CODEX_MODEL in JUDGE_IDENTITY.txt.
set -euo pipefail
cd /tmp
# --output-last-message: codex's stdout carries progress chrome ("tokens
# used" etc); the judged reply must be ONLY the model's final message.
OUT="$(mktemp /tmp/judge-codex.XXXXXX)"
trap 'rm -f "$OUT"' EXIT
codex exec --sandbox read-only --skip-git-repo-check \
  ${JUDGE_CODEX_MODEL:+--model "$JUDGE_CODEX_MODEL"} \
  --output-last-message "$OUT" - >/dev/null 2>&1
cat "$OUT"
