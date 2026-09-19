#!/usr/bin/env python3
"""Drain every estate of a built fleet on the current product binary.

A fleet built on an earlier binary is settled for that binary's duties. When
the product gains a duty that reshapes a settled estate (the chest re-bin of
ADR-026, which deals rooms above capacity into chests and re-sweeps them per
chest), the fleet needs one drain on the new binary to carry it, and the
catalog's `encoded` state already holds. This runs `mootx01 drain --db` over
every estate the catalog enumerates (unit sets and the aggregate), a bounded
number at a time, and records each estate's wall clock so the build cost of
the new duties is a number, not a feeling.

    fleet_drain.py --exe <mootx01> --port swift --dataset lme-s \\
        --catalog <base>/swift/lme-s/catalog.json --jobs 4 --out <report.json>

Nothing but the product finisher touches an estate. An estate whose drain
exits non-zero is listed in the report and the run continues; the exit code
is non-zero when any estate failed.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import pathlib
import subprocess
import sys
import time

import artifact_layout as layout


def drain_one(exe: pathlib.Path, estate: str) -> dict:
    started = time.time()
    proc = subprocess.run([str(exe), "drain", "--db", estate], capture_output=True, text=True)
    return {
        "estate": estate,
        "seconds": round(time.time() - started, 3),
        "exit": proc.returncode,
        "tail": (proc.stdout + proc.stderr).strip().splitlines()[-3:],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", required=True, type=pathlib.Path, help="the product binary")
    ap.add_argument("--port", required=True, choices=("swift", "rust"))
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--catalog", required=True, type=pathlib.Path, help="<base>/<port>/<dataset>/catalog.json")
    ap.add_argument("--jobs", type=int, default=4, help="estates drained at once")
    ap.add_argument("--out", required=True, type=pathlib.Path, help="the per-estate clock report")
    args = ap.parse_args()

    if not args.exe.is_file():
        print(f"fleet_drain: no binary at {args.exe}", file=sys.stderr)
        return 2
    estates = layout.fleet_estates_from_catalog(str(args.catalog))
    if not estates:
        print(f"fleet_drain: the catalog at {args.catalog} enumerates no estates", file=sys.stderr)
        return 2
    print(f"fleet_drain: {len(estates)} estates, {args.jobs} at a time, binary {args.exe}", flush=True)

    started = time.time()
    results: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for result in pool.map(lambda e: drain_one(args.exe, e), estates):
            results.append(result)
            flag = "ok" if result["exit"] == 0 else f"EXIT {result['exit']}"
            print(f"  {pathlib.Path(result['estate']).name}  {result['seconds']:.1f}s  {flag}", flush=True)
    failed = [r for r in results if r["exit"] != 0]
    seconds = [r["seconds"] for r in results]
    report = {
        "port": args.port,
        "dataset": args.dataset,
        "binary": str(args.exe),
        "catalog": str(args.catalog),
        "jobs": args.jobs,
        "estates": len(results),
        "failed": len(failed),
        "wall_seconds": round(time.time() - started, 1),
        "per_estate_seconds": {
            "min": min(seconds), "median": sorted(seconds)[len(seconds) // 2], "max": max(seconds),
            "sum": round(sum(seconds), 1),
        },
        "results": results,
        "finished": layout.now_iso(),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"fleet_drain: {len(results)} drained, {len(failed)} failed, wall {report['wall_seconds']}s, "
          f"median {report['per_estate_seconds']['median']}s per estate; report {args.out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
