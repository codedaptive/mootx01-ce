"""mootx01_seam: the three §11 calls on a stub product binary and a stub importer."""
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SEAM = HERE.parent / "mootx01_seam.py"

STUB_BINARY = r'''#!/usr/bin/env python3
import json, os, sys
verb = sys.argv[1]
db = sys.argv[sys.argv.index("--db") + 1]
if verb == "drain":
    open(os.path.join(db, "drained"), "w").write("1\n"); sys.exit(0)
if verb == "serve":
    idle = not os.path.exists(os.path.join(db, "busy"))
    for line in sys.stdin:
        msg = json.loads(line)
        if "id" not in msg: continue
        if msg["method"] == "initialize":
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {}}), flush=True)
        else:
            drains = [{"name": "corpus_encode", "state": "idle" if idle else "busy", "pending": 0 if idle else 3}]
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"],
                              "result": {"structuredContent": {"data": {"drains": drains}}}}), flush=True)
    sys.exit(0)
sys.exit(2)
'''

STUB_IMPORTER = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv
unit = json.load(open(a[a.index("--file") + 1]))
estate = os.path.join(a[a.index("--estates-dir") + 1], a[a.index("--estate-name") + 1])
os.makedirs(estate, exist_ok=True)
json.dump({"records": [r["id"] for r in unit["records"]], "subjects": [r.get("subject") for r in unit["records"]],
           "binary": os.environ.get("MOOTX01_BINARY")}, open(os.path.join(estate, "estate.sqlite"), "w"))
print("imported", len(unit["records"]))
'''


def write_exe(path: pathlib.Path, text: str) -> pathlib.Path:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


class SeamTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.binary = write_exe(self.tmp / "mootx01", STUB_BINARY)
        self.importer = write_exe(self.tmp / "import_units.py", STUB_IMPORTER)
        self.units = self.tmp / "units"
        self.units.mkdir()
        (self.units / "u1.json").write_text(json.dumps({"format_version": 1, "name": "u1", "records": [
            {"id": "u1/S1", "content": "hello", "room": "r", "subject": "seed subject", "wing": "Personal"}]}))
        self.env = dict(os.environ, MOOTX01_BINARY=str(self.binary), MOOTX01_SEAM_IMPORTER=str(self.importer),
                        MOOTX01_SEAM_UNITS_DIR=str(self.units))

    def seam(self, *args):
        return subprocess.run([sys.executable, str(SEAM), *map(str, args)], capture_output=True, text=True, env=self.env)

    def rows(self, path, rows):
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))
        return path

    def test_provision_makes_the_directory_and_reports_it(self):
        estate = self.tmp / "swift" / "ds" / "estate_set1" / "u1"
        out = self.seam("provision", estate)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue(estate.is_dir())
        self.assertEqual(out.stdout.strip(), f"provisioned {estate}")

    def test_import_runs_the_importer_on_the_seed_record_and_prints_the_count(self):
        estate = self.tmp / "swift" / "ds" / "estate_set1" / "u1"
        estate.mkdir(parents=True)
        src = self.rows(self.tmp / "u1.jsonl", [{"id": "u1/S1", "body": "hello", "room": "r"}])
        out = self.seam("import", estate, src)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "imported 1")
        built = json.load(open(estate / "estate.sqlite"))
        self.assertEqual(built["subjects"], ["seed subject"])   # the seed record, not the projection row
        self.assertEqual(built["binary"], str(self.binary))

    def test_import_without_a_seed_record_synthesises_one_from_the_row(self):
        estate = self.tmp / "swift" / "ds" / "estate_set1" / "x9"
        estate.mkdir(parents=True)
        src = self.rows(self.tmp / "x9.jsonl", [{"id": "x9/1", "body": "first line\nmore", "room": "r"}])
        out = self.seam("import", estate, src)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(json.load(open(estate / "estate.sqlite"))["subjects"], ["first line"])
        unit = json.load(open(estate.parent / "x9.unit.json"))
        self.assertEqual(unit["records"][0]["event_time"], "2026-01-01T00:00:00Z")

    def test_aggregate_import_is_staged_and_paid_once_at_batch_drain(self):
        aggregate = self.tmp / "swift" / "ds" / "aggregate" / "ds"
        aggregate.mkdir(parents=True)
        a = self.rows(self.tmp / "a.jsonl", [{"id": "u1/S1", "body": "hello", "room": "r"}])
        b = self.rows(self.tmp / "b.jsonl", [{"id": "u2/S1", "body": "other", "room": "r"}])
        self.assertEqual(self.seam("import", aggregate, a).stdout.strip(), "imported 1")
        self.assertEqual(self.seam("import", aggregate, b).stdout.strip(), "imported 1")
        self.assertFalse((aggregate / "estate.sqlite").exists())
        lst = self.tmp / "list.txt"
        lst.write_text(f"{aggregate}\n")
        out = self.seam("batch-drain", lst)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(json.load(open(aggregate / "estate.sqlite"))["records"], ["u1/S1", "u2/S1"])
        self.assertFalse((aggregate / ".pending").exists())
        self.assertTrue(out.stdout.startswith(f"idle {aggregate} "))

    def test_batch_drain_runs_the_finisher_then_reads_status(self):
        estate = self.tmp / "swift" / "ds" / "estate_set1" / "u1"
        estate.mkdir(parents=True)
        (estate / "estate.sqlite").write_text("x" * 10)
        lst = self.tmp / "list.txt"
        lst.write_text(f"{estate}\n")
        out = self.seam("batch-drain", lst)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue((estate / "drained").exists())
        parts = out.stdout.split()
        self.assertEqual(parts[:2], ["idle", str(estate)])
        self.assertGreater(int(parts[2]), 0)

    def test_batch_drain_fails_when_status_is_not_idle(self):
        estate = self.tmp / "swift" / "ds" / "estate_set1" / "u1"
        estate.mkdir(parents=True)
        (estate / "busy").write_text("")
        lst = self.tmp / "list.txt"
        lst.write_text(f"{estate}\n")
        out = self.seam("batch-drain", lst)
        self.assertEqual(out.returncode, 1)
        self.assertTrue(out.stdout.startswith(f"failed {estate} drain-status-not-settled:"), out.stdout)

    def test_fact_lane_with_only_blocked_sources_is_settled(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("seam", SEAM)
        seam = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(seam)
        blocked = {"name": "fact_extraction", "state": "draining", "pending": 1,
                   "detail": "no extractor registered; ready: 0, running: 0, partial: 0, retrying: 0, "
                             "blocked: 1, rejected: 0, not applicable: 0, empty: 0"}
        ready = dict(blocked, detail=blocked["detail"].replace("ready: 0", "ready: 1"))
        self.assertTrue(seam.lane_settled(blocked))
        self.assertFalse(seam.lane_settled(ready))
        # The dreaming lane is recall-event work only a resident's governor
        # pumps; `mootx01 drain` settles without it, so the seam does too.
        self.assertTrue(seam.lane_settled({"name": "dreaming", "state": "draining", "pending": 1,
                                           "detail": "stream: dreaming"}))
        self.assertFalse(seam.lane_settled({"name": "corpus_encode", "state": "draining", "pending": 2}))


if __name__ == "__main__":
    unittest.main()
