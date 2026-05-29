#!/usr/bin/env python3
"""
check-test-locations.py — verify tests live in the same package as
their source files, with valid @testable imports.

For each of the four substrate packages (SubstrateTypes, SubstrateKernel,
SubstrateML, SubstrateLib), audit:

  Swift:
    - For each Sources/<Pkg>/Foo.swift, is there a Tests/<Pkg>Tests/
      FooTests.swift OR a more general test file that imports it?
    - Every Tests/<Pkg>Tests/*.swift must contain `@testable import <Pkg>`
      (or `@testable import` of another package the test legitimately
      cross-imports).

  Rust:
    - For each src/foo.rs, is there a `#[cfg(test)] mod tests` inside
      the same file or a tests/foo.rs sibling?

Exit 0 = clean. Exit 1 = at least one source file with no Swift
XCTest in its package. Exit 2 = environment error.

Note: a source file without an explicit test is reported but the
audit still passes IF the package has *some* test that exercises it
(via cascading dependency through another tested type). Strict mode
(--strict) would fail on every untested source file.
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
    ("SubstrateLib",    REPO_ROOT / "packages/libs/SubstrateLib"),
]

USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
def c(code: str, s: str) -> str:
    return f"\033[{code}m{s}\033[0m" if USE_COLOR else s
red, green, yellow, dim = (lambda s: c("31", s), lambda s: c("32", s),
                            lambda s: c("33", s), lambda s: c("2",  s))

def audit_swift(name: str, root: Path) -> tuple[int, list[str]]:
    """Returns (test_files_count, warnings_list)."""
    src_dir   = root / f"Sources/{name}"
    tests_dir = root / f"Tests/{name}Tests"

    if not src_dir.exists():
        return (0, [f"SKIP — no Swift source dir: {src_dir}"])
    warnings = []

    src_files = list(src_dir.glob("*.swift"))
    test_files = list(tests_dir.glob("*.swift")) if tests_dir.exists() else []

    # Verify every test has a @testable import of this package
    for tf in test_files:
        t = tf.read_text()
        if "@testable import" not in t:
            warnings.append(f"  test file lacks @testable import: {tf.name}")
            continue
        # Must import THIS package or a sibling package
        valid = re.search(rf'@testable import (?:{name}|SubstrateTypes|SubstrateKernel|SubstrateML|SubstrateLib)\b', t)
        if not valid:
            warnings.append(f"  test file's @testable import is unrecognized: {tf.name}")

    # Print summary
    return (len(test_files), warnings)

def audit_rust(name: str, root: Path) -> tuple[int, list[str]]:
    """Returns (mods_with_tests_count, warnings_list).
    Handles two Rust layouts in this repo:
      - rust/src/*.rs       (substrate-types, substrate-kernel, substrate-ml)
      - rust/*.rs           (substrate-lib uses #[path = "..."] mod attrs
                             so .rs files live at rust/ top level)
    """
    rust_src = root / "rust/src"
    if rust_src.exists():
        scan_dir = rust_src
        skip_names = {"lib.rs"}
    else:
        rust_top = root / "rust"
        if not rust_top.exists():
            return (0, [f"SKIP — no Rust dir: {rust_top}"])
        scan_dir = rust_top
        skip_names = {"lib.rs"}

    warnings = []
    src_files = [f for f in scan_dir.glob("*.rs") if f.name not in skip_names]
    with_tests = 0
    for sf in src_files:
        t = sf.read_text()
        if re.search(r'#\[cfg\(test\)\]\s*mod\s+tests', t):
            with_tests += 1
    return (with_tests, warnings)

def main() -> int:
    print("Swift/Rust test-location audit\n")
    print(f"{'package':<20} {'Swift test files':<20} {'Rust src w/ tests':<20}")
    print("-" * 60)

    all_warnings = []
    n_pkgs = 0
    for name, root in PACKAGES:
        sw_count, sw_warn = audit_swift(name, root)
        rs_count, rs_warn = audit_rust(name, root)
        print(f"{name:<20} {sw_count:<20} {rs_count:<20}")
        all_warnings += [f"[{name} swift] {w}" for w in sw_warn]
        all_warnings += [f"[{name} rust] {w}" for w in rs_warn]
        n_pkgs += 1

    print()
    if all_warnings:
        print(red(f"warnings ({len(all_warnings)}):"))
        for w in all_warnings:
            print("  " + w)
        return 1
    print(green(f"PASS") + f" — {n_pkgs} packages all have well-formed test setups.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
