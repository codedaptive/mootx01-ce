"""Tests for mootx01_faker: the three calls and the three fault injections."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
FAKER = HERE.parent / "mootx01_faker.py"


def run(*args, config=None):
    env = dict(os.environ)
    env.pop("MOOTX01_FAKER_CONFIG", None)
    tmp = None
    if config is not None:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(config, tmp)
        tmp.close()
        env["MOOTX01_FAKER_CONFIG"] = tmp.name
    try:
        return subprocess.run([sys.executable, str(FAKER), *map(str, args)],
                              capture_output=True, text=True, env=env)
    finally:
        if tmp:
            os.unlink(tmp.name)


def write_records(path, ids):
    with open(path, "w", encoding="utf-8") as handle:
        for rid in ids:
            handle.write(json.dumps({"id": rid, "body": f"record {rid}"}) + "\n")


class FakerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def estate(self, name, records=()):
        estate = self.root / name
        self.assertEqual(run("provision", estate).returncode, 0)
        if records:
            recs = self.root / f"{name}.jsonl"
            write_records(recs, records)
            out = run("import", estate, recs)
            self.assertEqual(out.returncode, 0)
            self.assertEqual(out.stdout.strip(), f"imported {len(records)}")
        return estate

    def test_provision_writes_nine_files(self):
        estate = self.estate("e1")
        files = sorted(p.name for p in estate.iterdir())
        self.assertEqual(len(files), 9)
        self.assertIn("estate.sqlite", files)
        self.assertIn("id-map.json", files)

    def test_import_before_provision_fails(self):
        recs = self.root / "r.jsonl"
        write_records(recs, ["a"])
        out = run("import", self.root / "missing", recs)
        self.assertEqual(out.returncode, 1)
        self.assertTrue(out.stdout.startswith("failed"))

    def test_batch_drain_reports_idle_with_size(self):
        e1 = self.estate("e1", ["a", "b", "c"])
        e2 = self.estate("e2", ["d"])
        lst = self.root / "set.txt"
        lst.write_text(f"{e1}\n{e2}\n")
        out = run("batch-drain", lst)
        self.assertEqual(out.returncode, 0)
        lines = out.stdout.strip().splitlines()
        self.assertEqual(lines[0], f"idle {e1} {4096 + 3 * 512}")
        self.assertEqual(lines[1], f"idle {e2} {4096 + 512}")
        self.assertTrue((e1 / "faker.encoded").exists())

    def test_fail_match_stops_the_batch(self):
        e1 = self.estate("good", ["a"])
        e2 = self.estate("bad-one", ["b"])
        e3 = self.estate("after", ["c"])
        lst = self.root / "set.txt"
        lst.write_text(f"{e1}\n{e2}\n{e3}\n")
        out = run("batch-drain", lst, config={"fail_match": "bad-one"})
        self.assertEqual(out.returncode, 1)
        lines = out.stdout.strip().splitlines()
        self.assertTrue(lines[0].startswith(f"idle {e1}"))
        self.assertEqual(lines[1], f"failed {e2} injected-failure")
        self.assertFalse((e3 / "faker.encoded").exists())

    def test_die_after_exits_137_mid_batch(self):
        estates = [self.estate(f"e{i}", ["x"]) for i in range(4)]
        lst = self.root / "set.txt"
        lst.write_text("".join(f"{e}\n" for e in estates))
        out = run("batch-drain", lst, config={"die_after": 2})
        self.assertEqual(out.returncode, 137)
        self.assertEqual(len(out.stdout.strip().splitlines()), 2)
        self.assertFalse((estates[2] / "faker.encoded").exists())

    def test_stall_match_delays_that_estate(self):
        e1 = self.estate("slow", ["a"])
        lst = self.root / "set.txt"
        lst.write_text(f"{e1}\n")
        import time
        start = time.monotonic()
        out = run("batch-drain", lst,
                  config={"stall_match": "slow", "stall_ms": 300, "sleep_ms": 0})
        self.assertEqual(out.returncode, 0)
        self.assertGreaterEqual(time.monotonic() - start, 0.3)

    def test_usage_error(self):
        self.assertEqual(run("bogus").returncode, 2)


if __name__ == "__main__":
    unittest.main()
