"""Tests for artifact_import on the faker: clone, wave import, ledger, partition map."""
import json
import os
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import artifact_layout as L  # noqa: E402
import artifact_import as I  # noqa: E402

FAKER = HERE.parent / "mootx01_faker.py"


def write_projection(root, units, room_rule="room = first word", overlap=False):
    (root / "units").mkdir(parents=True)
    (root / "dataset.json").write_text(json.dumps({"room_rule": room_rule, "overlap": overlap}))
    for unit, records in units.items():
        with open(root / "units" / f"{unit}.jsonl", "w") as handle:
            for r in records:
                handle.write(json.dumps(r) + "\n")


def rec(rid, gold=None, shape="line"):
    return {"id": rid, "body": f"body {rid}", "room": "r", "shape": shape, "gold": gold or {}}


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        os.environ.pop("MOOTX01_FAKER_CONFIG", None)

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, units, overlap=False, set_size=2):
        proj = self.root / "proj"
        write_projection(proj, units, overlap=overlap)
        projection = I.Projection.open(proj)
        target = L.TargetMap([L.BaseFolder(self.root / "base1", 10**9)], 0)
        sets = L.lay_out_dataset(target, "swift", "demo", projection.unit_ids(),
                                 bytes_per_estate=1, aggregate_bytes=1, set_size=set_size)
        I.provision_all(FAKER, self.root / "template", sets)
        counts = I.import_waves(FAKER, projection, "demo", "swift", sets)
        return projection, sets, counts

    def faker_records(self, estate):
        p = estate / "faker.records"
        return p.read_text().split() if p.exists() else []

    def test_clone_gives_every_estate_the_ten_files_and_provisioned_state(self):
        _, sets, _ = self.build({"u1": [rec("a")], "u2": [rec("b")], "u3": [rec("c")]})
        for s in sets:
            for estate in s.estates.values():
                names = {p.name for p in estate.iterdir()}
                self.assertTrue(set(I_FILES) <= names, names)
                self.assertIn("address.json", names)

    def test_read_once_write_twice_no_overlap(self):
        units = {"u1": [rec("a"), rec("b")], "u2": [rec("c")], "u3": [rec("d"), rec("e"), rec("f")]}
        _, sets, counts = self.build(units)
        self.assertEqual(counts, {"u1": 2, "u2": 1, "u3": 3, "demo": 6})
        agg = sets[-1].estates["demo"]
        self.assertEqual(sorted(self.faker_records(agg)), list("abcdef"))
        self.assertEqual(L.read_address(agg)["record_count"], 6)

    def test_overlap_dataset_dedupes_the_aggregate(self):
        units = {"u1": [rec("a"), rec("b")], "u2": [rec("b"), rec("c")]}
        _, sets, counts = self.build(units, overlap=True)
        self.assertEqual(counts["u2"], 2)            # the unit keeps its copy
        self.assertEqual(counts["demo"], 3)          # the aggregate does not
        self.assertEqual(sorted(self.faker_records(sets[-1].estates["demo"])), ["a", "b", "c"])

    def test_ledger_has_room_rule_and_relation_per_question(self):
        units = {"u1": [rec("a", {"q1": "gold"}), rec("b", {"q1": "distractor", "q2": "gold"}), rec("c")]}
        _, sets, _ = self.build(units, set_size=5)
        ledger = json.loads((sets[0].estates["u1"] / "ledger.json").read_text())
        self.assertEqual(ledger["room_rule"], "room = first word")
        self.assertEqual(ledger["questions"], ["q1", "q2"])
        rel = {r["id"]: r["relation"] for r in ledger["records"]}
        self.assertEqual(rel["a"], {"q1": "gold", "q2": "absent"})
        self.assertEqual(rel["b"], {"q1": "distractor", "q2": "gold"})
        self.assertEqual(rel["c"], {"q1": "absent", "q2": "absent"})
        self.assertEqual(ledger["source"]["unit"], "u1")

    def test_partition_map_lists_exactly_its_estates_and_done_marker_exists(self):
        units = {f"u{i}": [rec(f"r{i}")] for i in range(5)}
        _, sets, _ = self.build(units, set_size=2)
        for s in sets[:-1]:
            doc = json.loads((s.path / "partition_map.json").read_text())
            self.assertEqual([e["unit"] for e in doc["estates"]], list(s.estates))
            self.assertEqual(doc["set"], s.name)
            for e in doc["estates"]:
                self.assertEqual(L.read_address(s.path / e["path"])["state"], "imported")
        self.assertFalse((sets[-1].path / "partition_map.json").exists())
        self.assertTrue((self.root / "base1/swift/demo/import.done").exists())

    def test_import_failure_marks_estate_failed_and_writes_no_map(self):
        proj = self.root / "proj"
        write_projection(proj, {"u1": [rec("a")], "u2": [rec("b")]})
        projection = I.Projection.open(proj)
        target = L.TargetMap([L.BaseFolder(self.root / "base1", 10**9)], 0)
        sets = L.lay_out_dataset(target, "swift", "demo", projection.unit_ids(),
                                 bytes_per_estate=1, aggregate_bytes=1, set_size=5)
        I.provision_all(FAKER, self.root / "template", sets)
        # Break u2 so the faker's import refuses it (not provisioned).
        for p in (sets[0].estates["u2"] / "estate.sqlite",):
            p.unlink()
        with self.assertRaises(I.ImportError_):
            I.import_waves(FAKER, projection, "demo", "swift", sets)
        failed = L.read_address(sets[0].estates["u2"])
        self.assertEqual(failed["state"], "failed")
        self.assertIn("not-provisioned", failed["error"])
        self.assertFalse((sets[0].estates["u2"] / "failed.txt").exists())
        self.assertFalse((sets[0].path / "partition_map.json").exists())
        self.assertFalse((self.root / "base1/swift/demo/import.done").exists())


I_FILES = (
    "estate.sqlite", "estate.sqlite-shm", "estate.sqlite-wal", "estate.queue.sqlite",
    "estate.queue.sqlite-shm", "estate.queue.sqlite-wal", "estate.vectors.vec",
    "encode.drain.lease", "id-map.json",
)

if __name__ == "__main__":
    unittest.main()
