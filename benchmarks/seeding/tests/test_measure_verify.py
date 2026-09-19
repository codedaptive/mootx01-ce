"""Tests for measure_verify.py's bounded-catalog receipt review.

At unit target-scale, a bounded fleet build (`make fleet-<ds> LIMIT=N` /
`UNITS=...`) writes a catalog holding fewer units than the dataset has.
That is not an error: questions naming an absent unit are excluded before
--limit is applied, so a smoke of N questions still measures N real
questions. The receipt therefore proves "every question got a call-return"
via `questions_measured` at unit scale (the bounded-catalog-aware count),
and via the older `n_questions` field everywhere else (no catalog, so
nothing is excluded and the two counts coincide).

measure_verify.py is an argparse script (executes at import time), so these
tests invoke it via subprocess — the same pattern test_faker.py uses.
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
MEASURE_VERIFY = HERE.parent / "measure_verify.py"


def base_report(**overrides):
    report = {
        "config": {"dataset": "locomo", "target_scale": "unit"},
        "n_questions": 2,
        "n_units": 2,
        "no_evidence": 0,
        "questions_in_file": 3,
        "questions_measured": 2,
        "questions_outside_catalog": 1,
        "hit_at_k": 0.5,
        "mrr": 0.5,
        "per_category": {"1": {"n": 2, "hit_at_k": 0.5, "mrr": 0.5}},
        "misses": [],
    }
    report.update(overrides)
    return report


def run_verify(report, *, dataset="locomo", target_scale="unit", expect_questions):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tmp:
        json.dump(report, tmp)
        tmp_path = tmp.name
    try:
        return subprocess.run(
            [sys.executable, str(MEASURE_VERIFY), "--report", tmp_path,
             "--dataset", dataset, "--target-scale", target_scale,
             "--expect-questions", str(expect_questions)],
            capture_output=True, text=True)
    finally:
        pathlib.Path(tmp_path).unlink(missing_ok=True)


class MeasureVerifyBoundedCatalogTests(unittest.TestCase):
    def test_unit_scale_bounded_catalog_2_of_3_is_green(self):
        # Fixture: catalog holds 2 of 3 units, 3-question file → 2 measured,
        # 1 outside the catalog. --expect-questions matches questions_measured,
        # not questions_in_file, so the bounded catalog does not read as a
        # shortfall.
        result = run_verify(base_report(), expect_questions=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GREEN", result.stdout)
        self.assertIn("questions_measured", result.stdout)

    def test_unit_scale_checks_questions_measured_not_n_questions(self):
        # n_questions and questions_measured diverging would be a real bug
        # (they are the same count under two names in the current runner),
        # but the verifier must key off questions_measured at unit scale —
        # prove that by setting n_questions to something that would pass and
        # questions_measured to something that must fail.
        report = base_report(n_questions=2, questions_measured=1)
        result = run_verify(report, expect_questions=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RED", result.stdout)

    def test_unit_scale_wrong_measured_count_is_red(self):
        report = base_report(questions_measured=1)
        result = run_verify(report, expect_questions=2)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("RED", result.stdout)

    def test_bench_aggregate_scale_uses_n_questions(self):
        # No catalog at bench-aggregate scale: questions_outside_catalog is
        # 0 and the classic n_questions field is what proves the call-return.
        report = base_report(
            config={"dataset": "locomo", "target_scale": "bench-aggregate"},
            n_questions=3, questions_measured=3, questions_outside_catalog=0,
            questions_in_file=3)
        result = run_verify(report, target_scale="bench-aggregate", expect_questions=3)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GREEN", result.stdout)

    def test_missing_bounded_catalog_fields_is_red(self):
        report = base_report()
        del report["questions_measured"]
        del report["questions_outside_catalog"]
        result = run_verify(report, expect_questions=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RED", result.stdout)


if __name__ == "__main__":
    unittest.main()
