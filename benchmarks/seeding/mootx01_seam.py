#!/usr/bin/env python3
"""The product seam (ARTIFACT_BUILDER_SPEC.md §11) on the real mootx01 binary.

    mootx01_seam provision   <estate-dir>
    mootx01_seam import      <estate-dir> <records.jsonl>
    mootx01_seam batch-drain <list-file>

Same three calls, arguments, exit codes and output lines as mootx01_faker, so
`artifact_build.py --exe` takes either. Environment, all set by the Makefile:

    MOOTX01_BINARY          the product binary for the port (required)
    MOOTX01_SEAM_UNITS_DIR  the seeder's units/ folder for the dataset; the
                            full seed record (subject, wing, event_time) is
                            read from here by record id, the projection row
                            carrying only id, body and room
    IMPORT_DRAIN_TIMEOUT    passed through to import_units.py

provision:   creates the directory. The product materialises the estate on the
             importer's first serve (create, flip the benchmark preferences
             off, import — spec §4 step 4), so an empty directory is the
             template and the clone copies nothing.
import:      one estate = one import_units.py run on a unit file assembled
             from the seed records of the rows in <records.jsonl>. The
             aggregate estate is the exception: its rows are staged under
             <estate-dir>/.pending/ and imported as ONE unit file when
             batch-drain reaches it, because the importer is strict-append
             (one file per estate, never a second append).
batch-drain: for each listed estate, the product's finisher `mootx01 drain
             --db <estate>` runs attached (GeniusLocusKit § DUTY_LIFECYCLE:
             it pays the encode queue and every row-debt lane until settled
             and exits with nothing left running), then one drain-status read
             over a stdio serve confirms every lane idle. Prints
             `idle <estate> <bytes>` or `failed <estate> <reason>`.
"""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
IMPORTER = pathlib.Path(os.environ.get("MOOTX01_SEAM_IMPORTER", HERE / "import_units.py"))
PENDING = ".pending"
IMPORT_LOG = "harness-import.log"
DRAIN_LOG = "harness-drain.log"


def binary() -> str:
    path = os.environ.get("MOOTX01_BINARY")
    if not path:
        sys.exit("mootx01_seam: MOOTX01_BINARY is not set")
    return path


def seed_records(units_dir: pathlib.Path | None) -> dict[str, dict]:
    """Every seed record of the dataset by id, from the seeder's unit files."""
    found: dict[str, dict] = {}
    if units_dir is None or not units_dir.is_dir():
        return found
    for unit_file in sorted(units_dir.glob("*.json")):
        with open(unit_file, encoding="utf-8") as handle:
            for record in json.load(handle).get("records", []):
                found[record["id"]] = record
    return found


def rows(records_file: pathlib.Path) -> list[dict]:
    with open(records_file, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def unit_file_for(estate: pathlib.Path, projection_rows: list[dict], seeds: dict[str, dict]) -> pathlib.Path:
    """Assemble the importer's unit file for one estate: the seed record for
    every row when the seeder wrote one, else the projection row itself
    (synthetic sources such as the smoke test carry body and room only)."""
    records = []
    for n, row in enumerate(projection_rows):
        seed = seeds.get(row["id"])
        if seed is None:
            # The importer requires every seed field; a synthetic row gets a
            # subject from its first line and a deterministic event time one
            # minute apart so the records order the way they were written.
            body = row["body"]
            seed = {"id": row["id"], "content": body, "room": row.get("room", "default"),
                    "subject": body.splitlines()[0][:80] if body else row["id"], "wing": "Personal",
                    "event_time": f"2026-01-01T00:{n // 60 % 60:02d}:{n % 60:02d}Z"}
        records.append(seed)
    unit = {"format_version": 1, "name": estate.name, "records": records}
    path = estate.parent / f"{estate.name}.unit.json"
    path.write_text(json.dumps(unit, ensure_ascii=False) + "\n", encoding="utf-8")
    return path


def run_importer(estate: pathlib.Path, unit_file: pathlib.Path) -> int:
    """import_units.py builds the estate at <estates-dir>/<estate-name>; its
    progress goes to the estate's harness-import.log, and its exit code is the
    verdict. Returns the record count on success."""
    env = dict(os.environ, MOOTX01_BINARY=binary())
    with open(estate / IMPORT_LOG, "a", encoding="utf-8") as log:
        proc = subprocess.run(
            [sys.executable, "-u", str(IMPORTER), "--file", str(unit_file),
             "--estates-dir", str(estate.parent), "--estate-name", estate.name],
            cwd=str(estate.parent), env=env, stdout=log, stderr=subprocess.STDOUT, text=True)
    if proc.returncode != 0:
        return -1
    with open(unit_file, encoding="utf-8") as handle:
        return len(json.load(handle)["records"])


def provision(estate: pathlib.Path) -> int:
    estate.mkdir(parents=True, exist_ok=True)
    print(f"provisioned {estate}")
    return 0


def is_aggregate(estate: pathlib.Path) -> bool:
    # artifact_layout.aggregate_dir: <base>/<port>/<dataset>/aggregate/<dataset>
    return estate.parent.name == "aggregate"


def import_records(estate: pathlib.Path, records_file: pathlib.Path) -> int:
    projection_rows = rows(records_file)
    if is_aggregate(estate):
        pending = estate / PENDING
        pending.mkdir(parents=True, exist_ok=True)
        (pending / f"{len(list(pending.iterdir())):06d}.jsonl").write_text(
            "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in projection_rows), encoding="utf-8")
        print(f"imported {len(projection_rows)}")
        return 0
    seeds = seed_records(units_dir())
    count = run_importer(estate, unit_file_for(estate, projection_rows, seeds))
    if count < 0:
        print(f"failed {estate} import (see {estate / IMPORT_LOG})")
        return 1
    print(f"imported {count}")
    return 0


def units_dir() -> pathlib.Path | None:
    value = os.environ.get("MOOTX01_SEAM_UNITS_DIR")
    return pathlib.Path(value) if value else None


def import_pending_aggregate(estate: pathlib.Path) -> str | None:
    """The aggregate's staged rows become one unit file and one importer run."""
    pending = estate / PENDING
    if not pending.is_dir():
        return None
    staged: list[dict] = []
    for part in sorted(pending.glob("*.jsonl")):
        staged.extend(rows(part))
    seeds = seed_records(units_dir())
    if run_importer(estate, unit_file_for(estate, staged, seeds)) < 0:
        return f"aggregate import (see {estate / IMPORT_LOG})"
    for part in pending.glob("*.jsonl"):
        part.unlink()
    pending.rmdir()
    return None


def lane_settled(lane: dict) -> bool:
    """A lane is settled when idle with nothing pending. The fact lane is
    also settled when nothing it holds is runnable: a stdio serve registers
    no extractor, so its status read reports every remaining source as
    blocked, and a blocked or rejected source is settled work
    (GeniusLocusKit § DUTY_LIFECYCLE), not debt the finisher left behind."""
    if lane.get("state") == "idle" and int(lane.get("pending") or 0) == 0:
        return True
    # The dreaming lane is the persistent dreaming queue's job depth:
    # recall-event work that only a resident's governor pumps. `mootx01
    # drain` settles every duty and exits with that lane untouched, and a
    # stdio serve never pumps it, so a job left behind by a resident that
    # died mid-cycle (three Swift convomem sets, 2026-09-19) is not debt the
    # finisher can pay and must not fail the set. The product's own
    # settled rule for drain excludes it; this rule matches.
    if lane.get("name") == "dreaming":
        return True
    if lane.get("name") != "fact_extraction":
        return False
    counts = {}
    for part in str(lane.get("detail", "")).split(";")[-1].split(","):
        key, _, value = part.strip().rpartition(": ")
        if key and value.isdigit():
            counts[key] = int(value)
    return all(counts.get(k, 1) == 0 for k in ("ready", "running", "partial", "retrying"))


def drain_status(estate: pathlib.Path) -> tuple[bool, str]:
    """One moot_drain_status read over a stdio serve on the estate. A stdio
    serve spawns nothing (§ DUTY_LIFECYCLE), so this is a pure read. Returns
    (settled, one-line lane summary); an unreadable status is never settled."""
    proc = subprocess.Popen([binary(), "serve", "--db", str(estate)], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def call(i: int, method: str, params: dict) -> dict:
        assert proc.stdin and proc.stdout
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n")
        proc.stdin.flush()
        while True:
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("serve closed")
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == i:
                return msg

    try:
        call(1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                               "clientInfo": {"name": "mootx01_seam", "version": "1"}})
        assert proc.stdin
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        proc.stdin.flush()
        res = call(2, "tools/call", {"name": "moot_drain_status", "arguments": {}})
    except (RuntimeError, OSError) as exc:
        return False, f"status-unreadable:{exc}"
    finally:
        try:
            proc.stdin.close()   # type: ignore[union-attr]
            proc.terminate()
            proc.wait(timeout=10)
        except Exception:
            pass
    drains = (((res.get("result") or {}).get("structuredContent") or {}).get("data") or {}).get("drains") or []
    summary = " ".join(f"{d.get('name')}={d.get('state')}/{d.get('pending')}" for d in drains)
    if not drains:
        return False, "status-empty"
    return all(lane_settled(d) for d in drains), summary


def dir_bytes(path: pathlib.Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def batch_drain(list_file: pathlib.Path) -> int:
    with open(list_file, encoding="utf-8") as handle:
        estates = [pathlib.Path(p.strip()) for p in handle if p.strip()]
    for estate in estates:
        try:
            reason = drain_one(estate)
        except Exception as exc:          # a crash must still name the estate on stdout
            reason = f"exception:{type(exc).__name__}:{exc}"
        if reason:
            print(f"failed {estate} {reason}")
            sys.stdout.flush()
            return 1
        print(f"idle {estate} {dir_bytes(estate)}")
        sys.stdout.flush()
    return 0


def drain_one(estate: pathlib.Path) -> str | None:
    """Settle one estate; None when settled, else the failure reason."""
    if is_aggregate(estate):
        reason = import_pending_aggregate(estate)
        if reason:
            return reason
    with open(estate / DRAIN_LOG, "a", encoding="utf-8") as log:
        proc = subprocess.run([binary(), "drain", "--db", str(estate)], stdout=log,
                              stderr=subprocess.STDOUT, text=True)
    if proc.returncode != 0:
        return f"drain-exit-{proc.returncode}"
    settled, summary = drain_status(estate)
    if not settled:
        return f"drain-status-not-settled:{summary.replace(' ', ',')}"
    return None


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    verb, args = argv[1], argv[2:]
    if verb == "provision" and len(args) == 1:
        return provision(pathlib.Path(args[0]))
    if verb == "import" and len(args) == 2:
        return import_records(pathlib.Path(args[0]), pathlib.Path(args[1]))
    if verb == "batch-drain" and len(args) == 1:
        return batch_drain(pathlib.Path(args[0]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
