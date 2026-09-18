#!/usr/bin/env python3
"""Artifact build: one dataset, one port, end to end (ARTIFACT_BUILDER_SPEC.md §4).

    lay out -> catalog -> start N watchers -> provision once and clone
    -> import in waves -> wait for the watchers -> done check

The executable is one parameter (§11): mootx01_faker for the assembly-line
smoke, the gated mootx01 binary for real builds. The target map comes from
--target-map or, when omitted, from MOOTX01_BENCH_TARGET_MAP (R1).
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

import artifact_import as imp
import artifact_layout as layout

WATCH = pathlib.Path(__file__).resolve().parent / "artifact_watch.py"


def start_watchers(n: int, *, exe: pathlib.Path, bases: list[pathlib.Path], port: str,
                   dataset: str, stale: float, poll: float, floor: int | None,
                   log_dir: pathlib.Path) -> list[subprocess.Popen]:
    log_dir.mkdir(parents=True, exist_ok=True)
    procs = []
    for i in range(1, n + 1):
        wid = f"w{i}"
        log = open(log_dir / f"watcher-{wid}.log", "w", encoding="utf-8")
        procs.append(subprocess.Popen(
            [sys.executable, str(WATCH), "--exe", str(exe), "--port", port,
             "--dataset", dataset, "--bases", *map(str, bases), "--id", wid,
             "--stale", str(stale), "--poll", str(poll),
             *(["--floor", str(floor)] if floor is not None else [])],
            stdout=log, stderr=subprocess.STDOUT, text=True))
    return procs


def done_check(sets: list[layout.LaidOutSet], projection: imp.Projection,
               counts: dict[str, int], dataset: str) -> list[str]:
    """§4 step 7. Returns the list of problems; empty means done."""
    problems = []
    union: set[str] = set()
    for s in sets:
        for unit, estate in s.estates.items():
            addr = layout.read_address(estate)
            if addr["state"] != "encoded":
                problems.append(f"{s.name}/{unit}: state {addr['state']}")
            if not (addr.get("size_bytes") or 0) > 0:
                problems.append(f"{s.name}/{unit}: no encoded size")
            if s.name != layout.AGGREGATE_SET:
                expected = len(projection.records(unit))
                union.update(r["id"] for r in projection.records(unit))
                if addr["record_count"] != expected:
                    problems.append(f"{s.name}/{unit}: records {addr['record_count']} != seed {expected}")
                if not (estate / imp.LEDGER_FILE).exists():
                    problems.append(f"{s.name}/{unit}: no ledger")
    if counts.get(dataset) != len(union):
        problems.append(f"aggregate records {counts.get(dataset)} != union {len(union)}")
    return problems


def build(*, exe: pathlib.Path, port: str, dataset: str, projection_dir: pathlib.Path,
          target: layout.TargetMap, set_size: int, watchers: int, bytes_per_estate: int,
          aggregate_bytes: int, stale: float, poll: float, template: pathlib.Path,
          log_dir: pathlib.Path, floor: int | None = None, limit: int = 0,
          only_units: list[str] | None = None, log=print) -> int:
    projection = imp.Projection.open(projection_dir)
    units = projection.unit_ids()
    if only_units:
        missing = sorted(set(only_units) - set(units))
        if missing:
            log(f"[build] NOT DONE: units not in the projection: {' '.join(missing)}")
            return 2
        units = [u for u in units if u in set(only_units)]
    if limit:
        units = sorted(units)[:limit]
    log(f"[build] {port}/{dataset}: {len(units)} units, set size {set_size}")

    sets = layout.lay_out_dataset(target, port, dataset, units, bytes_per_estate=bytes_per_estate,
                                  aggregate_bytes=aggregate_bytes, set_size=set_size)
    bases = [b.path for b in target.bases]
    layout.write_catalog(bases[0], port, dataset, sets)
    log(f"[build] laid out {len(sets) - 1} sets + aggregate across "
        f"{len({s.base for s in sets})} base folder(s)")

    procs = start_watchers(watchers, exe=exe, bases=bases, port=port, dataset=dataset,
                           stale=stale, poll=poll, floor=floor, log_dir=log_dir)
    log(f"[build] {watchers} watcher(s) started")

    try:
        imp.provision_all(exe, template, sets)
        log("[build] provisioned and cloned")
        counts = imp.import_waves(exe, projection, dataset, port, sets)
        log(f"[build] imported; aggregate {counts[dataset]} records; import.done written")
    except imp.ImportError_ as exc:
        log(f"[build] IMPORT FAILED: {exc}")
        for p in procs:
            p.terminate()
        return 2

    rc = 0
    for p in procs:
        p.wait()
        rc = max(rc, p.returncode)
    log(f"[build] watchers finished, worst exit {rc}")

    problems = done_check(sets, projection, counts, dataset)
    for problem in problems:
        log(f"[build] NOT DONE: {problem}")
    if problems or rc:
        return 1
    log(f"[build] DONE {port}/{dataset}")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--exe", required=True, type=pathlib.Path)
    ap.add_argument("--port", required=True, choices=("swift", "rust"))
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--projection", required=True, type=pathlib.Path)
    ap.add_argument("--target-map", type=pathlib.Path, help="default: $MOOTX01_BENCH_TARGET_MAP")
    ap.add_argument("--base", type=pathlib.Path,
                    help="one base folder for every set (the storage config's internal primary); overrides the target map")
    ap.add_argument("--floor", type=int, default=None,
                    help="disk floor in bytes; default: twice the previous set's encoded size")
    ap.add_argument("--set-size", type=int, default=layout.SET_SIZE)
    ap.add_argument("--watchers", type=int, default=2)
    ap.add_argument("--bytes-per-estate", type=int, default=8 * 1024 * 1024)
    ap.add_argument("--aggregate-bytes", type=int, default=1024 * 1024 * 1024)
    ap.add_argument("--stale", type=float, default=600.0)
    ap.add_argument("--poll", type=float, default=2.0)
    ap.add_argument("--work", required=True, type=pathlib.Path,
                    help="work root for the template estate and watcher logs")
    ap.add_argument("--limit", type=int, default=0,
                    help="build the first N units by sorted id (0 = every unit)")
    ap.add_argument("--units", nargs="*", default=None,
                    help="build exactly these units (a proof run names one)")
    a = ap.parse_args(argv[1:])
    floor = a.floor if a.floor is not None else 0    # layout places by estimate; watchers apply §6
    if a.base:
        target = layout.TargetMap([layout.BaseFolder(a.base.expanduser(), None)], floor)
    else:
        target = (layout.TargetMap.load(a.target_map, a.port, a.dataset, floor) if a.target_map
                  else layout.TargetMap.from_env(a.port, a.dataset, floor))
    return build(exe=a.exe, port=a.port, dataset=a.dataset, projection_dir=a.projection,
                 target=target, set_size=a.set_size, watchers=a.watchers,
                 bytes_per_estate=a.bytes_per_estate, aggregate_bytes=a.aggregate_bytes,
                 stale=a.stale, poll=a.poll, template=a.work / "template" / f"{a.port}-{a.dataset}",
                 log_dir=a.work / "logs" / f"{a.port}-{a.dataset}", floor=a.floor,
                 limit=a.limit, only_units=a.units or None)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
