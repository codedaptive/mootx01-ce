#!/usr/bin/env python3
"""Judged-protocol smoke review — report and dump shape, never scores.

Reviews one spec-lane smoke run the way measure_verify.py reviews a
measure receipt: the report landed and parses, its run_parameters carry
the artifact seam fields, and — for judged lanes run with a dump — the
judge-input dump exists and every line is a well-formed JSON object.
Any inequality = red, exit nonzero.

Usage:
  spec_smoke_verify.py --report-dir <dir> --protocol <name>
                       [--dump-dir <dir>] [--expect-judged N]

--expect-judged N: inflight mode — the newest report must carry a
judged-count field equal to N.
"""

import argparse
import glob
import json
import os
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--report-dir", required=True)
ap.add_argument("--protocol", required=True)
ap.add_argument("--dump-dir", default="")
ap.add_argument("--expect-judged", type=int, default=-1)
args = ap.parse_args()

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))


reports = sorted(
    glob.glob(os.path.join(args.report_dir, "**", "*.json"), recursive=True),
    key=os.path.getmtime)
reports = [r for r in reports if not r.endswith("-params.json")]
check("report file landed", bool(reports),
      f"{len(reports)} report(s) under {args.report_dir}")
report = {}
if reports:
    try:
        report = json.load(open(reports[-1]))
        check("report parses", True, os.path.basename(reports[-1]))
    except Exception as e:  # noqa: BLE001
        check("report parses", False, str(e))

# Lanes carry the seam fields either inside run_parameters (locomo-spec,
# lme-spec, membench-spec) or at the top level of a flat report
# (lmeb-spec, convomem-spec). Accept both shapes.
params = report.get("run_parameters", {})
if not isinstance(params, dict) or "target_scale" not in params:
    params = report
check("report carries target_scale",
      isinstance(params, dict) and "target_scale" in params,
      f"target_scale={params.get('target_scale')!r}")
check("estate_mode names the artifact source",
      str(params.get("estate_mode", "")).startswith("artifact"),
      f"estate_mode={params.get('estate_mode')!r}")

if args.dump_dir:
    lines = []
    files = sorted(glob.glob(os.path.join(args.dump_dir, "**", "*"),
                             recursive=True))
    files = [f for f in files if os.path.isfile(f)]
    bad = 0
    for f in files:
        for ln in open(f, encoding="utf-8", errors="replace"):
            ln = ln.strip()
            if not ln:
                continue
            lines.append(ln)
            try:
                obj = json.loads(ln)
                if not isinstance(obj, dict):
                    bad += 1
            except json.JSONDecodeError:
                bad += 1
    check("judge-input dump present", bool(files),
          f"{len(files)} file(s) under {args.dump_dir}")
    check("dump lines are JSON objects", lines != [] and bad == 0,
          f"{len(lines)} line(s), {bad} malformed")

if args.expect_judged >= 0:
    # Lane report field names vary (judged_count / judged); accept either.
    judged = report.get("judged_count", report.get("judged"))
    check("judged_count matches the vehicle", judged == args.expect_judged,
          f"{judged} == {args.expect_judged}")

width = max(len(n) for n, _, _ in results)
red = 0
print(f"spec smoke review — {args.protocol}")
for name, ok, detail in results:
    mark = "PASS" if ok else "FAIL"
    red += 0 if ok else 1
    print(f"  [{mark}] {name:{width}s}  {detail}")
print(f"spec smoke {'GREEN' if red == 0 else f'RED — {red} failing check(s)'}")
sys.exit(0 if red == 0 else 1)
