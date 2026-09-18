"""test_work_root_keep.py — unit tests for work-root.py --keep behaviour.

Tests the fix for c5b92b41: make clean must not erase the default archive
directory (a direct child of BENCH_WORK_ROOT).  The --keep flag passed as
``--keep archive`` from the Makefile preserves that child.

Pre-fix: ``clean()`` removed every child of the work root except the marker;
the archive directory was always erased.  These tests would have failed because
``archive/`` was absent after ``clean(work)``.
"""
from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile
import unittest

# Load work-root.py (hyphenated name; not directly importable as a module).
_SCRIPTS_DIR = pathlib.Path(__file__).parent
_spec = importlib.util.spec_from_file_location(
    "work_root", str(_SCRIPTS_DIR / "work-root.py"))
_mod = importlib.util.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(_mod)  # type: ignore[union-attr]

clean = _mod.clean
MARKER = _mod.MARKER
MARKER_TEXT = _mod.MARKER_TEXT


def _make_work_root(base: pathlib.Path) -> pathlib.Path:
    """Create a minimal work root with the required marker file."""
    work = base / "bench-work"
    work.mkdir()
    (work / MARKER).write_text(MARKER_TEXT)
    return work


class TestCleanKeep(unittest.TestCase):
    """clean() with --keep preserves named direct children."""

    def test_keep_archive_survives(self) -> None:
        """--keep archive: the archive subdirectory is not removed.

        Pre-fix (c5b92b41): clean(work) with no keep argument deleted archive.
        Post-fix: passing keep={"archive"} retains it.
        """
        with tempfile.TemporaryDirectory() as tmp:
            work = _make_work_root(pathlib.Path(tmp))
            archive = work / "archive"
            archive.mkdir()
            (archive / "data.txt").write_text("important")

            clean(work, keep={"archive"})

            self.assertTrue(archive.exists(), "archive dir must survive --keep archive")
            self.assertTrue((archive / "data.txt").exists(), "archive contents must survive")

    def test_other_dirs_still_removed(self) -> None:
        """Dirs not in the keep set are still removed."""
        with tempfile.TemporaryDirectory() as tmp:
            work = _make_work_root(pathlib.Path(tmp))
            (work / "archive").mkdir()
            (work / "scratch").mkdir()
            ((work / "scratch") / "tmp.txt").write_text("ephemeral")

            clean(work, keep={"archive"})

            self.assertFalse((work / "scratch").exists(), "scratch must be removed")
            self.assertTrue((work / "archive").exists(), "archive must survive")

    def test_marker_always_preserved(self) -> None:
        """The marker file is never removed regardless of keep set."""
        with tempfile.TemporaryDirectory() as tmp:
            work = _make_work_root(pathlib.Path(tmp))
            clean(work, keep=set())
            self.assertTrue((work / MARKER).exists(), "marker must always survive")

    def test_no_keep_removes_archive(self) -> None:
        """Without --keep the archive directory is removed (regression guard)."""
        with tempfile.TemporaryDirectory() as tmp:
            work = _make_work_root(pathlib.Path(tmp))
            (work / "archive").mkdir()

            clean(work, keep=None)

            self.assertFalse((work / "archive").exists(),
                             "archive is removed when keep is not supplied")

    def test_keep_multiple_names(self) -> None:
        """Multiple names in keep set are each preserved."""
        with tempfile.TemporaryDirectory() as tmp:
            work = _make_work_root(pathlib.Path(tmp))
            for name in ("archive", "cache", "logs"):
                (work / name).mkdir()
            (work / "tmp").mkdir()

            clean(work, keep={"archive", "cache", "logs"})

            for name in ("archive", "cache", "logs"):
                self.assertTrue((work / name).exists(), f"{name} must survive")
            self.assertFalse((work / "tmp").exists(), "tmp must be removed")


if __name__ == "__main__":
    unittest.main()
