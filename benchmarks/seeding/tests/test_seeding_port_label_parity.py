"""Seeding port-label parity: building the smoke set under either port
label produces the same unit estate names and byte-identical question rows.

SCOPE, and what this does NOT prove
-----------------------------------
Both runs execute the SAME builder, mootx01_faker.py, passed as
smoke_builder.FAKER.  smoke/swift.json and smoke/rust.json are identical
apart from the "port" string.  So this compares the seeding assembly line
against itself under two labels.  It does NOT compare the Swift harness
binary to the Rust harness binary, and it does NOT exercise Swift
artifactUnitEstateDir against Rust resolve_unit_from_catalog.

What it is worth: it pins the seeding layer as port-label-agnostic.  Nothing
in the builder may branch on the label.  That makes any later divergence
attributable to the harness binaries rather than to seeding, which is the
precondition a real resolver-parity gate would be built on.

Design
------
smoke_builder.run(port, FAKER) builds the full assembly line for a port
using the faker (no real mootx01 required).  smoke/swift.json and
smoke/rust.json are identical apart from the "port" string: 2 sets × 3
units, 4 records per unit.  Catalog row order, set sizes, and unit names
are therefore determined by the config, and the assertions below fail only
if something in the builder branches on the label.

Two assertions:

1. Path parity: the catalog-resolved estate directory basenames (unit000
   through unit005 plus the aggregate) are identical across labels.  The
   absolute paths differ (one carries "swift", the other "rust") but the
   estate NAME is the identity token the harness uses.

2. Question parity: the questions.jsonl lines are byte-identical.  Each
   line is a JSON object whose fields derive only from the estate basename
   (sample_id = basename, question = "test <basename>"); since both labels
   produce the same basenames in the same order, the serialised bytes match.

No skip path: the test builds its own fixture via the faker.  It has no
dependency on a pre-built mootx01 binary, a populated fleet, or any
external environment variable (MOOTX01_BENCH_TARGET_MAP is pointed at a
nonexistent path in setUp so an accidental TargetMap.from_env call fails
loudly rather than resolving an operator's real map).
"""
from __future__ import annotations

import os
import pathlib
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import artifact_layout as layout          # noqa: E402
import smoke_builder                       # noqa: E402


class SeedingPortLabelParityTests(unittest.TestCase):
    """Either port label produces the same unit estate names and byte-identical question rows."""

    def setUp(self):
        # Redirect MOOTX01_BENCH_TARGET_MAP to a nonexistent path.  Any
        # accidental call to TargetMap.from_env will fail loudly rather than
        # silently hitting the operator's real map.
        self._saved_env = os.environ.get(layout.TARGET_MAP_ENV)
        os.environ[layout.TARGET_MAP_ENV] = \
            "/this/path/does/not/exist/port-label-parity-test.json"

    def tearDown(self):
        if self._saved_env is None:
            os.environ.pop(layout.TARGET_MAP_ENV, None)
        else:
            os.environ[layout.TARGET_MAP_ENV] = self._saved_env

    def _build_port(self, port: str) -> tuple[pathlib.Path, pathlib.Path]:
        """Run smoke_builder for port with the faker, return (catalog_path, questions_path)."""
        rc = smoke_builder.run(port, smoke_builder.FAKER, log=lambda _: None)
        self.assertEqual(rc, 0, f"smoke_builder.run({port!r}) exited {rc}")
        primary_base = smoke_builder.SCRATCH / port / "base-primary"
        cat_path = (primary_base / port / smoke_builder.DATASET / "catalog.json")
        q_path = smoke_builder.SCRATCH / port / "questions.jsonl"
        self.assertTrue(cat_path.exists(), f"catalog not found at {cat_path}")
        self.assertTrue(q_path.exists(), f"questions.jsonl not found at {q_path}")
        return cat_path, q_path

    def test_unit_estate_names_are_identical_across_port_labels(self):
        """Either label's catalog resolves to the same set of estate directory names."""
        swift_cat, _ = self._build_port("swift")
        rust_cat, _ = self._build_port("rust")

        swift_dirs = layout.fleet_estates_from_catalog(str(swift_cat))
        rust_dirs = layout.fleet_estates_from_catalog(str(rust_cat))

        swift_names = sorted(pathlib.Path(p).name for p in swift_dirs)
        rust_names = sorted(pathlib.Path(p).name for p in rust_dirs)

        self.assertEqual(
            swift_names, rust_names,
            f"estate names differ between port labels:\n"
            f"  swift: {swift_names}\n"
            f"  rust:  {rust_names}",
        )

    def test_questions_jsonl_rows_are_byte_identical_across_port_labels(self):
        """Either label produces byte-identical questions.jsonl content.

        Each line is a JSON object whose fields derive only from the estate
        basename (sample_id = basename, question = "test <basename>").  Since
        the same builder runs under both labels,
        the serialised bytes are identical.

        The assertion compares full file content, not just line counts, so a
        port that produces the right lines in the wrong order is also caught.
        """
        _, swift_q = self._build_port("swift")
        _, rust_q = self._build_port("rust")

        swift_lines = swift_q.read_text(encoding="utf-8").splitlines()
        rust_lines = rust_q.read_text(encoding="utf-8").splitlines()

        self.assertEqual(
            len(swift_lines), len(rust_lines),
            f"question count differs: swift={len(swift_lines)}, rust={len(rust_lines)}",
        )
        for i, (sw, rs) in enumerate(zip(swift_lines, rust_lines)):
            self.assertEqual(
                sw, rs,
                f"questions.jsonl line {i + 1} differs:\n"
                f"  swift: {sw!r}\n"
                f"  rust:  {rs!r}",
            )


if __name__ == "__main__":
    unittest.main()
