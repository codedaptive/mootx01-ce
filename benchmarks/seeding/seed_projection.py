#!/usr/bin/env python3
"""Seed projection writer: the shape the artifact builder reads (§4 step 1).

Every seeder calls emit_projection once, after it has computed its units and
questions in its own terms. The builder (artifact_import.Projection) reads:

    <out>/projection/dataset.json          {"room_rule": str, "overlap": bool}
    <out>/projection/units/<unit>.jsonl    one record per line:
        {"id", "body", "room", "shape", "gold": {"<question-id>": "gold"|"distractor"}}

Gold relation per record per question of its unit: a record named by the
question's evidence is "gold"; every other record in the same haystack is a
"distractor". Records outside the unit are "absent", which the ledger fills
in for questions the record never met. Nothing here reads the product.
"""
from __future__ import annotations

import json
from pathlib import Path


def room_rule_text(module) -> str:
    """The seeder's room rule in words, from its classifier constants, so the
    ledger says how rooms were assigned without anyone reading the code."""
    return (f"room = classify_room(body): keyword vote over the seeder's room "
            f"lexicon; fewer than {module.THRESHOLD} hits -> 'general'; a sub-room "
            f"needs {module.SUB_THRESHOLD} sub-lexicon hits; ties break by room rank")


def emit_projection(out: Path, *, dataset: str, room_rule: str, overlap: bool,
                    units: dict[str, list[dict]], questions: list[dict],
                    shape: str) -> Path:
    """Write the projection. units: unit -> seeder records (need id, content,
    room). questions: rows with unit, question_id, gold_ids (record ids)."""
    root = out / "projection"
    (root / "units").mkdir(parents=True, exist_ok=True)
    (root / "dataset.json").write_text(json.dumps(
        {"dataset": dataset, "room_rule": room_rule, "overlap": overlap,
         "units": len(units), "questions": len(questions)}, indent=2) + "\n")

    by_unit: dict[str, list[dict]] = {}
    for q in questions:
        by_unit.setdefault(q["unit"], []).append(q)

    for unit, records in units.items():
        qs = by_unit.get(unit, [])
        with open(root / "units" / f"{unit}.jsonl", "w", encoding="utf-8") as handle:
            for r in records:
                gold = {}
                for q in qs:
                    gold[q["question_id"]] = "gold" if r["id"] in q["gold_ids"] else "distractor"
                handle.write(json.dumps({
                    "id": r["id"], "body": r["content"], "room": r["room"],
                    "shape": shape, "gold": gold}, ensure_ascii=False) + "\n")
    return root
