#!/usr/bin/env bash
# fetch-goldminer-model.sh — provision the Rust gold miner's default engine
# files (ADORNMENTLIB_SPEC 0.5.0 § Gold miner).
#
#   bash fetch-goldminer-model.sh [--dest <dir>]
#
# Downloads the official Qwen2-0.5B-Instruct Q4_K_M GGUF (~400 MB) from the
# publisher and pairs it with the HF tokenizer.json. The GGUF path is a
# PLUG: any Qwen2-family GGUF dropped at the same destination swaps the
# engine's model with zero code changes. License stays with the publisher.
#
# The destination defaults under the caller's own cache. Pass --dest, or set
# GOLDMINER_MODEL_DIR, to put it somewhere else — a shared model volume, for
# instance. Nothing here assumes a particular machine's layout.
set -euo pipefail

DEST="${GOLDMINER_MODEL_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mootx01/gguf/qwen2-0.5b-instruct}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done
mkdir -p "$DEST"

GGUF_URL="https://huggingface.co/Qwen/Qwen2-0.5B-Instruct-GGUF/resolve/main/qwen2-0_5b-instruct-q4_k_m.gguf"
TOK_URL="https://huggingface.co/Qwen/Qwen2-0.5B-Instruct/resolve/main/tokenizer.json"

if [[ ! -f "$DEST/model.gguf" ]]; then
  curl -L --fail -o "$DEST/model.gguf.part" "$GGUF_URL"
  mv "$DEST/model.gguf.part" "$DEST/model.gguf"
fi
if [[ ! -f "$DEST/tokenizer.json" ]]; then
  # Reuse an existing local HF snapshot's tokenizer instead of re-downloading
  # it. Opt in by pointing GOLDMINER_HF_SNAPSHOT at the checkout; unset, this
  # falls straight through to the publisher.
  LOCAL_TOK="${GOLDMINER_HF_SNAPSHOT:-}/tokenizer.json"
  if [[ -n "${GOLDMINER_HF_SNAPSHOT:-}" && -f "$LOCAL_TOK" ]]; then
    cp "$LOCAL_TOK" "$DEST/tokenizer.json"
  else
    curl -L --fail -o "$DEST/tokenizer.json.part" "$TOK_URL"
    mv "$DEST/tokenizer.json.part" "$DEST/tokenizer.json"
  fi
fi

ls -lh "$DEST"
