#!/usr/bin/env python3
"""Convert a pinned BERT encoder to CoreML and record a verified manifest."""

from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

from manifest_tools import (
    DIRECTORY_HASH_ALGORITHM,
    ManifestError,
    cross_encoder_record,
    directory_sha256,
    model_record,
    sha256_file,
    verify_manifest_files,
    verify_source_manifest,
    write_manifest,
)


SCRIPT_DIR = Path(__file__).resolve().parent


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--model-id", required=True)
    result.add_argument("--hf-repo", required=True)
    result.add_argument("--revision", required=True)
    result.add_argument(
        "--model-source",
        help="Local pinned HF snapshot to load instead of resolving --hf-repo (recommended for release builds)",
    )
    result.add_argument(
        "--source-manifest",
        required=True,
        type=Path,
        help="Linux flat manifest that pins identity and all four source files",
    )
    result.add_argument("--output-dir", required=True, type=Path)
    result.add_argument("--manifest", required=True, type=Path)
    result.add_argument("--vocab", required=True, type=Path)
    result.add_argument("--artifact-name", required=True)
    result.add_argument(
        "--kind",
        default="encoder",
        choices=("encoder", "cross-encoder"),
        help="encoder: last_hidden_state of a BERT encoder; cross-encoder: one logit from a BERT sequence classifier",
    )
    # Encoder identity (required with --kind encoder).
    result.add_argument("--dim", type=int)
    result.add_argument("--pooling", choices=("mean", "cls"))
    result.add_argument("--query-prefix")
    result.add_argument("--doc-prefix")
    result.add_argument("--window-words", type=int)
    result.add_argument("--overlap-divisor", type=int)
    result.add_argument("--max-spans", type=int)
    # Cross-encoder identity (required with --kind cross-encoder).
    result.add_argument("--pool", type=int)
    result.add_argument("--head", type=int)
    result.add_argument("--spans", type=int)
    result.add_argument("--rrf-k", type=int)
    result.add_argument("--max-sequence", required=True, type=int)
    result.add_argument("--deployment-target", default="macOS15", choices=("macOS15", "iOS18"))
    result.add_argument("--allow-network", action="store_true", help="Permit HF resolution outside the local cache")
    result.add_argument("--force", action="store_true", help="Replace exact output artifacts if they already exist")
    return result


def ensure_safe_output(path: Path) -> Path:
    if not path.is_absolute():
        raise ManifestError("--output-dir must be absolute")
    resolved = path.resolve()
    if resolved == Path(resolved.anchor):
        raise ManifestError("refusing to use a filesystem root as --output-dir")
    if resolved == SCRIPT_DIR or SCRIPT_DIR in resolved.parents:
        raise ManifestError("binary output must not be inside the pipeline source directory")
    probe = resolved
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    for ancestor in (probe, *probe.parents):
        if (ancestor / ".git").exists():
            raise ManifestError(f"binary output must not be inside a git checkout: {resolved}")
    return resolved


def command_observation(command: list[str]) -> dict[str, object]:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    return {
        "command": command,
        "exit_code": result.returncode,
        "stdout": result.stdout.strip(),
        "warnings": [line for line in result.stderr.splitlines() if line.strip()],
    }


def required_stdout(command: list[str], purpose: str) -> tuple[str, list[str]]:
    observation = command_observation(command)
    if observation["exit_code"] != 0 or not observation["stdout"]:
        raise ManifestError(f"cannot determine {purpose}: {observation}")
    return str(observation["stdout"]), list(observation["warnings"])  # type: ignore[arg-type]


def directory_size(directory: Path) -> int:
    return sum(child.stat().st_size for child in directory.rglob("*") if child.is_file())


def xcode_provenance(compile_warnings: list[str]) -> dict[str, object]:
    xcode_output, xcode_warnings = required_stdout(["xcodebuild", "-version"], "Xcode version")
    developer_dir, developer_warnings = required_stdout(["xcode-select", "-p"], "Xcode developer directory")
    compiler_path_text, find_warnings = required_stdout(
        ["xcrun", "--find", "coremlcompiler"], "coremlcompiler path"
    )
    compiler_path = Path(compiler_path_text)
    if not compiler_path.is_file():
        raise ManifestError(f"coremlcompiler path is not a file: {compiler_path}")
    xcode_lines = xcode_output.splitlines()
    return {
        "xcode": {
            "version": xcode_lines[0] if xcode_lines else xcode_output,
            "build_version": xcode_lines[1] if len(xcode_lines) > 1 else "",
            "developer_dir": developer_dir,
            "warnings": xcode_warnings + developer_warnings,
        },
        "coremlcompiler": {
            "path": str(compiler_path),
            "sha256": sha256_file(compiler_path),
            "discovery_warnings": find_warnings,
            "compile_warnings": compile_warnings,
        },
    }


def main() -> int:
    args = parser().parse_args()
    try:
        if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
            raise ManifestError("--revision must be a full lowercase 40-character git hash")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", args.model_id):
            raise ManifestError("--model-id contains unsafe characters")
        if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", args.hf_repo):
            raise ManifestError("--hf-repo must be a safe OWNER/NAME")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", args.artifact_name):
            raise ManifestError("--artifact-name contains unsafe characters")
        output_dir = ensure_safe_output(args.output_dir)
        if not args.vocab.is_file():
            raise ManifestError(f"vocab is missing: {args.vocab}")
        cross = args.kind == "cross-encoder"
        required_by_kind = (
            ("pool", "head", "spans", "rrf_k")
            if cross
            else ("dim", "pooling", "query_prefix", "doc_prefix", "window_words", "overlap_divisor", "max_spans")
        )
        for name in required_by_kind:
            if getattr(args, name) is None:
                raise ManifestError(f"--{name.replace('_', '-')} is required with --kind {args.kind}")

        try:
            import coremltools as ct  # type: ignore
            import numpy as np  # type: ignore
            import torch  # type: ignore
            import transformers  # type: ignore
            from huggingface_hub import snapshot_download  # type: ignore
            from transformers import AutoModel, AutoModelForSequenceClassification  # type: ignore
        except ImportError as error:
            raise ManifestError(
                f"missing conversion prerequisite {error}; use the pinned WP-H Python 3.11 environment"
            ) from error

        if args.model_source:
            source_path = Path(args.model_source).resolve()
            if not source_path.is_dir():
                raise ManifestError(f"--model-source is not a directory: {source_path}")
        else:
            source_path = Path(
                snapshot_download(
                    repo_id=args.hf_repo,
                    revision=args.revision,
                    allow_patterns=[
                        "config.json",
                        "tokenizer.json",
                        "model.safetensors",
                        "vocab.txt",
                    ],
                    local_files_only=not args.allow_network,
                )
            ).resolve()

        if cross:
            expected_source_identity = {
                "kind": "cross_encoder",
                "model_id": args.model_id,
                "model_version": args.revision,
                "max_sequence": args.max_sequence,
                "pool": args.pool,
                "head": args.head,
                "spans": args.spans,
                "rrf_k": args.rrf_k,
            }
        else:
            expected_source_identity = {
                "model_id": args.model_id,
                "model_version": args.revision,
                "dim": args.dim,
                "pooling": args.pooling,
                "query_prefix": args.query_prefix,
                "doc_prefix": args.doc_prefix,
                "window_words": args.window_words,
                "overlap_divisor": args.overlap_divisor,
                "max_spans": args.max_spans,
                "max_sequence": args.max_sequence,
            }
        source_manifest_hash_before = sha256_file(args.source_manifest)
        source_manifest = verify_source_manifest(
            args.source_manifest,
            source_path,
            expected_identity=expected_source_identity,
            hf_repo=args.hf_repo,
            hf_revision=args.revision,
        )
        source_manifest_hash = sha256_file(args.source_manifest)
        if source_manifest_hash != source_manifest_hash_before:
            raise ManifestError("source manifest changed while it was being verified")
        source_file_hashes = {
            entry["path"]: entry["sha256"] for entry in source_manifest["files"]
        }
        if sha256_file(args.vocab) != source_file_hashes["vocab.txt"]:
            raise ManifestError("--vocab differs from the source manifest vocab.txt")

        print(f"Loading verified {args.hf_repo} @ {args.revision} from {source_path}")
        if cross:
            # The sequence classifier carries its own pooler (dense + tanh over
            # [CLS]) and the one-label classifier; the traced graph emits the
            # logit directly, so no pooling stays external.
            model = AutoModelForSequenceClassification.from_pretrained(
                source_path,
                local_files_only=True,
                attn_implementation="eager",
            )
            if int(getattr(model.config, "num_labels", 0)) != 1:
                raise ManifestError("only scalar (num_labels == 1) pair classifiers are supported")
        else:
            model = AutoModel.from_pretrained(
                source_path,
                local_files_only=True,
                add_pooling_layer=False,
                attn_implementation="eager",
            )
        model.eval()

        hidden_size = int(getattr(model.config, "hidden_size", 0))
        position_limit = int(getattr(model.config, "max_position_embeddings", 0))
        if not cross and hidden_size != args.dim:
            raise ManifestError(f"model hidden_size {hidden_size} does not equal --dim {args.dim}")
        if position_limit < args.max_sequence:
            raise ManifestError(
                f"model max_position_embeddings {position_limit} is below --max-sequence {args.max_sequence}"
            )
        class LastHiddenState(torch.nn.Module):
            """CoreML-facing Int32 inputs; BERT receives Int64 and emits one tensor."""

            def __init__(self, wrapped: torch.nn.Module) -> None:
                super().__init__()
                self.wrapped = wrapped

            def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
                output = self.wrapped(
                    input_ids=input_ids.to(dtype=torch.int64),
                    attention_mask=attention_mask.to(dtype=torch.int64),
                    return_dict=False,
                )
                return output[0]

        class PairLogit(torch.nn.Module):
            """CoreML-facing Int32 pair inputs (ids, mask, segment ids); emits [1, 1] logits."""

            def __init__(self, wrapped: torch.nn.Module) -> None:
                super().__init__()
                self.wrapped = wrapped

            def forward(
                self, input_ids: torch.Tensor, attention_mask: torch.Tensor, token_type_ids: torch.Tensor
            ) -> torch.Tensor:
                output = self.wrapped(
                    input_ids=input_ids.to(dtype=torch.int64),
                    attention_mask=attention_mask.to(dtype=torch.int64),
                    token_type_ids=token_type_ids.to(dtype=torch.int64),
                    return_dict=False,
                )
                return output[0]

        dummy_ids = torch.zeros((1, args.max_sequence), dtype=torch.int32)
        dummy_mask = torch.ones((1, args.max_sequence), dtype=torch.int32)
        if cross:
            wrapper = PairLogit(model).eval()
            dummy_types = torch.zeros((1, args.max_sequence), dtype=torch.int32)
            example_inputs = (dummy_ids, dummy_mask, dummy_types)
            expected_shape = (1, 1)
        else:
            wrapper = LastHiddenState(model).eval()
            example_inputs = (dummy_ids, dummy_mask)
            expected_shape = (1, args.max_sequence, args.dim)
        with torch.inference_mode():
            traced = torch.jit.trace(wrapper, example_inputs, strict=True)
            traced_output = traced(*example_inputs)
        if tuple(traced_output.shape) != expected_shape:
            raise ManifestError(
                f"traced output shape {tuple(traced_output.shape)} does not equal {expected_shape}"
            )

        output_dir.mkdir(parents=True, exist_ok=True)
        mlpackage_path = output_dir / f"{args.artifact_name}.mlpackage"
        mlmodelc_path = output_dir / f"{args.artifact_name}.mlmodelc"
        vocab_path = output_dir / "vocab.txt"
        existing = [path for path in (mlpackage_path, mlmodelc_path, vocab_path) if path.exists()]
        if existing and not args.force:
            raise ManifestError(f"output already exists; pass --force to replace: {existing[0]}")
        if args.force:
            for path in existing:
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()

        deployment_target = getattr(ct.target, args.deployment_target)
        print(f"Converting fixed [1,{args.max_sequence}] Int32 inputs to CoreML")
        coreml_inputs = [
            ct.TensorType(name="input_ids", shape=(1, args.max_sequence), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, args.max_sequence), dtype=np.int32),
        ]
        if cross:
            coreml_inputs.append(
                ct.TensorType(name="token_type_ids", shape=(1, args.max_sequence), dtype=np.int32)
            )
        output_name = "logits" if cross else "last_hidden_state"
        coreml_model = ct.convert(
            traced,
            convert_to="mlprogram",
            inputs=coreml_inputs,
            outputs=[
                ct.TensorType(name=output_name, dtype=np.float32),
            ],
            compute_precision=ct.precision.FLOAT32,
            compute_units=ct.ComputeUnit.ALL,
            minimum_deployment_target=deployment_target,
        )
        coreml_model.save(str(mlpackage_path))

        compile_result = subprocess.run(
            ["xcrun", "coremlcompiler", "compile", str(mlpackage_path), str(output_dir)],
            capture_output=True,
            text=True,
            check=False,
        )
        if compile_result.returncode != 0:
            raise ManifestError(f"coremlcompiler failed: {compile_result.stderr.strip()}")
        if not mlmodelc_path.is_dir():
            raise ManifestError(f"coremlcompiler did not create expected artifact: {mlmodelc_path}")
        shutil.copy2(args.vocab, vocab_path)

        vocab_hash = sha256_file(vocab_path)
        compile_warnings = [line for line in compile_result.stderr.splitlines() if line.strip()]
        apple_tools = xcode_provenance(compile_warnings)
        files = [
            {
                "path": mlmodelc_path.name,
                "sha256": directory_sha256(mlmodelc_path),
                "type": "mlmodelc_dir",
            },
            {"path": "vocab.txt", "sha256": vocab_hash},
        ]
        ext = {
                "hf_repo": args.hf_repo,
                "hf_revision": args.revision,
                "source": "huggingface-pinned-revision",
                "source_manifest_sha256": source_manifest_hash,
                "source_files": source_file_hashes,
                "coreml_compute_units": "all",
                "coreml_compute_precision": "float32",
                "coreml_output": {
                    "name": output_name,
                    "dtype": "float32",
                },
                "coreml_deployment_target": args.deployment_target,
                "directory_hash_algorithm": DIRECTORY_HASH_ALGORITHM,
                "artifacts": {
                    "mlpackage": {
                        "path": mlpackage_path.name,
                        "sha256": directory_sha256(mlpackage_path),
                        "size_bytes": directory_size(mlpackage_path),
                        "role": "conversion_intermediate_not_shipped",
                    },
                    "mlmodelc": {
                        "path": mlmodelc_path.name,
                        "size_bytes": directory_size(mlmodelc_path),
                        "role": "shipped",
                    },
                },
                "converter_script_sha256": sha256_file(Path(__file__).resolve()),
                "tools": {
                    "python": platform.python_version(),
                    "coremltools": str(ct.__version__),
                    "numpy": str(np.__version__),
                    "torch": str(torch.__version__),
                    "transformers": str(transformers.__version__),
                    **apple_tools,
                },
        }
        if cross:
            manifest = cross_encoder_record(
                model_id=args.model_id,
                revision=args.revision,
                max_sequence=args.max_sequence,
                pool=args.pool,
                head=args.head,
                spans=args.spans,
                rrf_k=args.rrf_k,
                tokenizer_hash=vocab_hash,
                files=files,
                ext=ext,
            )
        else:
            manifest = model_record(
                model_id=args.model_id,
                revision=args.revision,
                dim=args.dim,
                pooling=args.pooling,
                query_prefix=args.query_prefix,
                doc_prefix=args.doc_prefix,
                window_words=args.window_words,
                overlap_divisor=args.overlap_divisor,
                max_spans=args.max_spans,
                max_sequence=args.max_sequence,
                tokenizer_hash=vocab_hash,
                files=files,
                ext=ext,
            )
        write_manifest(args.manifest, manifest)
        verify_manifest_files(args.manifest, output_dir, "apple")
        print(json.dumps({"manifest": str(args.manifest), "output": str(output_dir)}, indent=2))
        return 0
    except ManifestError as error:
        print(f"conversion error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
