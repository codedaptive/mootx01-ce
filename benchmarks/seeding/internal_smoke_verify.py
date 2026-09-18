#!/usr/bin/env python3
"""Internal-benchmark smoke review — the lane produced its receipt.

Internal lanes are mechanically scored and own their estate builds; the
smoke gates the MECHANISM: the vehicle run completed and produced its
report artifact, and every JSON report parses. Scores are never gated.

Usage:
  internal_smoke_verify.py --report-dir <dir> --lane <name>
                           [--stdout-file <path>] [--report-file <path>]

--stdout-file: lanes that report to stdout (supersession) pass the
captured stdout file; the review requires it non-empty instead of a
JSON report.
--report-file: the payload lanes name their single report file; the
review then also checks the payload-cell shape (arms present, every
cell carries its token and answer-presence figures).
"""

import argparse
import glob
import json
import os
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--report-dir", required=True)
ap.add_argument("--lane", required=True)
ap.add_argument("--stdout-file", default="")
ap.add_argument("--report-file", default="")
args = ap.parse_args()

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))


if args.report_file:
    path = os.path.join(args.report_dir, args.report_file)
    report = {}
    try:
        report = json.load(open(path))
        check("report parses", True, os.path.basename(path))
    except Exception as e:  # noqa: BLE001
        check("report parses", False, f"{path}: {e}")
    check("lane matches", report.get("lane") == args.lane,
          f"lane={report.get('lane')!r}")
    check("estate_mode names the artifact source",
          report.get("estate_mode") == "artifact-bench-aggregate",
          f"estate_mode={report.get('estate_mode')!r}")
    arms = report.get("arms", {})
    wanted = ["exact", "full_content", "dense"] + (
        ["synthesize"] if args.lane == "synthesis-payload" else [])
    check("arms present", all(a in arms for a in wanted),
          f"have {sorted(arms)}, want {wanted}")
    check("shape mapping recorded",
          report.get("shape_mapping", {}).get("preview") == "exact"
          and report.get("shape_mapping", {}).get("compressed") == "dense",
          f"shape_mapping={report.get('shape_mapping')!r}")

    # Annotated questions in the evaluated slice: n_questions minus the
    # definition's no_evidence (questions without an annotated evidence
    # turn). When any annotated question ran, the evidence figures are
    # REQUIRED on every cell — omission means unavailable, never zero.
    n_questions = report.get("n_questions", 0)
    annotated = (n_questions - report.get("no_evidence", 0)
                 if isinstance(n_questions, int) else 0)
    retrieval_cells = {"exact", "dense"}
    bad = []
    for a in wanted:
        cell = arms.get(a, {})
        if not (isinstance(cell.get("n"), int) and cell.get("n", 0) > 0):
            bad.append(f"{a}: n={cell.get('n')!r}")
        required = ["mean_tokens", "answer_presence_rate"]
        # The per-1k figure is defined only for nonzero mean tokens
        # (payload-economics.md "when mean tokens are nonzero").
        if isinstance(cell.get("mean_tokens"), (int, float)) \
                and cell.get("mean_tokens", 0) > 0:
            required.append("answer_presence_per_1k_tokens")
        if a in retrieval_cells:
            required += ["hit_at_k", "mrr"]
        if annotated > 0:
            required += ["evidence_hit_rate", "evidence_hits_per_1k_tokens"]
        for field in required:
            if not isinstance(cell.get(field), (int, float)):
                bad.append(f"{a}: {field}={cell.get(field)!r}")
        # Retrieval figures belong ONLY to the retrieval arms — the
        # full_content and synthesize shapes ride the exact arm's ranked
        # list and must not restate hit@k/MRR.
        if a not in retrieval_cells:
            for field in ("hit_at_k", "mrr"):
                if field in cell:
                    bad.append(f"{a}: forbidden {field} present")
    check("every arm cell carries its required figure set",
          not bad, "; ".join(bad[:5]) if bad else
          f"{len(wanted)} cell(s) complete (annotated={annotated})")
elif args.stdout_file:
    ok = os.path.exists(args.stdout_file) and os.path.getsize(args.stdout_file) > 0
    check("stdout report captured", ok,
          f"{args.stdout_file} "
          f"({os.path.getsize(args.stdout_file) if ok else 0} bytes)")
else:
    reports = [r for r in sorted(
        glob.glob(os.path.join(args.report_dir, "**", "*.json"), recursive=True),
        key=os.path.getmtime) if not r.endswith("-params.json")]
    check("report file landed", bool(reports),
          f"{len(reports)} report(s) under {args.report_dir}")
    bad = []
    for r in reports:
        try:
            obj = json.load(open(r))
            if not obj:
                bad.append(os.path.basename(r) + " (empty)")
        except Exception as e:  # noqa: BLE001
            bad.append(f"{os.path.basename(r)} ({e})")
    check("every report parses non-empty", reports != [] and not bad,
          "; ".join(bad[:3]) if bad else f"{len(reports)} parsed")

width = max(len(n) for n, _, _ in results)
red = 0
print(f"internal smoke review — {args.lane}")
for name, ok, detail in results:
    mark = "PASS" if ok else "FAIL"
    red += 0 if ok else 1
    print(f"  [{mark}] {name:{width}s}  {detail}")
print(f"internal smoke {'GREEN' if red == 0 else f'RED — {red} failing check(s)'}")
sys.exit(0 if red == 0 else 1)
