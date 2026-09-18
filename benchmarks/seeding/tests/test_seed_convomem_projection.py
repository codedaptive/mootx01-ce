"""ConvoMem seeder writes the builder's projection. Runs on one scene per evidence set."""
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

SEEDER = HERE.parent / "seed_convomem.py"
FIXTURE_ROOT = pathlib.Path(os.environ.get(
    "LMEB_DATA_DIR", "~/devlop/benchmark-cache/fixtures/lmeb/data/ConvoMem")).expanduser()


@unittest.skipUnless(FIXTURE_ROOT.is_dir(), f"ConvoMem fixture not present at {FIXTURE_ROOT}")
class ConvoMemProjectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = pathlib.Path(cls.tmp.name)
        proc = subprocess.run([sys.executable, str(SEEDER), "--fixture-root", str(FIXTURE_ROOT),
                               "--out", str(cls.out), "--limit", "1"],
                              capture_output=True, text=True)
        assert proc.returncode == 0, proc.stderr
        cls.questions = [json.loads(l) for l in (cls.out / "questions.jsonl").read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_one_unit_per_set_overlap_false(self):
        p = I.Projection.open(self.out / "projection")
        self.assertFalse(p.overlap)
        units = p.unit_ids()
        old_units = sorted(f.stem for f in (self.out / "units").glob("*.json"))
        self.assertEqual(units, old_units)
        self.assertGreaterEqual(len(units), 1)

    def test_records_match_old_unit_files(self):
        p = I.Projection.open(self.out / "projection")
        for unit in p.unit_ids():
            new = p.records(unit)
            old = json.loads((self.out / "units" / f"{unit}.json").read_text())["records"]
            self.assertEqual([r["id"] for r in new], [r["id"] for r in old])
            self.assertEqual([r["body"] for r in new], [r["content"] for r in old])
            self.assertEqual([r["room"] for r in new], [r["room"] for r in old])
            self.assertTrue(all(r["shape"] == "session" for r in new))

    def test_gold_relation_follows_qrels_per_scene_query(self):
        p = I.Projection.open(self.out / "projection")
        for unit in p.unit_ids():
            set_name, scene = unit.split("__", 1)
            scene_qs = [q for q in self.questions
                        if q["set"] == set_name and q["query_id"].rsplit("_q_", 1)[0] == scene]
            self.assertGreater(len(scene_qs), 0, unit)
            recs = p.records(unit)
            for n, q in enumerate(scene_qs, start=1):
                qid = f"{unit}/q{n}"
                gold = set(q["answer_session_ids"])
                for r in recs:
                    self.assertIn(qid, r["gold"])
                    self.assertEqual(r["gold"][qid], "gold" if r["id"] in gold else "distractor")
            for r in recs:
                self.assertEqual(len(r["gold"]), len(scene_qs))

    def test_dataset_counts(self):
        meta = json.loads((self.out / "projection" / "dataset.json").read_text())
        p = I.Projection.open(self.out / "projection")
        self.assertEqual(meta["dataset"], "convomem")
        self.assertEqual(meta["units"], len(p.unit_ids()))


if __name__ == "__main__":
    unittest.main()
