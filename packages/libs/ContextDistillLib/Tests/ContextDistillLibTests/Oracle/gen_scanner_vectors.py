#!/usr/bin/env python3
"""Generate scanner conformance vectors for CDL-01 Part 2 (Rust port).

For every row in all four JSONL beds (debug7, sample30, locomo, blind200),
this script runs every compiled-regex constant from distill_plus_converter.py
against the ``original`` field using ``finditer``, captures match spans and
groups as Unicode code-point offsets (Python ``str`` index == code-point
index), and writes the results to Vectors/scanner-vectors-v22.json.

Additionally records:
  - ``source_sha256``  from each row (cross-checks source_digest)
  - ``original_tokens_est`` from each row metrics field
  - ``split_enrichment``  result for ``original + " " + enrichment_trailer``

Usage (run from any directory; paths are relative to this script location):
    python3 gen_scanner_vectors.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Locate repo directories relative to this script.
# ---------------------------------------------------------------------------
ORACLE_DIR = Path(__file__).parent
VECTORS_DIR = ORACLE_DIR.parent / "Vectors"
OUT_PATH = VECTORS_DIR / "scanner-vectors-v22.json"

BEDS = ["debug7", "sample30", "locomo", "blind200"]

# ---------------------------------------------------------------------------
# Import the 26 compiled-regex constants from distill_plus_converter.py.
# ---------------------------------------------------------------------------
sys.path.insert(0, str(ORACLE_DIR))

import distill_plus_converter as dpc  # noqa: E402

# All 26 compiled-regex constants in distill_plus_converter.py,
# listed in definition order (lines 63-213 of the oracle).
PATTERNS: list[tuple[str, re.Pattern]] = [
    ("TRAILER_RE",               dpc.TRAILER_RE),
    ("PIPE_SPLIT_RE",            dpc.PIPE_SPLIT_RE),
    ("INLINE_NUMBERED_RE",       dpc.INLINE_NUMBERED_RE),
    ("LIST_MARKER_RE",           dpc.LIST_MARKER_RE),
    ("WORD_RE",                  dpc.WORD_RE),
    ("NUMBER_RE",                dpc.NUMBER_RE),
    ("DATE_RE",                  dpc.DATE_RE),
    ("CAPITALIZED_RE",           dpc.CAPITALIZED_RE),
    ("GREETING_PREFIX_RE",       dpc.GREETING_PREFIX_RE),
    ("GREETING_ONLY_RE",         dpc.GREETING_ONLY_RE),
    ("DIALOGUE_FILLER_ONLY_RE",  dpc.DIALOGUE_FILLER_ONLY_RE),
    ("REVISION_MARKER_RE",       dpc.REVISION_MARKER_RE),
    ("INITIAL_DRAFT_MARKER_RE",  dpc.INITIAL_DRAFT_MARKER_RE),
    ("OPERATIVE_RE",             dpc.OPERATIVE_RE),
    ("TURN_FILLER_RE",           dpc.TURN_FILLER_RE),
    ("ASSISTANT_BOILERPLATE_RE", dpc.ASSISTANT_BOILERPLATE_RE),
    ("EMBEDDED_USER_FACT_RE",    dpc.EMBEDDED_USER_FACT_RE),
    ("FENCE_OPEN_RE",            dpc.FENCE_OPEN_RE),
    ("MARKDOWN_HEADING_RE",      dpc.MARKDOWN_HEADING_RE),
    ("BOLD_HEADING_RE",          dpc.BOLD_HEADING_RE),
    ("FIELD_LINE_RE",            dpc.FIELD_LINE_RE),
    ("TABLE_SEPARATOR_RE",       dpc.TABLE_SEPARATOR_RE),
    ("DIAGRAM_RE",               dpc.DIAGRAM_RE),
    ("POLARITY_ONLY_RE",         dpc.POLARITY_ONLY_RE),
    ("TRANSFORM_FOLLOWUP_RE",    dpc.TRANSFORM_FOLLOWUP_RE),
    ("QUANTITY_VALUE_RE",        dpc.QUANTITY_VALUE_RE),
]
PATTERN_NAMES = [name for name, _ in PATTERNS]


def match_to_record(m: re.Match) -> dict:
    """Convert a single re.Match to a JSON-serialisable dict.

    ``s`` and ``e`` are Unicode code-point offsets (Python str indices ==
    code-point indices for Python 3 str objects).
    ``g`` is [full_match, group1, group2, ...]; non-participating groups
    are encoded as JSON null.
    """
    groups_tuple = m.groups()  # tuple of all capturing groups, None if absent
    return {
        "s": m.start(),
        "e": m.end(),
        "g": [m.group(0)] + [g for g in groups_tuple],
    }


def finditer_all(pattern: re.Pattern, text: str) -> list[dict]:
    """Return all non-overlapping matches of ``pattern`` in ``text``."""
    return [match_to_record(m) for m in pattern.finditer(text)]


def split_enrichment_result(original: str, enrichment_trailer: str) -> dict:
    """Compute split_enrichment(original + ' ' + enrichment_trailer).

    Mirrors distill_plus_converter.split_enrichment exactly.  The
    concatenation reconstructs a ``distilled`` field that contains a
    trailer so TRAILER_RE scanning can be verified end-to-end.
    When ``enrichment_trailer`` is empty, the concatenation is just
    ``original`` (no extra space), matching the empty-trailer case.
    """
    if enrichment_trailer:
        combined = original + " " + enrichment_trailer
    else:
        combined = original
    body, trailer = dpc.split_enrichment(combined)
    return {"body": body, "trailer": trailer}


def process_row(row: dict, bed: str) -> dict:
    """Extract all scanner outputs for one JSONL row."""
    original = row["original"]
    enrichment_trailer = row.get("enrichment_trailer", "")

    matches: dict[str, list[dict]] = {}
    for name, pat in PATTERNS:
        matches[name] = finditer_all(pat, original)

    return {
        "bed": bed,
        "drawer_id": row["drawer_id"],
        "source_sha256": row["source_sha256"],
        "original_tokens_est": row["metrics"]["original_tokens_est"],
        "split_enrichment": split_enrichment_result(original, enrichment_trailer),
        "matches": matches,
    }


def main() -> None:
    rows: list[dict] = []
    total = 0
    for bed in BEDS:
        path = VECTORS_DIR / f"{bed}-intent-span-v22.jsonl"
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                rows.append(process_row(row, bed))
                total += 1

    output = {
        "version": "v22",
        "bed_order": BEDS,
        "pattern_names": PATTERN_NAMES,
        "pattern_strings": {name: pat.pattern for name, pat in PATTERNS},
        "row_count": total,
        "rows": rows,
    }

    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(output, fh, ensure_ascii=False, separators=(",", ":"))
        fh.write("\n")

    print(f"Written {total} rows to {OUT_PATH}", flush=True)

    match_counts = {name: 0 for name in PATTERN_NAMES}
    for row in rows:
        for name in PATTERN_NAMES:
            match_counts[name] += len(row["matches"][name])
    print("Match counts per pattern:")
    for name, count in match_counts.items():
        print(f"  {name}: {count}")


if __name__ == "__main__":
    main()
