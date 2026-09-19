#!/usr/bin/env bash
# fetch-membench.sh — download the MemBench dataset from GitHub.
#
# Usage: scripts/fetch-membench.sh [--agent FirstAgent|ThirdAgent]
#
# Downloads all 7 LowLevel category JSON files for the requested agent
# perspective from import-myself/Membench into the external fixture store.
# Dataset files never enter the repository.
#
# License statement: No explicit LICENSE file was found in the import-myself/Membench
# repository as of 2026-08-06. The associated paper (arXiv 2506.21605) indicates
# the dataset is released for research purposes. This download is for INTERNAL
# DIAGNOSTIC use only. Do not use the dataset for commercial purposes without
# consulting the repository for any later-added license.
#
# SPEC-BEFORE-REALITY (verified 2026-08-06):
#   Base URL: https://raw.githubusercontent.com/import-myself/Membench/main/MemData
#   Agents:   FirstAgent, ThirdAgent
#   Files:    simple.json, comparative.json, aggregative.json, conditional.json,
#             knowledge_update.json, post_processing.json, noisy.json
#   Schema:   top-level dict with "roles" key → array of {tid, message_list, QA}
#   Verified: simple.json first item schema, including target_step_id = [[global_sid, session_idx]]
#   Estimate: ~8,500 items across 7 LowLevel categories (from file sizes ~50-350MB total)

set -euo pipefail

AGENT="${1:-FirstAgent}"
# Accept --agent <name> as an alternative to positional arg.
for i in "$@"; do
    if [[ "$i" == "--agent" ]]; then
        shift; AGENT="${1:-FirstAgent}"; break
    fi
done

if [[ "$AGENT" != "FirstAgent" && "$AGENT" != "ThirdAgent" ]]; then
    echo "ERROR: --agent must be 'FirstAgent' or 'ThirdAgent'; got '$AGENT'" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${BENCH_WORK_ROOT:?BENCH_WORK_ROOT is required; run this through make fetch}"
REPO_ROOT="$(cd "$BENCH_ROOT/.." && pwd -P)"
BENCH_WORK_ROOT="$(python3 "$SCRIPT_DIR/work-root.py" prepare --repo "$REPO_ROOT" --work "$BENCH_WORK_ROOT")"
DATA_DIR="$BENCH_WORK_ROOT/fixtures/membench/MemData/$AGENT"
GITHUB_RAW="https://raw.githubusercontent.com/import-myself/Membench/main/MemData/$AGENT"

# LowLevel category files (the paper's main evaluation set, ~8,500 items total).
CATEGORIES=(
    "simple"
    "comparative"
    "aggregative"
    "conditional"
    "knowledge_update"
    "post_processing"
    "noisy"
)

echo "MemBench fetch — agent: $AGENT — target: $DATA_DIR"
mkdir -p "$DATA_DIR"

for CAT in "${CATEGORIES[@]}"; do
    FILENAME="${CAT}.json"
    out="$DATA_DIR/$FILENAME"
    if [[ -f "$out" ]]; then
        echo "  already present: $FILENAME ($(wc -c < "$out") bytes)"
    else
        echo "  downloading $FILENAME ..."
        if command -v curl &>/dev/null; then
            curl -fL --progress-bar -o "$out" "${GITHUB_RAW}/${FILENAME}"
        elif command -v wget &>/dev/null; then
            wget -q --show-progress -O "$out" "${GITHUB_RAW}/${FILENAME}"
        else
            echo "ERROR: neither curl nor wget found. Install either to download the dataset." >&2
            exit 1
        fi
        echo "  saved: $out ($(wc -c < "$out") bytes)"
    fi
done

echo ""
echo "Dataset present at $DATA_DIR"
echo ""
echo "========================================================================================="
echo "IMPORTANT NOTICE: MemBench (import-myself/Membench, ACL Findings 2025)"
echo "========================================================================================="
echo "Paper: 'MemBench: Towards More Comprehensive Evaluation on the Memory of LLM-based Agents'"
echo "arXiv: https://arxiv.org/abs/2506.21605"
echo ""
echo "No explicit LICENSE file was found in the dataset repository as of 2026-08-06."
echo "This dataset is made available by the authors for research purposes."
echo "This benchmarker uses it for INTERNAL DIAGNOSTIC measurement only."
echo "Check https://github.com/import-myself/Membench for the current license status"
echo "before using this data for publication or commercial purposes."
echo "Dataset source: https://github.com/import-myself/Membench"
echo "========================================================================================="
echo ""
echo "Do NOT commit dataset files to this repository."
echo ""
echo "Run from benchmarks/: make measure-membench-spec PORT=swift"
