#!/usr/bin/env bash
# fetch-cl100k.sh — download the cl100k_base tiktoken vocabulary file.
#
# Usage: scripts/fetch-cl100k.sh
#
# Downloads cl100k_base.tiktoken from OpenAI's public blob storage into the
# external BENCH_WORK_ROOT fixture store. The artifact never enters the repo.
#
# The file is the vocabulary and BPE merge table for OpenAI's cl100k_base
# tokenizer, used by GPT-3.5 / GPT-4 / text-embedding-ada-002. It is
# required for the membench-spec §6 step_cap capacity lane to count
# context tokens per MEMBENCH_OFFICIAL_PROTOCOL.md §7 row 6 (operator ruling 
# vendor the artifact).
#
# Source URL: https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken
# License: Public URL from OpenAI, used under the Apache 2.0-licensed
#          tiktoken project (https://github.com/openai/tiktoken).
#          The file itself carries no separate license statement in the URL.
#          This download is for INTERNAL DIAGNOSTIC use only.
#
# File stats (verified 2026-08-18):
#   Lines:  100,256  (one token per line: base64-encoded bytes + rank)
#   Size:   ~1.6 MB
#   SHA-256: 223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7

set -euo pipefail

ARTIFACT_SHA256="223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7"
SOURCE_URL="https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken"
FILENAME="cl100k_base.tiktoken"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${BENCH_WORK_ROOT:?BENCH_WORK_ROOT is required; run this through make fetch-cl100k}"
REPO_ROOT="$(cd "$BENCH_ROOT/.." && pwd -P)"
BENCH_WORK_ROOT="$(python3 "$SCRIPT_DIR/work-root.py" prepare --repo "$REPO_ROOT" --work "$BENCH_WORK_ROOT")"
DATA_DIR="$BENCH_WORK_ROOT/fixtures/cl100k"
ARTIFACT="$DATA_DIR/$FILENAME"

echo "cl100k_base fetch — target: $ARTIFACT"
mkdir -p "$DATA_DIR"

# Idempotent: skip download if artifact is present and checksum matches.
if [[ -f "$ARTIFACT" ]]; then
    echo "  artifact present — verifying checksum..."
    ACTUAL_SHA256="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
    if [[ "$ACTUAL_SHA256" == "$ARTIFACT_SHA256" ]]; then
        echo "  checksum OK ($ACTUAL_SHA256)"
        echo ""
        echo "Artifact already present and verified: $ARTIFACT"
        exit 0
    else
        echo "  WARNING: checksum mismatch! Expected $ARTIFACT_SHA256, got $ACTUAL_SHA256."
        echo "  Re-downloading..."
        rm -f "$ARTIFACT"
    fi
fi

echo "  downloading $FILENAME ..."
if command -v curl &>/dev/null; then
    curl -fL --progress-bar -o "$ARTIFACT" "$SOURCE_URL"
elif command -v wget &>/dev/null; then
    wget -q --show-progress -O "$ARTIFACT" "$SOURCE_URL"
else
    echo "ERROR: neither curl nor wget found. Install either to download the artifact." >&2
    exit 1
fi

echo "  verifying checksum..."
ACTUAL_SHA256="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$ARTIFACT_SHA256" ]]; then
    echo "ERROR: SHA-256 mismatch after download!" >&2
    echo "  expected: $ARTIFACT_SHA256" >&2
    echo "  got:      $ACTUAL_SHA256" >&2
    rm -f "$ARTIFACT"
    exit 1
fi

echo "  checksum OK ($ACTUAL_SHA256)"
echo "  saved: $ARTIFACT ($(wc -c < "$ARTIFACT") bytes)"
echo ""
echo "Artifact present at $DATA_DIR"
echo ""
echo "========================================================================================="
echo "NOTICE: cl100k_base.tiktoken — OpenAI tiktoken vocabulary"
echo "========================================================================================="
echo "Source: $SOURCE_URL"
echo "Project: https://github.com/openai/tiktoken (Apache 2.0)"
echo ""
echo "This vocabulary file is the BPE merge table for cl100k_base (GPT-3.5/4)."
echo "Used by the membench-spec §6 step_cap lane for byte-exact context token counts."
echo "INTERNAL DIAGNOSTIC use only per MEMBENCH_OFFICIAL_PROTOCOL.md §7 row 6."
echo "========================================================================================="
echo ""
echo "Do NOT commit the artifact to this repository."
echo ""
echo "Run the benchmarker with token counting:"
echo "Run from benchmarks/: make measure-membench-spec CAPACITY=step_cap"
