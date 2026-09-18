#!/usr/bin/env bash
# judge-apple.sh — --judge-cmd backend over Apple's bundled on-device
# model (FoundationModels, macOS 26+). Contract: prompt on stdin, reply
# on stdout, exit 0; exit 2 = model unavailable (recorded as a judge
# failure, never graded as an answer).
#
# Binary resolution is external-work-root-relative, overridable via
# APPLE_JUDGE_BIN; it builds into external scratch on first use.
#
# Judge identity: "apple-foundationmodels" + `sw_vers -productVersion` —
# the bundled model revs with the OS, not this tool.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/apple-judge"
BENCH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BENCH_ROOT/.." && pwd -P)"
: "${BENCH_WORK_ROOT:?BENCH_WORK_ROOT is required; invoke the judge through the benchmark Makefile}"
BENCH_WORK_ROOT="$(python3 "$BENCH_ROOT/scripts/work-root.py" prepare --repo "$REPO_ROOT" --work "$BENCH_WORK_ROOT")"
SCRATCH="$BENCH_WORK_ROOT/build/apple-judge"
BIN="${APPLE_JUDGE_BIN:-$SCRATCH/release/apple-judge}"
if [ ! -x "$BIN" ]; then
  swift build -c release --package-path "$PKG_DIR" --scratch-path "$SCRATCH" >/dev/null 2>&1 \
    || { echo "judge-apple: cannot build apple-judge at $PKG_DIR" >&2; exit 2; }
  BIN="$SCRATCH/release/apple-judge"
fi
exec "$BIN"
