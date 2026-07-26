#!/usr/bin/env bash
# fetch-lmeb.sh — download LMEB ConvoMem subset from HuggingFace.
#
# Usage: scripts/fetch-lmeb.sh
#
# Downloads the 24 raw files for LMEB's ConvoMem subset (6 evidence types ×
# 4 files each: corpus.jsonl, queries.jsonl, candidates.jsonl, qrels.tsv)
# from KaLM-Embedding/LMEB on HuggingFace into:
#   apps/mcp-benchmarker/fixtures/lmeb/data/ConvoMem/
#
# The dataset directory is gitignored — data files are never committed.
#
# IMPORTANT: The HuggingFace datasets Python API does NOT expose qrels.tsv.
# This script downloads the raw files directly from the repo. The qrels are
# required for nDCG@10 / Recall@k scoring (see LME-06_BLAST_RADIUS.md).
#
# Schema verified 2026-07-26 against KaLM-Embedding/LMEB on HuggingFace.
#
# License: KaLM-Embedding/LMEB is MIT licensed.
#   Full text: https://huggingface.co/datasets/KaLM-Embedding/LMEB
#   Do NOT commit dataset files to this repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DATA_DIR="$REPO_ROOT/apps/mcp-benchmarker/fixtures/lmeb/data/ConvoMem"
HF_REPO="KaLM-Embedding/LMEB"
HF_BASE="https://huggingface.co/datasets/${HF_REPO}/resolve/main/Dialogue/ConvoMem"

EVIDENCE_TYPES=(
    "abstention_evidence"
    "assistant_facts_evidence"
    "changing_evidence"
    "implicit_connection_evidence"
    "preference_evidence"
    "user_evidence"
)

FILES_PER_TYPE=("corpus.jsonl" "queries.jsonl" "candidates.jsonl" "qrels.tsv")

echo "LMEB ConvoMem fetch — target: $DATA_DIR"
echo ""

total_files=$(( ${#EVIDENCE_TYPES[@]} * ${#FILES_PER_TYPE[@]} ))
fetched=0
already_present=0

for et in "${EVIDENCE_TYPES[@]}"; do
    mkdir -p "$DATA_DIR/$et"
    for f in "${FILES_PER_TYPE[@]}"; do
        out="$DATA_DIR/$et/$f"
        if [[ -f "$out" ]]; then
            echo "  already present: $et/$f ($(wc -c < "$out") bytes)"
            already_present=$(( already_present + 1 ))
        else
            echo "  downloading $et/$f ..."
            if command -v curl &>/dev/null; then
                curl -fL --progress-bar -o "$out" "${HF_BASE}/${et}/${f}"
            elif command -v wget &>/dev/null; then
                wget -q --show-progress -O "$out" "${HF_BASE}/${et}/${f}"
            else
                echo "ERROR: neither curl nor wget found. Install either to download the dataset." >&2
                exit 1
            fi
            fetched=$(( fetched + 1 ))
            echo "  saved: $out ($(wc -c < "$out") bytes)"
        fi
    done
    echo ""
done

echo "Done: $fetched downloaded, $already_present already present ($total_files total files)"
echo ""
echo "Dataset license (KaLM-Embedding/LMEB on HuggingFace):"
echo "  MIT License."
echo "  Full license text at: https://huggingface.co/datasets/KaLM-Embedding/LMEB"
echo "  Do NOT commit dataset files to this repository."
echo ""
echo "Run the LMEB benchmarker (Swift):"
echo "  .build/release/mcp-benchmarker lmeb --config <config.json> \\"
echo "    --limit 50 --seed 20260725"
echo ""
echo "Run the LMEB benchmarker (Rust):"
echo "  apps/mcp-benchmarker/rust/target/release/mcp-benchmarker-rs lmeb \\"
echo "    --config <config.json> --limit 50 --seed 20260725"
