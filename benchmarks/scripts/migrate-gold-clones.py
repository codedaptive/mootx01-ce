#!/usr/bin/env python3
"""migrate-gold-clones.py — one-time lift of per-family gold clone entries
into their primary cache entries (same-table ruling, operator ruling 2026-08-26).

For every `<runKey>-gold_<label>/<unit>` clone entry in the cache dir:
  1. Require the primary `<runKey>/<unit>` entry to exist (warn + keep the
     clone otherwise — never delete unmigrated inference).
  2. ATTACH the clone estate and INSERT OR IGNORE its adornment_minters row
     (parked, is_active=0) and adornments rows into the primary estate.
  3. Verify the primary now holds at least the clone's row count for that
     minter_id; on shortfall, keep the clone and report.
  4. Copy the clone's mint-sidecar.json to the primary as
     mint-sidecar-<label>.json (the resume-skip marker).
  5. Delete the clone unit dir once verified; delete the clone runKey dir
     when empty.

Idempotent: re-runs skip rows already present and re-verify counts.
Usage: migrate-gold-clones.py <cache-dir> [--dry-run]
"""
import os
import shutil
import sqlite3
import sys

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cache = sys.argv[1]
    dry = "--dry-run" in sys.argv
    lifted = kept = 0
    for run_key in sorted(os.listdir(cache)):
        if "-gold_" not in run_key:
            continue
        naked_key, label = run_key.rsplit("-gold_", 1)
        clone_root = os.path.join(cache, run_key)
        if not os.path.isdir(clone_root):
            continue
        for unit in sorted(os.listdir(clone_root)):
            clone_unit = os.path.join(clone_root, unit)
            if not os.path.isdir(clone_unit):
                continue
            clone_db = os.path.join(clone_unit, "estate", "estate.sqlite")
            primary_unit = os.path.join(cache, naked_key, unit)
            primary_db = os.path.join(primary_unit, "estate", "estate.sqlite")
            if not os.path.isfile(clone_db):
                print(f"KEEP (no clone db): {run_key}/{unit}")
                kept += 1
                continue
            if not os.path.isfile(primary_db):
                print(f"KEEP (no primary): {run_key}/{unit}")
                kept += 1
                continue
            cdb = sqlite3.connect(clone_db)
            want = cdb.execute(
                "SELECT count(*) FROM adornments WHERE minter_id=?", (label,)
            ).fetchone()[0]
            cdb.close()
            if dry:
                print(f"DRY: would lift {want} rows {run_key}/{unit}")
                continue
            db = sqlite3.connect(primary_db)
            db.execute("ATTACH DATABASE ? AS clone", (clone_db,))
            db.execute(
                """INSERT OR IGNORE INTO adornment_minters
                   (id,name,family,model_id,model_version,prompt_digest,parameters,is_active,ext)
                   SELECT id,name,family,model_id,model_version,prompt_digest,parameters,0,ext
                   FROM clone.adornment_minters WHERE id=?""", (label,))
            db.execute(
                """INSERT OR IGNORE INTO adornments (drawer_id,minter_id,text)
                   SELECT drawer_id,minter_id,text FROM clone.adornments
                   WHERE minter_id=?""", (label,))
            db.commit()
            have = db.execute(
                "SELECT count(*) FROM adornments WHERE minter_id=?", (label,)
            ).fetchone()[0]
            db.execute("DETACH DATABASE clone")
            db.close()
            if have < want:
                print(f"KEEP (shortfall {have}<{want}): {run_key}/{unit}")
                kept += 1
                continue
            side = os.path.join(clone_unit, "mint-sidecar.json")
            if os.path.isfile(side):
                shutil.copyfile(
                    side, os.path.join(primary_unit, f"mint-sidecar-{label}.json"))
            shutil.rmtree(clone_unit)
            lifted += 1
            print(f"LIFTED {want} rows: {run_key}/{unit}")
        if not dry and os.path.isdir(clone_root) and not os.listdir(clone_root):
            os.rmdir(clone_root)
            print(f"REMOVED empty clone key: {run_key}")
    print(f"done: lifted={lifted} kept={kept}")
    return 0 if kept == 0 else 2

if __name__ == "__main__":
    sys.exit(main())
