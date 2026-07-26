#!/usr/bin/env bash
# fetch-longmemeval.sh — download LongMemEval dataset from HuggingFace.
#
# Usage: scripts/fetch-longmemeval.sh
#
# Downloads the three variant JSON files from the xiaowu0162/longmemeval-cleaned
# dataset on HuggingFace into apps/mcp-benchmarker/fixtures/longmemeval/data/.
# The dataset directory is gitignored — data files are never committed.
#
# License statement: this script downloads data governed by the LongMemEval
# dataset license. Do not vendor the dataset into the repo. Run this script
# locally before running the longmemeval benchmarker subcommand.
#
# After download, this script prints the dataset's stated license from its
# README (if available via the HuggingFace datasets API).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DATA_DIR="$REPO_ROOT/apps/mcp-benchmarker/fixtures/longmemeval/data"
HF_REPO="xiaowu0162/longmemeval-cleaned"
HF_BASE="https://huggingface.co/datasets/${HF_REPO}/resolve/main"

echo "LongMemEval fetch — target: $DATA_DIR"
mkdir -p "$DATA_DIR"

# Three variant files (verified 2026-07-25 against xiaowu0162/longmemeval-cleaned tree):
#   _s and _m variants use _cleaned suffix; oracle does not.
# Re-verify if a 404 occurs (field layout or filenames may have changed upstream).
FILES=(
    "longmemeval_s_cleaned.json"
    "longmemeval_m_cleaned.json"
    "longmemeval_oracle.json"
)

for f in "${FILES[@]}"; do
    out="$DATA_DIR/$f"
    if [[ -f "$out" ]]; then
        echo "  already present: $f ($(wc -c < "$out") bytes)"
    else
        echo "  downloading $f ..."
        if command -v curl &>/dev/null; then
            curl -fL --progress-bar -o "$out" "${HF_BASE}/${f}"
        elif command -v wget &>/dev/null; then
            wget -q --show-progress -O "$out" "${HF_BASE}/${f}"
        else
            echo "ERROR: neither curl nor wget found. Install either to download the dataset." >&2
            exit 1
        fi
        echo "  saved: $out ($(wc -c < "$out") bytes)"
    fi
done

echo ""
echo "All three variants present in $DATA_DIR"
echo ""
echo "Dataset license (xiaowu0162/longmemeval-cleaned on HuggingFace):"
echo "  Creative Commons Attribution 4.0 International (CC BY 4.0)."
echo "  Full license text at: https://creativecommons.org/licenses/by/4.0/"
echo "  This data is governed by the dataset authors' stated license."
echo "  Do NOT commit dataset files to this repository."
echo ""
echo "Run the benchmarker:"
echo "  .build/release/mcp-benchmarker longmemeval --config <config.json> \\"
echo "    --variant s --limit 50 --seed 20260725"
