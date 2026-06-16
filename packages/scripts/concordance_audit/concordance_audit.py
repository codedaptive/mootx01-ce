#!/usr/bin/env python3
"""Concordance-completeness audit for the MOOTx01 Swift/Rust parity surface.

Every kit/lib under ``packages/libs/*`` and ``packages/kits/*`` carries a
``Swift/Rust Concordance`` section in its interface doc
(``docs/reference/<NAME>_INTERFACE*.md``). That section maps each public
contract concept Swift<->Rust. This tool detects DRIFT: top-level public
declarations present in the CODE but ABSENT from the concordance table.

Philosophy — CONCEPT, not every symbol:
  The goal is "a new public contract type must appear in the concordance,"
  not "every symbol that happens to be public." The concordance is keyed on
  the type/symbol NAME (the thing both ports must agree on), so the audit
  matches CODE declarations against NAMES mentioned anywhere in the
  concordance tables (Swift column, Rust column, or notes). A type counts as
  "documented" if its bare name appears in the concordance section as a
  backtick-quoted identifier. This deliberately tolerates the many table
  shapes in use (table-name rows, type rows, signature rows) — it keys on
  presence of the name, which is what drift would remove.

Output:
  Default is ADVISORY: print a readable per-package report and exit 0.
  ``--strict`` exits nonzero if any package has missing entries (CI gate).

Noise control:
  ``packages/scripts/concordance_audit/ignore.txt`` lists names to exclude
  (one ``name | reason`` per line). Keep it small and justified — platform
  bindings (CoreML/Metal/CloudKit), test-only types, etc. See the README.

Run from anywhere; paths resolve relative to the repo root (the directory
three levels above this script's ``packages/scripts/concordance_audit/`` home).
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --- Repo geometry -----------------------------------------------------------
# This file lives at <repo>/packages/scripts/concordance_audit/concordance_audit.py.
# REPO_ROOT is three levels up: concordance_audit/ -> scripts/ -> packages/ -> repo root.
TOOL_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOL_DIR.parent.parent.parent
PACKAGE_GLOBS = ("packages/libs/*", "packages/kits/*")
REFERENCE_DIR = REPO_ROOT / "docs" / "reference"
IGNORE_FILE = TOOL_DIR / "ignore.txt"

# --- Declaration patterns ----------------------------------------------------
# TOP-LEVEL only: anchored at column 0 (no leading indent). Nested public
# decls inside a type are members of an already-top-level type, not separate
# contract surface, so they are intentionally out of scope.
#
# Swift: public struct|enum|protocol|class|actor|typealias <Name>
SWIFT_DECL = re.compile(
    r"^public\s+(?:final\s+)?"
    r"(?:struct|enum|protocol|class|actor|typealias)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)
# Rust contract TYPES: pub struct|enum|trait|type <Name>. ``pub(crate)`` is
# excluded because ``\s`` will not match the ``(`` in ``pub(crate)``. pub
# use/const/static are not contract types and are out of scope.
RUST_DECL = re.compile(
    r"^pub\s+"
    r"(?:struct|enum|trait|type)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)
# Rust namespace-as-type modules: ``pub mod <PascalName>``. A PascalCase
# ``pub mod`` is the sanctioned Rust idiom for a caseless-enum namespace on
# the Swift side — e.g. SubstrateML's metric-name constants ship as Swift
# ``public enum VizGraphSignals { static let ... }`` and Rust
# ``pub mod VizGraphSignals { pub const ... }``. Both expose the same
# named constants under the same type name, so the module IS contract
# surface and must carry a concordance row. ORDINARY lowercase ``pub mod``
# (the normal Rust code-organization convention) is NOT contract surface and
# is deliberately excluded by the uppercase-initial anchor — those are
# internal module boundaries, not Swift<->Rust concepts. The leading
# uppercase letter is the discriminator: it signals "this module name is a
# type concept the other port agrees on," not a folder of code.
RUST_MOD_DECL = re.compile(r"^pub\s+mod\s+([A-Z][A-Za-z0-9_]*)")
# Free functions are OPT-IN (``--include-fn``). The mission spec wrote the
# Rust pattern as ``... type fn?`` — the ``?`` marks fn as optional. By
# default the audit keys on contract TYPES (the thing both ports must agree
# on structurally); free helper functions are a much larger, noisier surface
# and dilute the "new public contract type must be in concordance" signal.
RUST_FN_DECL = re.compile(r"^pub\s+(?:async\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)")

# A backtick-quoted identifier inside a concordance table, e.g. `RecallHit`
# or `recall::GLKRecallMode` or `drawers_table()`. We extract the bare
# trailing identifier so `recall::GLKRecallMode`, `GLKRecallMode`, and
# `GLKRecallMode<T>` all reduce to GLKRecallMode.
BACKTICK_TOKEN = re.compile(r"`([^`]+)`")
IDENT_TAIL = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)")

# A markdown heading whose text contains "Swift/Rust Concordance" (any depth,
# any trailing qualifier such as "— scored recall type system").
CONCORDANCE_HEADING = re.compile(r"^#{1,6}\s+.*Swift/Rust Concordance", re.IGNORECASE)
ANY_HEADING = re.compile(r"^#{1,6}\s+")


@dataclass
class PackageResult:
    name: str
    kind: str  # "lib" or "kit"
    doc_path: Path | None = None
    has_concordance: bool = False
    documented: set[str] = field(default_factory=set)
    swift_decls: dict[str, str] = field(default_factory=dict)  # name -> "file:line"
    rust_decls: dict[str, str] = field(default_factory=dict)
    missing: list[str] = field(default_factory=list)


def load_ignore() -> dict[str, str]:
    """Return {name: reason} from the ignore-list file (may be absent)."""
    ignored: dict[str, str] = {}
    if not IGNORE_FILE.exists():
        return ignored
    for raw in IGNORE_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # Format: name | reason   (reason optional but encouraged)
        if "|" in line:
            name, reason = line.split("|", 1)
            ignored[name.strip()] = reason.strip()
        else:
            ignored[line] = ""
    return ignored


def find_interface_doc(package_name: str) -> Path | None:
    """Map a package dir name to its interface doc, newest version wins.

    Doc files are named ``<UPPERCASEDNAME>_INTERFACE*.md``. A package may
    have several versioned docs (e.g. NeuronKit v0.8 and v0.85); prefer the
    one that actually carries a concordance section, then the lexically
    greatest filename (which sorts versions ascending).
    """
    prefix = package_name.upper() + "_INTERFACE"
    if not REFERENCE_DIR.is_dir():
        return None
    candidates = sorted(
        p for p in REFERENCE_DIR.glob(f"{prefix}*.md") if p.is_file()
    )
    if not candidates:
        return None
    # Prefer a doc that has a concordance section; among those, newest name.
    with_concordance = [c for c in candidates if _doc_has_concordance(c)]
    if with_concordance:
        return with_concordance[-1]
    return candidates[-1]


def _doc_has_concordance(doc: Path) -> bool:
    for line in doc.read_text(encoding="utf-8", errors="replace").splitlines():
        if CONCORDANCE_HEADING.match(line):
            return True
    return False


def parse_concordance_names(doc: Path) -> set[str]:
    """Collect every backtick-quoted identifier appearing inside any
    Swift/Rust Concordance section of the doc.

    A concordance section runs from its heading to the next heading of the
    same-or-shallower depth (or any heading — we stop at the next heading to
    stay conservative, then resume if another concordance heading appears).
    """
    names: set[str] = set()
    in_section = False
    section_depth = 0
    for line in doc.read_text(encoding="utf-8", errors="replace").splitlines():
        heading = ANY_HEADING.match(line)
        if heading:
            depth = len(line) - len(line.lstrip("#"))
            if CONCORDANCE_HEADING.match(line):
                in_section = True
                section_depth = depth
                continue
            # A new heading at same-or-shallower depth ends the section.
            if in_section and depth <= section_depth:
                in_section = False
            continue
        if not in_section:
            continue
        for token in BACKTICK_TOKEN.findall(line):
            # Reduce `recall::Foo`, `Foo()`, `Foo<T>` to trailing ident Foo,
            # and also keep ALL idents in the token so `func recall(_ h:...)`
            # style signature rows still contribute their type names.
            for ident in IDENT_TAIL.findall(token):
                names.add(ident)
    return names


def scan_decls(root: Path, patterns: tuple[re.Pattern, ...]) -> dict[str, str]:
    """Return {decl_name: "relpath:line"} for top-level matches under root."""
    found: dict[str, str] = {}
    if not root.is_dir():
        return found
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix not in (".swift", ".rs"):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            for pattern in patterns:
                m = pattern.match(line)
                if m:
                    name = m.group(1)
                    # First declaration site wins for the location label.
                    found.setdefault(name, f"{path.relative_to(REPO_ROOT)}:{lineno}")
                    break
    return found


def audit_package(
    pkg_dir: Path, kind: str, ignored: dict[str, str], include_fn: bool
) -> PackageResult:
    name = pkg_dir.name
    result = PackageResult(name=name, kind=kind)

    doc = find_interface_doc(name)
    result.doc_path = doc
    if doc is not None and _doc_has_concordance(doc):
        result.has_concordance = True
        result.documented = parse_concordance_names(doc)

    # Swift sources live under Sources/**; Rust under rust/src/**.
    # RUST_MOD_DECL is always included: a PascalCase ``pub mod`` is a
    # namespace-as-type concept (mirrors a Swift caseless enum), so it is
    # contract surface regardless of the --include-fn free-function toggle.
    rust_patterns: tuple[re.Pattern, ...] = (RUST_DECL, RUST_MOD_DECL)
    if include_fn:
        rust_patterns = (RUST_DECL, RUST_MOD_DECL, RUST_FN_DECL)
    result.swift_decls = scan_decls(pkg_dir / "Sources", (SWIFT_DECL,))
    result.rust_decls = scan_decls(pkg_dir / "rust" / "src", rust_patterns)

    # A name is "covered" if it appears in the concordance OR is ignored.
    all_decls = set(result.swift_decls) | set(result.rust_decls)
    for decl in sorted(all_decls):
        if decl in ignored:
            continue
        if decl in result.documented:
            continue
        result.missing.append(decl)
    return result


# Packages exempt from the type-concordance gate. AriaMcpKit is the ARIA engine —
# a wire-contract peer whose Swift and Rust ports agree at the JSON-RPC wire level
# with idiomatic (non-mirrored) internals, not a force-mirror substrate kit. Its
# contract lives in the ARIA_MCP_SPEC / ARIA_MCP_INTERFACE prose, not a type table,
# so the type-concordance discipline does not apply.
CONCORDANCE_EXEMPT = {"AriaMcpKit"}


def discover_packages() -> list[tuple[Path, str]]:
    pkgs: list[tuple[Path, str]] = []
    for glob in PACKAGE_GLOBS:
        kind = "lib" if "/libs/" in glob else "kit"
        for p in sorted(REPO_ROOT.glob(glob)):
            if p.is_dir() and p.name not in CONCORDANCE_EXEMPT:
                pkgs.append((p, kind))
    return pkgs


def render_report(results: list[PackageResult], ignored: dict[str, str]) -> str:
    lines: list[str] = []
    lines.append("Concordance-completeness audit")
    lines.append("=" * 60)
    lines.append(f"Repo: {REPO_ROOT}")
    lines.append(f"Ignore-list entries: {len(ignored)}")
    lines.append("")

    clean = []
    no_section = []
    gaps = []
    for r in results:
        if not r.has_concordance:
            no_section.append(r)
        elif r.missing:
            gaps.append(r)
        else:
            clean.append(r)

    for r in results:
        loc = (
            r.doc_path.relative_to(REPO_ROOT)
            if r.doc_path is not None
            else "(no interface doc found)"
        )
        n_swift = len(r.swift_decls)
        n_rust = len(r.rust_decls)
        if not r.has_concordance:
            status = "NO-CONCORDANCE-SECTION"
        elif r.missing:
            status = f"GAPS: {len(r.missing)}"
        else:
            status = "clean"
        lines.append(f"[{r.kind:>3}] {r.name:<20} {status}")
        lines.append(
            f"        doc={loc}  swift_types={n_swift} rust_types={n_rust} "
            f"documented_names={len(r.documented)}"
        )
        if r.missing:
            for decl in r.missing:
                site = r.swift_decls.get(decl) or r.rust_decls.get(decl) or "?"
                origin = "swift+rust"
                if decl in r.swift_decls and decl not in r.rust_decls:
                    origin = "swift-only"
                elif decl in r.rust_decls and decl not in r.swift_decls:
                    origin = "rust-only"
                lines.append(f"          - {decl}  ({origin})  {site}")
        lines.append("")

    lines.append("-" * 60)
    lines.append("Summary")
    lines.append(f"  packages scanned       : {len(results)}")
    lines.append(f"  clean (no gaps)        : {len(clean)}")
    lines.append(f"  advisory gaps          : {len(gaps)}")
    lines.append(f"  no concordance section : {len(no_section)}")
    if gaps:
        lines.append("  packages with gaps     : " + ", ".join(r.name for r in gaps))
    if no_section:
        lines.append(
            "  packages w/o section   : " + ", ".join(r.name for r in no_section)
        )
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit nonzero if any package has missing concordance entries "
        "or lacks a concordance section (for CI promotion).",
    )
    parser.add_argument(
        "--package",
        action="append",
        default=None,
        help="Restrict audit to one or more package names (repeatable). "
        "Used by Adams post-flight to scope the check to changed packages.",
    )
    parser.add_argument(
        "--include-fn",
        action="store_true",
        help="Also audit top-level free functions (pub fn / public func is "
        "NOT scanned for Swift). Off by default: the audit keys on contract "
        "TYPES, not helper functions. See README for rationale.",
    )
    args = parser.parse_args(argv)

    ignored = load_ignore()
    packages = discover_packages()
    if args.package:
        wanted = set(args.package)
        packages = [(p, k) for (p, k) in packages if p.name in wanted]
        missing_names = wanted - {p.name for (p, _k) in packages}
        if missing_names:
            print(
                f"warning: unknown package(s) ignored: {', '.join(sorted(missing_names))}",
                file=sys.stderr,
            )

    results = [
        audit_package(p, k, ignored, args.include_fn) for (p, k) in packages
    ]
    print(render_report(results, ignored))

    if args.strict:
        offenders = [r for r in results if r.missing or not r.has_concordance]
        if offenders:
            print(
                f"\n--strict: FAIL — {len(offenders)} package(s) need concordance work.",
                file=sys.stderr,
            )
            return 1
        print("\n--strict: PASS — all packages concordance-complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
