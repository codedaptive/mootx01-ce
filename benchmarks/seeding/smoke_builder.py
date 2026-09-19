#!/usr/bin/env python3
"""Assembly-line smoke test for the artifact builder (ARTIFACT_BUILDER_SPEC.md §8).

Proves every station hands off to the next. Never proves content. Runs on
the faker by default; pass --exe to run the same line on a real binary.

    smoke_builder.py --port swift [--exe PATH]

Reads the checked-in config smoke/<port>.json (no paths in it), writes a
trivial pass-through source and a two-entry target map into the gitignored
scratch folder, builds, then asserts the §8 list. Stores a tree summary so
the other port's run can be compared field for field.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import sys
import time

import artifact_build as build
import artifact_import as imp
import artifact_layout as layout
import artifact_watch as watch

HERE = pathlib.Path(__file__).resolve().parent
# Gitignored via seeding/.gitignore. MOOTX01_SMOKE_SCRATCH relocates it so a
# test can run the line without touching the folder a real smoke is using.
SCRATCH = pathlib.Path(os.environ.get("MOOTX01_SMOKE_SCRATCH") or HERE / "scratch")
FAKER = HERE / "mootx01_faker.py"
DATASET = "smoke"


def write_passthrough_source(root: pathlib.Path, sets: int, units_per_set: int,
                             records_per_unit: int) -> pathlib.Path:
    """The simplest possible input: one-line records with ids. Not a benchmark."""
    (root / "units").mkdir(parents=True)
    (root / "dataset.json").write_text(json.dumps(
        {"room_rule": "smoke: every record in room 'line'", "overlap": False}))
    for n in range(sets * units_per_set):
        unit = f"unit{n:03d}"
        with open(root / "units" / f"{unit}.jsonl", "w", encoding="utf-8") as handle:
            for r in range(records_per_unit):
                handle.write(json.dumps({"id": f"{unit}-r{r}", "body": f"line {r} of {unit}",
                                         "room": "line", "shape": "line",
                                         "gold": {f"q-{unit}": "gold" if r == 0 else "distractor"}}) + "\n")
    return root


def summarize(bases: list[pathlib.Path], port: str, exe_kind: str) -> dict:
    """Port-independent view of the tree and catalog for cross-port comparison.
    The faker writes a fixed ten-file estate that the comparison checks; a
    product estate's files are the product's own (and differ per port), so
    only state, record count, maps and catalog are compared for those."""
    out: dict = {"exe": exe_kind, "sets": {}, "catalog": None}
    for b in bases:
        d = b / port / DATASET
        if not d.is_dir():
            continue
        for sdir in sorted(list(d.glob("estate_set*")) + [d / layout.AGGREGATE_SET]):
            if not sdir.is_dir():
                continue
            estates = {}
            for e in sorted(p for p in sdir.iterdir() if p.is_dir()):
                addr = layout.read_address(e)
                estates[e.name] = {"state": addr["state"], "records": addr["record_count"]}
                if exe_kind == "faker":
                    estates[e.name]["files"] = sorted(p.name for p in e.iterdir()
                                                      if p.name not in ("faker.records", "faker.encoded"))
            out["sets"][sdir.name] = {"base_index": bases.index(b), "estates": estates,
                                      "maps": sorted(p.name for p in sdir.glob("partition_map*"))}
        cat = d / "catalog.json"
        if cat.exists():
            doc = json.loads(cat.read_text())
            out["catalog"] = [{k: r[k] for k in ("name", "estates", "state")} for r in doc["sets"]]
    return out


def write_questions(port: str, log=print) -> pathlib.Path:
    """Write a locomo-format questions.jsonl for the smoke set.

    Each unit estate (aggregate excluded) contributes one question whose
    sample_id equals the estate directory name (e.g. "unit000").

    artifact-recall --dataset locomo uses sample_id as the unit stem when
    resolving via --catalog, so sample_id = "unit000" routes the binary's
    resolver to the unit000 estate.  The aggregate set is excluded because
    it has no per-unit catalog row and the unit-scale resolver skips it.

    Output: scratch/<port>/questions.jsonl (one JSON object per line).
    """
    cat_path = SCRATCH / port / "base-primary" / port / DATASET / "catalog.json"
    if not cat_path.exists():
        raise FileNotFoundError(f"smoke catalog not found at {cat_path}; "
                                "run smoke_builder first")
    estate_dirs = layout.fleet_estates_from_catalog(str(cat_path))
    # Exclude the aggregate set: its parent directory is named AGGREGATE_SET.
    unit_dirs = [d for d in estate_dirs
                 if pathlib.Path(d).parent.name != layout.AGGREGATE_SET]
    questions_path = SCRATCH / port / "questions.jsonl"
    with open(questions_path, "w", encoding="utf-8") as fh:
        for estate_dir in unit_dirs:
            uid = pathlib.Path(estate_dir).name  # e.g. "unit000"
            fh.write(json.dumps({
                "sample_id": uid,
                "wing": "line",
                "question": f"test {uid}",
                "answer_session_ids": [],
            }) + "\n")
    log(f"[smoke] wrote {len(unit_dirs)} locomo questions to {questions_path}")
    return questions_path


def run(port: str, exe: pathlib.Path, log=print) -> int:
    cfg = json.loads((HERE / "smoke" / f"{port}.json").read_text())
    scratch = SCRATCH / port
    if scratch.exists():
        shutil.rmtree(scratch)
    scratch.mkdir(parents=True)
    started = time.monotonic()

    projection = write_passthrough_source(scratch / "projection", cfg["sets"],
                                          cfg["units_per_set"], cfg["records_per_unit"])
    bases = [scratch / "base-primary", scratch / "base-secondary"]
    # The faker's estates are a few bytes; a product estate is megabytes. The
    # primary cap must hold exactly one set either way, so it is sized per exe.
    per_estate = cfg["bytes_per_estate_estimate"] if exe == FAKER else cfg.get(
        "bytes_per_product_estate_estimate", 64 * 1024 * 1024)
    # Primary holds exactly one set's estimate, so set 2 and the aggregate fail over.
    target_map = {port: {DATASET: [
        {"path": str(bases[0]), "capacity_bytes": per_estate * cfg["units_per_set"]},
        {"path": str(bases[1])}]}}
    (scratch / "target-map.json").write_text(json.dumps(target_map, indent=2))
    target = layout.TargetMap.load(scratch / "target-map.json", port, DATASET, 0)

    rc = build.build(exe=exe, port=port, dataset=DATASET, projection_dir=projection, target=target,
                     set_size=cfg["units_per_set"], watchers=cfg["watchers"],
                     bytes_per_estate=per_estate, aggregate_bytes=per_estate,
                     stale=cfg["stale_seconds"], poll=0.05,
                     template=scratch / "template", log_dir=scratch / "logs", log=log)
    elapsed = time.monotonic() - started
    failures = [] if rc == 0 else [f"build exit {rc}"]

    # §8 assertions beyond the build's own done check.
    summary = summarize(bases, port, "faker" if exe == FAKER else "product")
    expected_sets = [f"estate_set{n}" for n in range(1, cfg["sets"] + 1)] + [layout.AGGREGATE_SET]
    if sorted(summary["sets"]) != sorted(expected_sets):
        failures.append(f"sets {sorted(summary['sets'])} != {sorted(expected_sets)}")
    for name, s in summary["sets"].items():
        if s["maps"] != [watch.DONE_MAP]:
            failures.append(f"{name}: maps {s['maps']}")
        for unit, e in s["estates"].items():
            if "files" in e:      # the faker's fixed ten-file estate (spec §8)
                ten_plus = set(imp_files()) | {"address.json", imp.LEDGER_FILE}
                if name == layout.AGGREGATE_SET:
                    ten_plus -= {imp.LEDGER_FILE}
                if not ten_plus <= set(e["files"]):
                    failures.append(f"{name}/{unit}: files {sorted(ten_plus - set(e['files']))} missing")
            if e["state"] != "encoded":
                failures.append(f"{name}/{unit}: state {e['state']}")
    if summary["sets"].get("estate_set1", {}).get("base_index") != 0:
        failures.append("estate_set1 not in primary")
    if summary["sets"].get("estate_set2", {}).get("base_index") != 1:
        failures.append("estate_set2 did not fail over to secondary")
    if not summary["catalog"] or {r["state"] for r in summary["catalog"]} != {"encoded"}:
        failures.append(f"catalog states {summary['catalog']}")
    if elapsed > cfg["max_seconds"]:
        failures.append(f"elapsed {elapsed:.1f}s > {cfg['max_seconds']}s")

    (scratch / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
    # Write the questions file used by the measure-smoke Makefile target.
    # Runs unconditionally (catalog may exist even when §8 assertions fail).
    try:
        write_questions(port, log=log)
    except FileNotFoundError as exc:
        failures.append(str(exc))
    other = SCRATCH / ("rust" if port == "swift" else "swift") / "summary.json"
    if other.exists():
        theirs = json.loads(other.read_text())
        if theirs.get("exe") != summary["exe"]:
            log(f"[smoke] other port's run used the {theirs.get('exe')}; no cross-port comparison")
        elif theirs != summary:
            failures.append("tree/catalog differs from the other port's run")
        else:
            log("[smoke] tree and catalog identical to the other port's run")

    for f in failures:
        log(f"[smoke] FAIL {f}")
    log(f"[smoke] {port}: {'PASS' if not failures else 'FAIL'} in {elapsed:.1f}s "
        f"({cfg['sets']} sets x {cfg['units_per_set']} units x {cfg['records_per_unit']} records, "
        f"{cfg['watchers']} watchers)")
    return 0 if not failures else 1


def imp_files():
    import mootx01_faker
    return mootx01_faker.ESTATE_FILES


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", required=True, choices=("swift", "rust"))
    ap.add_argument("--exe", type=pathlib.Path, default=FAKER)
    a = ap.parse_args(argv[1:])
    return run(a.port, a.exe)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
