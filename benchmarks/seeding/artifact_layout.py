#!/usr/bin/env python3
"""Artifact layout: target map, set planning, base-folder failover, address files.

ARTIFACT_BUILDER_SPEC.md §2 (R1 to R5) and §3 (C1, C3). Pure filesystem work,
no product calls. Standard library only.

Target map (JSON), per port per dataset an ordered list of base folders:

    {"swift": {"locomo": [{"path": "/Volumes/a/bench"},
                          {"path": "/Volumes/b/bench"}]}}

Each entry may carry "capacity_bytes". When present it caps what the builder
will place in that base folder (used by the smoke test, where both bases sit
on one disk). When absent the cap is the volume's free space as reported by
the OS. A set is placed in the first base folder with room for the whole set
estimate above the floor; a set is never split across base folders (R1a).
"""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import sys
import time
from dataclasses import dataclass, field

SET_SIZE = 100            # R3: at most 100 estates per set
# The target map is machine-local (absolute paths) and never checked in. Its
# location comes from this variable, set in the operator's shell dotfiles.
TARGET_MAP_ENV = "MOOTX01_BENCH_TARGET_MAP"
AGGREGATE_SET = "aggregate"
CAPACITY_FILE = ".capacity_bytes"   # written into a base folder given a capacity
STATES = ("laid_out", "provisioned", "imported", "encoded", "failed")

# Span-coverage predicate: counts DISTINCT drawers covered by the active
# encoder's current serving generation with kind=2 (span vectors).
#
# kind=2 selects span vectors specifically; kind=1 (BM25 term vectors) or any
# other kind must not be counted — they are not span coverage.
# The generation clause matches the currently-serving generation from
# vector_generations (COALESCE to 0 when no row exists yet). Vectors from a
# superseded generation were produced by an older encoder pass and do not
# satisfy the span-coverage contract — the active serve drains the estate to
# the current generation before an estate is READY.
#
# Defined here once so every consumer (import_units, smoke_verify) shares the
# same predicate and the two check-points cannot drift.
SPAN_COVERED_SQL = (
    "SELECT COUNT(DISTINCT v.item_id) FROM vectors v "
    "JOIN encoder_models e ON e.model_id = v.model_id "
    "AND e.is_active != 0 "
    "JOIN drawers d ON d.id = v.item_id "
    "WHERE d.tombstonedAt IS NULL AND d.content != '' "
    "AND v.kind = 2 "
    "AND v.generation = COALESCE("
    "  (SELECT serving_generation FROM vector_generations "
    "   WHERE model_id = e.model_id), 0)"
)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


@dataclass
class BaseFolder:
    path: pathlib.Path
    capacity_bytes: int | None = None   # None = ask the OS for free space
    placed_bytes: int = 0                # what this build has placed here

    def free_bytes(self) -> int:
        if self.capacity_bytes is not None:
            self.path.mkdir(parents=True, exist_ok=True)
            # Persist the cap so the watchers measure against the same number.
            (self.path / CAPACITY_FILE).write_text(f"{self.capacity_bytes}\n")
            return max(0, self.capacity_bytes - self.placed_bytes)
        self.path.mkdir(parents=True, exist_ok=True)
        return shutil.disk_usage(self.path).free


def used_bytes(base: pathlib.Path) -> int:
    return sum(p.stat().st_size for p in base.rglob("*") if p.is_file())


def free_bytes(base: pathlib.Path) -> int:
    """Free space on a base folder: capacity minus bytes on disk when the base
    carries a .capacity_bytes marker, else the volume's free space."""
    marker = base / CAPACITY_FILE
    if marker.exists():
        return int(marker.read_text().strip()) - used_bytes(base)
    return shutil.disk_usage(base).free


@dataclass
class TargetMap:
    bases: list[BaseFolder]
    floor_bytes: int

    @classmethod
    def from_env(cls, port: str, dataset: str, floor_bytes: int) -> "TargetMap":
        """Resolve the target map from MOOTX01_BENCH_TARGET_MAP. Loud on any gap."""
        raw = os.environ.get(TARGET_MAP_ENV)
        if not raw:
            fail(f"{TARGET_MAP_ENV} is not set; export it in your shell dotfiles, "
                 "pointing at the machine-local target map JSON")
        path = pathlib.Path(raw).expanduser()
        if not path.is_file():
            fail(f"{TARGET_MAP_ENV}={raw} does not name a readable file")
        return cls.load(path, port, dataset, floor_bytes)

    @classmethod
    def load(cls, path: pathlib.Path, port: str, dataset: str,
             floor_bytes: int) -> "TargetMap":
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        entries = data.get(port, {}).get(dataset)
        if entries is None:
            fail(f"target map {path} has no entry for {port}/{dataset}")
        bases = [BaseFolder(pathlib.Path(e["path"]).expanduser(),
                            e.get("capacity_bytes")) for e in entries]
        if not bases:
            fail(f"target map {path} entry for {port}/{dataset} is empty")
        return cls(bases, floor_bytes)

    def choose(self, needed_bytes: int) -> BaseFolder:
        """First base folder that can take the whole set above the floor."""
        for base in self.bases:
            if base.free_bytes() - needed_bytes >= self.floor_bytes:
                base.placed_bytes += needed_bytes
                return base
        raise RuntimeError(
            f"target map exhausted: no base folder has {needed_bytes} bytes "
            f"above the {self.floor_bytes} byte floor")


def plan_sets(unit_ids: list[str], set_size: int = SET_SIZE) -> list[list[str]]:
    """Split unit ids into sets of at most set_size, in order (R3)."""
    if set_size < 1:
        raise ValueError("set_size must be >= 1")
    return [unit_ids[i:i + set_size] for i in range(0, len(unit_ids), set_size)]


def set_dir(base: pathlib.Path, port: str, dataset: str, n: int) -> pathlib.Path:
    return base / port / dataset / f"estate_set{n}"


def aggregate_dir(base: pathlib.Path, port: str, dataset: str) -> pathlib.Path:
    return base / port / dataset / AGGREGATE_SET / dataset


def write_address(estate: pathlib.Path, *, unit: str, dataset: str, port: str,
                  set_name: str, state: str = "laid_out",
                  record_count: int | None = None,
                  size_bytes: int | None = None,
                  error: str | None = None) -> pathlib.Path:
    """Create or advance an estate's address file (C3). State only moves forward (C4)."""
    if state not in STATES:
        raise ValueError(f"unknown state {state}")
    path = estate / "address.json"
    if path.exists():
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
        if STATES.index(state) < STATES.index(doc["state"]) and doc["state"] != "failed":
            raise ValueError(f"{unit}: state cannot move back from {doc['state']} to {state}")
    else:
        doc = {"unit": unit, "dataset": dataset, "port": port, "set": set_name,
               "record_count": None, "size_bytes": None, "state": None,
               "timestamps": {}}
    doc["state"] = state
    doc["timestamps"][state] = now_iso()
    if record_count is not None:
        doc["record_count"] = record_count
    if size_bytes is not None:
        doc["size_bytes"] = size_bytes
    if error is not None:
        doc["error"] = error            # C4: failure text lives here, no sidecar
    estate.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)
    return path


def read_address(estate: pathlib.Path) -> dict:
    with open(estate / "address.json", encoding="utf-8") as handle:
        return json.load(handle)


@dataclass
class LaidOutSet:
    name: str                 # "estate_set3" or "aggregate"
    base: pathlib.Path
    path: pathlib.Path        # the set directory
    estates: dict[str, pathlib.Path] = field(default_factory=dict)  # unit -> dir


def lay_out_dataset(target: TargetMap, port: str, dataset: str,
                    unit_ids: list[str], *, bytes_per_estate: int,
                    aggregate_bytes: int,
                    set_size: int = SET_SIZE) -> list[LaidOutSet]:
    """§4 step 2. Create the empty tree and every address file at laid_out.

    bytes_per_estate and aggregate_bytes are the placement estimates used to
    choose a base folder per set (R1a). The watcher refines sizes after encode.
    """
    laid: list[LaidOutSet] = []
    for n, units in enumerate(plan_sets(unit_ids, set_size), start=1):
        base = target.choose(bytes_per_estate * len(units))
        sdir = set_dir(base.path, port, dataset, n)
        sdir.mkdir(parents=True, exist_ok=True)
        current = LaidOutSet(sdir.name, base.path, sdir)
        for unit in units:
            estate = sdir / unit
            estate.mkdir(parents=True, exist_ok=True)
            write_address(estate, unit=unit, dataset=dataset, port=port,
                          set_name=sdir.name)
            current.estates[unit] = estate
        laid.append(current)
    base = target.choose(aggregate_bytes)
    adir = aggregate_dir(base.path, port, dataset)
    adir.mkdir(parents=True, exist_ok=True)
    write_address(adir, unit=dataset, dataset=dataset, port=port,
                  set_name=AGGREGATE_SET)
    laid.append(LaidOutSet(AGGREGATE_SET, base.path, adir.parent, {dataset: adir}))
    return laid


# The watcher's terminal-failure marker, written into the set directory when
# a drain gives up. It is the only record of a set-level failure: the watcher
# flips the catalog row but never touches the estates' address files, so a
# catalog rewrite that read addresses alone would erase the failure.
FAILED_MAP = "partition_map.failed.json"


def set_state(s: "LaidOutSet") -> str:
    """A set's catalog state: failed when the watcher left its failure marker
    in the set directory, otherwise from the estates' address files — encoded
    when every estate reads encoded, failed when any does, else laid_out. A
    fresh lay-out has every address at laid_out; a relocated dataset keeps
    the state it earned where it was built, a recorded failure included."""
    if (s.path / FAILED_MAP).exists():
        return "failed"
    states = []
    for estate in s.estates.values():
        try:
            states.append(read_address(estate)["state"])
        except (OSError, KeyError, ValueError):
            states.append("laid_out")
    if states and all(st == "encoded" for st in states):
        return "encoded"
    if any(st == "failed" for st in states):
        return "failed"
    return "laid_out"


def write_catalog(primary_base: pathlib.Path, port: str, dataset: str,
                  sets: list[LaidOutSet]) -> pathlib.Path:
    """C1: the dataset catalog in the primary base folder, one row per set."""
    doc = {
        "port": port,
        "dataset": dataset,
        "written": now_iso(),
        "sets": [
            {"name": s.name, "base": str(s.base),
             "path": str(s.path.relative_to(s.base)),
             "estates": len(s.estates), "state": set_state(s)}
            for s in sets
        ],
    }
    path = primary_base / port / dataset / "catalog.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)
    return path


# ── Catalog-based estate resolution (C1) ────────────────────────────────────
# These functions live beside write_catalog so that reader and writer stay in
# sync. artifact_status.py imports them; do not duplicate here.

def estate_db(est_dir: str) -> str | None:
    """Return the path to the estate SQLite file inside est_dir, or None.

    Checks the two known locations: bare estate.sqlite at the root and the
    nested databases/default/ path introduced in schema 19.
    """
    for rel in ("estate.sqlite", "databases/default/estate.sqlite"):
        p = os.path.join(est_dir, rel)
        if os.path.exists(p):
            return p
    return None


def fleet_estates_from_catalog(cat_path: str) -> list[str]:
    """Return a sorted list of estate directory paths enumerated from the catalog.

    Reads catalog.json at cat_path, resolves each set's directory from its
    base+path fields, and lists one level of subdirectories within each set
    directory.  Returns only entries that carry a recognisable estate database.

    This is the sole catalog resolver.  artifact_status.py imports it; the
    function lives here beside write_catalog so that reader and writer cannot
    drift apart.
    """
    with open(cat_path, encoding="utf-8") as fh:
        cat = json.load(fh)
    estate_dirs: list[str] = []
    for s in cat.get("sets", []):
        # Each set row carries the absolute base folder and the path of the
        # set directory relative to that base (e.g. "swift/locomo/estate_set1").
        set_dir = pathlib.Path(s["base"]) / s["path"]
        if not set_dir.is_dir():
            continue
        # Estate subdirectories are one level below the set directory.
        # List them in stable order so sampling is reproducible.
        for entry in sorted(set_dir.iterdir()):
            if entry.is_dir() and estate_db(str(entry)):
                estate_dirs.append(str(entry))
    return estate_dirs


def primary_base_for_port(port: str) -> pathlib.Path:
    """Return the primary base folder for port, resolved from MOOTX01_BENCH_TARGET_MAP.

    Reads MOOTX01_BENCH_TARGET_MAP the same way TargetMap.from_env does and
    refuses through fail() with the same wording when the variable is unset or
    the file is unreadable.  The primary base is bases[0] for the port.

    All datasets in the port must agree on the same bases[0]; if any dataset
    names a different primary base, this function refuses loudly and names the
    disagreeing datasets — it does not pick one silently.
    """
    raw = os.environ.get(TARGET_MAP_ENV)
    if not raw:
        fail(f"{TARGET_MAP_ENV} is not set; export it in your shell dotfiles, "
             "pointing at the machine-local target map JSON")
    path = pathlib.Path(raw).expanduser()
    if not path.is_file():
        fail(f"{TARGET_MAP_ENV}={raw} does not name a readable file")
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    port_data = data.get(port)
    if not port_data:
        fail(f"target map {path} has no entry for port {port!r}")
    # Collect the primary base from each dataset and verify they all agree.
    primary_by_dataset: dict[str, pathlib.Path] = {}
    for dataset, entries in port_data.items():
        if not entries:
            fail(f"target map {path} entry for {port}/{dataset} is empty")
        primary_by_dataset[dataset] = pathlib.Path(entries[0]["path"]).expanduser()
    bases = set(str(b) for b in primary_by_dataset.values())
    if len(bases) > 1:
        disagreeing = ", ".join(
            f"{ds}={b}" for ds, b in sorted(primary_by_dataset.items()))
        fail(f"target map {path}: port {port!r} datasets do not share a common "
             f"primary base — {disagreeing}")
    return next(iter(primary_by_dataset.values()))


# ── CLI entry point ──────────────────────────────────────────────────────────
# Exposes write_catalog for Makefile recipes that need to produce a catalog.json
# without going through the full builder flow (e.g. validate-rc-full).
#
# Usage:
#   python3 artifact_layout.py write-catalog \
#     --primary-base <root>   --port <port>   --dataset <dataset> \
#     --set-base <abs-path>  --set-path <rel-path>
#                              ^ may repeat for multiple set rows
#
# Each --set-base / --set-path pair produces one row in catalog "sets".
# The unit count in each row is derived by scanning the resolved set directory
# for subdirectories that contain an estate database.

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        prog="artifact_layout",
        description="artifact_layout utilities",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    wc = sub.add_parser(
        "write-catalog",
        help="Write catalog.json for a dataset from one or more set rows",
    )
    wc.add_argument("--primary-base", required=True,
                    help="Root folder where <port>/<dataset>/catalog.json is written")
    wc.add_argument("--port", required=True, help="Port name (swift or rust)")
    wc.add_argument("--dataset", required=True, help="Dataset name")
    wc.add_argument("--set-base", required=True, dest="set_bases", action="append",
                    metavar="ABS_PATH",
                    help="Absolute base path for a set row (repeat for multiple sets)")
    wc.add_argument("--set-path", required=True, dest="set_paths", action="append",
                    metavar="REL_PATH",
                    help="Relative set-directory path for a set row (must match --set-base count)")

    args = parser.parse_args()

    if args.command == "write-catalog":
        if len(args.set_bases) != len(args.set_paths):
            print("error: --set-base and --set-path counts must match", file=sys.stderr)
            sys.exit(1)
        sets: list[LaidOutSet] = []
        for base_str, path_str in zip(args.set_bases, args.set_paths):
            base = pathlib.Path(base_str)
            set_dir_path = base / path_str
            # Count estates: subdirectories that carry an estate database.
            estates: dict[str, pathlib.Path] = {}
            if set_dir_path.exists():
                for d in sorted(set_dir_path.iterdir()):
                    if d.is_dir() and estate_db(str(d)):
                        estates[d.name] = d
            name = pathlib.Path(path_str).name
            sets.append(LaidOutSet(name=name, base=base, path=set_dir_path,
                                   estates=estates))
        out = write_catalog(pathlib.Path(args.primary_base), args.port, args.dataset, sets)
        print(out)
