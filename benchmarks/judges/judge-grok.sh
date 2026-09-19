#!/usr/bin/env bash
# judge-grok.sh — --judge-cmd backend over the Grok CLI. Contract:
# prompt on stdin, reply on stdout, exit 0.
#
# KNOWN EXPOSURE (documented, not silent): grok 0.2.118 has no stdin
# prompt mode — `-p/--single` requires the prompt as an argv value, and
# a literal "-" is treated as the prompt text, not a stdin sentinel.
# Process arguments are visible to other LOCAL users (ps, /proc
# cmdline) while the CLI runs, and judge prompts carry hydrated memory
# content. Run judged grok legs only on single-user machines until the
# CLI grows a stdin mode; re-check on grok upgrades. claude and codex
# wrappers are stdin-clean and unaffected.
#
# Judge identity: `grok --version` + account default model + run date
# in JUDGE_IDENTITY.txt.
set -euo pipefail
PROMPT="$(cat)"
cd /tmp
exec grok --single "$PROMPT" --output-format plain
