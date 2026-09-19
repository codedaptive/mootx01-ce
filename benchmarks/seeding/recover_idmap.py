#!/usr/bin/env python3
"""Recover id-map.json for an already-built estate.

Estates imported before id-map capture existed have no
{seed_record_id: drawer_uuid} map. This script reconstructs it by
matching seed records to drawer rows in estate.sqlite.

Matching strategy (in order):
  1. exact (subject, normalized event_time) — the import preserved both
  2. content-prefix (first 200 chars) fallback when a subject+time key
     collides across multiple drawers or seed records
  3. full (subject, event_time, content) triple when both coarser tiers
     collide (near-duplicate sessions differing after char 200)

`--self-test` runs the deterministic matching-tier regression test.

The live DB is never opened read-write: estate.sqlite and its -wal are
copied to a temp dir, the copy is checkpointed, and all reads hit the copy.

Usage:
  python3 recover_idmap.py --estate-dir <dir> --seed <seed.json>

Writes <estate-dir>/id-map.json (flat {seed_record_id: drawer_uuid}).
"""

import argparse
import json
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path


def cow_copy(src, dst):
    """Copy-on-write file copy (Bob standing order 2026-08-28): APFS clone
    via `cp -c`, falling back to a byte copy when cloning is impossible
    (cross-volume, non-APFS). The temp dir callers pass sits BESIDE the
    source (same volume) so the clone path is actually reachable."""
    import shutil, subprocess
    r = subprocess.run(["cp", "-c", src, dst], capture_output=True)
    if r.returncode != 0:
        shutil.copy2(src, dst)


def normalize_ts(ts):
    """Normalize an ISO8601 timestamp for comparison.

    Seed files carry '2023-05-20T03:29:00Z'; the estate stores
    '2023-05-20T03:29:00.000Z' (milliseconds). Strip fractional seconds
    and a trailing Z so both shapes compare equal.
    """
    if ts is None:
        return None
    ts = ts.strip().rstrip("Z")
    if "." in ts:
        ts = ts.split(".", 1)[0]
    return ts


def load_drawers(estate_dir):
    """Copy the DB (+wal) aside, checkpoint the copy, return drawer rows."""
    src = Path(estate_dir) / "estate.sqlite"
    if not src.exists():
        sys.exit(f"ERROR: {src} not found")
    # Clone dir beside the source (same volume) so cp -c can clonefile
    # (Bob standing order 2026-08-28: CoW is the default copy action).
    with tempfile.TemporaryDirectory(
            prefix=".tmp-verify-", dir=str(Path(src).parent)) as tmp:
        dst = Path(tmp) / "estate.sqlite"
        cow_copy(str(src), str(dst))
        for suffix in ("-wal", "-shm"):
            side = Path(str(src) + suffix)
            if side.exists():
                cow_copy(str(side), str(dst) + suffix)
        con = sqlite3.connect(dst)
        try:
            con.execute("PRAGMA wal_checkpoint")
            rows = con.execute(
                "SELECT id, subject, eventTime, content FROM drawers "
                "WHERE tombstonedAt IS NULL"
            ).fetchall()
        finally:
            con.close()
    return rows


def recover(estate_dir, seed_path):
    seed = json.loads(Path(seed_path).read_text())
    records = seed["records"] if isinstance(seed, dict) else seed
    drawers = load_drawers(estate_dir)

    # Index drawers by (subject, normalized event_time). Values are lists
    # because subjects (session labels) collide; a unique list of one is
    # a clean match, longer lists fall through to the content-prefix pass.
    by_key = {}
    by_prefix = {}
    by_triple = {}
    for uuid, subject, event_time, content in drawers:
        by_key.setdefault((subject, normalize_ts(event_time)), []).append(uuid)
        by_prefix.setdefault((content or "")[:200], []).append(uuid)
        # Third tier: the full (subject, time, content) triple. Disambiguates
        # sessions that share a subject+time slot AND a 200-char prefix but
        # differ later in the body (observed 11/19195 on the lme-s estate).
        by_triple.setdefault(
            (subject, normalize_ts(event_time), content or ""), []).append(uuid)

    id_map = {}
    unmatched = []
    ambiguous = []
    for rec in records:
        rid = rec["id"]
        key = (rec.get("subject"), normalize_ts(rec.get("event_time")))
        hits = by_key.get(key, [])
        if len(hits) == 1:
            id_map[rid] = hits[0]
            continue
        # Fallback: content prefix (first 200 chars), used when the
        # subject+event_time key is absent or maps to multiple drawers.
        phits = by_prefix.get((rec.get("content") or "")[:200], [])
        if len(phits) == 1:
            id_map[rid] = phits[0]
            continue
        # Full-triple tier for records both coarser tiers left ambiguous.
        thits = by_triple.get(
            (rec.get("subject"), normalize_ts(rec.get("event_time")),
             rec.get("content") or ""), [])
        if len(thits) == 1:
            id_map[rid] = thits[0]
        elif not hits and not phits and not thits:
            unmatched.append(rid)
        else:
            ambiguous.append((rid, len(hits), len(phits), len(thits)))

    # Every seed record must map to exactly one UUID, and no UUID twice.
    dupes = len(id_map) - len(set(id_map.values()))
    n = len(records)
    print(f"matched {len(id_map)}/{n} seed records "
          f"({len(drawers)} live drawers in estate)")
    if unmatched:
        print(f"UNMATCHED ({len(unmatched)}): {unmatched}", file=sys.stderr)
    if ambiguous:
        print(f"AMBIGUOUS ({len(ambiguous)}): {ambiguous}", file=sys.stderr)
    if dupes:
        print(f"ERROR: {dupes} drawer UUID(s) claimed by multiple seed "
              f"records — map is invalid", file=sys.stderr)
    if unmatched or ambiguous or dupes:
        return None
    return id_map


def self_test():
    """Deterministic regression test for the three matching tiers.

    Builds a temp estate.sqlite whose drawers collide on BOTH coarse tiers
    (same subject+event_time slot AND identical 200-char content prefix,
    differing only after char 200 — the 11-of-19195 lme-s case) and
    asserts the full-triple tier resolves every record to its exact
    drawer. Exits nonzero on any mismatch.
    """
    prefix = "x" * 200
    rows = [
        ("UUID-A", "Session with Alex", "2023-05-20T03:29:00Z", prefix + "alpha tail"),
        ("UUID-B", "Session with Alex", "2023-05-20T03:29:00Z", prefix + "beta tail"),
        ("UUID-C", "Session with Priya", "2023-06-01T10:00:00Z", "unique clean row"),
    ]
    records = [
        {"id": "rec-b", "subject": "Session with Alex",
         "event_time": "2023-05-20T03:29:00Z", "content": prefix + "beta tail"},
        {"id": "rec-a", "subject": "Session with Alex",
         "event_time": "2023-05-20T03:29:00Z", "content": prefix + "alpha tail"},
        {"id": "rec-c", "subject": "Session with Priya",
         "event_time": "2023-06-01T10:00:00Z", "content": "unique clean row"},
    ]
    expected = {"rec-a": "UUID-A", "rec-b": "UUID-B", "rec-c": "UUID-C"}
    with tempfile.TemporaryDirectory() as tmp:
        db = Path(tmp) / "estate.sqlite"
        con = sqlite3.connect(db)
        con.execute("CREATE TABLE drawers (id TEXT, subject TEXT, "
                    "eventTime TEXT, content TEXT, tombstonedAt TEXT)")
        con.executemany(
            "INSERT INTO drawers VALUES (?, ?, ?, ?, NULL)", rows)
        con.commit()
        con.close()
        seed = Path(tmp) / "seed.json"
        seed.write_text(json.dumps({"records": records}))
        id_map = recover(tmp, seed)
    if id_map != expected:
        sys.exit(f"SELF-TEST FAILED: got {id_map!r}, expected {expected!r}")
    print("recover_idmap self-test PASS: triple tier resolves "
          "prefix-colliding twins deterministically")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true",
                    help="run the deterministic matching-tier regression test")
    ap.add_argument("--estate-dir")
    ap.add_argument("--seed")
    args = ap.parse_args()

    if args.self_test:
        self_test()
        return
    if not args.estate_dir or not args.seed:
        ap.error("--estate-dir and --seed are required (or use --self-test)")

    id_map = recover(args.estate_dir, args.seed)
    if id_map is None:
        sys.exit(1)
    out = Path(args.estate_dir) / "id-map.json"
    out.write_text(json.dumps(id_map, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
