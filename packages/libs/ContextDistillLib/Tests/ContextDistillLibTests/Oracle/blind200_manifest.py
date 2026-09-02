#!/usr/bin/env python3
"""Shared fail-closed Blind-200 manifest and ordering helpers."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
from typing import Iterable, Sequence


SCHEMA_VERSION = "mootx01-blind-manifest-v1"
BED = "blind200"
COUNT = 200
SEED = "mootx01-blind-v1"
PROTOCOL = "v11.3"
REPRESENTATION = "model-plus"
CONVERTER_ID = "intent-span@intent-span-v22-authority-closure"
ORDERED_INPUT_DOMAIN = b"mootx01-ordered-input-v1\0"
HEX_SHA256 = re.compile(r"[0-9a-f]{64}")
UUID = re.compile(
    r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def selection_digest(drawer_id: str) -> str:
    return hashlib.sha256(
        SEED.encode("utf-8") + b"\0" + drawer_id.encode("utf-8")
    ).hexdigest()


def ordered_input_digest(records: Iterable[dict]) -> str:
    """Hash the exact ordered (full drawer UUID, source digest) sequence."""

    digest = hashlib.sha256(ORDERED_INPUT_DOMAIN)
    for record in records:
        digest.update(record["drawer_id"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(record["source_sha256"].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def validate_manifest(payload: dict) -> dict:
    if payload.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("unsupported Blind-200 manifest schema")
    if payload.get("bed") != BED or payload.get("record_count") != COUNT:
        raise ValueError("manifest is not an exact 200-record blind200 bed")
    selection = payload.get("selection")
    if not isinstance(selection, dict) or selection.get("seed") != SEED:
        raise ValueError("manifest selection seed mismatch")
    records = payload.get("records")
    if not isinstance(records, list) or len(records) != COUNT:
        raise ValueError("manifest must contain exactly 200 records")
    seen = set()
    for expected_ordinal, record in enumerate(records, 1):
        if not isinstance(record, dict):
            raise ValueError("manifest record is not an object")
        drawer_id = record.get("drawer_id")
        if record.get("ordinal") != expected_ordinal:
            raise ValueError("manifest ordinals are not contiguous and ordered")
        if not isinstance(drawer_id, str) or UUID.fullmatch(drawer_id) is None:
            raise ValueError(f"manifest record {expected_ordinal} lacks a full UUID")
        if drawer_id in seen:
            raise ValueError(f"manifest duplicate drawer_id {drawer_id}")
        seen.add(drawer_id)
        if HEX_SHA256.fullmatch(str(record.get("source_sha256", ""))) is None:
            raise ValueError(f"manifest record {drawer_id} lacks source_sha256")
        if record.get("selection_sha256") != selection_digest(drawer_id):
            raise ValueError(f"manifest selection digest mismatch for {drawer_id}")
    if payload.get("ordered_input_sha256") != ordered_input_digest(records):
        raise ValueError("manifest ordered-input digest mismatch")
    return payload


def load_manifest(path: Path) -> dict:
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read Blind-200 manifest {path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("Blind-200 manifest root must be an object")
    return validate_manifest(payload)


def ordered_ids(manifest: dict) -> list[str]:
    return [record["drawer_id"] for record in validate_manifest(manifest)["records"]]


def assert_exact_order(
        actual: Sequence[tuple[str, str]], manifest: dict, *, label: str) -> None:
    expected = [
        (record["drawer_id"], record["source_sha256"])
        for record in validate_manifest(manifest)["records"]
    ]
    if list(actual) != expected:
        raise ValueError(
            f"{label} full drawer ID/source digest sequence differs from manifest"
        )


def load_result(path: Path, manifest: dict, *, label: str) -> dict:
    """Load one complete result and bind its insertion order to the manifest."""
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read {label} result {path}: {exc}") from exc
    if not isinstance(payload, dict) or len(payload) != COUNT:
        size = len(payload) if isinstance(payload, dict) else "non-object"
        raise ValueError(f"{label} result has {size} records, expected {COUNT}")
    sequence = []
    for key, result in payload.items():
        if not isinstance(key, str) or not key.endswith("/chained"):
            raise ValueError(f"unexpected {label} result key: {key!r}")
        if not isinstance(result, dict):
            raise ValueError(f"{label} result {key} is not an object")
        checks = result.get("checks")
        if (not isinstance(checks, dict) or not checks
                or not all(isinstance(value, bool) for value in checks.values())):
            raise ValueError(f"{label} result {key} lacks boolean checks")
        facts = result.get("facts")
        if not isinstance(facts, dict):
            raise ValueError(f"{label} result {key} lacks facts")
        sequence.append((
            key.removesuffix("/chained"), facts.get("source_sha256")))
    assert_exact_order(sequence, manifest, label=f"{label} result")
    return payload


def validity_count(results: dict) -> int:
    return sum(all(result["checks"].values()) for result in results.values())


def receipt_path_for(result_path: Path) -> Path:
    result_path = Path(result_path)
    return result_path.with_name(f"{result_path.stem}.run.json")


def load_run_receipt(
        receipt_path: Path, result_path: Path, manifest_path: Path,
        manifest: dict, *, cell: str) -> dict:
    """Verify a completed receipt binds exact result, manifest, and model tier."""
    try:
        receipt = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read {cell} receipt {receipt_path}: {exc}") from exc
    if not isinstance(receipt, dict):
        raise ValueError(f"{cell} receipt is not an object")
    exact = {
        "schema_version": "mootx01-protocol-lab-run-v1",
        "cell": cell,
        "protocol": PROTOCOL,
        "bed": BED,
        "representation": REPRESENTATION,
        "converter_id": CONVERTER_ID,
        "status": "completed",
        "process_exit_status": 0,
        "ordered_input_sha256": manifest["ordered_input_sha256"],
        "manifest_path": str(Path(manifest_path).resolve()),
        "manifest_sha256": sha256_file(manifest_path),
        "result_path": str(Path(result_path).resolve()),
        "result_sha256": sha256_file(result_path),
    }
    for field, expected in exact.items():
        if receipt.get(field) != expected:
            raise ValueError(
                f"{cell} receipt {field} mismatch: "
                f"{receipt.get(field)!r} != {expected!r}")
    expected_records = [
        {
            "ordinal": record["ordinal"],
            "drawer_id": record["drawer_id"],
            "source_sha256": record["source_sha256"],
        }
        for record in manifest["records"]
    ]
    if receipt.get("ordered_records") != expected_records:
        raise ValueError(f"{cell} receipt ordered records differ from manifest")
    provenance = receipt.get("model_and_binary")
    required = {
        "rust_binary", "rust_binary_sha256", "rust_minter_id",
        "rust_model_file", "rust_model_sha256", "rust_declared_quant",
        "rust_gguf_file_type",
    }
    if not isinstance(provenance, dict) or not required <= set(provenance):
        raise ValueError(f"{cell} receipt lacks model/binary provenance")
    expected_quant = {
        "rust-nuextract-q8": "q8_0",
        "rust-nuextract-q4": "q4_k_m",
        "rust-nuextract-f16": "f16",
    }.get(cell)
    if expected_quant is None or provenance["rust_declared_quant"] != expected_quant:
        raise ValueError(f"{cell} receipt quantization provenance mismatch")
    return receipt
