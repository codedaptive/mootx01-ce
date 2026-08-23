#!/usr/bin/env python3
"""Verify the frozen Community 1.1 contract and golden fixture bundle."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import sys
import uuid
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent
CONTRACT_PATH = ROOT / "contract.json"
FIXTURE_ROOT = ROOT / "fixtures"
DIGEST_PATH = ROOT / "fixture-bundle.sha256"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ContractError(Exception):
    pass


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"{path}: {error}") from error


def canonical_bytes(value) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def bundle_sources():
    paths = [CONTRACT_PATH, *sorted(FIXTURE_ROOT.glob("*.json"))]
    for path in paths:
        relative = path.relative_to(ROOT).as_posix().encode("utf-8")
        yield relative + b"\n" + canonical_bytes(load_json(path)) + b"\n"


def compute_digest() -> str:
    digest = hashlib.sha256()
    for source in bundle_sources():
        digest.update(source)
    return digest.hexdigest()


def fail(path: str, message: str):
    raise ContractError(f"{path}: {message}")


class ShapeValidator:
    def __init__(self, contract: dict, digest: str):
        self.contract = contract
        self.types = contract["types"]
        self.reasons = set(contract["reasonCodes"])
        self.digest = digest

    def resolve_placeholders(self, value):
        if value == "@fixture-bundle.sha256":
            return self.digest
        if isinstance(value, list):
            return [self.resolve_placeholders(item) for item in value]
        if isinstance(value, dict):
            return {key: self.resolve_placeholders(item) for key, item in value.items()}
        return value

    def validate(self, value, shape: str, path: str):
        if shape.endswith("[]"):
            if not isinstance(value, list):
                fail(path, f"expected array of {shape[:-2]}")
            for index, item in enumerate(value):
                self.validate(item, shape[:-2], f"{path}[{index}]")
            return

        primitive = getattr(self, f"primitive_{shape.replace('-', '_')}", None)
        if primitive is not None:
            primitive(value, path)
            return

        definition = self.types.get(shape)
        if definition is None:
            fail(path, f"unknown shape {shape!r}")
        kind = definition.get("kind")
        if kind == "enum":
            if value not in definition["values"]:
                fail(path, f"expected one of {definition['values']}, got {value!r}")
        elif kind == "record":
            self.validate_fields(value, definition["fields"], path)
        elif kind == "union":
            if not isinstance(value, dict):
                fail(path, "expected object for tagged union")
            discriminator = definition["discriminator"]
            tag = value.get(discriminator)
            variants = definition["variants"]
            if tag not in variants:
                fail(path, f"unknown {discriminator} {tag!r}")
            fields = dict(definition.get("commonFields", {}))
            fields[discriminator] = "string"
            fields.update(variants[tag])
            self.validate_fields(value, fields, path)
        else:
            fail(path, f"unsupported shape kind {kind!r}")

    def validate_fields(self, value, fields: dict, path: str):
        if not isinstance(value, dict):
            fail(path, "expected object")
        allowed = set()
        required = set()
        normalized = {}
        for raw_name, shape in fields.items():
            optional = raw_name.endswith("?")
            name = raw_name[:-1] if optional else raw_name
            allowed.add(name)
            normalized[name] = shape
            if not optional:
                required.add(name)
        missing = sorted(required - value.keys())
        unknown = sorted(value.keys() - allowed)
        if missing:
            fail(path, f"missing fields {missing}")
        if unknown:
            fail(path, f"unknown fields {unknown}")
        for name, item in value.items():
            self.validate(item, normalized[name], f"{path}.{name}")

    @staticmethod
    def primitive_string(value, path):
        if not isinstance(value, str):
            fail(path, "expected string")

    @staticmethod
    def primitive_nonempty_string(value, path):
        if not isinstance(value, str) or not value:
            fail(path, "expected non-empty string")

    @staticmethod
    def primitive_boolean(value, path):
        if not isinstance(value, bool):
            fail(path, "expected boolean")

    @staticmethod
    def primitive_integer(value, path):
        if isinstance(value, bool) or not isinstance(value, int):
            fail(path, "expected integer")
        if not -(2**63) <= value < 2**63:
            fail(path, "integer is outside signed 64-bit range")

    def primitive_nonnegative_integer(self, value, path):
        self.primitive_integer(value, path)
        if value < 0:
            fail(path, "expected non-negative integer")

    @staticmethod
    def primitive_uuid(value, path):
        if not isinstance(value, str):
            fail(path, "expected UUID string")
        try:
            parsed = uuid.UUID(value)
        except (ValueError, AttributeError) as error:
            fail(path, f"invalid UUID: {error}")
        if str(parsed) != value.lower():
            fail(path, "UUID must use canonical hyphenated form")

    @staticmethod
    def primitive_date_time(value, path):
        if not isinstance(value, str) or not value.endswith("Z"):
            fail(path, "expected UTC RFC 3339 date-time ending in Z")
        try:
            datetime.fromisoformat(value[:-1] + "+00:00")
        except ValueError as error:
            fail(path, f"invalid date-time: {error}")

    @staticmethod
    def primitive_url(value, path):
        if not isinstance(value, str):
            fail(path, "expected URL string")
        parsed = urlparse(value)
        if not parsed.scheme or (parsed.scheme != "file" and not parsed.netloc):
            fail(path, "expected absolute URL")

    @staticmethod
    def primitive_base64(value, path):
        if not isinstance(value, str) or not value:
            fail(path, "expected non-empty base64 string")
        try:
            base64.b64decode(value, validate=True)
        except (ValueError, base64.binascii.Error) as error:
            fail(path, f"invalid base64: {error}")

    def primitive_reason_code(self, value, path):
        if value not in self.reasons:
            fail(path, f"unbounded reason code {value!r}")

    def primitive_contract_id(self, value, path):
        if value != self.contract["contractID"]:
            fail(path, f"expected contract ID {self.contract['contractID']!r}")

    def primitive_contract_version(self, value, path):
        if value != self.contract["contractVersion"]:
            fail(path, f"expected contract version {self.contract['contractVersion']!r}")

    @staticmethod
    def primitive_sha256_algorithm(value, path):
        if value != "sha256":
            fail(path, "expected sha256")

    @staticmethod
    def primitive_sha256(value, path):
        if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
            fail(path, "expected lowercase SHA-256 digest")


def validate_catalog(contract: dict):
    required_top = {
        "contractID",
        "contractVersion",
        "transport",
        "serialization",
        "fixtureDigestAlgorithm",
        "identityMethod",
        "readiness",
        "reasonCodes",
        "types",
        "endpoints",
        "requiredScenarioCoverage",
    }
    if set(contract) != required_top:
        fail("contract.json", f"top-level keys must be exactly {sorted(required_top)}")
    if contract["fixtureDigestAlgorithm"] != "sha256":
        fail("contract.json.fixtureDigestAlgorithm", "only sha256 is frozen for 1.1")
    if len(contract["reasonCodes"]) != len(set(contract["reasonCodes"])):
        fail("contract.json.reasonCodes", "duplicate reason code")
    if contract["reasonCodes"] != sorted(contract["reasonCodes"]):
        fail("contract.json.reasonCodes", "reason codes must be sorted")

    endpoint_names = [endpoint["name"] for endpoint in contract["endpoints"]]
    if len(endpoint_names) != len(set(endpoint_names)):
        fail("contract.json.endpoints", "duplicate endpoint name")
    if contract["identityMethod"] not in endpoint_names:
        fail("contract.json.identityMethod", "identity endpoint is not declared")
    for index, endpoint in enumerate(contract["endpoints"]):
        if set(endpoint) != {"name", "family", "mutation", "arguments", "result"}:
            fail(f"contract.json.endpoints[{index}]", "endpoint fields are not exact")
        for reference in (endpoint["arguments"], endpoint["result"]):
            if reference not in contract["types"]:
                fail(f"contract.json.endpoints[{index}]", f"unknown type {reference!r}")
    families = {endpoint["family"] for endpoint in contract["endpoints"]}
    if families != set(contract["requiredScenarioCoverage"]):
        fail("contract.json.requiredScenarioCoverage", "family set differs from endpoints")


def semantic_checks(case: dict, digest: str, path: str):
    method = case["method"]
    arguments = case["arguments"]
    result = case["result"]

    if method == "moot_community_contract_identity":
        exact = (
            result["contractID"] == "com.simple-machines.mootx01.community"
            and result["contractVersion"] == "1.1.0"
            and result["fixtureDigest"] == digest
        )
        expectation = case.get("expectation", "accept")
        if (expectation == "accept") != exact:
            fail(path, "identity expectation does not match exact identity")

    if method == "moot_community_capture_choices":
        destination_ids = {item["id"] for item in result["destinations"]}
        sensitivities = set(result["sensitivities"])
        default = result["defaultPolicy"]
        if default["destinationID"] not in destination_ids:
            fail(path, "capture default destination is not offered")
        if default["sensitivity"] not in sensitivities:
            fail(path, "capture default sensitivity is not offered")
        if default["lanEligible"] and not default["exportEligible"]:
            fail(path, "LAN eligibility cannot widen export-ineligible default")

    if method == "moot_community_capture" and result.get("outcome") == "applied":
        effective = result["effectivePolicy"]
        if effective["lanEligible"] and not effective["exportEligible"]:
            fail(path, "effective LAN eligibility cannot widen export-ineligible material")

    if method == "moot_community_review_dashboard":
        kinds = [mode["kind"] for mode in result["modes"]]
        if sorted(kinds) != ["endOfDay", "morning", "weekly"]:
            fail(path, "review dashboard must contain every mode exactly once")

    if method == "moot_community_review_session" and result.get("outcome") == "session":
        if arguments["kind"] != result["session"]["kind"]:
            fail(path, "review session kind differs from request")

    if method == "moot_community_review_complete" and result.get("outcome") == "completed":
        if arguments["sessionID"] != result["receipt"]["sessionID"]:
            fail(path, "completion receipt session differs from request")

    if method == "moot_community_obsidian_status":
        if ("checkpointAt" in result) != ("recordCount" in result):
            fail(path, "checkpointAt and recordCount must appear together")
        if result.get("state") == "synchronizing":
            if ("pendingCount" in result) != ("totalCount" in result):
                fail(path, "pendingCount and totalCount must appear together")
            if "pendingCount" in result and result["pendingCount"] > result["totalCount"]:
                fail(path, "pendingCount exceeds totalCount")

    plan = result.get("plan") if isinstance(result, dict) else None
    if isinstance(plan, dict) and "candidateCount" in plan:
        if plan["estimatedTransferCount"] + plan["policyExclusionCount"] > plan["candidateCount"]:
            fail(path, "transfer estimate plus exclusions exceeds candidates")

    if method == "moot_community_transfer_job_status" and result.get("outcome") == "status":
        if arguments["jobID"] != result["jobID"]:
            fail(path, "returned job identity differs from query")
        state = result["jobState"]
        if state["state"] == "running" and "processed" in state:
            if state["processed"] > state["total"]:
                fail(path, "transfer processed count exceeds total")


def validate_fixtures(contract: dict, digest: str):
    endpoints = {endpoint["name"]: endpoint for endpoint in contract["endpoints"]}
    validator = ShapeValidator(contract, digest)
    fixture_ids = set()
    seen_endpoints = set()
    coverage = defaultdict(set)
    count = 0

    fixture_paths = sorted(FIXTURE_ROOT.glob("*.json"))
    if not fixture_paths:
        fail("fixtures", "no fixture files")
    for fixture_path in fixture_paths:
        fixture = load_json(fixture_path)
        if set(fixture) != {"family", "cases"}:
            fail(str(fixture_path), "fixture file fields must be exactly family and cases")
        family = fixture["family"]
        if family not in contract["requiredScenarioCoverage"]:
            fail(str(fixture_path), f"unknown family {family!r}")
        if not isinstance(fixture["cases"], list) or not fixture["cases"]:
            fail(str(fixture_path), "cases must be a non-empty array")

        for index, raw_case in enumerate(fixture["cases"]):
            path = f"{fixture_path.relative_to(ROOT)}.cases[{index}]"
            allowed_case_fields = {"id", "covers", "method", "arguments", "result", "expectation"}
            required_case_fields = {"id", "covers", "method", "arguments", "result"}
            if not required_case_fields <= set(raw_case) or not set(raw_case) <= allowed_case_fields:
                fail(path, "fixture case fields are invalid")
            case_id = raw_case["id"]
            if not isinstance(case_id, str) or not case_id:
                fail(path, "case id must be a non-empty string")
            if case_id in fixture_ids:
                fail(path, f"duplicate case id {case_id!r}")
            fixture_ids.add(case_id)
            expectation = raw_case.get("expectation", "accept")
            if expectation not in {"accept", "client-refuses"}:
                fail(path, f"unknown expectation {expectation!r}")
            if not isinstance(raw_case["covers"], list) or not raw_case["covers"]:
                fail(path, "covers must be a non-empty array")

            method = raw_case["method"]
            endpoint = endpoints.get(method)
            if endpoint is None:
                fail(path, f"unknown endpoint {method!r}")
            if endpoint["family"] != family:
                fail(path, f"endpoint belongs to {endpoint['family']!r}, not {family!r}")
            case = validator.resolve_placeholders(raw_case)
            validator.validate(case["arguments"], endpoint["arguments"], f"{path}.arguments")
            validator.validate(case["result"], endpoint["result"], f"{path}.result")
            semantic_checks(case, digest, path)
            seen_endpoints.add(method)
            coverage[family].update(case["covers"])
            count += 1

    missing_endpoints = sorted(set(endpoints) - seen_endpoints)
    if missing_endpoints:
        fail("fixtures", f"endpoints without a golden fixture: {missing_endpoints}")
    for family, required in contract["requiredScenarioCoverage"].items():
        missing = sorted(set(required) - coverage[family])
        if missing:
            fail(f"fixtures.{family}", f"missing required scenario coverage {missing}")
    return count, coverage


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--print-digest",
        action="store_true",
        help="print the computed digest even when fixture-bundle.sha256 is absent",
    )
    args = parser.parse_args()
    contract = load_json(CONTRACT_PATH)
    validate_catalog(contract)
    digest = compute_digest()
    fixture_count, coverage = validate_fixtures(contract, digest)

    if args.print_digest:
        print(digest)
        return 0
    if not DIGEST_PATH.exists():
        fail(str(DIGEST_PATH), f"missing; computed digest is {digest}")
    stored = DIGEST_PATH.read_text(encoding="utf-8").strip()
    if stored != digest:
        fail(str(DIGEST_PATH), f"stored {stored!r}, computed {digest}")

    print(f"contract: {contract['contractID']} {contract['contractVersion']}")
    print(f"endpoints: {len(contract['endpoints'])}")
    print(f"fixtures: {fixture_count}")
    for family in sorted(coverage):
        print(f"coverage[{family}]: {','.join(sorted(coverage[family]))}")
    print(f"fixture digest: {digest}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ContractError as error:
        print(f"contract verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
