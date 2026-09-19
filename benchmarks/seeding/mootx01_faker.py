#!/usr/bin/env python3
"""mootx01_faker — stand-in for the three mootx01 calls the artifact builder makes.

ARTIFACT_BUILDER_SPEC.md §11. Same arguments, exit codes and output lines the
real binary uses, fake work inside. Lets the assembly line be built and smoke
tested without the product, and it stays as the
fast smoke path and the fault injector.

    mootx01_faker provision   <estate-dir>
    mootx01_faker import      <estate-dir> <records.jsonl>
    mootx01_faker batch-drain <estates.txt>

Output contract (one line per event, stdout):
    provisioned <estate-dir>
    imported <count>
    idle <estate-dir> <size-bytes>          per estate, as it "drains"
    failed <estate-dir> <reason>            then exit 1

Faults come from a JSON file named by MOOTX01_FAKER_CONFIG:
    sleep_ms      int   per-estate sleep in batch-drain (default 2)
    fail_match    str   substring; the first estate path containing it fails
    die_after     int   os._exit(137) after this many estates drained
    stall_match   str   substring; that estate sleeps stall_ms before idle
    stall_ms      int   how long (default 0)

The faker writes only inside the estate directories it is handed.
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import time

# The nine product files of one estate (spec R5). The real binary writes these;
# the faker writes them empty so layout assertions can count them.
ESTATE_FILES = (
    "estate.sqlite",
    "estate.sqlite-shm",
    "estate.sqlite-wal",
    "estate.queue.sqlite",
    "estate.queue.sqlite-shm",
    "estate.queue.sqlite-wal",
    "estate.vectors.vec",
    "encode.drain.lease",
    "id-map.json",
)

# Faker-private files. The builder never reads these; tests do.
RECORDS_FILE = "faker.records"
ENCODED_FILE = "faker.encoded"

# Fake size model: a fixed per-estate overhead plus a per-record cost, so the
# watcher's disk-floor arithmetic sees numbers that grow with content.
BASE_BYTES = 4096
BYTES_PER_RECORD = 512


def load_config() -> dict:
    path = os.environ.get("MOOTX01_FAKER_CONFIG")
    if not path:
        return {}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def provision(estate: pathlib.Path) -> int:
    estate.mkdir(parents=True, exist_ok=True)
    for name in ESTATE_FILES:
        target = estate / name
        if not target.exists():
            target.write_bytes(b"{}" if name.endswith(".json") else b"")
    print(f"provisioned {estate}")
    return 0


def import_records(estate: pathlib.Path, records: pathlib.Path) -> int:
    if not (estate / "estate.sqlite").exists():
        print(f"failed {estate} not-provisioned")
        return 1
    count = 0
    with open(records, encoding="utf-8") as source, \
            open(estate / RECORDS_FILE, "a", encoding="utf-8") as sink:
        for line in source:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            sink.write(record["id"] + "\n")
            count += 1
    print(f"imported {count}")
    return 0


def record_count(estate: pathlib.Path) -> int:
    path = estate / RECORDS_FILE
    if not path.exists():
        return 0
    with open(path, encoding="utf-8") as handle:
        return sum(1 for line in handle if line.strip())


def batch_drain(list_file: pathlib.Path, config: dict) -> int:
    sleep_s = config.get("sleep_ms", 2) / 1000.0
    fail_match = config.get("fail_match")
    die_after = config.get("die_after")
    stall_match = config.get("stall_match")
    stall_s = config.get("stall_ms", 0) / 1000.0

    with open(list_file, encoding="utf-8") as handle:
        estates = [pathlib.Path(p.strip()) for p in handle if p.strip()]

    drained = 0
    for estate in estates:
        text = str(estate)
        if fail_match and fail_match in text:
            print(f"failed {estate} injected-failure")
            sys.stdout.flush()
            return 1
        if stall_match and stall_match in text and stall_s > 0:
            time.sleep(stall_s)
        time.sleep(sleep_s)
        size = BASE_BYTES + BYTES_PER_RECORD * record_count(estate)
        (estate / ENCODED_FILE).write_text(f"{size}\n", encoding="utf-8")
        print(f"idle {estate} {size}")
        sys.stdout.flush()
        drained += 1
        if die_after is not None and drained >= die_after:
            # Simulate a crashed drainer: no cleanup, no further output.
            os._exit(137)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[0])
        return 2
    verb, args = argv[1], argv[2:]
    if verb == "provision" and len(args) == 1:
        return provision(pathlib.Path(args[0]))
    if verb == "import" and len(args) == 2:
        return import_records(pathlib.Path(args[0]), pathlib.Path(args[1]))
    if verb == "batch-drain" and len(args) == 1:
        return batch_drain(pathlib.Path(args[0]), load_config())
    print(f"failed usage {verb}")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
