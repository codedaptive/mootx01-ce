#!/usr/bin/env bash
# judge-claude.sh — --judge-cmd backend over the Claude Code CLI in print
# mode. Contract (LongMemEvalJudge.swift): prompt on stdin, reply on
# stdout, exit 0. Q&A only — no tools, no repo context.
#
# The prompt STAYS ON STDIN end to end — `claude -p` reads it there.
# Never lift it into an argv value: process arguments are visible to
# local observers (ps / /proc cmdline) while the CLI runs, and judge
# prompts carry hydrated memory content.
#
# Judge identity: record `claude --version` + JUDGE_CLAUDE_MODEL in the
# run's JUDGE_IDENTITY.txt (reports carry no judge identity by design).
set -euo pipefail
cd /tmp   # neutral cwd: no project context, no CLAUDE.md pickup
exec claude -p ${JUDGE_CLAUDE_MODEL:+--model "$JUDGE_CLAUDE_MODEL"} --tools ""
