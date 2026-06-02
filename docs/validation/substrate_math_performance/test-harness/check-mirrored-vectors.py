#!/usr/bin/env python3
"""
check-mirrored-vectors.py — kit mirrored-literal conformance drift detector.

BYCOPY_MIGRATION_001 (2026-06-02): ALL nine legacy by-copy conformance
families have been migrated to the shared-artifact gate (NEURONKIT_SPEC § 9
C-0). The FAMILIES dict is now empty. This script exits 0 in both lenient
and --strict modes because there are no remaining unmigrated families.

Migration complete:
  NeuronKit families (8): benchmark_scoring, mmr_rank,
    formal_concept_analysis, hybrid_recall, association_rule_mining,
    scenario_profile, context_synthesizer, bradley_terry.
    Artifact: packages/kits/NeuronKit/Tests/NeuronKitTests/Fixtures/
              lens_vectors.json (extended with 8 new top-level sections)
    Swift gate: LensVectorConformanceTests.swift
    Rust gate:  NeuronKit/rust/tests/lens_conformance.rs

  CognitionKit families (1): migration_ranking.
    Artifact: packages/kits/CognitionKit/Tests/CognitionKitTests/Fixtures/
              cognition_vectors.json (new file)
    Swift gate: CognitionVectorConformanceTests.swift
    Rust gate:  CognitionKit/rust/tests/cognition_conformance.rs

Historical note:
  The original FAMILIES dict carried nine families. At the first audit
  (2026-06-02) NONE carried machine-comparable two-sided literal anchors —
  the "mirrors" were structural fixtures, worked-math comments, or one-sided
  recordings. This script's job was to surface that gap; BYCOPY_MIGRATION_001
  resolved it by moving all families to the artifact gate.

Per-family modes (retained for reference; no families remain):
  exact             anchor value-sets must match, both directions
  tolerance:<eps>   anchors pair within <eps> after sorting — for
                    contracts documented as tolerance-based
  one-sided         the anchors are recorded in ONE leg only — no
                    two-sided table exists to diff
  not-comparable    the mirrored tables are structural/wire-string
                    fixtures this script cannot reliably extract

Exit status:
  0 — every comparable family's anchors agree (trivially: none remain)
  1 — at least one comparable family has DIVERGED, or (with --strict)
      any family remains non-comparable / unmigrated
  2 — invocation / environment error
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

# Repo root: this file lives at docs/validation/substrate_math_performance/test-harness/
REPO_ROOT = Path(__file__).resolve().parents[4]
KITS = REPO_ROOT / "packages" / "kits"

# All nine families have been migrated to the shared-artifact gate
# (BYCOPY_MIGRATION_001). This dict is intentionally empty. The artifact
# gates are in:
#   - packages/kits/NeuronKit/Tests/NeuronKitTests/Fixtures/lens_vectors.json
#   - packages/kits/CognitionKit/Tests/CognitionKitTests/Fixtures/cognition_vectors.json
#
# When a new by-copy family is added, add it here AND schedule a migration
# mission. The by-copy pattern is the anti-pattern; the artifact is the goal.
FAMILIES: dict[str, tuple[str, str, str]] = {}

FLOAT_RE = re.compile(r"\b\d+\.\d{4,}\b")


def strip_comments(source: str) -> str:
    """Remove /* */ blocks and //-to-EOL comments (Swift and Rust share
    both shapes; /// and //! fall under the // rule). Heuristic — a //
    inside a string literal is stripped too, which is symmetric across
    the legs and therefore safe for an anchor audit."""
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def rust_test_region(source: str) -> str:
    """The inline test module onward — where the mirrored tables live."""
    marker = source.find("#[cfg(test)]")
    return source[marker:] if marker != -1 else ""


def numeric_anchors(text: str) -> list[str]:
    """High-precision decimal anchors, normalized through float() so
    0.5000 and 0.50000 compare equal. Value-set semantics (a value used
    twice on one side and once on the other is the same vector)."""
    return sorted({repr(float(m)) for m in FLOAT_RE.findall(text)})


def main() -> int:
    diverged: list[str] = []
    needs_migration: list[str] = []

    for family, (swift_rel, rust_rel, mode) in sorted(FAMILIES.items()):
        swift_path = KITS / swift_rel
        rust_path = KITS / rust_rel
        if not swift_path.is_file() or not rust_path.is_file():
            print(f"error: {family}: missing file "
                  f"({swift_path if not swift_path.is_file() else rust_path})")
            return 2

        if mode in ("one-sided", "not-comparable"):
            reason = ("anchors recorded in one leg only"
                      if mode == "one-sided"
                      else "structural/wire fixtures, not literal anchors")
            print(f"not-comparable {family}: {reason}")
            needs_migration.append(family)
            continue

        swift_nums = numeric_anchors(strip_comments(swift_path.read_text()))
        rust_nums = numeric_anchors(strip_comments(rust_test_region(rust_path.read_text())))

        if not swift_nums and not rust_nums:
            print(f"not-comparable {family}: no high-precision anchors found")
            needs_migration.append(family)
            continue

        if mode.startswith("tolerance:"):
            eps = float(mode.split(":", 1)[1])
            ok = len(swift_nums) == len(rust_nums) and all(
                abs(float(a) - float(b)) <= eps
                for a, b in zip(sorted(swift_nums, key=float), sorted(rust_nums, key=float)))
            only_swift, only_rust = [], []
        else:
            cs, cr = Counter(swift_nums), Counter(rust_nums)
            only_swift = sorted((cs - cr).elements())
            only_rust = sorted((cr - cs).elements())
            ok = not only_swift and not only_rust

        if ok:
            print(f"ok       {family} ({len(swift_nums)} anchor value(s), {mode})")
        else:
            diverged.append(family)
            print(f"DIVERGED {family}: the mirrored tables no longer agree — fix both legs together")
            print(f"         swift: {swift_rel}")
            print(f"         rust:  {rust_rel}")
            if only_swift:
                print(f"         values only in Swift: {', '.join(only_swift[:8])}")
            if only_rust:
                print(f"         values only in Rust:  {', '.join(only_rust[:8])}")

    if needs_migration:
        print()
        print(f"{len(needs_migration)} family(ies) cannot be mechanically compared from literals:")
        print(f"  {', '.join(sorted(needs_migration))}")
        print("Their conformance is asserted by copy/one leg only. Gate them properly by")
        print("migrating each to the shared artifact (NEURONKIT_SPEC § 9 C-0, the")
        print("Tests/NeuronKitTests/Fixtures/lens_vectors.json pattern), then remove the")
        print("family from this manifest.")

    if diverged:
        print()
        print(f"{len(diverged)} family(ies) DIVERGED: {', '.join(diverged)}")
        print("Re-derive BOTH legs in the same change, or migrate the family to the")
        print("shared artifact and remove it from this manifest.")
        return 1
    if strict and needs_migration:
        print()
        print("--strict: unmigrated families remain — failing.")
        return 1
    return 0


if __name__ == "__main__":
    strict = "--strict" in sys.argv[1:]
    sys.exit(main())
