#!/usr/bin/env python3
"""Smoke-doctrine shape review — the automated gate checklist.

A smoke test is one short pass that builds a specimen, followed by a
thorough review that the data is EXACTLY the shape it is supposed to be
(operator ruling 2026-08-28). This script IS that review: every check is an exact
equality against the seed file's own numbers. Any inequality = red, exit
nonzero, and the make gates refuse to run the full build.

Usage:
  smoke_verify.py --seed out-locomo/wing-estate.json [--estate-dir DIR]
                  [--legacy-identity-ok] [--partial]

--estate-dir defaults to <seed dir>/estates/<seed stem> (where
import_units.py lands a --file build). Resolves both port layouts
(Swift: estate.sqlite at the root; Rust: databases/default/).
--legacy-identity-ok: accept a manifest ed25519 public key (estates
built before the federate-default-false change; transient catalog
records are non-federating by default in current builds, so new builds
must have none).
--partial: gate-probe mode for a build stopped mid-import — count checks
become "estate <= seed, no foreign rows" instead of strict equality;
encode coverage is reported but not gated (the probe is stopped before
the drain); room/wing/subject checks apply to what landed.
"""

import argparse
import collections
import json
import os
import shutil
import sqlite3
import sys
import tempfile

import artifact_layout as layout

def cow_copy(src, dst):
    """Copy-on-write file copy (standing order 2026-08-28): APFS clone
    via `cp -c`, falling back to a byte copy when cloning is impossible
    (cross-volume, non-APFS). The temp dir callers pass sits BESIDE the
    source (same volume) so the clone path is actually reachable."""
    import shutil, subprocess
    r = subprocess.run(["cp", "-c", src, dst], capture_output=True)
    if r.returncode != 0:
        shutil.copy2(src, dst)


ap = argparse.ArgumentParser()
ap.add_argument("--seed", required=True)
ap.add_argument("--estate-dir", default="")
ap.add_argument("--legacy-identity-ok", action="store_true")
ap.add_argument("--partial", action="store_true")
ap.add_argument("--resumable", action="store_true",
                help="review mode for a rows-complete estate whose encode "
                     "or span coverage is short: every count and shape "
                     "check is exact, but encode coverage is informational "
                     "and span coverage is bounded — the idempotent "
                     "build (import_units.py resume / span-short states) "
                     "converges exactly these two, so such an estate is "
                     "kept, never torn down")
args = ap.parse_args()

seed_path = os.path.abspath(args.seed)
stem = os.path.splitext(os.path.basename(seed_path))[0]
estate_dir = args.estate_dir or os.path.join(
    os.path.dirname(seed_path), "estates", stem)

seed = json.load(open(seed_path))
records = seed.get("records", [])
seed_facts = seed.get("facts") or []
seed_tunnels = seed.get("tunnels") or []

db = os.path.join(estate_dir, "estate.sqlite")
if not os.path.exists(db):
    db = os.path.join(estate_dir, "databases", "default", "estate.sqlite")
if not os.path.exists(db):
    print(f"SMOKE RED: no estate database under {estate_dir}")
    sys.exit(2)

# Work on a checkpointed copy so a live serve's WAL is included and the
# original is never touched. The copy is an APFS clone beside the source
# (same volume — standing order 2026-08-28: CoW is the default copy).
tmpd = tempfile.mkdtemp(prefix=".tmp-verify-", dir=os.path.dirname(db))
for ext in ("", "-wal", "-shm"):
    if os.path.exists(db + ext):
        cow_copy(db + ext, os.path.join(tmpd, "c.db" + ext))
con = sqlite3.connect(os.path.join(tmpd, "c.db"))
con.execute("PRAGMA wal_checkpoint")
q = lambda sql, *p: con.execute(sql, p).fetchall()
one = lambda sql, *p: q(sql, *p)[0][0]



results = []  # (name, ok, detail)


def check(name, ok, detail):
    results.append((name, ok, detail))


n_drawers = one("SELECT COUNT(*) FROM drawers")
eq = (lambda a, b: a <= b) if args.partial else (lambda a, b: a == b)
rel = "<=" if args.partial else "=="

check("drawers == seed records", eq(n_drawers, len(records)),
      f"{n_drawers} {rel} {len(records)}")

n_charter = one("SELECT COUNT(*) FROM drawers WHERE id LIKE '00000000-%'")
check("zero charter sentinel ids", n_charter == 0, f"found {n_charter}")

n_facts = one("SELECT COUNT(*) FROM kg_facts")
check("kg_facts == seed facts", eq(n_facts, len(seed_facts)),
      f"{n_facts} {rel} {len(seed_facts)}")

n_tunnels = one("SELECT COUNT(*) FROM tunnels")
check("tunnels == seed tunnels", eq(n_tunnels, len(seed_tunnels)),
      f"{n_tunnels} {rel} {len(seed_tunnels)}")

n_indexed = one("SELECT COUNT(*) FROM corpus_index_state")
if args.partial or args.resumable:
    # A stopped probe has not drained, and a resumable estate's encode
    # backfill is exactly what the idempotent build converges; coverage
    # is informational only in both modes.
    check("encode coverage (informational)", True,
          f"{n_indexed}/{n_drawers} indexed — not gated in this mode")
else:
    check("corpus_index_state == drawers", n_indexed == n_drawers,
          f"{n_indexed} == {n_drawers}")

# Room and wing distribution: exact per-name counts against the seed's
# own projection. The drawer's parent node is its room, or a chest under
# its room (depth 3, ADR-026) once the room has been re-binned; the
# room's parent is its wing. In --partial mode the landed rows must still
# name ONLY rooms/wings from the projection (no foreign names) and no
# room may exceed its seed count.
seed_rooms = collections.Counter(r["room"] for r in records)
seed_wings = collections.Counter(r["wing"] for r in records)
ROOM_OF_PARENT = (
    "JOIN nodes p ON d.parent_node_id = p.id "
    "JOIN nodes r ON r.id = CASE WHEN p.depth = 3 THEN p.parent_id ELSE p.id END ")
est_rooms = collections.Counter(dict(q(
    "SELECT r.display_name, COUNT(*) FROM drawers d " + ROOM_OF_PARENT + "GROUP BY r.display_name")))
est_wings = collections.Counter(dict(q(
    "SELECT w.display_name, COUNT(*) FROM drawers d " + ROOM_OF_PARENT +
    "JOIN nodes w ON r.parent_id = w.id GROUP BY w.display_name")))


def dist_ok(est, exp):
    foreign = [k for k in est if k not in exp]
    if foreign:
        return False, f"foreign names: {foreign[:5]}"
    if args.partial:
        over = [k for k in est if est[k] > exp[k]]
        return not over, (f"over-count: {over[:5]}" if over else
                          f"{len(est)}/{len(exp)} names, all within seed counts")
    if est != exp:
        diff = [(k, est.get(k, 0), exp.get(k, 0))
                for k in set(est) | set(exp) if est.get(k, 0) != exp.get(k, 0)]
        return False, f"mismatch (name, estate, seed): {diff[:5]}"
    return True, f"{len(exp)} names, counts identical"


ok, detail = dist_ok(est_rooms, seed_rooms)
check("room distribution matches projection", ok, detail)
ok, detail = dist_ok(est_wings, seed_wings)
check("wing distribution matches projection", ok, detail)

# Subject wrapper verbatim on a spread sample. In --partial mode a
# sampled record may not have landed yet; sample only landed content by
# matching seed subjects against the estate, requiring every LANDED
# subject lookup to hit.
step = max(1, len(records) // 20)
sample = records[::step][:20]
subj_hits, subj_miss = 0, []
for r in sample:
    n = one("SELECT COUNT(*) FROM drawers WHERE subject = ?", r["subject"])
    if n:
        subj_hits += 1
    else:
        subj_miss.append(r["subject"][:50])
if args.partial:
    check("subject wrapper verbatim (sampled)", subj_hits > 0,
          f"{subj_hits}/{len(sample)} sampled subjects present "
          "(partial build — misses may simply not have landed)")
else:
    check("subject wrapper verbatim (sampled)", not subj_miss,
          f"{subj_hits}/{len(sample)} found" +
          (f"; missing e.g. {subj_miss[:2]}" if subj_miss else ""))

# Plaintext posture: no db.key beside the estate, and the file opens as
# plain SQLite (header check).
keyfile = os.path.join(os.path.dirname(db), "db.key")
hdr = open(db, "rb").read(16)
check("plaintext posture", not os.path.exists(keyfile)
      and hdr.startswith(b"SQLite format 3"),
      f"db.key present: {os.path.exists(keyfile)}; "
      f"header: {hdr[:15].decode(errors='replace')!r}")

# Estate format row present and current.
try:
    fmt = q("SELECT * FROM glk_estate_format LIMIT 1")[0]
    check("estate format current", str(fmt[0]) == "estate-format",
          "|".join(str(x) for x in fmt))
except Exception as e:  # noqa: BLE001 — any read failure is a red
    check("estate format current", False, f"unreadable: {e}")

# Identity: a federate-false build carries no ed25519 public key.
n_pub = one("SELECT COUNT(*) FROM manifest WHERE key='ed25519_public_key'")
if args.legacy_identity_ok:
    check("identity (legacy ok)", True, f"manifest pubkey rows: {n_pub}")
else:
    check("no federation identity minted", n_pub == 0,
          f"manifest pubkey rows: {n_pub} (expected 0 — "
          "transient record is non-federating by default)")

# ── Span encoder coverage. Two checks:                                           ────────
#   12. exactly one active encoder is registered in encoder_models — a
#       build whose resident serve never registered the encoder is a
#       wiring regression.
#   13. every non-empty live drawer has a span-vector row (kind=2) for the
#       active encoder at the current serving generation. The resident HTTP
#       serve drains to full coverage before the estate is called READY.
#       In --partial (probe) mode coverage is bounded, not exact.
n_active_encoders = one(
    "SELECT COUNT(*) FROM encoder_models WHERE is_active != 0")
check("active encoder registered (exactly one)", n_active_encoders == 1,
      f"active encoder_models rows: {n_active_encoders} (expected 1)")
n_eligible = one(
    "SELECT COUNT(*) FROM drawers "
    "WHERE tombstonedAt IS NULL AND content != ''")
n_span_covered = one(layout.SPAN_COVERED_SQL)
# Bounded in --partial and --resumable (the span-short resume path
# drains the remainder); exact otherwise. In bounded mode a zero-coverage
# estate is always RED — coverage > 0 is required even in probe mode.
span_bounded = args.partial or args.resumable
if span_bounded:
    # A zero-coverage estate has not started encoding: RED regardless of mode.
    span_ok = n_span_covered > 0 and n_span_covered <= n_eligible
else:
    span_ok = n_span_covered == n_eligible
check("span coverage matches eligible drawers",
      span_ok,
      f"{n_span_covered} {'<=' if span_bounded else '=='} {n_eligible} "
      f"eligible drawers")

con.close()
shutil.rmtree(tmpd, ignore_errors=True)

width = max(len(n) for n, _, _ in results)
red = 0
print(f"smoke shape review — seed {os.path.basename(seed_path)} "
      f"({len(records)} records), estate {estate_dir}")
for name, ok, detail in results:
    mark = "PASS" if ok else "FAIL"
    red += 0 if ok else 1
    print(f"  [{mark}] {name:{width}s}  {detail}")
print(f"smoke {'GREEN' if red == 0 else f'RED — {red} failing check(s)'}")
sys.exit(0 if red == 0 else 1)
