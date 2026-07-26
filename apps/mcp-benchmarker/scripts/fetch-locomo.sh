#!/usr/bin/env bash
# fetch-locomo.sh — download the LoCoMo dataset from GitHub.
#
# Usage: scripts/fetch-locomo.sh
#
# Downloads locomo10.json from the snap-research/locomo GitHub repository into
# apps/mcp-benchmarker/fixtures/locomo/data/. The dataset directory is
# gitignored — data files are never committed.
#
# License statement: LoCoMo is released under the Creative Commons Attribution-
# NonCommercial 4.0 International (CC BY-NC 4.0) license. This download is for
# INTERNAL DIAGNOSTIC use only. Do not use the dataset for commercial purposes.
# Do not vendor the dataset into this repository.
#
# SPEC-BEFORE-REALITY (verified 2026-07-26):
#   URL: https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json
#   Schema: list of 10 conversation objects
#   Total QAs: 1,986 (1,542 scoreable categories 1-4; 444 adversarial category 5 excluded)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DATA_DIR="$REPO_ROOT/apps/mcp-benchmarker/fixtures/locomo/data"
GITHUB_RAW="https://raw.githubusercontent.com/snap-research/locomo/main/data"
FILENAME="locomo10.json"

echo "LoCoMo fetch — target: $DATA_DIR"
mkdir -p "$DATA_DIR"

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

echo ""
echo "Dataset present at $DATA_DIR"
echo ""
echo "========================================================================================="
echo "IMPORTANT LICENSE NOTICE: LoCoMo (snap-research/locomo, ACL 2024)"
echo "========================================================================================="
echo "License: Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)"
echo ""
echo "This dataset is for NON-COMMERCIAL use only."
echo "It may NOT be used for commercial purposes, including training commercial AI products."
echo "This benchmarker uses it for INTERNAL DIAGNOSTIC measurement only."
echo "Full license text: https://creativecommons.org/licenses/by-nc/4.0/"
echo "Dataset source:    https://github.com/snap-research/locomo"
echo "Paper:             Maharana et al., ACL 2024 — Evaluating Very Long-Term"
echo "                   Conversational Memory of LLM Agents"
echo "========================================================================================="
echo ""
echo "Do NOT commit dataset files to this repository."
echo ""
echo "Run the benchmarker:"
echo "  .build/release/mcp-benchmarker locomo --data-file fixtures/locomo/data/locomo10.json \\"
echo "    --limit 50 --seed 20260725"
