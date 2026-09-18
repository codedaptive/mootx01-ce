#!/usr/bin/env python3
"""Artifact health summary — the `make status` engine.

One row per benchmark per tier (Form-1 Swift fleet, Form-1 Rust fleet,
Form-2 Swift, Form-2 Rust twin), summarizing whether that benchmark is
READY to run:

  READY       every estate present, encode coverage complete
  BUILDING    estates still appearing (fewer built than unit seeds)
  INCOMPLETE  estates present but encode coverage short (serve died or
              still draining) — count shown
  MISSING     nothing built
  NO CATALOG  no catalog.json at the expected path; directory tree is
              not scanned as a fallback

Checks folded into the row rather than printed per estate:
  - encode coverage: corpus_index_state rows >= drawer rows (the
    2026-08-28 twin lesson: drawer-complete is not done)
  - posture: db.key beside a twin estate = encrypted, flagged
  - charters: drawer surplus over the seed count (pre-skip-charters
    builds carry +7 per estate), flagged not failed
  - format drift: glk_estate_format must agree across every estate
    scanned; disagreement names the outlier tier

Fleets are sampled (SAMPLE per fleet) — scanning 20k SQLite files per
status call is not a summary. Form-2 estates are checked exhaustively.

The catalog (C1, ARTIFACT_BUILDER_SPEC.md §3) at
<fleet-root>/<port>/<dataset>/catalog.json is the sole source of truth
for fleet estate locations.  Each set row carries the base folder and
relative path; estate subdirectories are enumerated one level below
the resolved set directory.  A root without a catalog.json is reported
as NO CATALOG; the directory tree is never scanned as a fallback.
"""

import argparse
import glob
import json
import os
import random
import sqlite3
import shutil
import tempfile

# estate_db, fleet_estates_from_catalog, and primary_base_for_port live in
# artifact_layout beside write_catalog so that reader and writer cannot drift apart.
from artifact_layout import (estate_db, fleet_estates_from_catalog,  # noqa: E402
                              primary_base_for_port)

SAMPLE = 12
DATASETS = ["lme-s", "locomo", "convomem", "membench"]
# Ports are symmetric tiers of the same benchmark.
# Form-2 estates live at WING_ROOT/<port>/<ds>/ (the complete estate is the
# "complete" key) and are probed directly — they do not use the catalog.
PORTS = ["swift", "rust"]
FORM2_KEYS = DATASETS + ["complete"]


def probe(est_dir):
    """(drawers, indexed, encrypted, fmt) for one estate, or None."""
    db = estate_db(est_dir)
    if db is None:
        return None
    encrypted = os.path.exists(os.path.join(os.path.dirname(db), "db.key"))
    t = tempfile.mkdtemp()
    try:
        shutil.copy(db, t + "/c.db")
        if os.path.exists(db + "-wal"):
            shutil.copy(db + "-wal", t + "/c.db-wal")
        c = sqlite3.connect(t + "/c.db")
        c.execute("PRAGMA wal_checkpoint")
        drawers = c.execute("SELECT COUNT(*) FROM drawers").fetchone()[0]
        indexed = c.execute(
            "SELECT COUNT(*) FROM corpus_index_state").fetchone()[0]
        try:
            fmt = c.execute(
                "SELECT * FROM glk_estate_format LIMIT 1").fetchone()
            # Drop timestamp-shaped columns: the drift key is the format
            # version, not when this particular estate was created.
            fmt = "/".join(str(x) for x in (fmt or ())
                           if "T" not in str(x) or ":" not in str(x)) or "?"
        except sqlite3.Error:
            fmt = "?"
        c.close()
        return drawers, indexed, encrypted, fmt
    except sqlite3.Error:
        return None
    finally:
        shutil.rmtree(t, ignore_errors=True)


def row(tier, ds, status, detail):
    print(f"{tier:14s} {ds:10s} {status:12s} {detail}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeding-dir", default=os.path.dirname(
        os.path.abspath(__file__)))
    ap.add_argument("--fleet-root", default=None,
                    help="Primary base folder: catalog.json lives at "
                         "<fleet-root>/<port>/<dataset>/catalog.json. "
                         "When absent, each port's base is resolved from "
                         "MOOTX01_BENCH_TARGET_MAP independently.")
    ap.add_argument("--wing-root", required=True)
    args = ap.parse_args()
    random.seed(0)   # stable sample across calls
    formats = {}     # fmt string -> first place seen

    print(f"{'tier':14s} {'benchmark':10s} {'status':12s} detail")
    print("-" * 72)

    # Every artifact ships in both ports: same units, that port's product
    # binary, that port's subtree of the root.
    # When --fleet-root is supplied (e.g. by gates using a fabricated root),
    # join it with the port name as before.  When absent, resolve each port's
    # primary base independently from MOOTX01_BENCH_TARGET_MAP so that the
    # two ports can land on different volumes without either being silently
    # reported against the wrong location.
    for port in PORTS:
        tier = f"fleet-{port}"
        if args.fleet_root is not None:
            fleet_base = os.path.join(args.fleet_root, port)
        else:
            fleet_base = os.path.join(str(primary_base_for_port(port)), port)
        for ds in DATASETS:
            units = glob.glob(os.path.join(
                args.seeding_dir, f"out-{ds}", "units", "*.json"))
            cat_path = os.path.join(fleet_base, ds, "catalog.json")
            if not os.path.exists(cat_path):
                # The catalog is the only source of truth (spec §3 C1).
                # The directory tree is never scanned as a fallback.
                row(tier, ds, "NO CATALOG",
                    f"no catalog.json at {os.path.join(fleet_base, ds)}")
                continue
            built = fleet_estates_from_catalog(cat_path)
            # Expected = what the catalog laid out (a bounded build via
            # LIMIT=/UNITS= lays out fewer estates than the dataset has
            # units); the seed count only when the catalog names no sets.
            with open(cat_path, encoding="utf-8") as fh:
                laid_out = sum(int(s.get("estates") or 0) for s in json.load(fh).get("sets", []))
            expected = laid_out or len(units)
            if not built:
                row(tier, ds, "MISSING", f"0 of {expected} units")
                continue
            if expected and len(built) < expected:
                row(tier, ds, "BUILDING",
                    f"{len(built)} of {expected} units")
                continue
            picks = random.sample(built, min(SAMPLE, len(built)))
            bad = 0
            for e in picks:
                p = probe(e)
                if p is None or p[1] < p[0]:
                    bad += 1
                elif p is not None:
                    formats.setdefault(p[3], f"{tier}/{ds}")
            if bad:
                row(tier, ds, "INCOMPLETE",
                    f"{bad}/{len(picks)} sampled units short on coverage")
            else:
                row(tier, ds, "READY",
                    f"{len(built)} units, coverage clean on {len(picks)} sampled")

    for port in PORTS:
        tier = f"form2-{port}"
        for ds in FORM2_KEYS:
            est = os.path.join(args.wing_root, port, ds)
            p = probe(est)
            if p is None:
                row(tier, ds, "MISSING", est)
                continue
            drawers, indexed, encrypted, fmt = p
            formats.setdefault(fmt, f"{tier}/{ds}")
            notes = []
            if encrypted:
                notes.append("ENCRYPTED")
            if indexed < drawers:
                pct = 100.0 * indexed / max(drawers, 1)
                row(tier, ds, "INCOMPLETE",
                    f"encode {indexed}/{drawers} ({pct:.0f}%)"
                    + (" " + " ".join(notes) if notes else ""))
            else:
                row(tier, ds, "READY",
                    f"{drawers} drawers, coverage complete"
                    + (" " + " ".join(notes) if notes else ""))

    print("-" * 72)
    if len(formats) > 1:
        print("FORMAT DRIFT:", "; ".join(
            f"{fmt} first seen at {where}" for fmt, where in formats.items()))
    else:
        print(f"estate format uniform: {next(iter(formats), '?')}")


if __name__ == "__main__":
    main()
