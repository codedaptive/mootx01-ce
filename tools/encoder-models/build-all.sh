#!/usr/bin/env bash
# Build pinned encoder artifacts outside git, with exact cross-platform identity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

PROFILE="arctic"
KIND="encoder"
OUTPUT_ROOT=""
SOURCE_DIR=""
ALLOW_NETWORK=0
RECORD_LINUX_MANIFEST=0
FORCE=0

# Explicit overrides are applied after the selected profile.
OVERRIDE_MODEL_ID=""
OVERRIDE_HF_REPO=""
OVERRIDE_REVISION=""
OVERRIDE_ARTIFACT_NAME=""
OVERRIDE_DIM=""
OVERRIDE_POOLING=""
OVERRIDE_QUERY_PREFIX="__UNSET__"
OVERRIDE_DOC_PREFIX="__UNSET__"
OVERRIDE_WINDOW_WORDS=""
OVERRIDE_OVERLAP_DIVISOR=""
OVERRIDE_MAX_SPANS=""
OVERRIDE_MAX_SEQUENCE=""
APPLE_MANIFEST=""
LINUX_MANIFEST=""

usage() {
  cat <<'EOF'
Usage: build-all.sh --output-root ABSOLUTE_DIR [OPTIONS]

Profiles:
  --profile arctic   Snowflake/snowflake-arctic-embed-s, CLS, query prefix,
                     max sequence 512 (default; active WP-H manifests)
  --profile minilm   sentence-transformers/all-MiniLM-L6-v2, mean, max 256
                     (preserved floor manifests)
  --profile minilm-cross
                     cross-encoder/ms-marco-MiniLM-L-6-v2, the retrieval-time
                     pair classifier (one logit per query/span pair), pair
                     limit 512, pool 50 / head 30 / spans 3 / RRF k 60
                     (cross-encoder-models-*.json manifests)

Input:
  --source-dir DIR   Use a local pinned HF snapshot for all four Rust files and
                     CoreML loading. This is the release-safe default mode.
  --allow-network    Permit downloads/HF resolution when no source dir is given.

Outputs:
  OUTPUT_ROOT/apple  <artifact>.aimodel, its export record, vocab.txt (Core AI, ADR-029)
  OUTPUT_ROOT/linux  config.json, tokenizer.json, model.safetensors, vocab.txt

Overrides:
  --model-id ID --hf-repo OWNER/NAME --revision FULL_40_HEX
  --artifact-name NAME --dim N --pooling mean|cls
  --query-prefix TEXT --doc-prefix TEXT --max-sequence N
  --window-words N --overlap-divisor N --max-spans N
  --apple-manifest FILE --linux-manifest FILE
  (the cross-encoder profile's pool, head, spans and rrf_k are fixed by the
  profile; they are the lab's measured values, not build inputs)

Other:
  --record-linux-manifest  Record hashes after a pinned source copy/download.
  --force                  Replace exact Apple output artifacts.
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
    --profile) need_value "$@"; PROFILE="$2"; shift 2 ;;
    --output-root) need_value "$@"; OUTPUT_ROOT="$2"; shift 2 ;;
    --source-dir) need_value "$@"; SOURCE_DIR="$2"; shift 2 ;;
    --allow-network) ALLOW_NETWORK=1; shift ;;
    --record-linux-manifest) RECORD_LINUX_MANIFEST=1; shift ;;
    --force) FORCE=1; shift ;;
    --model-id) need_value "$@"; OVERRIDE_MODEL_ID="$2"; shift 2 ;;
    --hf-repo) need_value "$@"; OVERRIDE_HF_REPO="$2"; shift 2 ;;
    --revision) need_value "$@"; OVERRIDE_REVISION="$2"; shift 2 ;;
    --artifact-name) need_value "$@"; OVERRIDE_ARTIFACT_NAME="$2"; shift 2 ;;
    --dim) need_value "$@"; OVERRIDE_DIM="$2"; shift 2 ;;
    --pooling) need_value "$@"; OVERRIDE_POOLING="$2"; shift 2 ;;
    --query-prefix) need_value "$@"; OVERRIDE_QUERY_PREFIX="$2"; shift 2 ;;
    --doc-prefix) need_value "$@"; OVERRIDE_DOC_PREFIX="$2"; shift 2 ;;
    --window-words) need_value "$@"; OVERRIDE_WINDOW_WORDS="$2"; shift 2 ;;
    --overlap-divisor) need_value "$@"; OVERRIDE_OVERLAP_DIVISOR="$2"; shift 2 ;;
    --max-spans) need_value "$@"; OVERRIDE_MAX_SPANS="$2"; shift 2 ;;
    --max-sequence) need_value "$@"; OVERRIDE_MAX_SEQUENCE="$2"; shift 2 ;;
    --apple-manifest) need_value "$@"; APPLE_MANIFEST="$2"; shift 2 ;;
    --linux-manifest) need_value "$@"; LINUX_MANIFEST="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$PROFILE" in
  arctic)
    MODEL_ID="arctic-embed-s-w60"
    HF_REPO="Snowflake/snowflake-arctic-embed-s"
    REVISION="e596f507467533e48a2e17c007f0e1dacc837b33"
    ARTIFACT_NAME="ArcticEmbedS"
    DIM=384
    POOLING="cls"
    QUERY_PREFIX="Represent this sentence for searching relevant passages: "
    DOC_PREFIX=""
    WINDOW_WORDS=60
    OVERLAP_DIVISOR=2
    MAX_SPANS=32
    MAX_SEQUENCE=512
    : "${APPLE_MANIFEST:=$SCRIPT_DIR/encoder-models-apple.json}"
    : "${LINUX_MANIFEST:=$SCRIPT_DIR/encoder-models-linux.json}"
    ;;
  minilm)
    MODEL_ID="minilm-l6-v2-w60"
    HF_REPO="sentence-transformers/all-MiniLM-L6-v2"
    REVISION="1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
    ARTIFACT_NAME="MiniLM-L6-v2"
    DIM=384
    POOLING="mean"
    QUERY_PREFIX=""
    DOC_PREFIX=""
    WINDOW_WORDS=60
    OVERLAP_DIVISOR=2
    MAX_SPANS=32
    MAX_SEQUENCE=256
    : "${APPLE_MANIFEST:=$SCRIPT_DIR/encoder-models-minilm-apple.json}"
    : "${LINUX_MANIFEST:=$SCRIPT_DIR/encoder-models-minilm-linux.json}"
    ;;
  minilm-cross)
    KIND="cross-encoder"
    MODEL_ID="ms-marco-minilm-l6-cross-v1"
    HF_REPO="cross-encoder/ms-marco-MiniLM-L-6-v2"
    REVISION="233902d25c440f23af6f7d6e94d2946bac0bee0a"
    # Pascal-cased model id: `CrossEncoderProfile.artifactName`, both ports.
    ARTIFACT_NAME="MsMarcoMinilmL6CrossV1"
    MAX_SEQUENCE=512
    POOL=50
    HEAD=30
    SPANS=3
    RRF_K=60
    : "${APPLE_MANIFEST:=$SCRIPT_DIR/cross-encoder-models-apple.json}"
    : "${LINUX_MANIFEST:=$SCRIPT_DIR/cross-encoder-models-linux.json}"
    ;;
  *) echo "unknown profile: $PROFILE" >&2; exit 2 ;;
esac

[ -n "$OVERRIDE_MODEL_ID" ] && MODEL_ID="$OVERRIDE_MODEL_ID"
[ -n "$OVERRIDE_HF_REPO" ] && HF_REPO="$OVERRIDE_HF_REPO"
[ -n "$OVERRIDE_REVISION" ] && REVISION="$OVERRIDE_REVISION"
[ -n "$OVERRIDE_ARTIFACT_NAME" ] && ARTIFACT_NAME="$OVERRIDE_ARTIFACT_NAME"
[ -n "$OVERRIDE_DIM" ] && DIM="$OVERRIDE_DIM"
[ -n "$OVERRIDE_POOLING" ] && POOLING="$OVERRIDE_POOLING"
[ "$OVERRIDE_QUERY_PREFIX" != "__UNSET__" ] && QUERY_PREFIX="$OVERRIDE_QUERY_PREFIX"
[ "$OVERRIDE_DOC_PREFIX" != "__UNSET__" ] && DOC_PREFIX="$OVERRIDE_DOC_PREFIX"
[ -n "$OVERRIDE_WINDOW_WORDS" ] && WINDOW_WORDS="$OVERRIDE_WINDOW_WORDS"
[ -n "$OVERRIDE_OVERLAP_DIVISOR" ] && OVERLAP_DIVISOR="$OVERRIDE_OVERLAP_DIVISOR"
[ -n "$OVERRIDE_MAX_SPANS" ] && MAX_SPANS="$OVERRIDE_MAX_SPANS"
[ -n "$OVERRIDE_MAX_SEQUENCE" ] && MAX_SEQUENCE="$OVERRIDE_MAX_SEQUENCE"

if [ -z "$OUTPUT_ROOT" ]; then
  echo "--output-root is required; model binaries never default into the source tree" >&2
  exit 2
fi
if [ -n "$SOURCE_DIR" ] && [ "$ALLOW_NETWORK" -eq 1 ]; then
  echo "--source-dir and --allow-network are mutually exclusive" >&2
  exit 2
fi
if [ -z "$SOURCE_DIR" ] && [ "$ALLOW_NETWORK" -eq 0 ]; then
  echo "provide --source-dir, or explicitly pass --allow-network" >&2
  exit 2
fi

OUTPUT_ROOT="$($PYTHON_BIN - "$OUTPUT_ROOT" "$SCRIPT_DIR" <<'PY'
import pathlib, sys
output = pathlib.Path(sys.argv[1]).expanduser()
source = pathlib.Path(sys.argv[2]).resolve()
if not output.is_absolute():
    raise SystemExit("--output-root must be absolute")
output = output.resolve()
if output == pathlib.Path(output.anchor):
    raise SystemExit("refusing a filesystem root as --output-root")
if output == source or source in output.parents:
    raise SystemExit("binary output must not be inside the pipeline source directory")
probe = output
while not probe.exists() and probe != probe.parent:
    probe = probe.parent
if any((parent / ".git").exists() for parent in (probe, *probe.parents)):
    raise SystemExit(f"binary output must not be inside a git checkout: {output}")
print(output)
PY
)"

if [ "$KIND" = "encoder" ]; then
  COMMON_ARGS=(
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
  VERIFY_COMMAND="verify"
else
  COMMON_ARGS=(
    --model-id "$MODEL_ID"
    --hf-repo "$HF_REPO"
    --revision "$REVISION"
    --max-sequence "$MAX_SEQUENCE"
    --pool "$POOL"
    --head "$HEAD"
    --spans "$SPANS"
    --rrf-k "$RRF_K"
  )
  VERIFY_COMMAND="verify-cross"
fi

FETCH_ARGS=(
  "${COMMON_ARGS[@]}"
  --kind "$KIND"
  --output-dir "$OUTPUT_ROOT/linux"
  --manifest "$LINUX_MANIFEST"
)
if [ -n "$SOURCE_DIR" ]; then
  FETCH_ARGS+=(--source-dir "$SOURCE_DIR")
fi
[ "$RECORD_LINUX_MANIFEST" -eq 1 ] && FETCH_ARGS+=(--record-manifest)

echo "=== Preparing and verifying Linux/Windows artifacts ==="
PYTHON_BIN="$PYTHON_BIN" bash "$SCRIPT_DIR/fetch-rust-triple.sh" "${FETCH_ARGS[@]}"

echo "=== Exporting and verifying the Apple artifact (Core AI) ==="
# ADR-029: one Apple runtime. The export runs from the Core AI PyTorch
# environment named by COREAI_PYTHON (coreai-torch and its runtime); it needs
# --source-dir, the verified local snapshot, and writes <artifact>.aimodel,
# its export record and vocab.txt under apple/, recording the asset in the
# apple manifest as its one aimodel_dir entry.
if [ -z "${COREAI_PYTHON:-}" ]; then
  echo "COREAI_PYTHON must name the Core AI PyTorch environment's python (coreai-torch installed)" >&2
  exit 2
fi
if [ -z "$SOURCE_DIR" ]; then
  echo "the Core AI export needs --source-dir (a verified local snapshot)" >&2
  exit 2
fi
COREAI_ARGS=(
  --kind "$KIND"
  --source-dir "$SOURCE_DIR"
  --output-dir "$OUTPUT_ROOT/apple"
  --artifact-name "$ARTIFACT_NAME"
  --max-sequence "$MAX_SEQUENCE"
  --vocab "$OUTPUT_ROOT/linux/vocab.txt"
  --manifest "$APPLE_MANIFEST"
)
# The profile's pooling travels into the asset (PooledMean or PooledCLS).
[ "$KIND" = "encoder" ] && COREAI_ARGS+=(--dim "$DIM" --pooling "$POOLING")
[ "$FORCE" -eq 1 ] && COREAI_ARGS+=(--force)
"$COREAI_PYTHON" "$SCRIPT_DIR/export-coreai.py" "${COREAI_ARGS[@]}"

LINUX_VOCAB="$($PYTHON_BIN "$SCRIPT_DIR/manifest_tools.py" "$VERIFY_COMMAND" \
  --manifest "$LINUX_MANIFEST" --root "$OUTPUT_ROOT/linux" --platform linux \
  "${COMMON_ARGS[@]}" >/dev/null && shasum -a 256 "$OUTPUT_ROOT/linux/vocab.txt" | awk '{print $1}')"
APPLE_VOCAB="$(shasum -a 256 "$OUTPUT_ROOT/apple/vocab.txt" | awk '{print $1}')"
if [ "$LINUX_VOCAB" != "$APPLE_VOCAB" ]; then
  echo "cross-platform vocab mismatch: linux=$LINUX_VOCAB apple=$APPLE_VOCAB" >&2
  exit 1
fi

echo "=== Encoder artifacts complete ==="
echo "model: $MODEL_ID @ $REVISION"
echo "apple: $OUTPUT_ROOT/apple"
echo "linux: $OUTPUT_ROOT/linux"
echo "vocab sha256: $LINUX_VOCAB"
echo "manifests: $APPLE_MANIFEST ; $LINUX_MANIFEST"
