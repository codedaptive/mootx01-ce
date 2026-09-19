"""catalog_exercise on a stub serve: the list-vs-table check, placeholder
capture, pinned outcomes, and survival of a serve that dies under a call."""
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
RUNNER = HERE.parent / "catalog_exercise.py"

# A stdio serve with three tools: `ping` answers ok and reports an id,
# `get` echoes the id it was given, `boom` exits the process mid-call.
STUB = r'''#!/usr/bin/env python3
import json, os, sys
db = sys.argv[sys.argv.index("--db") + 1]
assert os.path.basename(db) == "e1", db          # the clone keeps the estate's name
def send(obj): print(json.dumps(obj), flush=True)
for line in iter(sys.stdin.readline, ""):
    msg = json.loads(line)
    if "id" not in msg: continue
    m = msg["method"]; i = msg["id"]
    if m == "initialize": send({"jsonrpc":"2.0","id":i,"result":{}})
    elif m == "tools/list": send({"jsonrpc":"2.0","id":i,"result":{"tools":[{"name":"ping"},{"name":"get"},{"name":"boom"}]}})
    else:
        name = msg["params"]["name"]; args = msg["params"]["arguments"]
        if name == "ping": send({"jsonrpc":"2.0","id":i,"result":{"content":[{"type":"text","text":"pong"}],"structuredContent":{"data":{"item":{"id":"abc-1"}}}}})
        elif name == "get": send({"jsonrpc":"2.0","id":i,"result":{"content":[{"type":"text","text":"got "+args["id"]}],"structuredContent":{"data":{}}}})
        elif name == "boom": os._exit(3)
'''


class CatalogExerciseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.binary = self.tmp / "mootx01"
        self.binary.write_text(STUB)
        self.binary.chmod(self.binary.stat().st_mode | stat.S_IEXEC)
        self.estate = self.tmp / "e1"
        self.estate.mkdir()
        (self.estate / "estate.sqlite").write_text("x")
        (self.estate / "estate.pid").write_text("999")

    def run_with(self, calls, record=False):
        table = self.tmp / "calls.json"
        table.write_text(json.dumps(calls))
        out = self.tmp / "out"
        proc = subprocess.run([sys.executable, str(RUNNER), "--binary", str(self.binary), "--estate", str(self.estate),
                               "--calls", str(table), "--out", str(out), "--timeout", "20", *(["--record"] if record else [])],
                              capture_output=True, text=True)
        return proc, json.loads((out / "report.json").read_text())

    def test_pinned_pass_captures_ids_and_flags_every_mismatch(self):
        calls = [{"tool": "ping", "capture": {"ID": "item.id"}},
                 {"tool": "get", "arguments": {"id": "${ID}"}},
                 {"tool": "boom", "expect": "ok"}]
        proc, report = self.run_with(calls)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        by = {r["id"]: r for r in report["calls"]}
        self.assertEqual(by["ping"]["outcome"], "ok")
        self.assertEqual(by["ping"]["captured"], {"ID": "abc-1"})
        self.assertEqual(by["get"]["arguments"], {"id": "abc-1"})
        self.assertTrue(by["boom"]["outcome"].startswith("crash:"))
        self.assertEqual(len(report["failures"]), 1)
        self.assertIn("boom", report["failures"][0])
        self.assertFalse((self.tmp / "out" / "estate" / "e1" / "estate.pid").exists())   # never cloned

    def test_table_and_list_must_agree(self):
        proc, report = self.run_with([{"tool": "ping"}, {"tool": "nope"}])
        self.assertEqual(proc.returncode, 1)
        joined = " ".join(report["failures"])
        self.assertIn("not in the call table: boom", joined)
        self.assertIn("not in the call table: get", joined)
        self.assertIn("not in tools/list: nope", joined)

    def test_serve_is_reopened_after_a_crash_so_later_calls_still_fire(self):
        calls = [{"tool": "boom", "expect": "crash"}, {"tool": "ping"}, {"tool": "get", "arguments": {"id": "x"}}]
        proc, report = self.run_with(calls, record=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)   # record mode never judges
        outcomes = [r["outcome"] for r in report["calls"]]
        self.assertTrue(outcomes[0].startswith("crash:"))
        self.assertEqual(outcomes[1:], ["ok", "ok"])
        self.assertIn("text_head", report["calls"][1])


if __name__ == "__main__":
    unittest.main()
