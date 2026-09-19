#!/usr/bin/env python3
"""Export a pinned BERT-family model as a Core AI `.aimodel` with a dynamic
batch and sequence length: the Arctic sentence encoder with a CLS-pooled
output (ADR-028 E4), or the ms-marco pair classifier with a logit output
(ADR-029 D2, `--kind cross-encoder`).

This is the one Apple asset per model (ADR-029): `[B, L]` Int32 inputs with
B in 1...64 and L in 1...512, so the seams on macOS 27 and iOS 27 pad a chunk
to its longest text and run it in one inference. The encoder returns
`pooled` `[B, 384]`, the CLS token state of each row, pooled inside so a
padded row cannot be pooled wrongly; the cross encoder returns `logits` `[B]`.

The dtype is float32 throughout. The earlier FP16 CoreML conversion produced
NaNs through attention-mask overflow; that case is the regression check at
the end of this script: a batch padded with a full row of mask zeros must
still produce finite vectors for every row.

Runs from the Core AI PyTorch environment (coreai-torch and its runtime);
name it with PYTHON_BIN, as the README's Arctic build does. The model is
loaded from a verified local snapshot only; nothing is fetched.

Outputs, under --output-dir:
  <artifact-name>.aimodel          the Core AI asset
  <artifact-name>.export.json      source digests, shapes, reference vectors
                                   for the fixture sentences (float32), and
                                   the max abs difference between the
                                   exported program and the HF model
With --manifest, the apple manifest gains (or replaces) the asset's
`aimodel_dir` entry, digested the way `fetch-release.sh` verifies it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
from pathlib import Path

import numpy as np
import torch
import transformers
from coreai.runtime import AIModelAssetMetadata
from coreai_torch import TorchConverter, get_decomp_table

sys.path.insert(0, str(Path(__file__).resolve().parent))
import manifest_tools  # noqa: E402  (beside this script)

# The same two sentences the CoreML seam's fixture uses, plus one long
# passage, so the pad path (row two and three padded to the longest) is
# exercised at export time.
FIXTURE_TEXTS = [
    "Represent this sentence for searching relevant passages: what is the capital of france",
    "the api timeout is 30 seconds",
    "grocery list apples and oranges and a long tail of words to make this row the longest "
    "of the three so the other two rows are padded with mask zeros behind their tokens",
]
SOURCE_FILES = ("config.json", "tokenizer.json", "model.safetensors", "vocab.txt")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class PooledCLS(torch.nn.Module):
    """Int32 `[B, L]` ids and mask in; the CLS token state `[B, dim]` out."""

    def __init__(self, wrapped: torch.nn.Module) -> None:
        super().__init__()
        self.wrapped = wrapped

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        states = self.wrapped(
            input_ids=input_ids.to(dtype=torch.int64),
            attention_mask=attention_mask.to(dtype=torch.int64),
            return_dict=False,
        )[0]
        return states[:, 0, :]


class PooledMean(torch.nn.Module):
    """Int32 `[B, L]` ids and mask in; the mask-weighted mean of the token
    states `[B, dim]` out, the pooling the MiniLM profile declares. The mask
    is applied inside so a padded row pools only its real tokens, and an
    all-pad row divides by one instead of zero, as the Rust and CoreML
    mean-pooling paths do."""

    def __init__(self, wrapped: torch.nn.Module) -> None:
        super().__init__()
        self.wrapped = wrapped

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        states = self.wrapped(
            input_ids=input_ids.to(dtype=torch.int64),
            attention_mask=attention_mask.to(dtype=torch.int64),
            return_dict=False,
        )[0]
        mask = attention_mask.to(dtype=states.dtype).unsqueeze(-1)
        summed = (states * mask).sum(dim=1)
        counts = mask.sum(dim=1).clamp(min=1.0)
        return summed / counts


class PairLogit(torch.nn.Module):
    """Int32 `[B, L]` ids, mask and segment ids in; one logit per row out."""

    def __init__(self, wrapped: torch.nn.Module) -> None:
        super().__init__()
        self.wrapped = wrapped

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor, token_type_ids: torch.Tensor) -> torch.Tensor:
        logits = self.wrapped(
            input_ids=input_ids.to(dtype=torch.int64),
            attention_mask=attention_mask.to(dtype=torch.int64),
            token_type_ids=token_type_ids.to(dtype=torch.int64),
            return_dict=False,
        )[0]
        return logits[:, 0]


# The pair fixture: one query against three spans of different lengths, so
# the padded rows of a batch are exercised at export time.
PAIR_QUERY = "what is the capital of france"
PAIR_SPANS = [
    "paris is the capital and largest city of france",
    "the api timeout is 30 seconds",
    "grocery list apples and oranges and a long tail of words to make this row the longest "
    "of the three so the other two rows are padded with mask zeros behind their tokens",
]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    result.add_argument("--source-dir", required=True, type=Path, help="verified local HF snapshot of the encoder")
    result.add_argument("--output-dir", required=True, type=Path)
    result.add_argument("--kind", choices=("encoder", "cross-encoder"), default="encoder",
                        help="encoder: pooled [B, dim] output (see --pooling); cross-encoder: one logit per pair, [B] output")
    result.add_argument("--artifact-name", default="ArcticEmbedS")
    result.add_argument("--dim", type=int, default=384)
    result.add_argument("--pooling", choices=("cls", "mean"), default="cls",
                        help="encoder only: how the token states become the [B, dim] output; must match the profile's manifest pooling")
    result.add_argument("--max-batch", type=int, default=64, help="upper bound of the dynamic batch axis")
    result.add_argument("--max-sequence", type=int, default=512, help="upper bound of the dynamic sequence axis")
    result.add_argument("--vocab", type=Path, help="vocab.txt to place beside the asset (the Linux triple's, so both platforms hash the same file)")
    result.add_argument("--manifest", type=Path, help="apple manifest to record the asset in (aimodel_dir entry)")
    result.add_argument("--force", action="store_true", help="replace an existing asset")
    result.add_argument("--include-debug-info", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    source: Path = args.source_dir
    for name in SOURCE_FILES:
        if not (source / name).is_file():
            print(f"missing source file {source / name}", file=sys.stderr)
            return 2

    cross = args.kind == "cross-encoder"
    print(f"Loading {source} (local files only, float32, {args.kind})")
    tokenizer = transformers.AutoTokenizer.from_pretrained(source, local_files_only=True)
    if cross:
        # The sequence classifier carries its own pooler and the one-label
        # head; the export emits the logit directly, nothing pools outside.
        model = transformers.AutoModelForSequenceClassification.from_pretrained(
            source, local_files_only=True, attn_implementation="eager",
        )
        if int(getattr(model.config, "num_labels", 0)) != 1:
            print("only scalar (num_labels == 1) pair classifiers are supported", file=sys.stderr)
            return 2
        model.eval()
        model.to(torch.float32)
        encoded = tokenizer([PAIR_QUERY] * len(PAIR_SPANS), PAIR_SPANS, padding=True, truncation=True,
                            max_length=args.max_sequence, return_tensors="pt")
        wrapper = PairLogit(model).eval()
        fixture = {"query": PAIR_QUERY, "spans": PAIR_SPANS}
    else:
        model = transformers.AutoModel.from_pretrained(
            source, local_files_only=True, add_pooling_layer=False, attn_implementation="eager",
        )
        model.eval()
        model.to(torch.float32)
        hidden = int(model.config.hidden_size)
        if hidden != args.dim:
            print(f"model hidden_size {hidden} does not equal --dim {args.dim}", file=sys.stderr)
            return 2
        encoded = tokenizer(FIXTURE_TEXTS, padding=True, truncation=True, max_length=args.max_sequence, return_tensors="pt")
        # The profile's pooling is baked into the asset: the adapter reads
        # `pooled` as-is, so an asset pooled the wrong way would feed
        # incompatible vectors to recall (codex finding 2026-09-19).
        wrapper = (PooledMean(model) if args.pooling == "mean" else PooledCLS(model)).eval()
        fixture = {"texts": FIXTURE_TEXTS}

    # Reference inputs: three rows padded to the longest, so the export sees
    # a batch above one and a mask with zeros.
    input_ids = encoded["input_ids"].to(torch.int32)
    attention_mask = encoded["attention_mask"].to(torch.int32)
    inputs = {"input_ids": input_ids, "attention_mask": attention_mask}
    if cross:
        inputs["token_type_ids"] = encoded["token_type_ids"].to(torch.int32)
    with torch.inference_mode():
        reference = wrapper(**inputs).numpy().astype(np.float32)

    batch = torch.export.Dim("batch_size", min=1, max=args.max_batch)
    seq = torch.export.Dim("seq_len", min=1, max=args.max_sequence)
    dynamic_shapes = {name: {0: batch, 1: seq} for name in inputs}
    print(f"torch.export with dynamic batch 1..{args.max_batch} and sequence 1..{args.max_sequence}")
    exported = torch.export.export(wrapper, args=(), kwargs=inputs, dynamic_shapes=dynamic_shapes)
    exported = exported.run_decompositions(get_decomp_table())
    with torch.inference_mode():
        traced = exported.module()(**inputs).numpy().astype(np.float32)
    max_abs_diff = float(np.max(np.abs(traced - reference)))
    if not np.all(np.isfinite(traced)):
        print("exported program produced a non-finite value on the padded fixture batch", file=sys.stderr)
        return 3
    print(f"exported program vs HF model, max abs diff {max_abs_diff:.3e}")

    # The FP16 NaN regression: a row that is entirely pad (mask all zero)
    # inside a batch must not poison the batch. Float32 has no overflow
    # here; the check is kept so a future dtype change cannot pass silently.
    padded_inputs = {name: torch.cat([t, torch.zeros((1, t.shape[1]), dtype=torch.int32)]) for name, t in inputs.items()}
    with torch.inference_mode():
        padded = exported.module()(**padded_inputs).numpy()
    if not np.all(np.isfinite(padded[: input_ids.shape[0]])):
        print("an all-pad row made a real row non-finite (the FP16 attention-mask overflow shape)", file=sys.stderr)
        return 3

    mode = TorchConverter.Mode.DEBUG if args.include_debug_info else TorchConverter.Mode.RELEASE
    converter = TorchConverter(mode=mode).add_exported_program(
        exported_program=exported, input_names=list(inputs), output_names=["logits" if cross else "pooled"],
    )
    program = converter.to_coreai()
    program.optimize()

    output_dir: Path = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    asset_path = output_dir / f"{args.artifact_name}.aimodel"
    if asset_path.exists():
        if not args.force:
            print(f"{asset_path} exists; pass --force to replace it", file=sys.stderr)
            return 2
        shutil.rmtree(asset_path) if asset_path.is_dir() else asset_path.unlink()
    metadata = AIModelAssetMetadata()
    if cross:
        metadata.author = "sentence-transformers"
        metadata.license = "Apache-2.0"
        metadata.model_description = (
            "cross-encoder/ms-marco-MiniLM-L-6-v2 pair classifier, one logit per pair, float32, dynamic batch and sequence. "
            "Source: https://huggingface.co/cross-encoder/ms-marco-MiniLM-L-6-v2"
        )
    else:
        metadata.author = "Snowflake"
        metadata.license = "Apache-2.0"
        metadata.model_description = (
            f"{args.artifact_name} sentence encoder, {args.pooling} pooled, float32, dynamic batch and sequence. "
            "Source: https://huggingface.co/Snowflake/snowflake-arctic-embed-s"
        )
    metadata.creation_date = int(time.time())
    program.save_asset(asset_path, metadata)
    print(f"saved {asset_path}")
    if args.vocab is not None:
        shutil.copyfile(args.vocab, output_dir / "vocab.txt")
        print(f"placed vocab.txt beside the asset from {args.vocab}")

    record = {
        "artifact": asset_path.name,
        "asset_sha256": manifest_tools.artifact_digest(asset_path, "aimodel_dir" if asset_path.is_dir() else None),
        "dtype": "float32",
        "kind": args.kind,
        "inputs": {name: ["batch 1..%d" % args.max_batch, "seq 1..%d" % args.max_sequence, "int32"] for name in inputs},
        "output": {"logits": ["batch", "float32"]} if cross else {"pooled": ["batch", args.dim, "float32"], "pooling": "cls"},
        "source_dir": str(source),
        "source_files": {name: sha256(source / name) for name in SOURCE_FILES},
        "fixture": fixture,
        "fixture_token_counts": attention_mask.sum(dim=1).tolist(),
        "reference_vectors": reference.tolist(),
        "exported_vs_reference_max_abs_diff": max_abs_diff,
        "all_pad_row_finite": True,
        "coreai_torch": getattr(sys.modules["coreai_torch"], "__version__", "?"),
        "torch": torch.__version__,
        "transformers": transformers.__version__,
    }
    (output_dir / f"{args.artifact_name}.export.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"wrote {output_dir / (args.artifact_name + '.export.json')}")

    if args.manifest is not None:
        manifest = manifest_tools.load_manifest(args.manifest)
        entry = {"path": asset_path.name, "sha256": record["asset_sha256"], "type": "aimodel_dir"}
        files = [f for f in manifest.get("files", []) if f.get("type") != "aimodel_dir"]
        files.append(entry)
        manifest["files"] = files
        manifest.setdefault("ext", {})["coreai_export"] = {
            "dtype": "float32", "batch": [1, args.max_batch], "sequence": [1, args.max_sequence],
            "output": "logits" if cross else "pooled", "coreai_torch": record["coreai_torch"],
        }
        if not cross:
            manifest["ext"]["coreai_export"]["pooling"] = "cls"
        manifest_tools.validate_coverage(manifest, "apple")
        manifest_tools.write_manifest(args.manifest, manifest)
        print(f"recorded {asset_path.name} in {args.manifest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
