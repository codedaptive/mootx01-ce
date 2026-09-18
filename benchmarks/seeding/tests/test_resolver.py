"""G1: resolver parity — fleet_estates_from_catalog returns exactly the estates
built by smoke_builder for a two-set smoke catalog.

Setup
-----
smoke_builder.run("swift", smoke_builder.FAKER) builds a two-set smoke
catalog into seeding/scratch/swift/ using its own internal scratch target
map.  It never reads MOOTX01_BENCH_TARGET_MAP (G3 already guards that).

After the build, fleet_estates_from_catalog is called on the catalog.json
that write_catalog placed in the primary base folder.  The reference side is
the named unit IDs from smoke/swift.json (unit000-unit005) plus the aggregate
estate ("smoke"), not a re-walk of the directories with the same algorithm.

The test asserts specific estate directory names so that a resolver returning
the right NUMBER of wrong paths fails on a named value, not a count.

No file is written outside seeding/scratch/ or Python's temp directories.
MOOTX01_BENCH_TARGET_MAP is set to a nonexistent path in setUp so that any
accidental call to TargetMap.from_env would fail noisily.
"""
import os
import pathlib
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import artifact_layout as layout  # noqa: E402
from artifact_layout import estate_db, fleet_estates_from_catalog  # noqa: E402


# ── G1 ───────────────────────────────────────────────────────────────────────

class ResolverParityG1Tests(unittest.TestCase):
    """G1: fleet_estates_from_catalog lists exactly the estates smoke_builder built.

    smoke/swift.json specifies 2 sets × 3 units = 6 unit estates plus one
    aggregate estate.  Unit names are unit000-unit005 (the builder assigns
    unit{n:03d} for n in range(sets * units_per_set)).  The aggregate estate
    is named after the dataset ("smoke").

    The reference in test_resolver_returns_named_estates is the KNOWN unit ids
    from the config, not a re-walk of the set directories with the same
    algorithm fleet_estates_from_catalog uses.  A resolver that walks the right
    directories but returns wrong names (or right names in wrong directories)
    fails on a named value.
    """

    PORT = "swift"
    # Names come directly from smoke/swift.json: 2 sets × 3 units, named unit{n:03d}.
    # estate_set1 lands in base-primary, estate_set2 + aggregate in base-secondary.
    EXPECTED_UNIT_IDS = [
        "unit000", "unit001", "unit002",  # estate_set1 (primary base)
        "unit003", "unit004", "unit005",  # estate_set2 (secondary base, failover)
    ]
    # The aggregate estate is named after the dataset (smoke_builder.DATASET = "smoke").
    AGGREGATE_ID = "smoke"

    def setUp(self):
        # Point MOOTX01_BENCH_TARGET_MAP at a nonexistent path so that any
        # accidental call to TargetMap.from_env fails loudly rather than
        # silently resolving to the operator's real map.
        self._saved_env = os.environ.get(layout.TARGET_MAP_ENV)
        os.environ[layout.TARGET_MAP_ENV] = \
            "/this/path/does/not/exist/g1-resolver-test.json"

    def tearDown(self):
        if self._saved_env is None:
            os.environ.pop(layout.TARGET_MAP_ENV, None)
        else:
            os.environ[layout.TARGET_MAP_ENV] = self._saved_env

    def _run_smoke_and_get_catalog(self):
        """Run smoke_builder for swift and return (primary_base, catalog_path)."""
        import smoke_builder

        rc = smoke_builder.run(self.PORT, smoke_builder.FAKER, log=lambda _: None)
        self.assertEqual(rc, 0, f"smoke_builder.run exited {rc}")

        # smoke_builder writes to SCRATCH/swift/base-primary/.
        primary_base = smoke_builder.SCRATCH / self.PORT / "base-primary"
        cat_path = primary_base / self.PORT / smoke_builder.DATASET / "catalog.json"
        self.assertTrue(
            cat_path.exists(),
            f"catalog.json not found after smoke build at {cat_path}")
        return primary_base, cat_path

    def test_resolver_returns_named_estates(self):
        """fleet_estates_from_catalog returns exactly the named estates the builder created."""
        _, cat_path = self._run_smoke_and_get_catalog()

        resolved = fleet_estates_from_catalog(str(cat_path))

        # Reference: unit IDs we know the builder assigns, not re-derived by walking.
        expected_names = sorted(self.EXPECTED_UNIT_IDS + [self.AGGREGATE_ID])

        # Primary assertion: resolver returns paths whose basenames match the
        # known unit ids.  Named so a wrong-path result fails on the id, not a count.
        resolved_names = sorted(pathlib.Path(p).name for p in resolved)
        self.assertEqual(
            resolved_names, expected_names,
            f"resolver returned estate names {resolved_names!r}; "
            f"expected {expected_names!r} (unit000-unit005 from smoke/swift.json "
            f"plus aggregate '{self.AGGREGATE_ID}')")

        # Every resolved path must carry a recognisable estate database.
        for p in resolved:
            self.assertIsNotNone(
                estate_db(p),
                f"resolved path {p!r} does not carry an estate.sqlite")

        # No duplicate paths (a resolver bug returning the same estate twice from
        # two catalog rows would still pass the name check above).
        self.assertEqual(
            len(resolved), len(set(resolved)),
            f"resolver returned duplicate paths: {resolved!r}")

    def test_resolver_does_not_call_from_env(self):
        """fleet_estates_from_catalog never calls TargetMap.from_env."""
        _, cat_path = self._run_smoke_and_get_catalog()

        from_env_calls: list = []
        original_from_env = layout.TargetMap.from_env.__func__

        @classmethod  # type: ignore[misc]
        def sentinel(cls, *args, **kwargs):
            from_env_calls.append(args)
            return original_from_env(cls, *args, **kwargs)

        layout.TargetMap.from_env = sentinel
        try:
            fleet_estates_from_catalog(str(cat_path))
        finally:
            layout.TargetMap.from_env = classmethod(original_from_env)

        self.assertFalse(
            from_env_calls,
            "fleet_estates_from_catalog must not call TargetMap.from_env; "
            f"was called with: {from_env_calls}")


if __name__ == "__main__":
    unittest.main()
