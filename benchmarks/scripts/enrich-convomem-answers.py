#!/usr/bin/env python3
"""
enrich-convomem-answers.py — inject gold answers into LMEB ConvoMem queries.jsonl.

The LMEB export (KaLM-Embedding/LMEB on HuggingFace) carries only `id` and `text`
per query; it omits the gold answer field entirely.  Without answers the harness
skips the judge step and every convomem-spec record scores 0 on judged_count.

This script:
  1. Downloads the Salesforce/ConvoMem dataset from HuggingFace into
     $BENCH_WORK_ROOT/fixtures/convomem-qa/ (idempotent: skips if already present).
  2. Builds a question-text → answer lookup from the ConvoMem evidence_questions
     JSON files (one file per scene; each file has one or more evidence_items).
  3. For each of the six LMEB evidence types, matches every LMEB query text to
     its ConvoMem question (exact match first; normalised whitespace/case second).
  4. Backs up the original queries.jsonl to queries.lmeb-original.jsonl (once;
     idempotent), then writes an enriched queries.jsonl with the answer field set.

Prints per-type matched/unmatched counts to stdout.
Exits non-zero if any query is unmatched.

Usage:
    BENCH_WORK_ROOT=/path/to/work-root python3 enrich-convomem-answers.py

The LMEB fixture directory is resolved from $BENCH_WORK_ROOT/fixtures/lmeb/data/ConvoMem/.
Symlinks are resolved before writing so the shared store is never edited in place.
"""

import json
import os
import re
import sys
import shutil
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

EVIDENCE_TYPES = [
    "abstention_evidence",
    "assistant_facts_evidence",
    "changing_evidence",
    "implicit_connection_evidence",
    "preference_evidence",
    "user_evidence",
]

HF_REPO_ID = "Salesforce/ConvoMem"
CONVOMEM_SUBDIR = "core_benchmark/evidence_questions"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def normalise(text: str) -> str:
    """Collapse whitespace and lowercase for fuzzy matching."""
    return re.sub(r"\s+", " ", text.strip()).lower()


def fetch_convomem(dest_dir: Path) -> None:
    """Download Salesforce/ConvoMem evidence_questions into dest_dir if absent."""
    sentinel = dest_dir / ".fetch-complete"
    if sentinel.exists():
        print(f"[fetch] ConvoMem QA already present at {dest_dir} — skipping download.")
        return

    dest_dir.mkdir(parents=True, exist_ok=True)
    print(f"[fetch] Downloading {HF_REPO_ID} → {dest_dir} …")

    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        print(
            "ERROR: huggingface_hub is not installed. "
            "Run: pip install huggingface-hub",
            file=sys.stderr,
        )
        sys.exit(1)

    snapshot_download(
        repo_id=HF_REPO_ID,
        repo_type="dataset",
        local_dir=str(dest_dir),
        allow_patterns=[f"{CONVOMEM_SUBDIR}/**"],
        ignore_patterns=["*.gitattributes"],
    )

    sentinel.touch()
    print(f"[fetch] Download complete.")


def build_answer_map(convomem_dir: Path, evidence_type: str) -> dict[str, str]:
    """
    Read all ConvoMem scene JSON files for one evidence type and return
    a mapping from question text to answer.  Both exact and normalised keys
    are stored so the lookup can try exact first.
    """
    et_dir = convomem_dir / CONVOMEM_SUBDIR / evidence_type
    if not et_dir.exists():
        print(f"WARNING: ConvoMem directory not found: {et_dir}", file=sys.stderr)
        return {}

    exact: dict[str, str] = {}
    normalised: dict[str, str] = {}

    for json_file in sorted(et_dir.rglob("*.json")):
        try:
            with json_file.open(encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception as exc:
            print(f"WARNING: could not parse {json_file}: {exc}", file=sys.stderr)
            continue

        items = data.get("evidence_items", [])
        for item in items:
            q = item.get("question", "")
            a = item.get("answer", "")
            if q and a:
                exact[q] = a
                normalised[normalise(q)] = a

    return {"exact": exact, "normalised": normalised}


def enrich_queries(
    lmeb_dir: Path,
    convomem_dir: Path,
    evidence_type: str,
) -> tuple[int, int]:
    """
    Enrich queries.jsonl for one evidence type.  Returns (matched, unmatched).
    Writes queries.lmeb-original.jsonl backup then overwrites queries.jsonl.
    Both paths are resolved through symlinks so the shared store is never
    edited in place.
    """
    queries_link = lmeb_dir / evidence_type / "queries.jsonl"
    if not queries_link.exists():
        print(f"WARNING: {queries_link} not found — skipping.", file=sys.stderr)
        return 0, 0

    # Resolve the real path so we write through the symlink chain.
    queries_real = Path(os.path.realpath(queries_link))
    backup_real = queries_real.parent / "queries.lmeb-original.jsonl"

    # Backup original once (idempotent).
    if not backup_real.exists():
        shutil.copy2(queries_real, backup_real)
        print(f"[{evidence_type}] Backed up original to {backup_real.name}")
    else:
        print(f"[{evidence_type}] Backup already exists — reading from {backup_real.name}")

    # Build answer map.
    answer_map = build_answer_map(convomem_dir, evidence_type)
    exact_map = answer_map.get("exact", {})
    norm_map = answer_map.get("normalised", {})

    if not exact_map:
        print(f"WARNING: no answers found for {evidence_type}.", file=sys.stderr)

    # Read queries from the backup (the clean original).
    with backup_real.open(encoding="utf-8") as fh:
        raw_queries = [json.loads(line) for line in fh if line.strip()]

    enriched = []
    matched = 0
    unmatched_ids = []

    for q in raw_queries:
        q_id = q["id"]
        q_text = q["text"]

        answer = exact_map.get(q_text)
        if answer is None:
            answer = norm_map.get(normalise(q_text))

        if answer is not None:
            q["answer"] = answer
            matched += 1
        else:
            unmatched_ids.append(q_id)

        enriched.append(q)

    unmatched = len(unmatched_ids)

    # Write enriched file.
    with queries_real.open("w", encoding="utf-8") as fh:
        for row in enriched:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    if unmatched_ids:
        print(
            f"[{evidence_type}] matched={matched}  unmatched={unmatched}  "
            f"— first unmatched: {unmatched_ids[:3]}",
            file=sys.stderr,
        )
    else:
        print(f"[{evidence_type}] matched={matched}  unmatched={unmatched}")

    return matched, unmatched


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    bench_work_root_env = os.environ.get("BENCH_WORK_ROOT", "")
    if not bench_work_root_env:
        print("ERROR: BENCH_WORK_ROOT is not set.", file=sys.stderr)
        return 1

    bench_work_root = Path(bench_work_root_env).resolve()
    convomem_qa_dir = bench_work_root / "fixtures" / "convomem-qa"
    lmeb_convomem_dir = bench_work_root / "fixtures" / "lmeb" / "data" / "ConvoMem"

    if not lmeb_convomem_dir.exists():
        print(
            f"ERROR: LMEB ConvoMem fixture directory not found: {lmeb_convomem_dir}",
            file=sys.stderr,
        )
        return 1

    # Step 1: fetch ConvoMem QA data.
    fetch_convomem(convomem_qa_dir)

    # Step 2: enrich each evidence type.
    total_matched = 0
    total_unmatched = 0

    print()
    print("Evidence type                       matched  unmatched")
    print("─" * 54)

    for et in EVIDENCE_TYPES:
        m, u = enrich_queries(lmeb_convomem_dir, convomem_qa_dir, et)
        total_matched += m
        total_unmatched += u
        status = "OK" if u == 0 else "UNMATCHED"
        print(f"  {et:<38} {m:>5}  {u:>5}   {status}")

    print("─" * 54)
    print(f"  {'TOTAL':<38} {total_matched:>5}  {total_unmatched:>5}")
    print()

    if total_unmatched > 0:
        print(
            f"ERROR: {total_unmatched} queries could not be matched to a ConvoMem answer.",
            file=sys.stderr,
        )
        return 1

    print("All queries enriched successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
