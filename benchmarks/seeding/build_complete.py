#!/usr/bin/env python3
"""Complete-aggregate builder — one seed file holding every dataset.

Unions the per-dataset aggregates (out-*/aggregate.json) into
out-complete/aggregate.json. Record ids get a dataset prefix so build
plumbing stays collision-free; rooms and subjects are untouched
(provenance-blind — nothing benchmark-shaped is added). Facts' record_id
and tunnels' from/to are remapped with the same prefix.
"""

import argparse
import json
from collections import Counter
from pathlib import Path

from seed_lme_s import wing_for_room

# Per-set Form-2 file: lme = the deduped beast (aggregate.json, life
# wings); the others = wing estates. The complete estate strips instance
# wings back to life wings (one flagship life-shaped artifact).
SETS = {"out-lme-s": "aggregate.json", "out-locomo": "wing-estate.json",
        "out-convomem": "wing-estate.json", "out-membench": "wing-estate.json"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True,
                        help="external seeding work directory")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    records, facts, tunnels = [], [], []
    seen = set()
    per_set = {}
    for s, fname in SETS.items():
        path = root / s / fname
        if not path.exists():
            print(f"SKIP {s}: no aggregate.json")
            continue
        d = json.loads(path.read_text())
        prefix = s.removeprefix("out-") + "/"
        n = 0
        for r in d.get("records", []):
            rid = prefix + r["id"]
            if rid in seen:
                continue
            seen.add(rid)
            merged = {**r, "id": rid}
            merged["wing"] = wing_for_room(merged.get("room", "general"))
            records.append(merged)
            n += 1
        for f in d.get("facts", []):
            facts.append({**f, "record_id": prefix + f["record_id"]})
        for t in d.get("tunnels", []):
            tunnels.append({**t, "from": prefix + t["from"],
                            "to": prefix + t["to"]})
        per_set[s] = n

    out = root / "out-complete"
    out.mkdir(exist_ok=True)
    doc = {"format_version": 1, "name": "complete-aggregate",
           "records": records}
    if facts:
        doc["facts"] = facts
    if tunnels:
        doc["tunnels"] = tunnels
    (out / "aggregate.json").write_text(
        json.dumps(doc, ensure_ascii=False, indent=1))

    rooms = Counter(r["room"] for r in records)
    print(f"records: {len(records)}  facts: {len(facts)}  "
          f"tunnels: {len(tunnels)}")
    for s, n in per_set.items():
        print(f"  {s:14s} {n:7d}")
    print("\nroom distribution:")
    for room, n in rooms.most_common():
        print(f"  {room:10s} {n:7d}  {100*n/len(records):5.1f}%")


if __name__ == "__main__":
    main()
