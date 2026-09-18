---
title: Encoder Model Packaging
version: 0.3.0
status: working-internal
date: 2026-09-06
description: "How the pinned Arctic encoder and retained MiniLM floor become verified external artifacts and packaging inputs. 0.3.0: ENC-PACK — hand-staging instructions removed; release asset layout and fetch script described; shipped layouts documented for all four distribution paths."
---

# Encoder Model Packaging

The paths below identify the prepared packaging inputs. The Xcode and installer
entries remain proposals for the packaging lane to apply and qualify.

## Model records

The active WP-H model is `arctic-embed-s-w60`:

- HF source: `Snowflake/snowflake-arctic-embed-s`
- pinned revision and `model_version`:
  `e596f507467533e48a2e17c007f0e1dacc837b33`
- dimension 384, CLS pooling
- query prefix exactly
  `Represent this sentence for searching relevant passages: `; empty document
  prefix
- 60-word windows, overlap divisor 2, maximum 32 spans, maximum sequence 512
- tokenizer hash
  `07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3`

`minilm-l6-v2-w60` remains the audition floor and remains rebuildable. Its
profile retains mean pooling, no prefixes, and maximum sequence 256. The root
platform manifests describe the active Arctic model; the
`encoder-models-minilm-*.json` files preserve the floor records.

## Pipeline and external workspace

The repository destination for the pipeline is `tools/encoder-models/`. The
current controlled staging paths are (`ENCODER_WORK` is the encoder work root on a local volume, outside the repository; `<run>` is the build run label):

```text
pipeline: $ENCODER_WORK/arctic-embed-s-w60/work/<run>/pipeline
venv:     $ENCODER_WORK/arctic-embed-s-w60/work/<run>/venv
evidence: $ENCODER_WORK/arctic-embed-s-w60/work/<run>/evidence
output:   $ENCODER_WORK/arctic-embed-s-w60
apple:    $ENCODER_WORK/arctic-embed-s-w60/apple
linux:    $ENCODER_WORK/arctic-embed-s-w60/linux
```

Large binaries stay in this external workspace. They are never committed.

The pipeline contains:

| File | Purpose |
|---|---|
| `build-all.sh` | Resolve one profile and build both platform artifacts outside Git |
| `fetch-rust-triple.sh` | Copy or fetch four pinned Rust assets and verify them |
| `convert-coreml.py` | Convert the pinned BERT model to FP32 Core ML and compile it |
| `manifest_tools.py` | Create manifests and verify exact coverage, identity, and digests |
| `test_manifest_tools.py` | Offline fail-closed manifest and directory-hash tests |
| `encoder-models-apple.json` | Active Arctic Apple manifest |
| `encoder-models-linux.json` | Active Arctic Linux/Windows manifest |
| `encoder-models-minilm-*.json` | Retained MiniLM floor manifests |
| `vocab/vocab.txt` | Vendored WordPiece vocabulary shared by both current profiles |

## Prerequisites and frozen runtime

The successful Arctic conversion used Python 3.11.16, coremltools 9.0, torch
2.7.0, transformers 4.51.3, tokenizers 0.21.4, numpy 1.26.4, and safetensors
0.8.0. It used Xcode 27.0 build 27A5218g and `coremlcompiler` SHA-256
`946fca15b0ea36e51d675a50fc1d846fa338d8241cd3944e3d3e203762e40d81`.
The complete Python freeze lives in the external evidence directory.

## Build from the pinned local snapshot

```bash
PYTHON_BIN=$ENCODER_WORK/arctic-embed-s-w60/work/<run>/venv/bin/python \
tools/encoder-models/build-all.sh \
  --profile arctic \
  --output-root $ENCODER_WORK/arctic-embed-s-w60 \
  --source-dir ~/.cache/huggingface/hub/models--Snowflake--snowflake-arctic-embed-s/snapshots/e596f507467533e48a2e17c007f0e1dacc837b33 \
  --force
```

The local snapshot is the release path and performs no model download. Omitting
`--source-dir` is rejected unless the caller explicitly supplies
`--allow-network`. `--output-root` is always required, and the scripts reject a
binary output inside a Git checkout or the pipeline source directory.

The Linux flat manifest is also the required conversion source manifest. Before
model loading, the converter checks every registry field, the exact HF repository
and full revision, and the SHA-256 of `config.json`, `tokenizer.json`,
`model.safetensors`, and `vocab.txt` in the selected local snapshot. Network mode
resolves the exact revision first and applies the same checks to the resulting
local snapshot. The Apple manifest records those verified input digests and the
source-manifest digest.

## Apple artifact

The build creates:

```text
apple/ArcticEmbedS.mlpackage/   conversion intermediate, not shipped
apple/ArcticEmbedS.mlmodelc/    compiled artifact that ships
apple/vocab.txt
```

The converter exposes fixed `[1,512]` Int32 `input_ids` and `attention_mask`,
casts to the model's Int64 input internally, and returns Float32
`last_hidden_state` with shape `[1,512,384]`. CLS pooling remains external and
is selected by the registry row. Compute units remain `.all`.

`compute_precision=ct.precision.FLOAT32` is required. The rejected default-FP16
artifact overflowed the attention-mask sentinel to `-inf`; the generated graph
then evaluated `0 * -inf` for valid tokens and returned NaNs under both `.all`
and CPU-only preflights. The FP32 artifact returned finite vectors and matched
all six ONNX references at cosine `>= 0.9999999999996002`.

The active Apple manifest records the shipped directory digest
`6c44eca8a3347ed5a20fb7c22d4fd08ea58d4422e3fbadc963db28fdb42aef42`,
the 133,779,183-byte compiled directory, and the intermediate package's framed
directory digest and size. Directory hashes use sorted POSIX relative paths,
framed path lengths, framed file sizes, and file bytes; symlinks are rejected.

## Linux and Windows artifact

The build creates:

```text
linux/config.json
linux/tokenizer.json
linux/model.safetensors
linux/vocab.txt
```

Normal operation verifies the checked-in manifest and fails on missing or extra
entries, metadata disagreement, invalid hash syntax, digest mismatch, or a
`tokenizer_hash` that differs from `sha256(vocab.txt)`. `--record-manifest` is a
separate bootstrap mode for a trusted pinned-revision copy or download; it
atomically writes the manifest and immediately verifies it.

## Release asset

The encoder model ships as a versioned release asset on the
`codedaptive/mootx01-ee` repository, tag `models-arctic-embed-s-w60`.

| Asset | Platform | sha256 |
|---|---|---|
| `arctic-embed-s-w60-apple.tar.gz` | macOS (Apple Silicon + Intel) | `88e476c51999e7ecf8548084cf0e43bb88b92be298a79d50cc5fb974fb6e2d0a` |
| `arctic-embed-s-w60-linux.tar.gz` | Linux + Windows | `5f71131f1452c15da4f94481b7b1e3fbf7d9ad9b67289e39a3e8b964f100533c` |

Both assets are verified by `manifest_tools.py verify` against their platform
manifests (HF repo `Snowflake/snowflake-arctic-embed-s`, revision
`e596f507467533e48a2e17c007f0e1dacc837b33`).

## Fetch script

`tools/encoder-models/fetch-release.sh` downloads, sha256-verifies, and
manifest-verifies the model for a given platform:

```bash
tools/encoder-models/fetch-release.sh apple <dest-dir>
tools/encoder-models/fetch-release.sh linux <dest-dir>
```

The script is idempotent: an already-verified dest-dir is left intact. Force
re-download with `FETCH_NOCACHE=1`. Uses `gh` CLI for authenticated
private-repo access; falls back to curl/wget with `GH_TOKEN`.

## Shipped layouts

### macOS/iOS app bundle

The release CI places the Apple model at
`share/mootx01/models/arctic-embed-s-w60/` in the build workspace, then the
Xcode build (via `project.yml` `Resources/arctic-embed-s-w60` folder resource)
bundles it into the `.app`. At runtime, `ModelDirectoryResolver` slot 2 (bundle
resources) finds it by model ID.

```text
Mootx01.app/Contents/Resources/arctic-embed-s-w60/ArcticEmbedS.mlmodelc/
Mootx01.app/Contents/Resources/arctic-embed-s-w60/vocab.txt
```

### macOS/Linux release tarball

The release tarball ships model files at the share path beside the binary:

```text
mootx01
moot-mgr
share/mootx01/models/arctic-embed-s-w60/ArcticEmbedS.mlmodelc/   (Apple)
share/mootx01/models/arctic-embed-s-w60/vocab.txt

share/mootx01/models/arctic-embed-s-w60/config.json              (Linux)
share/mootx01/models/arctic-embed-s-w60/tokenizer.json
share/mootx01/models/arctic-embed-s-w60/model.safetensors
share/mootx01/models/arctic-embed-s-w60/vocab.txt
```

`scripts/install.sh` extracts the tarball and copies the `share/` tree one
level above the binary install directory so the resolver's share slot resolves:

```text
<install_prefix>/bin/mootx01
<install_prefix>/share/mootx01/models/arctic-embed-s-w60/<files>
```

### Windows installer (Inno Setup)

`distribution/windows/mootx01-setup.iss` installs from
`{#BinDir}\share\mootx01\models\arctic-embed-s-w60\*` to
`{app}\..\share\mootx01\models\arctic-embed-s-w60` (where
`{app}` = `{%USERPROFILE}\.mootx01\bin`), matching the share-slot layout.

### Windows zip (install.ps1)

`scripts/install.ps1` copies the extracted `share\mootx01\models\arctic-embed-s-w60\`
directory from the zip to `<install_dir>\..\share\mootx01\models\arctic-embed-s-w60\`.

## Untracked packaging inputs (app bundle path)

The `apps/Mootx01-App/Resources/arctic-embed-s-w60/` directory is a
packaging input placed by the release CI before the Xcode build. It is
excluded from Git (`.gitignore`). The release CI fetches it via
`fetch-release.sh apple`. Only source, manifests, tests, and documentation
enter version control; the large binary model files do not.

## Runtime integrity and registry handoff

The platform manifests record every packaged file digest. Runtime resolution
uses `sha256(vocab.txt)` as the fast sentinel and treats a mismatch as model
unavailable. Large model artifacts are verified by this build pipeline and
sealed by the later packaging step.

The active seed row and resolver tables must match the Arctic manifests exactly.
Those are product changes owned outside this pipeline. A different
`model_version`, tokenizer hash, pooling policy, prefix, dimension, sequence
limit, or window geometry requires coordinated registry and re-index handling.

The existing data-directory search slot remains reserved for a later download
feature: `<data directory>/models/<model_id>/` precedes bundled or installed
resources. WP-H does not add a download mechanism.
