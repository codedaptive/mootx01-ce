#!/usr/bin/env python3
"""Pre-push guard: block pushes that carry unsanctioned docs content.

Invoked by .githooks/pre-push (git passes ref updates on stdin). For
every commit about to be pushed, the TREE OF THAT COMMIT is inspected
(not the working directory), so a clean checkout cannot mask a dirty
ref. The push is rejected if any violation is found; the offending
paths are listed for cleanup.

Policy (this repo is PUBLIC — docs/ is user-facing documentation only):

1. docs/ may contain only the sanctioned top-level entries listed in
   SANCTIONED_DOCS. Anything else — a new subdirectory or stray file —
   blocks the push. Adding a new sanctioned directory is a deliberate
   act: edit this list in the same commit that introduces the
   directory, and say why in the commit message.

2. Internal engineering work-product is blocked ANYWHERE in the tree by
   name shape: blast-radius reports, mission completion/status notes,
   and any docs_internal/ path (that tree belongs to the private
   internal-docs repo, never here).
"""

import subprocess
import sys

# Sanctioned top-level entries under docs/. Keep alphabetized.
SANCTIONED_DOCS = {
    "README.md",
    "articles",
    "assets",
    "concepts",
    "decisions",
    "engineering",
    "guide",
    "reference",
    "start-here",
    "templates",
    "validation",
}

ZERO_SHA = "0" * 40


def tree_paths(sha: str) -> list[str]:
    out = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", sha],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.splitlines()


def violations(paths: list[str]) -> list[str]:
    bad = []
    for p in paths:
        parts = p.split("/")
        # Rule 1: docs/ allowlist.
        if parts[0] == "docs" and len(parts) > 1:
            if parts[1] not in SANCTIONED_DOCS:
                bad.append(p)
                continue
        # Rule 2: internal work-product shapes, anywhere in the tree.
        base = parts[-1]
        if "docs_internal" in parts:
            bad.append(p)
        elif "blast_radius" in parts:
            bad.append(p)
        elif base.endswith("_BLAST_RADIUS.md") or "_BLAST_RADIUS" in base:
            bad.append(p)
        elif base.startswith("COMPLETION_") or base.endswith("_COMPLETION.md"):
            bad.append(p)
        elif parts[0] == "docs" and len(parts) > 1 and parts[1] == "status":
            bad.append(p)
    return bad


def main() -> int:
    failed = False
    for line in sys.stdin:
        fields = line.split()
        if len(fields) != 4:
            continue
        _local_ref, local_sha, _remote_ref, _remote_sha = fields
        if local_sha == ZERO_SHA:  # branch deletion — nothing to scan
            continue
        bad = violations(tree_paths(local_sha))
        if bad:
            failed = True
            print(f"PUSH BLOCKED — unsanctioned docs content in {local_sha[:12]}:",
                  file=sys.stderr)
            for p in sorted(set(bad)):
                print(f"  {p}", file=sys.stderr)
    if failed:
        print(
            "\nInternal work-product (blast-radius reports, completion/status "
            "notes, docs_internal content) belongs in the private internal-docs "
            "tree, never in this public repo. Remove the files from the tree "
            "(relocating content first) and push again. To sanction a NEW docs/ "
            "subdirectory, add it to SANCTIONED_DOCS in "
            "scripts/prepush_docs_guard.py in the same commit.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
