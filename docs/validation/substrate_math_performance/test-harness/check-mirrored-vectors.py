#!/usr/bin/env python3
"""
check-mirrored-vectors.py — kit mirrored-literal conformance drift detector.

The kits' legacy Swift/Rust test pairs assert cross-version conformance
through MIRRORED LITERALS: the same expected values typed into both
legs' test sources by hand ("vectors shared by copy"). If one side's
literals are edited alone, the legs silently stop proving the same
contract — nothing catches it until someone diffs by hand. This script
is that diff, automated, for the families where it CAN be automated —
and an explicit inventory of the families where it cannot.

Anchor signal (comments stripped first): high-precision decimal
literals (4+ fractional digits) in the Swift test file vs the Rust
inline test region. Values that precise are recorded conformance
numbers, never incidental counts. String/wire fixtures and structural
tables are NOT mechanically comparable from source (Swift @Test display
names and language syntax drown the signal) — families built on those
report `not-comparable` with the prescribed fix.

Per-family modes:
  exact             anchor value-sets must match, both directions
  tolerance:<eps>   anchors pair within <eps> after sorting — for
                    contracts documented as tolerance-based
  one-sided         the anchors are recorded in ONE leg only (e.g. the
                    Bradley-Terry ladder values: produced by a Swift
                    run, asserted as literals in tournament.rs) — no
                    two-sided table exists to diff
  not-comparable    the mirrored tables are structural/wire-string
                    fixtures this script cannot reliably extract

`one-sided` and `not-comparable` families are reported every run as
needing migration to the shared-artifact gate (NEURONKIT_SPEC § 9 C-0,
the Tests/NeuronKitTests/Fixtures/lens_vectors.json pattern). When a
family migrates, REMOVE it from this manifest — the artifact gate
supersedes this heuristic.

Run result on first audit (2026-06-02): NONE of the nine legacy
families carry machine-comparable two-sided literal anchors in code —
the "mirrors" are structural fixtures, worked-math comments, or
one-sided recordings. Until migrated, their cross-version agreement is
asserted by convention only and CANNOT be proven mechanically. That is
the finding this script keeps visible on every run.

Exit status:
  0 — every comparable family's anchors agree
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

# family name -> (swift test file, rust source file, mode)
FAMILIES: dict[str, tuple[str, str, str]] = {
    "mmr_rank": (
        "NeuronKit/Tests/NeuronKitTests/MMRRankTests.swift",
        "NeuronKit/rust/src/mmr_rank.rs",
        "exact",
    ),
    "association_rule_mining": (
        "NeuronKit/Tests/NeuronKitTests/AssociationRuleMiningTests.swift",
        "NeuronKit/rust/src/association_rule_mining.rs",
        "exact",
    ),
    "bradley_terry": (
        "NeuronKit/Tests/NeuronKitTests/BradleyTerryTests.swift",
        "NeuronKit/rust/src/tournament.rs",
        # The dominance-ladder anchors were produced by a Swift run and
        # are asserted (to 1e-6) as literals in the RUST tests only —
        # the Swift suite asserts the MM stationary condition instead.
        "one-sided",
    ),
    "benchmark_scoring": (
        "NeuronKit/Tests/NeuronKitTests/BenchmarkScoringTests.swift",
        "NeuronKit/rust/src/benchmark_scoring.rs",
        # Expected values are simple fractions (0.5, 1.0) asserted
        # against shared id-set fixtures — no high-precision anchors.
        "not-comparable",
    ),
    "scenario_profile": (
        "NeuronKit/Tests/NeuronKitTests/ScenarioProfileTests.swift",
        "NeuronKit/rust/src/scenario_profile.rs",
        # Wire-format JSON string fixtures.
        "not-comparable",
    ),
    "context_synthesizer": (
        "NeuronKit/Tests/NeuronKitTests/ContextSynthesizerTests.swift",
        "NeuronKit/rust/src/context_synthesizer.rs",
        # Structural document fixtures (summaries, patterns).
        "not-comparable",
    ),
    "formal_concept_analysis": (
        "NeuronKit/Tests/NeuronKitTests/FormalConceptAnalysisTests.swift",
        "NeuronKit/rust/src/formal_concept_analysis.rs",
        # Structural concept-lattice fixtures.
        "not-comparable",
    ),
    "hybrid_recall": (
        "NeuronKit/Tests/NeuronKitTests/HybridRecallTests.swift",
        "NeuronKit/rust/src/hybrid_recall.rs",
        "exact",
    ),
    "migration_ranking": (
        "CognitionKit/Tests/CognitionKitTests/MigrationRankingTests.swift",
        "CognitionKit/rust/src/migration_ranking.rs",
        "exact",
    ),
}

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
