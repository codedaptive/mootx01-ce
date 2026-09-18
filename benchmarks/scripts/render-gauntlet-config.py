#!/usr/bin/env python3
"""Render the checked-in gauntlet template with external runtime paths."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shlex


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--work-root", required=True)
    args = parser.parse_args()

    template = pathlib.Path(args.template)
    output = pathlib.Path(args.output)
    binary = pathlib.Path(args.binary).resolve()
    work = pathlib.Path(args.work_root).resolve()
    tag = hashlib.sha256(str(work).encode()).hexdigest()[:12]
    data_dir = pathlib.Path("/tmp") / f"mootx01-benchmark-gauntlet-{tag}"

    doc = json.loads(template.read_text())
    # The scratch directory is a transient catalog record (`--db <dir>`):
    # plaintext by the product's rule, identity in memory, never a catalog entry.
    command = (
        "MOOTX01_VAULT=1 MOOTX01_SUBJECT_RIDER=0 "
        f"{shlex.quote(str(binary))} serve --db {shlex.quote(str(data_dir))}"
    )
    for endpoint in ("source", "target"):
        doc[endpoint]["transport"]["stdio"]["command"] = command

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(doc, indent=2) + "\n")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
