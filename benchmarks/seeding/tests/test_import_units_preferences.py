"""Tests for set_benchmark_preferences in import_units.

Verifies that set_benchmark_preferences first materialises the estate through
`mootx01 serve --db` (initialize, then stop), then calls
`mootx01 preference set <key> off --db` for each key in BENCHMARK_PREFERENCES_OFF,
then calls `mootx01 preference list --db`, and returns the correct dict.
"""
import os
import pathlib
import stat
import sys
import tempfile
import textwrap
import unittest

HERE = pathlib.Path(__file__).resolve().parent


class TestSetBenchmarkPreferences(unittest.TestCase):

    def test_calls_and_return(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = pathlib.Path(tmp) / "mootx01_stub"
            calls_log = pathlib.Path(tmp) / "calls.log"

            # Stub executable: appends argv[1:] to calls.log. `serve --db <dir>`
            # writes estate.sqlite into <dir> (the product materialises the
            # estate on first open) and answers JSON-RPC on stdin -- every
            # request carrying an id gets an empty result, notifications are
            # ignored, exit on EOF. `preference list` prints the six-line
            # preference listing.
            stub.write_text(textwrap.dedent(f'''\
                #!/usr/bin/env python3
                import json
                import os
                import sys
                args = sys.argv[1:]
                with open({str(calls_log)!r}, "a") as fh:
                    fh.write(" ".join(args) + "\\n")
                if args[:2] == ["serve", "--db"]:
                    open(os.path.join(args[2], "estate.sqlite"), "ab").close()
                    for line in sys.stdin:
                        msg = json.loads(line)
                        if "id" in msg:
                            print(json.dumps({{"jsonrpc": "2.0", "id": msg["id"],
                                              "result": {{}}}}), flush=True)
                elif args[:2] == ["preference", "list"]:
                    print("fact_extraction on")
                    print("consolidation off")
                    print("contradiction_sweep off")
                    print("cross_encoder_routing off")
                    print("maintenance off")
                    print("adaptive_recall off")
            '''))
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

            # Patch environment and argv before importing import_units.
            os.environ["MOOTX01_BINARY"] = str(stub)
            sys.argv = ["import_units.py", "--estates-dir", tmp]
            sys.path.insert(0, str(HERE.parent))

            # Re-import to pick up the stub binary.
            if "import_units" in sys.modules:
                del sys.modules["import_units"]
            import import_units as iu

            estate_dir = pathlib.Path(tmp) / "test_estate"
            estate_dir.mkdir()

            result = iu.set_benchmark_preferences(str(estate_dir))

            # Verify returned dict has every OFF key mapped to "off".
            for key in iu.BENCHMARK_PREFERENCES_OFF:
                self.assertEqual(result.get(key, "").strip(), "off",
                                 f"expected {key}=off in returned dict")

            # The first serve materialised the estate before any preference write.
            self.assertTrue((estate_dir / "estate.sqlite").exists(),
                            "serve --db did not create estate.sqlite")

            # Verify call log: one serve line (create), then five set lines in
            # BENCHMARK_PREFERENCES_OFF order (flip), then one list line.
            lines = calls_log.read_text().splitlines()
            expected_calls = [f"serve --db {estate_dir}"] + [
                f"preference set {key} off --db {estate_dir}"
                for key in iu.BENCHMARK_PREFERENCES_OFF
            ] + [f"preference list --db {estate_dir}"]
            self.assertEqual(lines, expected_calls)

    def test_extra_off_key_from_environment(self):
        # MOOTX01_BENCH_PREFERENCES_OFF_EXTRA adds keys to the flip: the Rust
        # artifact build names fact_extraction there (ruling 2026-09-16).
        with tempfile.TemporaryDirectory() as tmp:
            stub = pathlib.Path(tmp) / "mootx01_stub"
            calls_log = pathlib.Path(tmp) / "calls.log"
            stub.write_text(textwrap.dedent(f'''\
                #!/usr/bin/env python3
                import json
                import os
                import sys
                args = sys.argv[1:]
                with open({str(calls_log)!r}, "a") as fh:
                    fh.write(" ".join(args) + "\\n")
                if args[:2] == ["serve", "--db"]:
                    open(os.path.join(args[2], "estate.sqlite"), "ab").close()
                    for line in sys.stdin:
                        msg = json.loads(line)
                        if "id" in msg:
                            print(json.dumps({{"jsonrpc": "2.0", "id": msg["id"],
                                              "result": {{}}}}), flush=True)
                elif args[:2] == ["preference", "list"]:
                    for key in ("fact_extraction", "consolidation", "contradiction_sweep",
                                "cross_encoder_routing", "maintenance", "adaptive_recall"):
                        print(key + " off")
            '''))
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
            os.environ["MOOTX01_BINARY"] = str(stub)
            os.environ["MOOTX01_BENCH_PREFERENCES_OFF_EXTRA"] = "fact_extraction"
            sys.argv = ["import_units.py", "--estates-dir", tmp]
            sys.path.insert(0, str(HERE.parent))
            if "import_units" in sys.modules:
                del sys.modules["import_units"]
            try:
                import import_units as iu
                estate_dir = pathlib.Path(tmp) / "test_estate"
                estate_dir.mkdir()
                result = iu.set_benchmark_preferences(str(estate_dir))
            finally:
                del os.environ["MOOTX01_BENCH_PREFERENCES_OFF_EXTRA"]
            self.assertEqual(result.get("fact_extraction", "").strip(), "off")
            self.assertIn(f"preference set fact_extraction off --db {estate_dir}",
                          calls_log.read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
