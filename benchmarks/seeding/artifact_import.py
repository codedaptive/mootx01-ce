#!/usr/bin/env python3
"""Artifact import: provision once and clone, then wave import with ledger.

ARTIFACT_BUILDER_SPEC.md §4 steps 3 and 4, §5 ledger, §3 C2 partition maps.
Talks to the product through exactly two of the three seam calls (§11):

    <exe> provision <estate-dir>
    <exe> import    <estate-dir> <records.jsonl>

Seed projection layout the importer reads (§4 step 1 writes it):

    <projection>/dataset.json          {"room_rule": "...", "overlap": bool}
    <projection>/units/<unit>.jsonl    one record per line:
        {"id": str, "body": str, "room": str, "shape": str,
         "gold": {"<question-id>": "gold" | "distractor"}}

Records absent from a unit's gold map are "absent" for every question. The
ledger records gold | distractor | absent per record per question of the unit.
"""
from __future__ import annotations

import concurrent.futures
import json
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
from dataclasses import dataclass

import artifact_layout as layout

LEDGER_FILE = "ledger.json"
PARTITION_MAP = "partition_map.json"


def import_jobs() -> int:
    """Unit imports run at once per set: MOOTX01_BENCH_IMPORT_JOBS, default 1
    (the serial order every earlier build used). The recipes pass IMPORT_JOBS."""
    try:
        return max(1, int(os.environ.get("MOOTX01_BENCH_IMPORT_JOBS", "1")))
    except ValueError:
        return 1
IMPORT_DONE = "import.done"
BUILDER_VERSION = "artifact-builder/0.3"


class ImportError_(RuntimeError):
    """A seam call failed. Message carries the estate and the binary's last line."""


def run_seam(exe: pathlib.Path, *args: str) -> str:
    proc = subprocess.run([str(exe), *map(str, args)], capture_output=True, text=True)
    last = (proc.stdout.strip().splitlines() or [""])[-1]
    if proc.returncode != 0 or last.startswith("failed"):
        raise ImportError_(f"{exe.name} {args[0]} {args[1]}: {last or proc.stderr.strip()}")
    return last


# ── §4 step 3: provision once, clone ────────────────────────────────────────

def provision_template(exe: pathlib.Path, template: pathlib.Path) -> None:
    template.mkdir(parents=True, exist_ok=True)
    run_seam(exe, "provision", template)


def clone_template(template: pathlib.Path, estate: pathlib.Path) -> None:
    """Copy-on-write copy of every template file into the estate directory.

    address.json already lives in the estate (laid_out) and is never in the
    template, so nothing is overwritten. macOS uses cp -c (APFS clonefile);
    elsewhere a plain copy.
    """
    estate.mkdir(parents=True, exist_ok=True)
    if platform.system() == "Darwin":
        subprocess.run(["cp", "-c", "-R", f"{template}/.", f"{estate}/"], check=True)
    else:
        for item in template.iterdir():
            if item.is_dir():
                shutil.copytree(item, estate / item.name, dirs_exist_ok=True)
            else:
                shutil.copy2(item, estate / item.name)


def provision_all(exe: pathlib.Path, template: pathlib.Path,
                  sets: list[layout.LaidOutSet]) -> None:
    provision_template(exe, template)
    for s in sets:
        for unit, estate in s.estates.items():
            if layout.is_built(estate):
                continue                       # resume: keep what an earlier run built
            clone_template(template, estate)
            addr = layout.read_address(estate)
            layout.write_address(estate, unit=unit, dataset=addr["dataset"],
                                 port=addr["port"], set_name=addr["set"],
                                 state="provisioned")


# ── Seed projection ─────────────────────────────────────────────────────────

@dataclass
class Projection:
    root: pathlib.Path
    room_rule: str
    overlap: bool

    @classmethod
    def open(cls, root: pathlib.Path) -> "Projection":
        with open(root / "dataset.json", encoding="utf-8") as handle:
            meta = json.load(handle)
        return cls(root, meta["room_rule"], bool(meta.get("overlap", False)))

    def unit_ids(self) -> list[str]:
        return sorted(p.stem for p in (self.root / "units").glob("*.jsonl"))

    def unit_file(self, unit: str) -> pathlib.Path:
        return self.root / "units" / f"{unit}.jsonl"

    def records(self, unit: str) -> list[dict]:
        with open(self.unit_file(unit), encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]


# ── §5 ledger ───────────────────────────────────────────────────────────────

def write_ledger(estate: pathlib.Path, *, projection: Projection, dataset: str,
                 unit: str, records: list[dict], digest: str) -> None:
    questions = sorted({q for r in records for q in r.get("gold", {})})
    rows = []
    for r in records:
        gold = r.get("gold", {})
        rows.append({
            "id": r["id"],
            "shape": r.get("shape", "unknown"),
            "relation": {q: gold.get(q, "absent") for q in questions},
        })
    doc = {
        "room_rule": projection.room_rule,
        "questions": questions,
        "records": rows,
        "source": {"dataset": dataset, "unit": unit,
                   "projection_digest": digest, "builder": BUILDER_VERSION},
    }
    path = estate / LEDGER_FILE
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def projection_digest(path: pathlib.Path) -> str:
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


# ── §3 C2 partition map ─────────────────────────────────────────────────────

def write_partition_map(s: layout.LaidOutSet, counts: dict[str, int]) -> pathlib.Path:
    doc = {
        "set": s.name,
        "base": str(s.base),
        "written": layout.now_iso(),
        "estates": [
            {"unit": unit, "path": str(estate.relative_to(s.path)),
             "record_count": counts[unit]}
            for unit, estate in s.estates.items()
        ],
    }
    path = s.path / PARTITION_MAP
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)          # atomic: the map appears whole or not at all
    return path


# ── §4 step 4: wave import, read once, write twice ──────────────────────────

def parse_count(line: str) -> int:
    verb, count = line.split()
    if verb != "imported":
        raise ImportError_(f"unexpected import reply: {line}")
    return int(count)


def import_waves(exe: pathlib.Path, projection: Projection, dataset: str,
                 port: str, sets: list[layout.LaidOutSet]) -> dict[str, int]:
    """Import every set in order; write ledgers, partition maps, import.done.

    Returns record counts per unit plus the aggregate under the dataset name.
    On a seam failure the estate is marked failed and the error is re-raised;
    no partition map is written for the failed set.
    """
    aggregate_set = next(s for s in sets if s.name == layout.AGGREGATE_SET)
    aggregate = aggregate_set.estates[dataset]
    seen: set[str] = set()
    counts: dict[str, int] = {}
    aggregate_count = 0

    with tempfile.TemporaryDirectory() as scratch:
        scratch_dir = pathlib.Path(scratch)
        for s in sets:
            if s.name == layout.AGGREGATE_SET:
                continue
            set_counts: dict[str, int] = {}
            # A set the watcher finished keeps its done map only while every
            # unit in it is built. A resume that widened the build lays new
            # units into such a set; the done marker would then read as
            # terminal and the new units would never drain, so the marker
            # is retired and a fresh claimable map is written for the set
            # (codex finding 2026-09-19).
            done_map = s.path / "partition_map.done.json"
            set_done = done_map.exists()
            if set_done and any(layout.read_address(e).get("state") != "encoded" for e in s.estates.values()):
                done_map.rename(s.path / f"partition_map.done.{layout.now_iso().replace(':', '')}.json")
                set_done = False
            # Unit imports run IMPORT_JOBS at a time: every unit is its own
            # estate served by its own process, so they are independent, and
            # a one-record unit is a few seconds of process handoffs rather
            # than work (measured 4 s / 7 s per unit, 2026-09-19). The
            # aggregate is one estate and takes the units' records afterwards,
            # in unit order, so its content is the same whatever the worker
            # count.
            def import_unit(unit_estate):
                unit, estate = unit_estate
                source = projection.unit_file(unit)
                # Resume: a unit imported or encoded by an earlier run is not
                # imported again, but its records still go into the aggregate,
                # which is laid out fresh whenever any unit is new.
                already = layout.read_address(estate)["state"] in ("imported", "encoded")
                try:
                    if already:
                        count = layout.read_address(estate)["record_count"]
                    else:
                        count = parse_count(run_seam(exe, "import", estate, source))
                except ImportError_ as exc:
                    layout.write_address(estate, unit=unit, dataset=dataset, port=port,
                                         set_name=s.name, state="failed", error=str(exc))
                    raise
                if not already:
                    write_ledger(estate, projection=projection, dataset=dataset, unit=unit,
                                 records=projection.records(unit), digest=projection_digest(source))
                    layout.write_address(estate, unit=unit, dataset=dataset, port=port,
                                         set_name=s.name, state="imported", record_count=count)
                return unit, count

            with concurrent.futures.ThreadPoolExecutor(max_workers=import_jobs()) as pool:
                for unit, count in pool.map(import_unit, list(s.estates.items())):
                    set_counts[unit] = count
            for unit in s.estates:
                source = projection.unit_file(unit)
                records = projection.records(unit)
                # Second write: the aggregate. Overlapping datasets skip ids
                # already present; non-overlapping ones write the same file.
                try:
                    if projection.overlap:
                        fresh = [r for r in records if r["id"] not in seen]
                        if fresh:
                            sub = scratch_dir / f"{unit}.agg.jsonl"
                            sub.write_text("".join(json.dumps(r) + "\n" for r in fresh))
                            aggregate_count += parse_count(run_seam(exe, "import", aggregate, sub))
                    else:
                        aggregate_count += parse_count(run_seam(exe, "import", aggregate, source))
                except ImportError_ as exc:
                    layout.write_address(aggregate, unit=dataset, dataset=dataset, port=port,
                                         set_name=layout.AGGREGATE_SET, state="failed", error=str(exc))
                    raise
                seen.update(r["id"] for r in records)
            if not set_done:
                write_partition_map(s, set_counts)  # last, after every estate
            counts.update(set_counts)

    layout.write_address(aggregate, unit=dataset, dataset=dataset, port=port,
                         set_name=layout.AGGREGATE_SET, state="imported",
                         record_count=aggregate_count)
    counts[dataset] = aggregate_count
    marker = aggregate.parent.parent / IMPORT_DONE     # <port>/<dataset>/import.done
    marker.write_text(layout.now_iso() + "\n", encoding="utf-8")
    return counts
