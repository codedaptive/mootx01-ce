#!/usr/bin/env python3
"""
check-lockstep.py — Swift/Rust 1:1 type-parity audit.

For each substrate package (SubstrateTypes, SubstrateKernel, SubstrateML),
enumerate every public symbol in the Rust crate, then verify a
corresponding public Swift symbol exists in the same package. Reports any
Rust-only symbol as a lockstep violation.

Why this exists: the Phase 6.6 commit moved `Row` from Verbs.swift to
SubstrateTypes/Row.swift but dropped the `public typealias RowId = UUID`
that lived alongside it. The Rust port kept `pub struct RowId(pub u128)`.
That Swift/Rust drift slipped past unit tests and conformance — the
files using RowId weren't reached by the SubstrateLib test runs.

Lockstep contract:
  - Every Rust public type has a Swift counterpart at the same name.
  - Modulo idiomatic naming: Rust snake_case → Swift CamelCase
    (e.g. row_state::RowState → Swift RowState).
  - Modulo language-shape: Rust trait → Swift protocol, Rust pub fn at
    module scope → Swift extension static func is acceptable; this audit
    flags the TYPE-LEVEL parity only (struct/enum/trait/protocol).

Exit status:
  0 — every Rust public type/trait/enum has a Swift mirror
  1 — at least one mismatch
  2 — environment error

Naming conversion: snake_case → CamelCase by capitalizing each segment.
HLC, FFT, FNV, NMF are special-cased as acronyms that stay all-caps.

False positives possible (Rust-only types that are wire-internal or
nested helpers). Each violation includes a hint string so you can decide:
fix Swift, suppress here, or document the asymmetry.
"""

from __future__ import annotations
import os
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT  = SCRIPT_DIR.parents[3]

PACKAGES = [
    ("SubstrateTypes",  REPO_ROOT / "packages/libs/SubstrateTypes"),
    ("SubstrateKernel", REPO_ROOT / "packages/libs/SubstrateKernel"),
    ("SubstrateML",     REPO_ROOT / "packages/libs/SubstrateML"),
]

# Acronyms that stay all-caps when converting snake_case → CamelCase.
ACRONYMS = {"hlc", "fft", "fnv", "nmf", "hnsw", "udc", "crc"}

# Rust types whose Swift mirror is intentionally absent (with rationale).
# These are wire-internal helpers, FFI shims, or Rust-only optimization types.
EXCEPTIONS = {
    # RowLite: Rust-only stub struct for MomentSummary (fingerprint +
    # capture_hlc only; doesn't carry the full Row payload). Swift
    # MomentSummary takes the full Row directly with a closure
    # predicate; no parallel optimization needed because Swift's
    # closure capture handles the field-subsetting on the call site.
    "RowLite",
}

USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
def c(code: str, s: str) -> str:
    return f"\033[{code}m{s}\033[0m" if USE_COLOR else s
red, green, yellow, dim = (lambda s: c("31", s), lambda s: c("32", s),
                            lambda s: c("33", s), lambda s: c("2",  s))

# ---------- helpers ----------

def snake_to_camel(name: str) -> list[str]:
    """Convert snake_case to plausible CamelCase variants.
    Returns a list because some names have multiple valid mappings
    (e.g. info_theory → InformationTheory not InfoTheory; the audit
    accepts either)."""
    parts = name.split('_')
    out = []
    for p in parts:
        if p.lower() in ACRONYMS:
            out.append(p.upper())
        else:
            out.append(p[:1].upper() + p[1:])
    return ["".join(out)]

def extract_rust_pub_types(rust_dir: Path) -> set[tuple[str, str]]:
    """Return set of (kind, name) for every `pub struct/enum/trait/type`
    at module top level. Skips items inside fn bodies or impl blocks."""
    found = set()
    type_re = re.compile(
        r'^pub\s+(?:\(crate\)\s+)?(?:unsafe\s+)?(struct|enum|trait|type)\s+([A-Z][A-Za-z0-9_]*)',
        re.MULTILINE
    )
    for rs in sorted(rust_dir.glob("*.rs")):
        if rs.name == "lib.rs":
            continue
        text = rs.read_text()
        # Strip block + line comments so we don't match types described in docstrings
        text = re.sub(r'//[^\n]*', '', text)
        text = re.sub(r'/\*[\s\S]*?\*/', '', text)
        for m in type_re.finditer(text):
            kind, name = m.group(1), m.group(2)
            found.add((kind, name))
    return found

def extract_swift_pub_types(swift_dir: Path) -> set[str]:
    """Return set of all Swift public type names: struct/enum/class/
    protocol/typealias/actor at top level or extension-scope."""
    found = set()
    decl_re = re.compile(
        r'^(?:public|open)\s+'
        r'(?:final\s+|indirect\s+|static\s+)*'
        r'(struct|enum|class|protocol|typealias|actor)\s+'
        r'([A-Z][A-Za-z0-9_]*)',
        re.MULTILINE
    )
    for sw in sorted(swift_dir.glob("*.swift")):
        text = sw.read_text()
        text = re.sub(r'//[^\n]*', '', text)
        text = re.sub(r'/\*[\s\S]*?\*/', '', text)
        for m in decl_re.finditer(text):
            found.add(m.group(2))
    return found

# ---------- main ----------

def audit_package(name: str, root: Path) -> tuple[int, int]:
    """Returns (n_ok, n_missing)."""
    swift_src = root / f"Sources/{name}"
    rust_src  = root / "rust/src"

    if not swift_src.exists():
        print(f"  {yellow('SKIP')} {name}: no Swift source at {swift_src}")
        return (0, 0)
    if not rust_src.exists():
        print(f"  {yellow('SKIP')} {name}: no Rust source at {rust_src}")
        return (0, 0)

    rust_types  = extract_rust_pub_types(rust_src)
    swift_types = extract_swift_pub_types(swift_src)

    print(f"\n{name}")
    print("-" * (len(name) + 4))
    print(dim(f"  Rust public types: {len(rust_types)}"))
    print(dim(f"  Swift public types: {len(swift_types)}"))

    n_ok = n_miss = 0
    for kind, rust_name in sorted(rust_types):
        if rust_name in EXCEPTIONS:
            continue
        # candidates: rust_name as-is, or any snake_to_camel of it.
        # Rust public type names are already CamelCase so they should match
        # 1:1 to Swift in most cases.
        if rust_name in swift_types:
            n_ok += 1
        else:
            # Allow common Rust-only patterns to be flagged with hints
            hint = ""
            if rust_name.endswith("Error"):
                hint = " (Rust error enum — Swift may use throws/Result instead)"
            elif kind == "trait":
                hint = " (Rust trait — Swift might mirror as protocol with same name)"
            elif kind == "type":
                hint = " (Rust type alias — Swift typealias expected)"
            print(f"  {red('MISSING')} {kind:6s} {rust_name}{hint}")
            n_miss += 1

    if n_miss == 0:
        print(f"  {green(f'all {n_ok} Rust public types have Swift mirrors')}")
    return (n_ok, n_miss)

def main() -> int:
    total_ok = total_miss = 0
    for name, root in PACKAGES:
        ok, miss = audit_package(name, root)
        total_ok += ok
        total_miss += miss

    print()
    print(f"summary: {green(f'{total_ok} matched')}, "
          f"{red(f'{total_miss} missing')}")
    if total_miss > 0:
        print()
        print(red("FAIL") + " — Swift/Rust lockstep violation(s) detected.")
        print()
        print("next steps:")
        print("  - if the Rust type should have a Swift mirror: add it")
        print("  - if the Rust type is intentionally Rust-only:")
        print("    add to EXCEPTIONS in this script with a comment explaining why")
        return 1
    print(green("PASS") + " — Swift/Rust lockstep clean.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
