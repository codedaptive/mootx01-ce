"""Tests for artifact_watch on the faker: drain, claim race, stale reclaim, crash retry, failure."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import artifact_layout as L  # noqa: E402
import artifact_import as I  # noqa: E402
import artifact_watch as W   # noqa: E402
sys.path.insert(0, str(HERE))
from test_import import write_projection, rec  # noqa: E402

FAKER = HERE.parent / "mootx01_faker.py"
WATCH = HERE.parent / "artifact_watch.py"


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        os.environ.pop("MOOTX01_FAKER_CONFIG", None)

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, n_units=5, set_size=2, records=1):
        proj = self.root / "proj"
        units = {f"u{i}": [rec(f"u{i}r{j}") for j in range(records)] for i in range(n_units)}
        write_projection(proj, units)
        projection = I.Projection.open(proj)
        self.bases = [self.root / "base1", self.root / "base2"]
        target = L.TargetMap([L.BaseFolder(self.bases[0], 10**9), L.BaseFolder(self.bases[1], 10**9)], 0)
        sets = L.lay_out_dataset(target, "swift", "demo", projection.unit_ids(),
                                 bytes_per_estate=1, aggregate_bytes=1, set_size=set_size)
        L.write_catalog(self.bases[0], "swift", "demo", sets)
        I.provision_all(FAKER, self.root / "template", sets)
        I.import_waves(FAKER, projection, "demo", "swift", sets)
        return sets

    def watcher(self, wid="w1", stale=600, config=None, floor=None):
        env = dict(os.environ)
        if config is not None:
            cfg = self.root / f"{wid}.cfg.json"
            cfg.write_text(json.dumps(config))
            env["MOOTX01_FAKER_CONFIG"] = str(cfg)
        return subprocess.Popen([sys.executable, str(WATCH), "--exe", str(FAKER), "--port", "swift",
                                 "--dataset", "demo", "--bases", *map(str, self.bases),
                                 "--id", wid, "--stale", str(stale), "--poll", "0.05",
                                 *(["--floor", str(floor)] if floor is not None else [])],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)

    def map_names(self, sdir):
        return sorted(p.name for p in sdir.glob("partition_map*"))

    def test_single_watcher_drains_every_set_and_the_aggregate(self):
        sets = self.build()
        proc = self.watcher()
        out, err = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 0, err)
        for s in sets:
            self.assertEqual(self.map_names(s.path), ["partition_map.done.json"], s.name)
            for estate in s.estates.values():
                addr = L.read_address(estate)
                self.assertEqual(addr["state"], "encoded")
                self.assertGreater(addr["size_bytes"], 0)
        done = json.loads((sets[0].path / "partition_map.done.json").read_text())
        self.assertEqual(done["drained_by"], "w1")
        self.assertEqual(done["encoded_size"], sum(L.read_address(e)["size_bytes"] for e in sets[0].estates.values()))
        catalog = json.loads((self.bases[0] / "swift/demo/catalog.json").read_text())
        self.assertEqual({r["state"] for r in catalog["sets"]}, {"encoded"})

    def test_two_watchers_never_drain_the_same_set_twice(self):
        sets = self.build(n_units=12, set_size=2)
        w1, w2 = self.watcher("w1", config={"sleep_ms": 20}), self.watcher("w2", config={"sleep_ms": 20})
        for p in (w1, w2):
            _, err = p.communicate(timeout=60)
            self.assertEqual(p.returncode, 0, err)
        drained_by = [json.loads((s.path / "partition_map.done.json").read_text())["drained_by"] for s in sets]
        self.assertEqual(len(drained_by), len(sets))
        self.assertEqual(set(drained_by), {"w1", "w2"})   # both got work, none twice

    def test_stale_claim_is_reclaimed_and_resumed(self):
        sets = self.build(n_units=3, set_size=3)
        s = sets[0]
        # A dead watcher: claim exists, one estate already encoded, heartbeat old.
        claim = s.path / "partition_map.dead.claimed"
        (s.path / "partition_map.json").rename(claim)
        first = next(iter(s.estates.values()))
        L.write_address(first, unit="u0", dataset="demo", port="swift", set_name=s.name,
                        state="encoded", size_bytes=999)
        old = time.time() - 3600
        os.utime(claim, (old, old))
        proc = self.watcher("w9", stale=1)
        out, err = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 0, err)
        self.assertIn("reclaimed stale", out)
        self.assertEqual(self.map_names(s.path), ["partition_map.done.json"])
        self.assertEqual(L.read_address(first)["size_bytes"], 999)   # not re-drained
        self.assertEqual(L.read_address(first)["timestamps"].keys() & {"encoded"}, {"encoded"})

    def test_drainer_crash_is_retried_and_completes(self):
        sets = self.build(n_units=3, set_size=3)
        proc = self.watcher("w1", config={"die_after": 2})
        out, err = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 0, err)
        self.assertIn("released estate_set1 after crash", out)
        self.assertEqual(self.map_names(sets[0].path), ["partition_map.done.json"])
        self.assertTrue(all(L.read_address(e)["state"] == "encoded" for e in sets[0].estates.values()))

    def test_three_crashes_give_up_and_mark_the_set_failed(self):
        sets = self.build(n_units=4, set_size=4)
        proc = self.watcher("w1", config={"die_after": 1})
        out, err = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 1, err)
        self.assertEqual(self.map_names(sets[0].path), ["partition_map.failed.json"])
        failed = json.loads((sets[0].path / "partition_map.failed.json").read_text())
        self.assertIn("batch-drain exit 137", failed["reason"])
        self.assertEqual(failed["attempts"], 2)          # two releases, third crash gives up
        encoded = [e for e in sets[0].estates.values() if L.read_address(e)["state"] == "encoded"]
        self.assertEqual(len(encoded), 3)                # one estate per attempt before dying
        self.assertEqual(self.map_names(sets[-1].path), ["partition_map.done.json"])

    def test_disk_floor_skips_blocked_base_and_drains_the_healthy_one(self):
        # Two units per set, 4 units -> set1 in base1, set2 + aggregate in base2
        # (base1 capacity fits exactly one set estimate). A high floor then
        # blocks base1 (over capacity once cloned) while base2 has room.
        proj = self.root / "proj"
        units = {f"u{i}": [rec(f"u{i}r0")] for i in range(4)}
        write_projection(proj, units)
        projection = I.Projection.open(proj)
        self.bases = [self.root / "base1", self.root / "base2"]
        target = L.TargetMap([L.BaseFolder(self.bases[0], 2 * 1000), L.BaseFolder(self.bases[1], 10**12)], 0)
        sets = L.lay_out_dataset(target, "swift", "demo", projection.unit_ids(),
                                 bytes_per_estate=1000, aggregate_bytes=1000, set_size=2)
        L.write_catalog(self.bases[0], "swift", "demo", sets)
        I.provision_all(FAKER, self.root / "template", sets)
        I.import_waves(FAKER, projection, "demo", "swift", sets)
        self.assertEqual(sets[0].base.name, "base1")
        self.assertEqual(sets[1].base.name, "base2")
        proc = self.watcher("w1", floor=1)
        out, err = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 3, err + out)
        self.assertIn("disk floor reached", out)
        self.assertEqual(self.map_names(sets[0].path), ["partition_map.json"])       # left unclaimed
        self.assertEqual(self.map_names(sets[1].path), ["partition_map.done.json"])  # healthy base drained
        self.assertEqual(self.map_names(sets[-1].path), ["partition_map.done.json"])

    def test_failed_line_marks_set_failed_and_others_finish(self):
        sets = self.build(n_units=4, set_size=2)
        proc = self.watcher("w1", config={"fail_match": "estate_set1/u1"})
        out, err = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 1, err)
        self.assertEqual(self.map_names(sets[0].path), ["partition_map.failed.json"])
        failed = json.loads((sets[0].path / "partition_map.failed.json").read_text())
        self.assertIn("injected-failure", failed["reason"])
        self.assertEqual(self.map_names(sets[1].path), ["partition_map.done.json"])
        self.assertEqual(self.map_names(sets[-1].path), ["partition_map.done.json"])
        catalog = json.loads((self.bases[0] / "swift/demo/catalog.json").read_text())
        states = {r["name"]: r["state"] for r in catalog["sets"]}
        self.assertEqual(states["estate_set1"], "failed")
        self.assertEqual(states["estate_set2"], "encoded")


if __name__ == "__main__":
    unittest.main()


class ResumeTests(WatchTests):
    """A second build over a bounded first one keeps the built units, imports
    only the new ones, and rebuilds the aggregate from every unit."""

    def test_resume_keeps_built_units_and_rebuilds_the_aggregate(self):
        first = self.build(n_units=3, set_size=2, records=2)      # u0..u2 imported
        kept = {u: L.read_address(e) for s in first if s.name != L.AGGREGATE_SET
                for u, e in s.estates.items()}
        self.assertEqual({a["state"] for a in kept.values()}, {"imported"})
        old_agg = next(s for s in first if s.name == L.AGGREGATE_SET).estates["demo"]
        self.assertEqual(L.read_address(old_agg)["record_count"], 6)

        # The wider projection: the first three units plus two new ones.
        proj = self.root / "proj-wider"
        units = {f"u{i}": [rec(f"u{i}r{j}") for j in range(2)] for i in range(5)}
        write_projection(proj, units)
        projection = I.Projection.open(proj)
        target = L.TargetMap([L.BaseFolder(self.bases[0], 10**9), L.BaseFolder(self.bases[1], 10**9)], 0)
        sets = L.lay_out_dataset(target, "swift", "demo", projection.unit_ids(),
                                 bytes_per_estate=1, aggregate_bytes=1, set_size=2)
        for s in sets:
            if s.name == L.AGGREGATE_SET:
                self.assertEqual(L.read_address(s.estates["demo"])["state"], "laid_out",
                                 "the aggregate is laid out again when any unit is new")
                continue
            for u, e in s.estates.items():
                if u in kept:
                    self.assertEqual(L.read_address(e), kept[u], f"{u} kept as built")
                else:
                    self.assertEqual(L.read_address(e)["state"], "laid_out")
        I.provision_all(FAKER, self.root / "template", sets)
        counts = I.import_waves(FAKER, projection, "demo", "swift", sets)
        self.assertEqual(counts["demo"], 10, "the aggregate holds every unit's records")
        self.assertEqual({u: counts[u] for u in kept}, {u: 2 for u in kept})
        for s in sets:
            if s.name == L.AGGREGATE_SET:
                continue
            for u, e in s.estates.items():
                addr = L.read_address(e)
                self.assertEqual(addr["state"], "imported")
                if u in kept:
                    self.assertEqual(addr["timestamps"], kept[u]["timestamps"], f"{u} not imported again")
            self.assertTrue((s.path / "partition_map.json").exists(), "every unfinished set gets its map")
