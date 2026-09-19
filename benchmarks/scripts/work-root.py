#!/usr/bin/env python3
"""Validate and manage the benchmark's external work root.

The repository is immutable input. Builds, downloads, estates, caches, logs,
smoke receipts, and raw results belong under one marked directory outside it.

Adoption rule for `prepare`: a missing directory is created and marked; an
existing directory is accepted only when it is empty or already carries the
marker file. An existing nonempty directory without the marker is refused.
`prepare` runs while make parses the Makefile — for `make clean` too — so a
marker it wrote itself would be the only thing between
`make clean BENCH_WORK_ROOT=<some real directory>` and that directory's
contents. `clean` empties only a directory that carries the marker.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import sys


MARKER = ".mootx01-benchmark-work-root"
MARKER_TEXT = "mootx01-benchmark-work-root-v1\n"


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def validate(repo_arg: str, work_arg: str, create: bool) -> pathlib.Path:
    repo = pathlib.Path(repo_arg).expanduser().resolve()
    work_requested = pathlib.Path(work_arg).expanduser()
    if not work_requested.is_absolute():
        fail(f"BENCH_WORK_ROOT must be absolute: {work_requested}")
    if create:
        adoptable = work_requested.resolve()
        if adoptable.exists():
            if not adoptable.is_dir():
                fail(f"BENCH_WORK_ROOT exists and is not a directory: {adoptable}")
            # Adoption rule (module docstring): an existing directory is
            # adopted only when it is empty or already marked. Anything
            # else is somebody's data, and `clean` would empty it.
            if not (adoptable / MARKER).is_file() and any(adoptable.iterdir()):
                fail(
                    f"refusing to adopt nonempty unmarked directory {adoptable}; "
                    "choose an empty directory or create the marker yourself: "
                    f"printf '{MARKER_TEXT.strip()}\\n' > {adoptable / MARKER}"
                )
        work_requested.mkdir(parents=True, exist_ok=True)
    work = work_requested.resolve()

    if work == pathlib.Path(work.anchor):
        fail("BENCH_WORK_ROOT may not be a filesystem root")
    if work == repo or repo in work.parents:
        fail(f"BENCH_WORK_ROOT is inside the repository: {work}")
    if work in repo.parents:
        fail(f"BENCH_WORK_ROOT contains the repository and is unsafe to clean: {work}")

    marker = work / MARKER
    if create:
        if marker.exists() and marker.read_text() != MARKER_TEXT:
            fail(f"work-root marker has unexpected content: {marker}")
        # Atomic write (temp + rename): every make invocation — including
        # the smoke gates' inner sub-makes — runs prepare, so concurrent
        # writers are routine. A plain write_text truncates first, and a
        # reader in that window sees a partial marker and Stops the build
        # (observed 2026-08-29 during parallel wing builds).
        tmp = marker.with_suffix(".tmp-%d" % os.getpid())
        tmp.write_text(MARKER_TEXT)
        tmp.replace(marker)
    elif not marker.is_file() or marker.read_text() != MARKER_TEXT:
        fail(f"refusing unmarked work root: {work}")
    return work


def clean(work: pathlib.Path, keep: set[str] | None = None) -> None:
    """Remove every direct child of *work* except the marker and kept names.

    SAFETY: ``keep`` names direct children of ``work`` that must not be
    removed.  The default ``archive`` child is passed via ``--keep archive``
    from the Makefile so that ``make archive`` followed by ``make clean`` does
    not erase the default archive location.  The invariant from the Makefile
    comment at line 948 — "archive cannot delete anything" — is preserved in
    both directions: ``archive`` never deletes, and ``clean`` never deletes
    ``archive`` when passed here.
    """
    skip = {MARKER}
    if keep:
        skip.update(keep)
    for child in work.iterdir():
        if child.name in skip:
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "clean"))
    parser.add_argument("--repo", required=True)
    parser.add_argument("--work", required=True)
    # --keep NAME (repeatable): skip this direct child during clean.
    # Passed as --keep archive by the Makefile so the durable archive
    # directory is never erased by make clean.
    parser.add_argument("--keep", action="append", default=[],
                        metavar="NAME",
                        help="direct child of work root to leave untouched during clean")
    args = parser.parse_args()

    work = validate(args.repo, args.work, create=args.action == "prepare")
    if args.action == "clean":
        clean(work, keep=set(args.keep) if args.keep else None)
    print(work)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
