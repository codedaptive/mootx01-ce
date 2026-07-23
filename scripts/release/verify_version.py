#!/usr/bin/env python3
"""Release version-stamp consistency gate.

A CE release stamps the product version in ~16 sites across three hand-maintained
groups (binary, plugin manifests, embedded installer copies). They drifted once
(v1.0.31 shipped with the binary and embedded copies still reading 1.0.30 while
the plugin manifests read 1.0.31), which this gate exists to make impossible to
repeat: it trusts NO single site and asserts the whole set agrees, so it catches
a missed binary bump, a missed embedded copy, or an EE->CE sync gap alike.

Run before cutting a tag (and in CI). Exits non-zero on ANY disagreement.

  python3 scripts/release/verify_version.py            # infer version, check all
  python3 scripts/release/verify_version.py 1.0.31     # also assert it equals this
  python3 scripts/release/verify_version.py 1.1.0-beta-03

The authoritative version is the mootx01-cli package version in
apps/mootx01/rust/Cargo.toml; every other site must match it.
"""
from __future__ import annotations
import json
import re
import sys
from pathlib import Path

# Repo root = two levels up from scripts/release/.
ROOT = Path(__file__).resolve().parents[2]

# SemVer with an optional pre-release component, but NOT a slice of a longer
# dotted number (e.g. the IP 127.0.0.1 must not read as version 127.0.0).
SEMVER = re.compile(
    r"(?<![\d.])\d+\.\d+\.\d+"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?![\d.])"
)

PLUGIN_MANIFESTS = [
    "distribution/plugin/.claude-plugin/plugin.json",
    "distribution/plugin/.codex-plugin/plugin.json",
    "distribution/plugin/.cursor-plugin/plugin.json",
    "distribution/plugin/.plugin/plugin.json",
    "distribution/plugin/plugin.json",
    "distribution/plugin/gemini-extension.json",
]
INSTALL_BUNDLE = "apps/mootx01/rust/src/embedded/install-bundle.json"
EMBEDDED_SWIFT = "apps/mootx01/Sources/MootInstallerCore/Generated/EmbeddedArtifacts.swift"


def read(rel: str) -> str:
    return (ROOT / rel).read_text()


def fail(errs: list[str]) -> None:
    print("version-verify: FAIL")
    for e in errs:
        print(f"  ✗ {e}")
    sys.exit(1)


def cargo_package_version() -> str:
    """The [package] version in Cargo.toml — the authoritative product version."""
    text = read("apps/mootx01/rust/Cargo.toml")
    in_pkg = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            in_pkg = s == "[package]"
        elif in_pkg and s.startswith("version"):
            m = re.search(r'"([^"]+)"', s)
            if m:
                return m.group(1)
    raise SystemExit("version-verify: could not read [package] version from Cargo.toml")


def main() -> None:
    auth = cargo_package_version()
    expected = sys.argv[1] if len(sys.argv) > 1 else auth
    errs: list[str] = []

    if auth != expected:
        errs.append(f"Cargo.toml [package] version {auth!r} != expected {expected!r}")

    # --- Group 1: binary stamps ---
    mm = read("apps/mootx01/Sources/mootx01/MootMain.swift")
    m = re.search(r'currentVersion\s*=\s*"([^"]+)"', mm)
    if not m or m.group(1) != expected:
        errs.append(f"MootMain.currentVersion {m.group(1) if m else '?'!r} != {expected!r}")
    m_swift_date = re.search(r'releaseDate\s*=\s*"([^"]+)"', mm)

    lock = read("apps/mootx01/rust/Cargo.lock")
    m = re.search(r'name\s*=\s*"mootx01-cli"\s*\nversion\s*=\s*"([^"]+)"', lock)
    if not m or m.group(1) != expected:
        errs.append(f"Cargo.lock mootx01-cli version {m.group(1) if m else '?'!r} != {expected!r}")

    librs = read("apps/mootx01/rust/src/lib.rs")
    m_rust_date = re.search(r'RELEASE_DATE:\s*&str\s*=\s*"([^"]+)"', librs)
    # Dates need not equal the version, but the two legs MUST agree on the date.
    if m_swift_date and m_rust_date and m_swift_date.group(1) != m_rust_date.group(1):
        errs.append(
            f"release date disagrees: Swift {m_swift_date.group(1)!r} "
            f"vs Rust {m_rust_date.group(1)!r}"
        )

    # --- Group 2: plugin manifests (parse as JSON, read the version key) ---
    for rel in PLUGIN_MANIFESTS:
        try:
            v = json.loads(read(rel)).get("version")
        except Exception as e:  # noqa: BLE001 - report and continue
            errs.append(f"{rel}: not valid JSON ({e})")
            continue
        if v != expected:
            errs.append(f"{rel}: version {v!r} != {expected!r}")

    readme = read("distribution/plugin/README.md")
    m = re.search(
        r"Version\s+(\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)",
        readme,
    )
    if not m or m.group(1) != expected:
        errs.append(f"plugin README version {m.group(1) if m else '?'!r} != {expected!r}")

    changelog = read("distribution/plugin/CHANGELOG.md")
    m = re.search(
        r"##\s*\[(\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)\]",
        changelog,
    )
    if not m or m.group(1) != expected:
        errs.append(f"plugin CHANGELOG heading {m.group(1) if m else '?'!r} != {expected!r}")

    # --- Group 3: embedded installer copies ---
    ij = read(INSTALL_BUNDLE)
    try:
        json.loads(ij)
    except Exception as e:  # noqa: BLE001
        errs.append(f"{INSTALL_BUNDLE}: not valid JSON ({e})")
    # Every 3-part version token in the bundle must be the product version.
    # (2-part tokens like roadmap "1.0" don't match SEMVER, so they're ignored.)
    bad = sorted({v for v in SEMVER.findall(ij) if v != expected})
    if bad:
        errs.append(f"{INSTALL_BUNDLE}: stray version tokens {bad} (expected only {expected})")

    # The Swift copy is the escaped byte-image of install-bundle.json; it must
    # unescape to EXACTLY the same bytes, or the two installers disagree.
    ea = read(EMBEDDED_SWIFT)
    m = re.search(r'installBundleJSON\s*=\s*"(.*?)"\s*$', ea, re.S | re.M)
    if not m:
        errs.append(f"{EMBEDDED_SWIFT}: could not locate installBundleJSON literal")
    else:
        try:
            decoded = json.loads('"' + m.group(1) + '"')
        except Exception as e:  # noqa: BLE001
            errs.append(f"{EMBEDDED_SWIFT}: literal is not a decodable string ({e})")
            decoded = None
        if decoded is not None and decoded.strip() != ij.strip():
            errs.append(
                f"{EMBEDDED_SWIFT}: unescaped Swift copy does not byte-match "
                f"{INSTALL_BUNDLE} (embedded copies out of sync)"
            )

    if errs:
        fail(errs)
    print(f"version-verify: OK — every stamp reads {expected}")


if __name__ == "__main__":
    main()
