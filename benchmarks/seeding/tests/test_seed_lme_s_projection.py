"""LME-S seeder writes the builder's projection. Runs on two instances of the real fixture."""
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

SEEDER = HERE.parent / "seed_lme_s.py"
FIXTURE = pathlib.Path(os.environ.get(
    "LME_S_JSON",
    "~/devlop/benchmark-cache/fixtures/longmemeval/data/longmemeval_s_cleaned.json")).expanduser()


@unittest.skipUnless(FIXTURE.exists(), f"LME-S fixture not present at {FIXTURE}")
class LmeSProjectionTests(unittest.TestCase):
    LIMIT = 2

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = pathlib.Path(cls.tmp.name)
        proc = subprocess.run([sys.executable, str(SEEDER), "--fixture", str(FIXTURE),
                               "--out", str(cls.out), "--limit", str(cls.LIMIT)],
                              capture_output=True, text=True)
        assert proc.returncode == 0, proc.stderr
        cls.instances = json.loads(FIXTURE.read_text())[:cls.LIMIT]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_projection_opens_overlap_true_and_units_follow_the_limit(self):
        p = I.Projection.open(self.out / "projection")
        self.assertTrue(p.overlap)
        self.assertIn("classify_room", p.room_rule)
        self.assertEqual(p.unit_ids(), sorted(i["question_id"] for i in self.instances))

    def test_records_match_the_old_unit_file(self):
        p = I.Projection.open(self.out / "projection")
        for inst in self.instances:
            qid = inst["question_id"]
            new = p.records(qid)
            old = json.loads((self.out / "units" / f"{qid}.json").read_text())["records"]
            self.assertEqual([r["id"] for r in new], [r["id"] for r in old])
            self.assertEqual([r["body"] for r in new], [r["content"] for r in old])
            self.assertEqual([r["room"] for r in new], [r["room"] for r in old])
            self.assertTrue(all(r["shape"] == "session" for r in new))

    def test_gold_relation_marks_answer_sessions_only(self):
        p = I.Projection.open(self.out / "projection")
        for inst in self.instances:
            qid = inst["question_id"]
            gold_ids = set(inst["answer_session_ids"])
            golds = 0
            for r in p.records(qid):
                self.assertEqual(list(r["gold"]), [f"{qid}/q1"])
                expected = "gold" if r["id"] in gold_ids else "distractor"
                self.assertEqual(r["gold"][f"{qid}/q1"], expected, f"{qid} {r['id']}")
                golds += expected == "gold"
            self.assertEqual(golds, len(gold_ids & {r["id"] for r in p.records(qid)}))
            self.assertGreater(golds, 0)

    def test_dataset_counts(self):
        meta = json.loads((self.out / "projection" / "dataset.json").read_text())
        self.assertEqual(meta["dataset"], "lme-s")
        self.assertEqual(meta["units"], self.LIMIT)
        self.assertEqual(meta["questions"], self.LIMIT)


if __name__ == "__main__":
    unittest.main()
