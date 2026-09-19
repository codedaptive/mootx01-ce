#!/usr/bin/env bash
# Fetch or copy the pinned Rust encoder assets, then verify every file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

KIND="encoder"
MODEL_ID=""
HF_REPO=""
REVISION=""
OUTPUT_DIR=""
MANIFEST=""
SOURCE_DIR=""
POOL=""
HEAD=""
SPANS=""
RRF_K=""
DIM=""
POOLING=""
QUERY_PREFIX=""
DOC_PREFIX=""
WINDOW_WORDS=""
OVERLAP_DIVISOR=""
MAX_SPANS=""
MAX_SEQUENCE=""
RECORD_MANIFEST=0
VERIFY_ONLY=0

usage() {
  cat <<'EOF'
Usage: fetch-rust-triple.sh OPTIONS

Required:
  --model-id ID --hf-repo OWNER/NAME --revision FULL_40_HEX
  --output-dir DIR --manifest FILE --max-sequence N
  encoder (default --kind encoder):
    --dim N --pooling mean|cls --query-prefix TEXT --doc-prefix TEXT
    --window-words N --overlap-divisor N --max-spans N
  cross encoder (--kind cross-encoder):
    --pool N --head N --spans N --rrf-k N

Source mode (choose at most one):
  --source-dir DIR   Copy the four files from a pinned local snapshot.
  --verify-only      Do not copy or download; verify OUTPUT_DIR only.
  (neither)          Download the four files from the pinned HF revision.

Manifest mode:
  default            Fail unless the existing manifest exactly covers and
                     hashes all four files.
  --record-manifest  Atomically record hashes after the pinned-revision fetch
                     or copy, then immediately verify them.
EOF
}

need_value() {
  if [ "$#" -lt 2 ]; then
    echo "missing value for $1" >&2
    usage >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind) need_value "$@"; KIND="$2"; shift 2 ;;
    --pool) need_value "$@"; POOL="$2"; shift 2 ;;
    --head) need_value "$@"; HEAD="$2"; shift 2 ;;
    --spans) need_value "$@"; SPANS="$2"; shift 2 ;;
    --rrf-k) need_value "$@"; RRF_K="$2"; shift 2 ;;
    --model-id) need_value "$@"; MODEL_ID="$2"; shift 2 ;;
    --hf-repo) need_value "$@"; HF_REPO="$2"; shift 2 ;;
    --revision) need_value "$@"; REVISION="$2"; shift 2 ;;
    --output-dir) need_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --manifest) need_value "$@"; MANIFEST="$2"; shift 2 ;;
    --source-dir) need_value "$@"; SOURCE_DIR="$2"; shift 2 ;;
    --dim) need_value "$@"; DIM="$2"; shift 2 ;;
    --pooling) need_value "$@"; POOLING="$2"; shift 2 ;;
    --query-prefix) need_value "$@"; QUERY_PREFIX="$2"; shift 2 ;;
    --doc-prefix) need_value "$@"; DOC_PREFIX="$2"; shift 2 ;;
    --window-words) need_value "$@"; WINDOW_WORDS="$2"; shift 2 ;;
    --overlap-divisor) need_value "$@"; OVERLAP_DIVISOR="$2"; shift 2 ;;
    --max-spans) need_value "$@"; MAX_SPANS="$2"; shift 2 ;;
    --max-sequence) need_value "$@"; MAX_SEQUENCE="$2"; shift 2 ;;
    --record-manifest) RECORD_MANIFEST=1; shift ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$KIND" in
  encoder)
    REQUIRED=(
      "dim:$DIM" "pooling:$POOLING" "window-words:$WINDOW_WORDS"
      "overlap-divisor:$OVERLAP_DIVISOR" "max-spans:$MAX_SPANS"
    ) ;;
  cross-encoder)
    REQUIRED=("pool:$POOL" "head:$HEAD" "spans:$SPANS" "rrf-k:$RRF_K") ;;
  *) echo "--kind must be encoder or cross-encoder" >&2; exit 2 ;;
esac
for pair in \
  "model-id:$MODEL_ID" "hf-repo:$HF_REPO" "revision:$REVISION" \
  "output-dir:$OUTPUT_DIR" "manifest:$MANIFEST" \
  "max-sequence:$MAX_SEQUENCE" "${REQUIRED[@]}"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if [ -z "$value" ]; then
    echo "--${name} is required" >&2
    exit 2
  fi
done

case "$MODEL_ID" in *[!A-Za-z0-9._-]*|'') echo "unsafe model id: $MODEL_ID" >&2; exit 2 ;; esac
if ! [[ "$HF_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "--hf-repo must be a safe OWNER/NAME" >&2
  exit 2
fi
if ! [[ "$REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "--revision must be a full lowercase 40-character git hash" >&2
  exit 2
fi
if [ "$KIND" = "encoder" ] && [ "$POOLING" != "mean" ] && [ "$POOLING" != "cls" ]; then
  echo "--pooling must be mean or cls" >&2
  exit 2
fi
if [ "$VERIFY_ONLY" -eq 1 ] && [ -n "$SOURCE_DIR" ]; then
  echo "--verify-only and --source-dir are mutually exclusive" >&2
  exit 2
fi
if [ "$VERIFY_ONLY" -eq 1 ] && [ "$RECORD_MANIFEST" -eq 1 ]; then
  echo "--verify-only cannot record a new manifest" >&2
  exit 2
fi

FILES=(config.json tokenizer.json model.safetensors vocab.txt)

if [ "$VERIFY_ONLY" -eq 0 ]; then
  mkdir -p "$OUTPUT_DIR"
  for file in "${FILES[@]}"; do
    temporary="${OUTPUT_DIR}/.${file}.partial-$$"
    trap 'rm -f -- "$temporary"' EXIT
    if [ -n "$SOURCE_DIR" ]; then
      if [ ! -f "${SOURCE_DIR}/${file}" ]; then
        echo "source file missing: ${SOURCE_DIR}/${file}" >&2
        exit 1
      fi
      cp -p -- "${SOURCE_DIR}/${file}" "$temporary"
    else
      url="https://huggingface.co/${HF_REPO}/resolve/${REVISION}/${file}"
      echo "fetching ${file} @ ${REVISION:0:12}"
      curl --proto '=https' --tlsv1.2 --silent --show-error --location --fail \
        --output "$temporary" "$url"
    fi
    mv -f -- "$temporary" "${OUTPUT_DIR}/${file}"
    trap - EXIT
  done
fi

if [ "$KIND" = "encoder" ]; then
  COMMON_RECORD_ARGS=(
    --model-id "$MODEL_ID"
    --hf-repo "$HF_REPO"
    --revision "$REVISION"
    --dim "$DIM"
    --pooling "$POOLING"
    --query-prefix "$QUERY_PREFIX"
    --doc-prefix "$DOC_PREFIX"
    --window-words "$WINDOW_WORDS"
    --overlap-divisor "$OVERLAP_DIVISOR"
    --max-spans "$MAX_SPANS"
    --max-sequence "$MAX_SEQUENCE"
  )
  RECORD_COMMAND="record-linux"
  VERIFY_COMMAND="verify"
else
  COMMON_RECORD_ARGS=(
    --model-id "$MODEL_ID"
    --hf-repo "$HF_REPO"
    --revision "$REVISION"
    --max-sequence "$MAX_SEQUENCE"
    --pool "$POOL"
    --head "$HEAD"
    --spans "$SPANS"
    --rrf-k "$RRF_K"
  )
  RECORD_COMMAND="record-linux-cross"
  VERIFY_COMMAND="verify-cross"
fi

if [ "$RECORD_MANIFEST" -eq 1 ]; then
  "$PYTHON_BIN" "$SCRIPT_DIR/manifest_tools.py" "$RECORD_COMMAND" \
    --manifest "$MANIFEST" --root "$OUTPUT_DIR" "${COMMON_RECORD_ARGS[@]}"
else
  "$PYTHON_BIN" "$SCRIPT_DIR/manifest_tools.py" "$VERIFY_COMMAND" \
    --manifest "$MANIFEST" --root "$OUTPUT_DIR" --platform linux \
    "${COMMON_RECORD_ARGS[@]}"
fi

echo "Rust encoder assets ready at: ${OUTPUT_DIR}/"
