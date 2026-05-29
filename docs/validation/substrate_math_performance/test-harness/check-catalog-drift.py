#!/usr/bin/env python3
"""
check-catalog-drift.py — primitive-CRC documentation drift detector.

Verifies that the human-readable CRC summary documents are in sync with
the actual measured CRCs from the canonical vector files. Runs before
tagging a release; wire into CI to make CRC drift impossible.

The failure mode this catches: when the harness regenerates canonical
vectors, the per-primitive CRC changes, but the summary documents that
quote those CRCs don't get resynced. The selection state (the reference
implementations) stays correct, but operators reading the docs see
stale fingerprints. The drift this script was created to repair had
exactly this shape — 15 entries in the cookbook and harness-reference
disagreed with the vector files, plus 3 in the catalog.

Source of truth: the `crc expected` line emitted by validate-vectors
when reading vectors/<name>.json. That CRC is the canonical fingerprint
of the reference's output on the locked test cases — what the harness
gate enforces.

Documents checked:
  1. primitive-catalog.md
       (test-harness/primitive-catalog.md)
  2. HARNESS_REFERENCE_v1.0
       (docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md)
  3. GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0 §18.2
       (docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md)

Exit status:
  0 — all CRCs in all three documents match vector files
  1 — at least one CRC drift or required-document completeness gap
  2 — invocation / environment error
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# ---------- locate paths from the script's own location ----------

SCRIPT_DIR  = Path(__file__).resolve().parent
HARNESS_DIR = SCRIPT_DIR
REPO_ROOT   = HARNESS_DIR.parents[3]   # …/test-harness → …/substrate_math_performance → …/validation → …/docs → repo root

VECTORS_DIR = HARNESS_DIR / "vectors"
CATALOG     = HARNESS_DIR / "primitive-catalog.md"
HARNESS_REF = REPO_ROOT / "docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md"
COOKBOOK    = REPO_ROOT / "docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md"
VALIDATE    = HARNESS_DIR / "swift/.build/debug/validate-vectors"

# ---------- pretty output (color iff tty and NO_COLOR unset) ----------

USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
def c(code: str, s: str) -> str:
    return f"\033[{code}m{s}\033[0m" if USE_COLOR else s
red    = lambda s: c("31", s)
green  = lambda s: c("32", s)
yellow = lambda s: c("33", s)
dim    = lambda s: c("2",  s)

def err(msg: str)  -> None: print(f"{red('error:')} {msg}", file=sys.stderr)
def warn(msg: str) -> None: print(f"{yellow('warn:')} {msg}", file=sys.stderr)

# ---------- sanity checks ----------

for path in (VECTORS_DIR, CATALOG, HARNESS_REF, COOKBOOK):
    if not path.exists():
        err(f"missing: {path}")
        sys.exit(2)

if not (VALIDATE.exists() and os.access(VALIDATE, os.X_OK)):
    warn("validate-vectors not built — building now")
    try:
        subprocess.run(
            ["swift", "build"], cwd=HARNESS_DIR / "swift", check=True,
            capture_output=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        err(f"validate-vectors build failed: {e}")
        err(f"run `cd {HARNESS_DIR/'swift'} && swift build` to see details")
        sys.exit(2)

# ---------- step 1: gather truth from vector files ----------

CRC_RE = re.compile(r"^\s*crc expected:\s*(0x[0-9a-fA-F]{8})\s*$", re.MULTILINE)

def measure_truth() -> dict[str, str]:
    truth: dict[str, str] = {}
    for vec in sorted(VECTORS_DIR.glob("*.json")):
        name = vec.stem
        proc = subprocess.run(
            [str(VALIDATE), str(vec)], capture_output=True, text=True,
        )
        output = proc.stdout + proc.stderr
        m = CRC_RE.search(output)
        if not m:
            err(f"could not extract CRC from validate-vectors on {vec.name}")
            err(f"output was:\n{output}")
            sys.exit(2)
        truth[name] = m.group(1)
    return truth

# ---------- step 2: extract claimed CRCs from each document ----------

def catalog_crc(text: str, name: str) -> str | None:
    """Format: | `name` | `0xHEX` | §x | ...   (markdown table row)
       Also matches the alias form `| `name` (aka `other`) | …`
       used for `lattice` (aka `udc_tree_distance`)."""
    pattern = (
        rf"^\|\s*`{re.escape(name)}`"      # leading | + `name`
        rf"(?:\s*\(aka[^)]*\))?"          # optional " (aka `xxx`)"
        rf"\s*\|\s*`(0x[0-9a-fA-F]{{8}})`\s*\|"
    )
    m = re.search(pattern, text, re.MULTILINE)
    return m.group(1) if m else None

def harness_ref_crc(text: str, name: str) -> str | None:
    """Format: #### `name` — §x — CRC `0xHEX`"""
    pattern = rf"^####\s+`{re.escape(name)}`[^\n]*?CRC\s+`(0x[0-9a-fA-F]{{8}})`"
    m = re.search(pattern, text, re.MULTILINE)
    return m.group(1) if m else None

def cookbook_crc(text: str, name: str) -> str | None:
    """Format (§18.2 ASCII table): '  name              CRC 0xHEX   §x'
       Also matches the alias form '  name (aka other_name)
                              CRC 0xHEX'  with possible line-wrap,
       used for 'lattice (aka udc_tree_distance)'.
       Anchor on whitespace+name+(boundary)+...+CRC so 'hamming'
       doesn't accidentally match a 'hamming_nn' row."""
    # Boundary char after name: whitespace OR opening paren of alias
    pattern = (
        rf"(?:^|\s){re.escape(name)}"
        rf"(?:\s+\(aka[^)]*\))?"   # optional " (aka ...)"
        rf"\s+CRC\s+(0x[0-9a-fA-F]{{8}})"
    )
    m = re.search(pattern, text, re.MULTILINE | re.DOTALL)
    return m.group(1) if m else None

# ---------- step 3: compare and report ----------

def main() -> int:
    truth = measure_truth()
    print(dim(f"collected {len(truth)} truth CRCs from {VECTORS_DIR}"))
    print()

    catalog_text     = CATALOG.read_text()
    harness_ref_text = HARNESS_REF.read_text()
    cookbook_text    = COOKBOOK.read_text()

    print(f"{'primitive':<26} {'vectors':<12} {'catalog':<12} {'harness-ref':<12} {'cookbook§18':<12} result")
    print("-" * 86)

    n_clean = n_drift = n_gap = n_warn = 0

    for name in sorted(truth):
        t = truth[name]
        cat_v = catalog_crc(catalog_text, name)
        hr_v  = harness_ref_crc(harness_ref_text, name)
        cb_v  = cookbook_crc(cookbook_text, name)

        result = green("ok")
        status = "clean"

        # Drift: a doc has a CRC and it doesn't match truth
        for v in (cat_v, hr_v, cb_v):
            if v is not None and v != t:
                result = red("DRIFT")
                status = "drift"
                break

        # Gap: a required doc is missing the row
        if status == "clean":
            if cat_v is None:
                result = red("GAP (catalog)")
                status = "gap"
            elif hr_v is None:
                result = red("GAP (harness-ref)")
                status = "gap"
            elif cb_v is None:
                # cookbook §18.2 gaps are pre-existing — warn, don't fail
                result = yellow("gap (cookbook §18.2)")
                status = "warn"

        print(f"{name:<26} {t:<12} {(cat_v or '—'):<12} {(hr_v or '—'):<12} {(cb_v or '—'):<12} {result}")

        if status == "clean": n_clean += 1
        elif status == "warn": n_clean += 1; n_warn += 1
        elif status == "drift": n_drift += 1
        elif status == "gap": n_gap += 1

    print()
    summary = (
        f"summary: {green(f'{n_clean} clean')}, "
        f"{red(f'{n_drift} drift')}, "
        f"{red(f'{n_gap} gap')}"
    )
    if n_warn:
        summary += f" ({yellow(f'{n_warn} cookbook §18.2 gap — non-fatal')})"
    print(summary)

    if n_drift > 0 or n_gap > 0:
        print()
        print(red("FAIL") + " — CRC drift or completeness gap detected.")
        print()
        print("next steps:")
        print("  - if a vector was regenerated: update the doc CRC(s) to match")
        print("  - if a doc was hand-edited:    revert the doc, the vector is truth")
        print("  - if a primitive is missing:   add the catalog / harness-ref row")
        return 1

    print(green("PASS") + " — all CRC documentation is in sync with vector files.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
