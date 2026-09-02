#!/usr/bin/env python3
"""Generate atoms-fixture-v22.json for CDL-01 Part 3 conformance pinning.

Selects one oracle row per shape.primary from the four vector beds, runs
_intent_atoms on each, and writes the full atom lists (all IntentAtom and
SpeakerTurn fields) to Vectors/atoms-fixture-v22.json.

This file is FROZEN after generation. The Rust port's intent_atoms output
is pinned against it.

Usage (run from the Oracle/ directory, or from the package root):
    python3 Tests/ContextDistillLibTests/Oracle/gen_atoms_fixture.py
"""

from __future__ import annotations

import json
from pathlib import Path
import sys

ORACLE_DIR = Path(__file__).parent
sys.path.insert(0, str(ORACLE_DIR))

from distill_plus_converter import _intent_atoms, _speaker_turns

VECTORS_DIR = ORACLE_DIR.parent / "Vectors"
BEDS = ["debug7", "sample30", "locomo", "blind200"]
PRIMARIES = ["dialogue", "entity_dense", "hybrid", "prose", "timeline"]
OUTPUT = VECTORS_DIR / "atoms-fixture-v22.json"


def load_all_rows() -> list[dict]:
    rows: list[dict] = []
    for bed in BEDS:
        path = VECTORS_DIR / f"{bed}-intent-span-v22.jsonl"
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    return rows


def atom_to_dict(atom) -> dict:
    return {
        "atom_id": atom.atom_id,
        "start": atom.start,
        "end": atom.end,
        "text": atom.text,
        "kind": atom.kind,
        "speaker": atom.speaker,
        "dependencies": list(atom.dependencies),
        "hard_required": atom.hard_required,
    }


def turn_to_dict(turn) -> dict:
    return {
        "start": turn.start,
        "end": turn.end,
        "first_line_end": turn.first_line_end,
        "body_start": turn.body_start,
        "speaker": turn.speaker,
    }


def main() -> None:
    rows = load_all_rows()
    print(f"Loaded {len(rows)} total rows.")

    selected: dict[str, dict] = {}
    for row in rows:
        primary = row["shape"]["primary"]
        if primary in PRIMARIES and primary not in selected:
            selected[primary] = row
        if len(selected) == len(PRIMARIES):
            break

    print(f"Selected {len(selected)} rows: "
          + ", ".join(f"{p}={v['drawer_id'][:8]}" for p, v in selected.items()))

    fixture: list[dict] = []
    for primary, row in selected.items():
        source = row["original"]
        atoms, hard, coverage, unsupported, mode_details = _intent_atoms(source)
        turns = _speaker_turns(source)

        entry = {
            "drawer_id": row["drawer_id"],
            "shape_primary": primary,
            "mode": mode_details.get("mode", "unknown"),
            "atoms": [atom_to_dict(a) for a in atoms],
            "hard_ids": sorted(hard),
            "coverage_ids": sorted(coverage),
            "unsupported": sorted(set(unsupported)),
            "speaker_turns": [turn_to_dict(t) for t in turns],
        }
        fixture.append(entry)
        print(f"  {primary}: {row['drawer_id'][:8]} "
              f"mode={entry['mode']} atoms={len(atoms)} turns={len(turns)}")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as fh:
        json.dump(fixture, fh, ensure_ascii=False, indent=2)
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
