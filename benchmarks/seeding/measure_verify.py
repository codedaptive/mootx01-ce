#!/usr/bin/env python3
"""Measure-smoke shape review — the artifact-recall receipt checklist.

The measure smoke runs a tiny artifact-recall pass (the vehicle) and this
script reviews the RECEIPT the same way smoke_verify.py reviews an estate:
exact expectations, any inequality = red, exit nonzero. It gates the
MECHANISM (every question got a call-return, the report carries every
field the ramp relies on) — never the scores themselves: retrieval
quality is the ramp's question, on settled artifacts, one pass per cell.

Usage:
  measure_verify.py --report <path.json> --dataset <ds>
                    --target-scale <scale> --expect-questions N
"""

import argparse
import json
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--report", required=True)
ap.add_argument("--dataset", required=True)
ap.add_argument("--target-scale", required=True)
ap.add_argument("--expect-questions", type=int, required=True)
args = ap.parse_args()

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))


try:
    r = json.load(open(args.report))
except Exception as e:  # noqa: BLE001 — unreadable report is the red
    print(f"measure smoke RED: report unreadable at {args.report}: {e}")
    sys.exit(2)

cfg = r.get("config", {})
check("report parses, config present", bool(cfg), f"keys: {sorted(r.keys())}")
check("dataset matches", cfg.get("dataset") == args.dataset,
      f"{cfg.get('dataset')} == {args.dataset}")
check("target scale matches", cfg.get("target_scale") == args.target_scale,
      f"{cfg.get('target_scale')} == {args.target_scale}")

# A bounded fleet build (`make fleet-<ds> LIMIT=N` / `UNITS=...`) writes a
# catalog holding fewer units than the dataset's questions.jsonl has. At
# unit scale that is not an error: questions naming an absent unit are
# excluded before --limit is applied, so a smoke of N questions still
# measures N real questions. The count that proves "every question got a
# call-return" is therefore questions_measured at unit scale (the count
# actually asked, after the catalog filter), and n_questions everywhere
# else (no catalog, so nothing is excluded and the two counts coincide).
if args.target_scale == "unit":
    check("questions_measured matches --expect-questions (unit scale, "
          "bounded-catalog aware)",
          r.get("questions_measured") == args.expect_questions,
          f"questions_measured {r.get('questions_measured')} == {args.expect_questions}")
else:
    check("every question got a call-return",
          r.get("n_questions") == args.expect_questions,
          f"n_questions {r.get('n_questions')} == {args.expect_questions}")

check("unit count sane", isinstance(r.get("n_units"), int) and r["n_units"] >= 1,
      f"n_units: {r.get('n_units')}")

# The three bounded-catalog receipt fields must be present and sane at
# every scale (0 at the two aggregate scales, which carry no catalog).
check("questions_in_file present and non-negative",
      isinstance(r.get("questions_in_file"), int) and r["questions_in_file"] >= 0,
      f"questions_in_file: {r.get('questions_in_file')}")
check("questions_measured present and non-negative",
      isinstance(r.get("questions_measured"), int) and r["questions_measured"] >= 0,
      f"questions_measured: {r.get('questions_measured')}")
check("questions_outside_catalog present and non-negative",
      isinstance(r.get("questions_outside_catalog"), int)
      and r["questions_outside_catalog"] >= 0,
      f"questions_outside_catalog: {r.get('questions_outside_catalog')}")
check("questions_measured does not exceed questions_in_file",
      isinstance(r.get("questions_measured"), int)
      and isinstance(r.get("questions_in_file"), int)
      and r["questions_measured"] <= r["questions_in_file"],
      f"questions_measured {r.get('questions_measured')} <= "
      f"questions_in_file {r.get('questions_in_file')}")

for metric in ("hit_at_k", "mrr"):
    v = r.get(metric)
    check(f"{metric} present and in [0,1]",
          isinstance(v, (int, float)) and 0.0 <= v <= 1.0, f"{metric}={v}")

check("per-label breakdown present",
      isinstance(r.get("per_category"), dict) and len(r["per_category"]) >= 1,
      f"labels: {sorted(r.get('per_category', {}).keys())[:5]}")
check("misses list present (inspectability)",
      isinstance(r.get("misses"), list), f"misses: {len(r.get('misses', []))}")
# Every miss row must carry the fields a human needs to inspect it.
bad_miss = [m for m in r.get("misses", [])
            if not all(k in m for k in ("sample_id", "question", "expected", "got_top3"))]
check("miss rows carry inspection fields", not bad_miss,
      f"malformed rows: {len(bad_miss)}")
# An all-unmapped result set means the id-map does not belong to this
# estate — a wiring failure, not a retrieval result.
all_got = [g for m in r.get("misses", []) for g in m.get("got_top3", [])]
unmapped = [g for g in all_got if str(g).startswith("unmapped:")]
check("returned ids map through id-map",
      not all_got or len(unmapped) < len(all_got),
      f"{len(unmapped)}/{len(all_got)} top-3 ids unmapped")

width = max(len(n) for n, _, _ in results)
red = 0
print(f"measure smoke receipt review — {args.report}")
for name, ok, detail in results:
    mark = "PASS" if ok else "FAIL"
    red += 0 if ok else 1
    print(f"  [{mark}] {name:{width}s}  {detail}")
print(f"measure smoke {'GREEN' if red == 0 else f'RED — {red} failing check(s)'}")
sys.exit(0 if red == 0 else 1)
