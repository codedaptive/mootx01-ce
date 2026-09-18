#!/usr/bin/env python3
"""Manifest creation and fail-closed artifact verification for encoder models."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import sys
from pathlib import Path
from typing import Any, Iterable


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
LINUX_PATHS = {"config.json", "tokenizer.json", "model.safetensors", "vocab.txt"}
DIRECTORY_HASH_ALGORITHM = "mootx01-directory-sha256-v1"
DIRECTORY_HASH_DOMAIN = b"mootx01-directory-sha256-v1\0"


class ManifestError(ValueError):
    """A manifest is incomplete, malformed, or disagrees with its artifacts."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def directory_sha256(directory: Path) -> str:
    """Hash a directory with framed POSIX relative paths, sizes, and bytes.

    v1 framing is:
      domain-tag || repeated(u64be(path-byte-count), path-utf8,
                             u64be(file-byte-count), file-bytes)
    Files are ordered by their POSIX relative path. Symlinks are rejected so
    the digest never depends on a target outside the artifact directory.
    """
    if not directory.is_dir():
        raise ManifestError(f"not a directory: {directory}")
    files: list[tuple[str, Path]] = []
    for child in directory.rglob("*"):
        if child.is_symlink():
            raise ManifestError(f"symlink is not allowed in directory artifact: {child}")
        if child.is_file():
            files.append((child.relative_to(directory).as_posix(), child))
    if not files:
        raise ManifestError(f"directory artifact contains no files: {directory}")
    digest = hashlib.sha256(DIRECTORY_HASH_DOMAIN)
    for relative, child in sorted(files):
        path_bytes = relative.encode("utf-8")
        size = child.stat().st_size
        digest.update(struct.pack(">Q", len(path_bytes)))
        digest.update(path_bytes)
        digest.update(struct.pack(">Q", size))
        with child.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def artifact_digest(path: Path, file_type: str | None) -> str:
    if file_type in {"mlmodelc_dir", "directory"}:
        return directory_sha256(path)
    if file_type is not None:
        raise ManifestError(f"unsupported manifest file type {file_type!r}")
    if not path.is_file():
        raise ManifestError(f"not a regular file: {path}")
    return sha256_file(path)


def model_record(
    *,
    model_id: str,
    revision: str,
    dim: int,
    pooling: str,
    query_prefix: str,
    doc_prefix: str,
    window_words: int,
    overlap_divisor: int,
    max_spans: int,
    max_sequence: int,
    tokenizer_hash: str,
    files: list[dict[str, str]],
    ext: dict[str, Any],
) -> dict[str, Any]:
    if pooling not in {"mean", "cls"}:
        raise ManifestError(f"pooling must be mean or cls, got {pooling!r}")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ManifestError("revision must be a full lowercase 40-character git hash")
    if not SHA256_RE.fullmatch(tokenizer_hash):
        raise ManifestError("tokenizer_hash must be a lowercase sha256")
    for name, value in {
        "dim": dim,
        "window_words": window_words,
        "overlap_divisor": overlap_divisor,
        "max_spans": max_spans,
        "max_sequence": max_sequence,
    }.items():
        if value < 1:
            raise ManifestError(f"{name} must be positive")
    return {
        "model_id": model_id,
        "model_version": revision,
        "dim": dim,
        "pooling": pooling,
        "query_prefix": query_prefix,
        "doc_prefix": doc_prefix,
        "window_words": window_words,
        "overlap_divisor": overlap_divisor,
        "max_spans": max_spans,
        "max_sequence": max_sequence,
        "tokenizer_hash": tokenizer_hash,
        "files": files,
        "ext": ext,
    }


def cross_encoder_record(
    *,
    model_id: str,
    revision: str,
    max_sequence: int,
    pool: int,
    head: int,
    spans: int,
    rrf_k: int,
    tokenizer_hash: str,
    files: list[dict[str, str]],
    ext: dict[str, Any],
) -> dict[str, Any]:
    """A cross-encoder manifest: the `CrossEncoderProfile` fields plus files.

    A cross encoder scores (query, span) pairs to one logit; it has no
    dimension, pooling, prefixes or span geometry, so its record carries the
    profile's operating limits instead. `kind` distinguishes it from an
    encoder record so a verifier never reads one as the other.
    """
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ManifestError("revision must be a full lowercase 40-character git hash")
    if not SHA256_RE.fullmatch(tokenizer_hash):
        raise ManifestError("tokenizer_hash must be a lowercase sha256")
    for name, value in {
        "max_sequence": max_sequence,
        "pool": pool,
        "head": head,
        "spans": spans,
        "rrf_k": rrf_k,
    }.items():
        if value < 1:
            raise ManifestError(f"{name} must be positive")
    if head > pool:
        raise ManifestError("head must not exceed pool")
    return {
        "kind": "cross_encoder",
        "model_id": model_id,
        "model_version": revision,
        "max_sequence": max_sequence,
        "pool": pool,
        "head": head,
        "spans": spans,
        "rrf_k": rrf_k,
        "tokenizer_hash": tokenizer_hash,
        "files": files,
        "ext": ext,
    }


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(json.dumps(manifest, indent=2, sort_keys=False) + "\n")
    temporary.replace(path)


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"cannot read manifest {path}: {error}") from error
    if not isinstance(value, dict):
        raise ManifestError(f"manifest root must be an object: {path}")
    return value


def _file_entries(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        raise ManifestError("manifest files must be a non-empty array")
    seen: set[str] = set()
    checked: list[dict[str, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ManifestError("every manifest file entry must be an object")
        path = entry.get("path")
        expected = entry.get("sha256")
        if not isinstance(path, str) or not path or Path(path).is_absolute() or ".." in Path(path).parts:
            raise ManifestError(f"unsafe manifest path {path!r}")
        if path in seen:
            raise ManifestError(f"duplicate manifest path {path!r}")
        seen.add(path)
        if not isinstance(expected, str) or not SHA256_RE.fullmatch(expected):
            raise ManifestError(f"{path}: sha256 is absent or not 64 lowercase hex characters")
        checked.append(entry)
    return checked


def validate_coverage(manifest: dict[str, Any], platform: str) -> list[dict[str, Any]]:
    entries = _file_entries(manifest)
    paths = {entry["path"] for entry in entries}
    if platform == "linux":
        if paths != LINUX_PATHS:
            raise ManifestError(
                f"linux manifest coverage must be exactly {sorted(LINUX_PATHS)}, got {sorted(paths)}"
            )
    elif platform == "apple":
        model_entries = [entry for entry in entries if entry.get("type") == "mlmodelc_dir"]
        if len(model_entries) != 1 or paths != {"vocab.txt", model_entries[0]["path"]}:
            raise ManifestError("apple manifest must cover exactly vocab.txt and one mlmodelc_dir")
        if not model_entries[0]["path"].endswith(".mlmodelc"):
            raise ManifestError("apple directory artifact must end in .mlmodelc")
    else:
        raise ManifestError(f"unsupported platform {platform!r}")
    return entries


def validate_identity(manifest: dict[str, Any], expected: dict[str, Any]) -> None:
    for field, value in expected.items():
        if manifest.get(field) != value:
            raise ManifestError(
                f"manifest {field} mismatch; expected {value!r}, got {manifest.get(field)!r}"
            )


def verify_manifest_files(
    manifest_path: Path,
    root: Path,
    platform: str,
    expected_identity: dict[str, Any] | None = None,
) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    if expected_identity is not None:
        validate_identity(manifest, expected_identity)
    entries = validate_coverage(manifest, platform)
    for entry in entries:
        artifact = root / entry["path"]
        actual = artifact_digest(artifact, entry.get("type"))
        if actual != entry["sha256"]:
            raise ManifestError(
                f"{entry['path']}: sha256 mismatch; expected {entry['sha256']}, got {actual}"
            )
    vocab_hash = next(entry["sha256"] for entry in entries if entry["path"] == "vocab.txt")
    if manifest.get("tokenizer_hash") != vocab_hash:
        raise ManifestError(
            f"tokenizer_hash {manifest.get('tokenizer_hash')!r} does not equal vocab.txt sha256 {vocab_hash}"
        )
    return manifest


def verify_nuextract_manifest(
    manifest_path: Path,
    root: Path,
    platform: str,
) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    validate_identity(manifest, {
        "kind": "fact_extractor",
        "model_id": "numind/NuExtract-1.5-tiny",
        "model_version": "63e2e80c804d9c97f3f19a4aa25613e7beca83c9",
        "architecture": "qwen2",
    })
    entries = _file_entries(manifest)
    paths = {entry["path"] for entry in entries}
    if platform == "apple":
        models = [
            entry for entry in entries if entry["path"].endswith(".aimodel")
        ]
        if "tokenizer.json" not in paths \
                or (paths - {"tokenizer.json"}) != {entry["path"] for entry in models} \
                or len(models) != 1 or models[0].get("type") != "directory":
            raise ManifestError(
                "Apple NuExtract manifest must cover tokenizer.json and one .aimodel directory")
    elif platform == "linux":
        if paths != {"model.gguf", "tokenizer.json"}:
            raise ManifestError(
                "Linux NuExtract manifest must cover exactly model.gguf and tokenizer.json")
    else:
        raise ManifestError(f"unsupported platform {platform!r}")
    for entry in entries:
        actual = artifact_digest(root / entry["path"], entry.get("type"))
        if actual != entry["sha256"]:
            raise ManifestError(
                f"{entry['path']}: sha256 mismatch; expected {entry['sha256']}, got {actual}")
    tokenizer_hash = next(
        entry["sha256"] for entry in entries if entry["path"] == "tokenizer.json")
    if manifest.get("tokenizer_hash") != tokenizer_hash:
        raise ManifestError("NuExtract tokenizer_hash does not equal tokenizer.json sha256")
    return manifest


def verify_source_manifest(
    manifest_path: Path,
    source_root: Path,
    *,
    expected_identity: dict[str, Any],
    hf_repo: str,
    hf_revision: str,
) -> dict[str, Any]:
    """Verify a pinned HF snapshot's registry identity and all source bytes."""
    if not re.fullmatch(r"[0-9a-f]{40}", hf_revision):
        raise ManifestError("source hf_revision must be a full lowercase 40-character git hash")
    manifest = verify_manifest_files(
        manifest_path,
        source_root,
        "linux",
        expected_identity=expected_identity,
    )
    ext = manifest.get("ext")
    if not isinstance(ext, dict):
        raise ManifestError("source manifest ext must record hf_repo and hf_revision")
    if ext.get("hf_repo") != hf_repo:
        raise ManifestError(
            f"source manifest hf_repo mismatch; expected {hf_repo!r}, got {ext.get('hf_repo')!r}"
        )
    if ext.get("hf_revision") != hf_revision:
        raise ManifestError(
            "source manifest hf_revision does not equal the requested full revision"
        )
    return manifest


def linux_file_entries(root: Path) -> list[dict[str, str]]:
    return [
        {"path": name, "sha256": sha256_file(root / name)}
        for name in ("config.json", "tokenizer.json", "model.safetensors", "vocab.txt")
    ]


def _add_cross_record_fields(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--hf-repo", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--max-sequence", required=True, type=int)
    parser.add_argument("--pool", required=True, type=int)
    parser.add_argument("--head", required=True, type=int)
    parser.add_argument("--spans", required=True, type=int)
    parser.add_argument("--rrf-k", required=True, type=int)


def cross_identity(args: argparse.Namespace) -> dict[str, Any]:
    """The identity fields a cross-encoder manifest must match."""
    return {
        "kind": "cross_encoder",
        "model_id": args.model_id,
        "model_version": args.revision,
        "max_sequence": args.max_sequence,
        "pool": args.pool,
        "head": args.head,
        "spans": args.spans,
        "rrf_k": args.rrf_k,
    }


def _add_record_fields(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--hf-repo", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--dim", required=True, type=int)
    parser.add_argument("--pooling", required=True, choices=("mean", "cls"))
    parser.add_argument("--query-prefix", required=True)
    parser.add_argument("--doc-prefix", required=True)
    parser.add_argument("--window-words", required=True, type=int)
    parser.add_argument("--overlap-divisor", required=True, type=int)
    parser.add_argument("--max-spans", required=True, type=int)
    parser.add_argument("--max-sequence", required=True, type=int)


def _identity_from_args(args: argparse.Namespace) -> dict[str, Any]:
    return {
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


def _main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)

    verify = subcommands.add_parser("verify", help="verify exact coverage and every artifact digest")
    verify.add_argument("--manifest", required=True, type=Path)
    verify.add_argument("--root", required=True, type=Path)
    verify.add_argument("--platform", required=True, choices=("apple", "linux"))
    _add_record_fields(verify)

    record = subcommands.add_parser("record-linux", help="write a Linux manifest from local artifacts")
    record.add_argument("--manifest", required=True, type=Path)
    record.add_argument("--root", required=True, type=Path)
    _add_record_fields(record)

    verify_cross = subcommands.add_parser(
        "verify-cross", help="verify a cross-encoder manifest's coverage, identity and digests"
    )
    verify_cross.add_argument("--manifest", required=True, type=Path)
    verify_cross.add_argument("--root", required=True, type=Path)
    verify_cross.add_argument("--platform", required=True, choices=("apple", "linux"))
    _add_cross_record_fields(verify_cross)

    record_cross = subcommands.add_parser(
        "record-linux-cross", help="write a cross-encoder Linux manifest from local artifacts"
    )
    record_cross.add_argument("--manifest", required=True, type=Path)
    record_cross.add_argument("--root", required=True, type=Path)
    _add_cross_record_fields(record_cross)

    verify_nuextract = subcommands.add_parser(
        "verify-nuextract", help="verify a NuExtract fact-extractor manifest and artifacts"
    )
    verify_nuextract.add_argument("--manifest", required=True, type=Path)
    verify_nuextract.add_argument("--root", required=True, type=Path)
    verify_nuextract.add_argument(
        "--platform", required=True, choices=("apple", "linux"))

    args = parser.parse_args(argv)
    try:
        if args.command == "verify-nuextract":
            verify_nuextract_manifest(args.manifest, args.root, args.platform)
            print(f"verified {args.platform} NuExtract manifest: {args.manifest}")
            return 0

        if args.command == "verify-cross":
            verify_manifest_files(
                args.manifest, args.root, args.platform, expected_identity=cross_identity(args)
            )
            print(f"verified {args.platform} cross-encoder manifest: {args.manifest}")
            return 0

        if args.command == "record-linux-cross":
            entries = linux_file_entries(args.root)
            vocab_hash = next(entry["sha256"] for entry in entries if entry["path"] == "vocab.txt")
            manifest = cross_encoder_record(
                model_id=args.model_id,
                revision=args.revision,
                max_sequence=args.max_sequence,
                pool=args.pool,
                head=args.head,
                spans=args.spans,
                rrf_k=args.rrf_k,
                tokenizer_hash=vocab_hash,
                files=entries,
                ext={
                    "hf_repo": args.hf_repo,
                    "hf_revision": args.revision,
                    "source": "huggingface-pinned-revision",
                },
            )
            write_manifest(args.manifest, manifest)
            verify_manifest_files(args.manifest, args.root, "linux", expected_identity=cross_identity(args))
            print(f"recorded and verified linux cross-encoder manifest: {args.manifest}")
            return 0

        if args.command == "verify":
            verify_manifest_files(
                args.manifest,
                args.root,
                args.platform,
                expected_identity=_identity_from_args(args),
            )
            print(f"verified {args.platform} manifest: {args.manifest}")
            return 0

        entries = linux_file_entries(args.root)
        vocab_hash = next(entry["sha256"] for entry in entries if entry["path"] == "vocab.txt")
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
            files=entries,
            ext={
                "hf_repo": args.hf_repo,
                "hf_revision": args.revision,
                "source": "huggingface-pinned-revision",
            },
        )
        write_manifest(args.manifest, manifest)
        verify_manifest_files(args.manifest, args.root, "linux")
        print(f"recorded and verified linux manifest: {args.manifest}")
        return 0
    except ManifestError as error:
        print(f"manifest error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(_main())
