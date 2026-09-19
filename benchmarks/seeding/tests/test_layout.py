"""Tests for artifact_layout: set planning, failover, address files, catalog."""
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import artifact_layout as L  # noqa: E402


class LayoutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def target(self, capacities, floor=0):
        bases = [L.BaseFolder(self.root / f"base{i}", cap)
                 for i, cap in enumerate(capacities, start=1)]
        return L.TargetMap(bases, floor)

    def test_plan_sets_caps_at_set_size_in_order(self):
        sets = L.plan_sets([f"u{i}" for i in range(250)])
        self.assertEqual([len(s) for s in sets], [100, 100, 50])
        self.assertEqual(sets[2][0], "u200")

    def test_choose_fails_over_and_never_splits_a_set(self):
        target = self.target([1000, 5000], floor=100)
        first = target.choose(800)      # 1000-800 = 200 >= 100: fits primary
        second = target.choose(800)     # primary has 200 left: secondary
        self.assertEqual(first.path.name, "base1")
        self.assertEqual(second.path.name, "base2")

    def test_choose_exhausted_raises(self):
        target = self.target([100], floor=0)
        with self.assertRaises(RuntimeError):
            target.choose(101)

    def test_lay_out_creates_tree_and_address_files(self):
        target = self.target([10_000, 10_000], floor=0)
        units = [f"u{i}" for i in range(5)]
        sets = L.lay_out_dataset(target, "swift", "demo", units,
                                 bytes_per_estate=10, aggregate_bytes=10, set_size=2)
        names = [s.name for s in sets]
        self.assertEqual(names, ["estate_set1", "estate_set2", "estate_set3", "aggregate"])
        e = self.root / "base1/swift/demo/estate_set2/u3"
        self.assertTrue(e.is_dir())
        addr = L.read_address(e)
        self.assertEqual(addr["state"], "laid_out")
        self.assertEqual(addr["set"], "estate_set2")
        self.assertIn("laid_out", addr["timestamps"])
        agg = self.root / "base1/swift/demo/aggregate/demo"
        self.assertEqual(L.read_address(agg)["set"], "aggregate")

    def test_lay_out_second_set_lands_in_secondary(self):
        target = self.target([25, 1000], floor=0)
        units = [f"u{i}" for i in range(4)]
        sets = L.lay_out_dataset(target, "rust", "demo", units,
                                 bytes_per_estate=10, aggregate_bytes=10, set_size=2)
        self.assertEqual(sets[0].base.name, "base1")   # 20 of 25
        self.assertEqual(sets[1].base.name, "base2")   # 20 does not fit in 5
        self.assertEqual(sets[2].base.name, "base2")   # aggregate 10 does not fit in the 5 left

    def test_address_state_moves_forward_only(self):
        e = self.root / "e"
        L.write_address(e, unit="u", dataset="d", port="swift", set_name="estate_set1")
        L.write_address(e, unit="u", dataset="d", port="swift", set_name="estate_set1",
                        state="imported", record_count=8)
        with self.assertRaises(ValueError):
            L.write_address(e, unit="u", dataset="d", port="swift",
                            set_name="estate_set1", state="provisioned")
        addr = L.read_address(e)
        self.assertEqual(addr["record_count"], 8)
        self.assertEqual(set(addr["timestamps"]), {"laid_out", "imported"})

    def test_from_env_stops_loud_when_unset_or_missing(self):
        import os
        saved = os.environ.pop(L.TARGET_MAP_ENV, None)
        try:
            with self.assertRaises(SystemExit) as cm:
                L.TargetMap.from_env("swift", "demo", 0)
            self.assertEqual(cm.exception.code, 2)
            os.environ[L.TARGET_MAP_ENV] = str(self.root / "nope.json")
            with self.assertRaises(SystemExit):
                L.TargetMap.from_env("swift", "demo", 0)
            m = self.root / "map.json"
            m.write_text(json.dumps({"swift": {"demo": [{"path": str(self.root / "b")}]}}))
            os.environ[L.TARGET_MAP_ENV] = str(m)
            self.assertEqual(L.TargetMap.from_env("swift", "demo", 0).bases[0].path.name, "b")
            with self.assertRaises(SystemExit):
                L.TargetMap.from_env("rust", "demo", 0)
        finally:
            if saved is None:
                os.environ.pop(L.TARGET_MAP_ENV, None)
            else:
                os.environ[L.TARGET_MAP_ENV] = saved

    def test_catalog_records_base_per_set(self):
        target = self.target([25, 1000], floor=0)
        sets = L.lay_out_dataset(target, "swift", "demo", ["a", "b", "c", "d"],
                                 bytes_per_estate=10, aggregate_bytes=10, set_size=2)
        path = L.write_catalog(target.bases[0].path, "swift", "demo", sets)
        doc = json.loads(path.read_text())
        bases = {row["name"]: pathlib.Path(row["base"]).name for row in doc["sets"]}
        self.assertEqual(bases["estate_set1"], "base1")
        self.assertEqual(bases["estate_set2"], "base2")
        self.assertEqual(doc["sets"][0]["path"], "swift/demo/estate_set1")

    def test_catalog_keeps_a_recorded_failure_over_encoded_addresses(self):
        # A set whose every estate reached encoded and whose watcher then
        # recorded a terminal failure reads failed on every rewrite, not
        # encoded: the failure marker lives in the set directory, never in
        # the address files.
        target = self.target([1000], floor=0)
        sets = L.lay_out_dataset(target, "swift", "demo", ["a", "b"],
                                 bytes_per_estate=10, aggregate_bytes=10, set_size=2)
        failed, aggregate = sets
        for unit, estate in failed.estates.items():
            for state in ("imported", "encoded"):
                L.write_address(estate, unit=unit, dataset="demo", port="swift",
                                set_name=failed.name, state=state)
        self.assertEqual(L.set_state(failed), "encoded")
        (failed.path / L.FAILED_MAP).write_text('{"reason": "gave up"}\n')
        self.assertEqual(L.set_state(failed), "failed")
        doc = json.loads(L.write_catalog(target.bases[0].path, "swift", "demo",
                                         sets).read_text())
        states = {row["name"]: row["state"] for row in doc["sets"]}
        self.assertEqual(states[failed.name], "failed")
        self.assertEqual(states[aggregate.name], "laid_out")


if __name__ == "__main__":
    unittest.main()
