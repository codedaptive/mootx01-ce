"""Gates for artifact_status.py catalog-based discovery (C1) and smoke_builder
env-var isolation (A1/G3).

G1: status reads the catalog and reports only catalogued estates.
    A decoy estate present on disk but absent from catalog.json is not reported.
    Fails against baseline where status scans the directory tree.

G2: a root with estate directories but no catalog.json is reported as
    NO CATALOG, not READY or BUILDING.
    Fails against baseline where status scans the directory tree.

G3: smoke_builder uses its own scratch target map regardless of
    MOOTX01_BENCH_TARGET_MAP.  Passes both before and after (A1 was
    already satisfied; this is a regression guard).

G4: when --fleet-root is omitted, status resolves each port against its own
    primary base from MOOTX01_BENCH_TARGET_MAP.  A catalog planted at the
    old single-root location for the rust port is not found; only the catalog
    under the rust port's own primary base is consulted.
    Fails against the pre-fix code that used one shared fleet root for both ports.
"""
import json
import os
import pathlib
import sqlite3
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
STATUS = HERE.parent / "artifact_status.py"
sys.path.insert(0, str(HERE.parent))

import artifact_layout as layout  # noqa: E402


# ── helpers ──────────────────────────────────────────────────────────────────

def make_estate_db(estate_dir: pathlib.Path, drawers: int, indexed: int) -> None:
    """Create a minimal estate.sqlite so the probe function can read it."""
    estate_dir.mkdir(parents=True, exist_ok=True)
    db = estate_dir / "estate.sqlite"
    conn = sqlite3.connect(str(db))
    conn.execute("CREATE TABLE drawers (id TEXT)")
    for i in range(drawers):
        conn.execute("INSERT INTO drawers VALUES (?)", (f"d{i}",))
    conn.execute("CREATE TABLE corpus_index_state (id TEXT)")
    for i in range(indexed):
        conn.execute("INSERT INTO corpus_index_state VALUES (?)", (f"d{i}",))
    conn.commit()
    conn.close()


def run_status(fleet_root: str, wing_root: str, seeding_dir: str) -> str:
    """Run artifact_status.py and return its combined stdout+stderr output."""
    import subprocess
    result = subprocess.run(
        [sys.executable, str(STATUS),
         "--fleet-root", fleet_root,
         "--wing-root", wing_root,
         "--seeding-dir", seeding_dir],
        capture_output=True, text=True)
    return result.stdout + result.stderr


# ── G1 ───────────────────────────────────────────────────────────────────────

class CatalogDiscoveryG1Tests(unittest.TestCase):
    """G1: status reports exactly the catalogued estates; the decoy is excluded.

    Setup
    -----
    fleet_root/swift/locomo/catalog.json  -- lists estate_set1 / unit001
    fleet_root/swift/locomo/estate_set1/unit001/estate.sqlite  (5 drawers, 5 indexed -> READY)
    fleet_root/swift/locomo/estates/DECOY_ESTATE/estate.sqlite (5 drawers, 2 indexed -> INCOMPLETE)

    Old status (directory tree scan) discovers DECOY_ESTATE and reports INCOMPLETE.
    New status (catalog) discovers unit001 and reports READY.
    The test asserts READY and the absence of INCOMPLETE in the locomo output row.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def _build_fixture(self):
        fleet_root = self.root / "fleet"

        # Catalogued estate: 5 drawers, 5 indexed -> READY
        unit_dir = fleet_root / "swift" / "locomo" / "estate_set1" / "unit001"
        make_estate_db(unit_dir, drawers=5, indexed=5)

        # Decoy estate (old-style path): 5 drawers, 2 indexed -> INCOMPLETE
        decoy_dir = fleet_root / "swift" / "locomo" / "estates" / "DECOY_ESTATE"
        make_estate_db(decoy_dir, drawers=5, indexed=2)

        # Catalog: one set pointing at estate_set1
        cat_dir = fleet_root / "swift" / "locomo"
        catalog = {
            "port": "swift",
            "dataset": "locomo",
            "written": "2026-01-01T00:00:00Z",
            "sets": [
                {
                    "name": "estate_set1",
                    "base": str(fleet_root),
                    "path": "swift/locomo/estate_set1",
                    "estates": 1,
                    "state": "encoded",
                },
            ],
        }
        (cat_dir / "catalog.json").write_text(
            json.dumps(catalog, indent=2), encoding="utf-8")

        return fleet_root

    def test_catalog_estates_reported_not_decoy(self):
        """Status must report READY (catalogued unit001), not INCOMPLETE (decoy)."""
        fleet_root = self._build_fixture()
        wing_root = self.root / "wing"
        wing_root.mkdir()
        seeding_dir = self.root / "seeding"
        seeding_dir.mkdir()

        out = run_status(str(fleet_root), str(wing_root), str(seeding_dir))

        # Find the output row for fleet-swift / locomo
        locomo_line = next(
            (ln for ln in out.splitlines() if "fleet-swift" in ln and "locomo" in ln),
            None)
        self.assertIsNotNone(locomo_line, f"no fleet-swift/locomo row in output:\n{out}")
        self.assertIn(
            "READY", locomo_line,
            f"Expected READY (catalogued estate has full coverage) but got:\n{locomo_line}\n"
            f"Full output:\n{out}")
        self.assertNotIn(
            "INCOMPLETE", locomo_line,
            f"DECOY_ESTATE (INCOMPLETE) must not drive the row; got:\n{locomo_line}")


# ── G2 ───────────────────────────────────────────────────────────────────────

class NoCatalogG2Tests(unittest.TestCase):
    """G2: a root with estate directories but no catalog.json reports NO CATALOG.

    Setup
    -----
    fleet_root/swift/locomo/estates/unit001/estate.sqlite  (5 drawers, 5 indexed)
    no catalog.json anywhere under fleet_root/swift/locomo/

    Old status (directory tree scan) finds unit001 and reports READY.
    New status (catalog) finds no catalog.json and reports NO CATALOG.
    The test asserts the output row contains NO CATALOG, not READY or BUILDING.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_catalog_reports_no_catalog_state(self):
        """Status must report NO CATALOG when catalog.json is absent."""
        fleet_root = self.root / "fleet"

        # Estate present on disk in old-style path, no catalog.json
        estate_dir = fleet_root / "swift" / "locomo" / "estates" / "unit001"
        make_estate_db(estate_dir, drawers=5, indexed=5)

        wing_root = self.root / "wing"
        wing_root.mkdir()
        seeding_dir = self.root / "seeding"
        seeding_dir.mkdir()

        out = run_status(str(fleet_root), str(wing_root), str(seeding_dir))

        locomo_line = next(
            (ln for ln in out.splitlines() if "fleet-swift" in ln and "locomo" in ln),
            None)
        self.assertIsNotNone(locomo_line, f"no fleet-swift/locomo row in output:\n{out}")
        self.assertIn(
            "NO CATALOG", locomo_line,
            f"Expected NO CATALOG state but got:\n{locomo_line}\n"
            f"Full output:\n{out}")
        self.assertNotIn(
            "READY", locomo_line,
            f"Status must not report READY when no catalog.json exists:\n{locomo_line}")


# ── G3 ───────────────────────────────────────────────────────────────────────

class SmokeBuilderEnvIsolationG3Tests(unittest.TestCase):
    """G3: smoke_builder uses its own scratch map and ignores the env variable.

    This is a regression guard for A1 (already satisfied at baseline).
    smoke_builder.py:92 calls TargetMap.load(scratch / 'target-map.json')
    and never calls TargetMap.from_env.  Setting MOOTX01_BENCH_TARGET_MAP
    to a nonexistent path must not affect the smoke result.
    """

    def test_env_var_ignored_smoke_resolves_from_scratch(self):
        """smoke_builder succeeds even when MOOTX01_BENCH_TARGET_MAP is garbage."""
        import smoke_builder
        # The test's own scratch, never the folder a real smoke run is using.
        smoke_builder.SCRATCH = pathlib.Path(tempfile.mkdtemp(prefix="smoke-g3-"))

        # Point the env var at a guaranteed nonexistent path
        saved = os.environ.get(layout.TARGET_MAP_ENV)
        os.environ[layout.TARGET_MAP_ENV] = "/this/path/does/not/exist/map.json"
        from_env_calls = []
        original_from_env = layout.TargetMap.from_env.__func__

        @classmethod  # type: ignore[misc]
        def sentinel(cls, *args, **kwargs):
            from_env_calls.append(args)
            return original_from_env(cls, *args, **kwargs)

        layout.TargetMap.from_env = sentinel
        try:
            rc = smoke_builder.run("swift", smoke_builder.FAKER)
        finally:
            layout.TargetMap.from_env = classmethod(original_from_env)
            if saved is None:
                os.environ.pop(layout.TARGET_MAP_ENV, None)
            else:
                os.environ[layout.TARGET_MAP_ENV] = saved

        self.assertEqual(
            rc, 0,
            "smoke_builder.run() must succeed regardless of MOOTX01_BENCH_TARGET_MAP")
        self.assertFalse(
            from_env_calls,
            "smoke_builder.run() must not call TargetMap.from_env; "
            f"called with: {from_env_calls}")


# ── G4 ───────────────────────────────────────────────────────────────────────

class PerPortBaseResolutionG4Tests(unittest.TestCase):
    """G4: without --fleet-root, status resolves each port against its own base.

    Setup
    -----
    swift_base and rust_base are two DIFFERENT directories.
    Target map: swift uses swift_base for all four datasets,
                rust  uses rust_base  for all four datasets.

    Catalogs planted:
      swift_base/swift/locomo/catalog.json  -- one READY estate (correct swift loc)
      swift_base/rust/locomo/catalog.json   -- one estate   (the old wrong rust loc;
                                               a single-root implementation would find
                                               this for the rust port and NOT report
                                               NO CATALOG)

    rust_base/rust/locomo/catalog.json is intentionally ABSENT.

    With per-port resolution (fixed):
      fleet-swift/locomo -> READY  (swift_base is the right base for swift)
      fleet-rust/locomo  -> NO CATALOG  (rust_base has no catalog; the decoy
                                          at swift_base/rust/ is never consulted)

    With single-root resolution (broken):
      fleet-root = swift_base (from primary_base_for_port("swift"))
      fleet-rust/locomo -> found at swift_base/rust/locomo/catalog.json -> NOT NO CATALOG
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()
        # Remove the env var if we set it; restore original value in test body.

    def _build_target_map(self, swift_base: pathlib.Path,
                          rust_base: pathlib.Path) -> pathlib.Path:
        """Write a target map with different primary bases for each port."""
        datasets = ["lme-s", "locomo", "convomem", "membench"]
        target_map = {
            "swift": {ds: [{"path": str(swift_base)}] for ds in datasets},
            "rust":  {ds: [{"path": str(rust_base)}]  for ds in datasets},
        }
        path = self.root / "target-map.json"
        path.write_text(json.dumps(target_map, indent=2), encoding="utf-8")
        return path

    def test_per_port_base_resolution_without_fleet_root(self):
        """Status resolves each port against its own base; the cross-port catalog is ignored."""
        import subprocess

        swift_base = self.root / "swift_base"
        rust_base = self.root / "rust_base"
        swift_base.mkdir()
        rust_base.mkdir()

        target_map_path = self._build_target_map(swift_base, rust_base)

        # Correct swift catalog: swift_base/swift/locomo/catalog.json -> READY
        swift_unit_dir = swift_base / "swift" / "locomo" / "estate_set1" / "unit001"
        make_estate_db(swift_unit_dir, drawers=3, indexed=3)
        swift_cat_dir = swift_base / "swift" / "locomo"
        swift_catalog = {
            "port": "swift", "dataset": "locomo",
            "written": "2026-01-01T00:00:00Z",
            "sets": [{
                "name": "estate_set1",
                "base": str(swift_base),
                "path": "swift/locomo/estate_set1",
                "estates": 1, "state": "encoded",
            }],
        }
        (swift_cat_dir / "catalog.json").write_text(
            json.dumps(swift_catalog, indent=2), encoding="utf-8")

        # Decoy rust catalog at the OLD single-root location:
        # swift_base/rust/locomo/catalog.json.
        # A broken implementation that resolves rust against swift_base would find
        # this and NOT report NO CATALOG for the rust port.
        rust_decoy_dir = swift_base / "rust" / "locomo" / "estate_set1" / "unit001"
        make_estate_db(rust_decoy_dir, drawers=3, indexed=3)
        rust_decoy_cat_dir = swift_base / "rust" / "locomo"
        rust_decoy_catalog = {
            "port": "rust", "dataset": "locomo",
            "written": "2026-01-01T00:00:00Z",
            "sets": [{
                "name": "estate_set1",
                "base": str(swift_base),
                "path": "rust/locomo/estate_set1",
                "estates": 1, "state": "encoded",
            }],
        }
        (rust_decoy_cat_dir / "catalog.json").write_text(
            json.dumps(rust_decoy_catalog, indent=2), encoding="utf-8")

        # rust_base/rust/locomo/catalog.json is intentionally absent.
        # The new code must look here (rust_base) and find nothing -> NO CATALOG.

        wing_root = self.root / "wing"
        wing_root.mkdir()
        seeding_dir = self.root / "seeding"
        seeding_dir.mkdir()

        saved_env = os.environ.get(layout.TARGET_MAP_ENV)
        os.environ[layout.TARGET_MAP_ENV] = str(target_map_path)
        try:
            # Run WITHOUT --fleet-root: per-port resolution must kick in.
            result = subprocess.run(
                [sys.executable, str(STATUS),
                 "--wing-root", str(wing_root),
                 "--seeding-dir", str(seeding_dir)],
                capture_output=True, text=True)
            out = result.stdout + result.stderr
        finally:
            if saved_env is None:
                os.environ.pop(layout.TARGET_MAP_ENV, None)
            else:
                os.environ[layout.TARGET_MAP_ENV] = saved_env

        swift_line = next(
            (ln for ln in out.splitlines() if "fleet-swift" in ln and "locomo" in ln),
            None)
        rust_line = next(
            (ln for ln in out.splitlines() if "fleet-rust" in ln and "locomo" in ln),
            None)

        self.assertIsNotNone(swift_line, f"no fleet-swift/locomo row in output:\n{out}")
        self.assertIsNotNone(rust_line,  f"no fleet-rust/locomo row in output:\n{out}")

        # Swift must resolve against swift_base (has catalog -> NOT NO CATALOG).
        self.assertNotIn(
            "NO CATALOG", swift_line,
            f"fleet-swift must find its catalog at {swift_base}/swift/locomo/; "
            f"got:\n{swift_line}\nFull output:\n{out}")

        # Rust must resolve against rust_base (no catalog there -> NO CATALOG).
        # The decoy at {swift_base}/rust/locomo/ must not be consulted.
        self.assertIn(
            "NO CATALOG", rust_line,
            f"fleet-rust must report NO CATALOG: its base is {rust_base}, "
            f"which has no catalog.json (the decoy at {swift_base}/rust/ "
            f"is the old single-root location and must be ignored); "
            f"got:\n{rust_line}\nFull output:\n{out}")


if __name__ == "__main__":
    unittest.main()
