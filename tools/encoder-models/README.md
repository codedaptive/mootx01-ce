# Encoder model artifact pipeline

This directory builds pinned encoder artifacts and verifies their manifests.
Model binaries and build environments must stay outside Git.

## Profiles

| Profile | Registry role | HF revision | Pooling | Prefix | Maximum sequence |
|---|---|---|---|---|---:|
| `arctic` | active WP-H seed | `Snowflake/snowflake-arctic-embed-s@e596f507467533e48a2e17c007f0e1dacc837b33` | CLS | queries only: `Represent this sentence for searching relevant passages: ` | 512 |
| `minilm` | retained audition floor | `sentence-transformers/all-MiniLM-L6-v2@1110a243fdf4706b3f48f1d95db1a4f5529b4d41` | attention-masked mean | none | 256 |
| `minilm-cross` | retrieval-time cross encoder | `cross-encoder/ms-marco-MiniLM-L-6-v2@233902d25c440f23af6f7d6e94d2946bac0bee0a` | classifier head (pooler tanh, one logit) | none | 512 (pair) |

`encoder-models-apple.json` and `encoder-models-linux.json` describe Arctic.
`encoder-models-minilm-apple.json` and `encoder-models-minilm-linux.json` are the
original historical floor records and should remain byte-for-byte unchanged.
`cross-encoder-models-apple.json` and `cross-encoder-models-linux.json` describe
the cross encoder; their record carries the `CrossEncoderProfile` fields
(`max_sequence`, `pool`, `head`, `spans`, `rrf_k`) under `kind: cross_encoder`
instead of the encoder geometry, and `manifest_tools.py verify-cross` /
`record-linux-cross` are their verifier and bootstrap.

## Fact-extraction model release

`nuextract-models-apple.json` and `nuextract-models-linux.json` describe the
NuExtract-1.5-tiny fact extractor (`numind/NuExtract-1.5-tiny@63e2e80c804d9c97f3f19a4aa25613e7beca83c9`).
Its assets are published the same way as the encoder model, as the pre-release
`models-nuextract-tiny-v1.5` on the product repository: `nuextract-tiny-v1.5-apple.tar.gz`
(the CoreAI `.aimodel` directory plus `tokenizer.json`), `nuextract-tiny-v1.5-linux.tar.gz`
(`model.gguf` plus `tokenizer.json`, also used by Windows), and `SHA256SUMS`.
`fetch-release.sh <apple|linux> <dest-dir> nuextract-tiny-v1.5` downloads, checks
the tarball digest, and verifies the layout with `manifest_tools.py verify-nuextract`.
The release workflow and the harness stage the result at
`share/mootx01/models/nuextract-tiny-v1.5/` beside the product binary, which is
where both ports' fact-extractor builders look when no path is configured.

## External paths

Run these setup commands from anywhere inside the repository. Adjust the
external paths when using another controlled workspace.

```bash
ENCODER_REPO_ROOT="$(git rev-parse --show-toplevel)"
ENCODER_WORK_ROOT=/Volumes/llm_models/benchmark/work/encoder-models/arctic-embed-s-w60/work/wp-h-codex-20260905
ENCODER_OUTPUT_ROOT=/Volumes/llm_models/benchmark/work/encoder-models/arctic-embed-s-w60
ENCODER_EVIDENCE_ROOT="$ENCODER_WORK_ROOT/evidence"
ENCODER_PYTHON="$ENCODER_WORK_ROOT/venv/bin/python"
ARCTIC_SOURCE="$HOME/.cache/huggingface/hub/models--Snowflake--snowflake-arctic-embed-s/snapshots/e596f507467533e48a2e17c007f0e1dacc837b33"
```

The successful Arctic conversion used Python 3.11.16, coremltools 9.0, torch
2.7.0, transformers 4.51.3, tokenizers 0.21.4, numpy 1.26.4, safetensors 0.8.0,
and Xcode 27.0 build 27A5218g. The compiler was
`/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/coremlcompiler`
with SHA-256
`946fca15b0ea36e51d675a50fc1d846fa338d8241cd3944e3d3e203762e40d81`.
The complete Python freeze is at
`$ENCODER_EVIDENCE_ROOT/conversion-runtime-freeze.txt`.

## Build Arctic from the pinned local snapshot

```bash
PYTHON_BIN="$ENCODER_PYTHON" \
bash "$ENCODER_REPO_ROOT/tools/encoder-models/build-all.sh" \
  --profile arctic \
  --output-root "$ENCODER_OUTPUT_ROOT" \
  --source-dir "$ARCTIC_SOURCE" \
  --force
```

This creates `apple/` and `linux/` under the external output root. `--force`
replaces only the three exact Apple outputs for the selected profile. Before
loading model code or weights, the converter requires the Linux source manifest,
checks its complete registry identity and pinned HF repository and revision, and
verifies `config.json`, `tokenizer.json`, `model.safetensors`, and `vocab.txt` in
the selected source directory. A newly generated Apple manifest records the
source-manifest digest and those verified input digests.

Network resolution is disabled unless `--allow-network` is explicit:

```bash
PYTHON_BIN="$ENCODER_PYTHON" \
bash "$ENCODER_REPO_ROOT/tools/encoder-models/build-all.sh" \
  --profile arctic \
  --output-root "$ENCODER_OUTPUT_ROOT" \
  --allow-network \
  --force
```

Network mode resolves the exact 40-character revision into a local HF snapshot
and applies the same source-manifest identity and digest checks before loading
the model.

## The Apple asset is Core AI (ADR-028 E4, ADR-029)

Every Apple profile ships one asset, `<artifact>.aimodel`, exported from the
pinned snapshot by `export-coreai.py` through coreai-torch: dynamic batch
(1...64) and sequence (1...512), float32. Sentence encoders return `pooled`
`[B, 384]` (CLS); the cross encoder (`--kind cross-encoder`) returns `logits`
`[B]`. `build-all.sh` runs the export for the Apple side and needs the Core
AI PyTorch environment named by `COREAI_PYTHON` (coreai-torch with its
runtime); there is no CoreML converter any more.

```bash
COREAI_PYTHON=/path/to/coreai-torch/.venv/bin/python \
PYTHON_BIN="$ENCODER_PYTHON" \
bash "$ENCODER_REPO_ROOT/tools/encoder-models/build-all.sh" \
  --profile arctic \
  --output-root "$ENCODER_OUTPUT_ROOT" \
  --source-dir "$ARCTIC_SOURCE" \
  --force
```

The export writes `<artifact>.aimodel`, `<artifact>.export.json` (source
digests, shapes, the fixture's float32 reference vectors or logits, the
exported-program vs HF max abs difference, and the all-pad-row finiteness
check that stands in for the earlier FP16 NaN regression) and `vocab.txt`
under `apple/`, and records the asset as the apple manifest's one
`aimodel_dir` entry.

## Verify and record Linux artifacts

Normal operation verifies the authoritative manifest. It requires exact model
metadata, exact four-file coverage, every file digest, and equality between
`tokenizer_hash` and `sha256(vocab.txt)`. To verify already prepared Arctic
files without copying or downloading:

```bash
PYTHON_BIN="$ENCODER_PYTHON" \
bash "$ENCODER_REPO_ROOT/tools/encoder-models/fetch-rust-triple.sh" \
  --model-id arctic-embed-s-w60 \
  --hf-repo Snowflake/snowflake-arctic-embed-s \
  --revision e596f507467533e48a2e17c007f0e1dacc837b33 \
  --output-dir "$ENCODER_OUTPUT_ROOT/linux" \
  --manifest "$ENCODER_REPO_ROOT/tools/encoder-models/encoder-models-linux.json" \
  --dim 384 --pooling cls \
  --query-prefix 'Represent this sentence for searching relevant passages: ' \
  --doc-prefix '' --window-words 60 --overlap-divisor 2 \
  --max-spans 32 --max-sequence 512 --verify-only
```

`--record-manifest` is a controlled bootstrap operation. Use it only after
copying from a trusted local snapshot or downloading the full pinned revision.
It atomically replaces the selected Linux manifest and immediately verifies the
result. Without that flag, incomplete coverage, invalid digests, digest
mismatches, and identity disagreements fail closed.

## Rebuild the retained MiniLM floor

The checked-in MiniLM manifests preserve their original short revision and
three-file historical form. A generalized rebuild needs a normalized four-file
Linux manifest with the full revision, so direct both generated manifests to an
external location:

```bash
MINILM_OUTPUT_ROOT=/Volumes/llm_models/benchmark/work/encoder-models/minilm-l6-v2-w60
MINILM_MANIFEST_ROOT="$MINILM_OUTPUT_ROOT/manifests"
MINILM_SOURCE="$HOME/.cache/huggingface/hub/models--sentence-transformers--all-MiniLM-L6-v2/snapshots/1110a243fdf4706b3f48f1d95db1a4f5529b4d41"

PYTHON_BIN="$ENCODER_PYTHON" \
bash "$ENCODER_REPO_ROOT/tools/encoder-models/build-all.sh" \
  --profile minilm \
  --output-root "$MINILM_OUTPUT_ROOT" \
  --source-dir "$MINILM_SOURCE" \
  --apple-manifest "$MINILM_MANIFEST_ROOT/encoder-models-apple.json" \
  --linux-manifest "$MINILM_MANIFEST_ROOT/encoder-models-linux.json" \
  --record-linux-manifest \
  --force
```

The manifest writer creates the external manifest directory when needed. These
overrides prevent the rebuild from changing either checked-in floor record.

## Build the cross encoder

The cross encoder is a BERT sequence classifier. `--profile minilm-cross`
exports it with `--kind cross-encoder`: three Int32 inputs (`input_ids`,
`attention_mask`, `token_type_ids`) of shape `[B, L]`, B in 1...64 and L in
1...512, and one Float32 `logits` output of shape `[B]`. The pooler and
classifier stay inside the graph; the Rust runtime reads them from the same
safetensors (`bert.pooler.dense`, `classifier`). Model id
`ms-marco-minilm-l6-cross-v1`, artifact `MsMarcoMinilmL6CrossV1.aimodel`.

```bash
CROSS_OUTPUT_ROOT=/Volumes/llm_models/benchmark/work/encoder-models/ms-marco-minilm-l6-cross-v1
CROSS_SOURCE=<pinned snapshot of cross-encoder/ms-marco-MiniLM-L-6-v2 @ 233902d2…>

PYTHON_BIN="$ENCODER_PYTHON" \
bash "$ENCODER_REPO_ROOT/tools/encoder-models/build-all.sh" \
  --profile minilm-cross \
  --output-root "$CROSS_OUTPUT_ROOT" \
  --source-dir "$CROSS_SOURCE" \
  --force
```

The kit tests that load the built classifier read `MOOT_CROSS_ENCODER_ASSETS`
set to that output root (`apple/` for Swift, `linux/` for Rust) and skip when
it is unset. The runtime resolves the model through the same three slots as
the encoders under `<configuration>/models/ms-marco-minilm-l6-cross-v1/`.

## Required Core ML precision

Both the sentence encoder (`arctic`, `minilm`) and the cross encoder
(`minilm-cross`) are converted with `compute_precision=ct.precision.FLOAT32`.
`convert-coreml.py` applies `FLOAT32` to both branches at line 349.

For the sentence encoder, the requirement is well-established: a default FP16
conversion overflowed BERT's finite attention-mask sentinel to `-inf`. The
resulting MIL graph multiplied `0 * -inf` for valid tokens and returned
non-finite vectors on both `.all` and CPU-only execution. The explicit FP32
conversion preserves the finite sentinel while retaining `.all` compute units
and fixed `[1,512]` Int32 inputs. The recorded FP32 preflight matched all six
ONNX reference vectors at cosine `>= 0.9999999999996002`; its log is
`$ENCODER_EVIDENCE_ROOT/coreml-preflight-fp32.log`.

The cross encoder shares the same BERT attention mechanism and the same
arithmetic hazard: a classifier head logit derived from an overflowed sentinel
produces a non-finite or arbitrarily large value, making the rerank order
meaningless. The pipeline applies `FLOAT32` to the classifier output
(`logits`, shape `[1,1]`) for the same reason it does for `last_hidden_state`.
No separate preflight evidence was collected for the cross encoder; the
sentence-encoder root cause applies directly.

Run the offline structural tests with:

```bash
cd "$ENCODER_REPO_ROOT/tools/encoder-models"
PYTHONDONTWRITEBYTECODE=1 "$ENCODER_PYTHON" -m unittest -v test_manifest_tools.py
```
