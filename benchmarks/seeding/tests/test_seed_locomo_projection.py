"""LoCoMo seeder writes the builder's projection. Runs on one conversation of the real fixture."""
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

SEEDER = HERE.parent / "seed_locomo.py"
FIXTURE = pathlib.Path(os.environ.get(
    "LOCOMO_JSON", "~/devlop/benchmark-cache/fixtures/locomo/data/locomo10.json")).expanduser()


@unittest.skipUnless(FIXTURE.exists(), f"LoCoMo fixture not present at {FIXTURE}")
class LocomoProjectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = pathlib.Path(cls.tmp.name)
        proc = subprocess.run([sys.executable, str(SEEDER), "--fixture", str(FIXTURE),
                               "--out", str(cls.out), "--limit", "1"],
                              capture_output=True, text=True)
        assert proc.returncode == 0, proc.stderr
        cls.stdout = proc.stdout
        cls.fixture = json.loads(FIXTURE.read_text())[0]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_projection_opens_with_the_builder_reader(self):
        p = I.Projection.open(self.out / "projection")
        self.assertFalse(p.overlap)
        self.assertIn("classify_room", p.room_rule)
        self.assertIn("'general'", p.room_rule)
        self.assertEqual(p.unit_ids(), [self.fixture["sample_id"]])

    def test_records_match_the_old_unit_file_and_carry_room_and_shape(self):
        p = I.Projection.open(self.out / "projection")
        sid = self.fixture["sample_id"]
        new = p.records(sid)
        old = json.loads((self.out / "units" / f"{sid}.json").read_text())["records"]
        self.assertEqual([r["id"] for r in new], [r["id"] for r in old])
        self.assertEqual([r["body"] for r in new], [r["content"] for r in old])
        self.assertEqual([r["room"] for r in new], [r["room"] for r in old])
        self.assertTrue(all(r["shape"] == "session" for r in new))
        self.assertGreater(len(new), 1)

    def test_gold_relation_matches_the_evidence_sessions(self):
        p = I.Projection.open(self.out / "projection")
        sid = self.fixture["sample_id"]
        new = {r["id"]: r for r in p.records(sid)}
        questions = [json.loads(l) for l in (self.out / "questions.jsonl").read_text().splitlines()]
        self.assertEqual(len(questions), len(self.fixture["qa"]))
        for n, q in enumerate(questions, start=1):
            qid = f"{sid}/q{n}"
            gold_ids = set(q["answer_session_ids"])
            for rid, r in new.items():
                self.assertIn(qid, r["gold"])
                self.assertEqual(r["gold"][qid], "gold" if rid in gold_ids else "distractor",
                                 f"{qid} {rid}")
        # Every question with evidence names at least one gold record.
        with_evidence = [q for q in questions if q["answer_session_ids"]]
        self.assertGreater(len(with_evidence), 0)
        for q in with_evidence:
            self.assertTrue(any(new[g]["gold"][f"{sid}/q{questions.index(q) + 1}"] == "gold"
                                for g in q["answer_session_ids"] if g in new))

    def test_dataset_file_counts(self):
        meta = json.loads((self.out / "projection" / "dataset.json").read_text())
        self.assertEqual(meta["dataset"], "locomo")
        self.assertEqual(meta["units"], 1)
        self.assertEqual(meta["questions"], len(self.fixture["qa"]))


if __name__ == "__main__":
    unittest.main()
