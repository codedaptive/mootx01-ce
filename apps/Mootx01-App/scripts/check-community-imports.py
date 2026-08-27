#!/usr/bin/env python3
"""Reject private Swift modules from the Community source projection."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


PRIVATE_MODULES = {
    "AppIntents",
    "CloudKit",
    "Contacts",
    "EventKit",
    "FoundationModels",
    "MootIntentKit",
    "MootProGateway",
    "MootProUI",
    "MootEnterpriseGateway",
    "MootEnterpriseUI",
    "NearbyInteraction",
    "WorkPacketKit",
}

# Swift permits attributes before an import and permits declaration-scoped
# imports such as `import class CloudKit.CKContainer`. Both forms must count.
IMPORT = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)",
)
CAN_IMPORT = re.compile(r"\bcanImport\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)")


def private_references(line: str) -> set[str]:
    """Return private modules named by one Swift import or canImport guard."""
    found: set[str] = set()
    imported = IMPORT.match(line)
    if imported and imported.group(1) in PRIVATE_MODULES:
        found.add(imported.group(1))
    found.update(module for module in CAN_IMPORT.findall(line) if module in PRIVATE_MODULES)
    return found


def self_test() -> None:
    cases = {
        "import CloudKit": {"CloudKit"},
        "@preconcurrency import CloudKit": {"CloudKit"},
        "import class CloudKit.CKContainer": {"CloudKit"},
        "#if canImport(FoundationModels)": {"FoundationModels"},
        "import Foundation": set(),
        "let words = \"import CloudKit\"": set(),
    }
    for source, expected in cases.items():
        actual = private_references(source)
        if actual != expected:
            raise AssertionError(f"scanner mismatch for {source!r}: {actual} != {expected}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
    if not args.paths:
        return 0

    violations: list[str] = []
    for root in args.paths:
        files = [root] if root.is_file() else sorted(root.rglob("*.swift"))
        for path in files:
            for line_number, line in enumerate(path.read_text().splitlines(), start=1):
                for module in sorted(private_references(line)):
                    violations.append(f"{path}:{line_number}: private module {module}: {line.strip()}")

    if violations:
        print("Community source references private modules:", file=sys.stderr)
        for violation in violations:
            print(f"  {violation}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
