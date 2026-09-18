#!/usr/bin/env python3
"""Artifact watcher: claim partition maps, batch-drain them, record the result.

ARTIFACT_BUILDER_SPEC.md §6 and §4 steps 5 to 6. The filesystem is the only
coordinator. N watchers per port run this same loop:

    list the dataset's sets across every base folder
    reclaim any claim whose heartbeat is stale
    try to claim one unclaimed partition map by atomic rename
    hand its not-yet-encoded estates to  <exe> batch-drain <list-file>
    per "idle <estate> <size>" line: address -> encoded, touch the claim
    on success rename the claim to partition_map.done.json
    repeat until import.done exists and no map is claimable or claimed

File names in a set directory:
    partition_map.json                 claimable
    partition_map.<watcher>.claimed    in flight; mtime is the heartbeat
    partition_map.done.json            finished, carries encoded_size
    partition_map.failed.json          gave up, carries the reason

The aggregate has no partition map from the importer. Once import.done
exists a watcher writes one for it (set of one) with exclusive create, so
the aggregate drains through the same path as every other set.

A drainer that exits without a "failed" line (a crash) releases the claim
for a retry; three crashes on one set mark it failed. A "failed" line marks
the set failed at once.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import threading
import sys
import tempfile
import time

import artifact_layout as layout
from artifact_import import IMPORT_DONE, PARTITION_MAP

DONE_MAP = "partition_map.done.json"
# One name for the failure marker: the layout module reads it when it
# rewrites a catalog, so the state a watcher recorded survives relocation.
FAILED_MAP = layout.FAILED_MAP
MAX_ATTEMPTS = 3


def dataset_dirs(bases: list[pathlib.Path], port: str, dataset: str) -> list[pathlib.Path]:
    return [b / port / dataset for b in bases if (b / port / dataset).is_dir()]


class Watcher:
    def __init__(self, *, exe: pathlib.Path, bases: list[pathlib.Path], port: str,
                 dataset: str, watcher_id: str, stale_seconds: float,
                 poll_seconds: float, floor_bytes: int | None, log=print):
        self.exe = exe
        self.bases = bases
        self.port = port
        self.dataset = dataset
        self.id = watcher_id
        self.stale = stale_seconds
        self.poll = poll_seconds
        self.floor = floor_bytes
        self.log = log
        self.last_set_bytes = 0
        self.failed_sets: list[str] = []

    # ── discovery ───────────────────────────────────────────────────────────

    def set_dirs(self) -> list[pathlib.Path]:
        found = []
        for d in dataset_dirs(self.bases, self.port, self.dataset):
            found.extend(sorted(p for p in d.glob("estate_set*") if p.is_dir()))
            agg = d / layout.AGGREGATE_SET
            if agg.is_dir():
                found.append(agg)
        return found

    def import_done(self) -> bool:
        return any((d / IMPORT_DONE).exists()
                   for d in dataset_dirs(self.bases, self.port, self.dataset))

    def ensure_aggregate_map(self) -> None:
        """After import.done, give the aggregate a claimable map (exclusive create)."""
        if not self.import_done():
            return
        for d in dataset_dirs(self.bases, self.port, self.dataset):
            agg_set = d / layout.AGGREGATE_SET
            estate = agg_set / self.dataset
            if not estate.is_dir() or any(agg_set.glob("partition_map*")):
                continue
            addr = layout.read_address(estate)
            if addr["state"] not in ("imported", "encoded", "failed"):
                continue
            doc = {"set": layout.AGGREGATE_SET, "base": str(d.parent.parent),
                   "written": layout.now_iso(),
                   "estates": [{"unit": self.dataset, "path": self.dataset,
                                "record_count": addr["record_count"]}]}
            try:
                fd = os.open(agg_set / PARTITION_MAP, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
            except FileExistsError:
                return
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(doc, handle, indent=2)

    # ── claims ──────────────────────────────────────────────────────────────

    def claimed_name(self) -> str:
        return f"partition_map.{self.id}.claimed"

    def reclaim_stale(self) -> None:
        now = time.time()
        for sdir in self.set_dirs():
            for claim in sdir.glob("partition_map.*.claimed"):
                if now - claim.stat().st_mtime > self.stale:
                    try:
                        claim.rename(sdir / PARTITION_MAP)
                        self.log(f"[{self.id}] reclaimed stale {sdir.name} from {claim.name}")
                    except FileNotFoundError:
                        pass

    def try_claim(self, sdir: pathlib.Path) -> pathlib.Path | None:
        target = sdir / self.claimed_name()
        try:
            (sdir / PARTITION_MAP).rename(target)   # atomic; loser gets not-found
        except FileNotFoundError:
            return None
        return target

    def floor_bytes(self) -> int:
        """§6: an explicit floor, else twice the previous set's encoded size."""
        return self.floor if self.floor is not None else 2 * self.last_set_bytes

    def disk_ok(self, sdir: pathlib.Path) -> bool:
        """Room for one more set on this set's base folder, above the floor.

        A base folder carrying a .capacity_bytes file (written by the layout
        when the target map gave a capacity) is measured against that cap;
        otherwise against the volume's free space. Mirrors artifact_layout.
        """
        base = self.base_of(sdir)
        return layout.free_bytes(base) - self.last_set_bytes >= self.floor_bytes()

    def base_of(self, sdir: pathlib.Path) -> pathlib.Path:
        for b in self.bases:
            try:
                sdir.relative_to(b)
                return b
            except ValueError:
                continue
        return sdir

    # ── drain ───────────────────────────────────────────────────────────────

    def drain(self, claim: pathlib.Path) -> None:
        sdir = claim.parent
        with open(claim, encoding="utf-8") as handle:
            doc = json.load(handle)
        pending = [sdir / e["path"] for e in doc["estates"]
                   if layout.read_address(sdir / e["path"])["state"] != "encoded"]
        total = sum(layout.read_address(sdir / e["path"]).get("size_bytes") or 0
                    for e in doc["estates"])

        outcome = "done"
        reason = ""
        if pending:
            with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as lst:
                lst.write("".join(f"{p}\n" for p in pending))
                list_file = lst.name
            try:
                proc = subprocess.Popen([str(self.exe), "batch-drain", list_file],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                assert proc.stdout is not None
                # Heartbeat for as long as the drainer runs: one product estate
                # can take longer than the stale limit before its idle line, and
                # a claim that goes quiet that long is reclaimed by a peer. The
                # claim file vanishing under us means exactly that; stop.
                lost = threading.Event()
                stop = threading.Event()

                def beat() -> None:
                    while not stop.wait(max(0.05, min(self.stale / 3, 5.0))):
                        try:
                            os.utime(claim)
                        except FileNotFoundError:
                            lost.set()
                            return
                beater = threading.Thread(target=beat, daemon=True)
                beater.start()
                for line in proc.stdout:
                    parts = line.split()
                    if len(parts) == 3 and parts[0] == "idle":
                        estate, size = pathlib.Path(parts[1]), int(parts[2])
                        addr = layout.read_address(estate)
                        layout.write_address(estate, unit=addr["unit"], dataset=self.dataset,
                                             port=self.port, set_name=addr["set"],
                                             state="encoded", size_bytes=size)
                        total += size
                    elif parts and parts[0] == "failed":
                        outcome, reason = "failed", line.strip()
                proc.wait()
                stop.set()
                beater.join()
                if lost.is_set() or not claim.exists():
                    # A peer reclaimed the set while we drained it; its
                    # address files carry what we finished, and the peer
                    # resumes from the first estate not yet encoded.
                    self.log(f"[{self.id}] lost claim on {sdir.name} to a peer; standing down")
                    return
                if outcome == "done" and proc.returncode != 0:
                    outcome, reason = "crashed", f"batch-drain exit {proc.returncode}"
            finally:
                os.unlink(list_file)

        if outcome == "done":
            doc["encoded_size"] = total
            doc["drained_by"] = self.id
            doc["finished"] = layout.now_iso()
            self.write_and_rename(claim, doc, sdir / DONE_MAP)
            self.last_set_bytes = total
            self.update_catalog(sdir, "encoded")
            self.log(f"[{self.id}] done {sdir.name} {total} bytes")
        elif outcome == "crashed" and doc.get("attempts", 0) + 1 < MAX_ATTEMPTS:
            doc["attempts"] = doc.get("attempts", 0) + 1
            self.write_and_rename(claim, doc, sdir / PARTITION_MAP)   # release for retry
            self.log(f"[{self.id}] released {sdir.name} after crash, attempt {doc['attempts']}")
        else:
            doc["reason"] = reason
            doc["failed_by"] = self.id
            self.write_and_rename(claim, doc, sdir / FAILED_MAP)
            self.update_catalog(sdir, "failed")
            self.failed_sets.append(sdir.name)
            self.log(f"[{self.id}] FAILED {sdir.name}: {reason}")

    @staticmethod
    def write_and_rename(claim: pathlib.Path, doc: dict, final: pathlib.Path) -> None:
        claim.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
        claim.rename(final)

    # ── catalog ─────────────────────────────────────────────────────────────

    def update_catalog(self, sdir: pathlib.Path, state: str) -> None:
        """Set one row's state in the primary catalog under a lock file."""
        primary = self.bases[0] / self.port / self.dataset
        path = primary / "catalog.json"
        if not path.exists():
            return
        lock = primary / "catalog.lock"
        for _ in range(500):
            try:
                fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
                os.close(fd)
                break
            except FileExistsError:
                time.sleep(0.01)
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
            for row in doc["sets"]:
                if row["name"] == sdir.name:
                    row["state"] = state
            tmp = path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
            tmp.replace(path)
        finally:
            try:
                os.unlink(lock)
            except FileNotFoundError:
                pass

    # ── loop ────────────────────────────────────────────────────────────────

    def in_flight(self) -> bool:
        return any(next(sdir.glob("partition_map.*.claimed"), None) is not None
                   for sdir in self.set_dirs())

    def finished(self) -> bool:
        if not self.import_done():
            return False
        for sdir in self.set_dirs():
            names = {p.name for p in sdir.glob("partition_map*")}
            if not names & {DONE_MAP, FAILED_MAP}:
                return False
        return True

    def run(self) -> int:
        while True:
            self.ensure_aggregate_map()
            self.reclaim_stale()
            claimed = None
            blocked: list[pathlib.Path] = []
            for sdir in self.set_dirs():
                if not (sdir / PARTITION_MAP).exists():
                    continue
                if not self.disk_ok(sdir):
                    blocked.append(sdir)      # skip; other base folders may have room
                    continue
                claimed = self.try_claim(sdir)
                if claimed:
                    break
            if claimed:
                self.drain(claimed)
                continue
            if blocked and self.import_done() and not self.in_flight():
                # Every claimable set sits below the floor and nobody else is
                # draining: the map is exhausted for this watcher.
                for sdir in blocked:
                    self.log(f"[{self.id}] disk floor reached at {sdir}; left unclaimed")
                return 3
            if self.finished():
                return 1 if self.failed_sets else 0
            time.sleep(self.poll)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--exe", required=True, type=pathlib.Path)
    ap.add_argument("--port", required=True)
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--bases", required=True, nargs="+", type=pathlib.Path)
    ap.add_argument("--id", default=f"w{os.getpid()}")
    ap.add_argument("--stale", type=float, default=600.0, help="seconds before a claim is stale")
    ap.add_argument("--poll", type=float, default=2.0)
    ap.add_argument("--floor", type=int, default=None,
                    help="disk floor in bytes; default: twice the previous set's encoded size")
    args = ap.parse_args(argv[1:])
    watcher = Watcher(exe=args.exe, bases=args.bases, port=args.port, dataset=args.dataset,
                      watcher_id=args.id, stale_seconds=args.stale, poll_seconds=args.poll,
                      floor_bytes=args.floor)
    return watcher.run()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
