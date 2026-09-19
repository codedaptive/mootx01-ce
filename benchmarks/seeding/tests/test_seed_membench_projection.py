"""MemBench seeder writes the builder's projection. Runs on one item per family and category."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import artifact_import as I  # noqa: E402

SEEDER = HERE.parent / "seed_membench.py"
FIXTURE_ROOT = pathlib.Path(os.environ.get(
    "MEMBENCH_DATA_DIR", "~/devlop/benchmark-cache/fixtures/membench/MemData")).expanduser()


@unittest.skipUnless(FIXTURE_ROOT.is_dir(), f"MemBench fixture not present at {FIXTURE_ROOT}")
class MemBenchProjectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = pathlib.Path(cls.tmp.name)
        proc = subprocess.run([sys.executable, str(SEEDER), "--fixture-root", str(FIXTURE_ROOT),
                               "--out", str(cls.out), "--limit", "1"],
                              capture_output=True, text=True)
        assert proc.returncode == 0, proc.stderr
        cls.questions = {}
        for line in (cls.out / "questions.jsonl").read_text().splitlines():
            q = json.loads(line)
            cls.questions[f"{q['family']}__{q['category']}__{q['section']}__{q['tid']}"] = q

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_units_match_written_unit_files_overlap_false(self):
        p = I.Projection.open(self.out / "projection")
        self.assertFalse(p.overlap)
        self.assertIn("room_for", p.room_rule)
        old_units = sorted(f.stem for f in (self.out / "units").glob("*.json"))
        self.assertEqual(p.unit_ids(), old_units)
        self.assertGreater(len(old_units), 1)

    def test_records_match_old_unit_files_and_are_topical(self):
        p = I.Projection.open(self.out / "projection")
        for unit in p.unit_ids():
            new = p.records(unit)
            old = json.loads((self.out / "units" / f"{unit}.json").read_text())["records"]
            self.assertEqual([r["id"] for r in new], [r["id"] for r in old])
            self.assertEqual([r["body"] for r in new], [r["content"] for r in old])
            self.assertEqual([r["room"] for r in new], [r["room"] for r in old])
            self.assertTrue(all(r["shape"] == "topical" for r in new))

    def test_gold_relation_is_the_answer_drawers(self):
        p = I.Projection.open(self.out / "projection")
        checked = 0
        for unit in p.unit_ids():
            gold = set(self.questions[unit]["answer_drawer_ids"])
            for r in p.records(unit):
                self.assertEqual(list(r["gold"]), [f"{unit}/q1"])
                self.assertEqual(r["gold"][f"{unit}/q1"], "gold" if r["id"] in gold else "distractor")
                checked += 1
        self.assertGreater(checked, 0)

    def test_dataset_counts(self):
        meta = json.loads((self.out / "projection" / "dataset.json").read_text())
        p = I.Projection.open(self.out / "projection")
        self.assertEqual(meta["dataset"], "membench")
        self.assertEqual(meta["units"], len(p.unit_ids()))
        self.assertEqual(meta["questions"], len(p.unit_ids()))


if __name__ == "__main__":
    unittest.main()
