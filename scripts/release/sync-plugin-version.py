#!/usr/bin/env python3
"""Force the plugin version to equal the CE product version.

The plugin (manifests in `distribution/plugin/` + the embedded installer bundle)
is produced by the private EE generator and published into CE wholesale. Its
version must ALWAYS equal the CE product version — external tools reject a
plugin whose version disagrees with the binary that installs it. But the
generator is deliberately decoupled from CE versioning: it stamps a sentinel
(`0.0.0`) and never needs to know the CE version.

This script closes that gap on the CE side. Run it immediately after every
EE→CE plugin publish. It reads the CE product version (the binary's own
`[package]` version in Cargo.toml — the single source of truth) and rewrites
every plugin/embedded version token to match, tolerant of whatever the
generator emitted (the `0.0.0` sentinel, or a stale version from an older
regen). Then it runs verify_version.py as the gate.

  python3 scripts/release/sync-plugin-version.py

Idempotent: a tree already consistent at the CE version is a no-op. This does
NOT touch the binary stamps (that is bump_version.py's job at release) — it only
drags the plugin surfaces up to whatever the binary already says. The division:
bump_version.py moves the whole product to a NEW version at release;
this script makes a freshly-published plugin match the CURRENT version.

NOTE: the embedded bundle carries all 10 host plugins as one EE-generated
artifact; CE cannot regenerate its content (only the `claude-code` host has
source in `distribution/plugin/`). So this stamps the VERSION in place — it does
not regenerate content. Content freshness is the publish step's responsibility.
"""
from __future__ import annotations
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

CARGO_TOML = "apps/mootx01/rust/Cargo.toml"
README = "distribution/plugin/README.md"
PLUGIN_CHANGELOG = "distribution/plugin/CHANGELOG.md"
INSTALL_BUNDLE = "apps/mootx01/rust/src/embedded/install-bundle.json"
EMBEDDED_SWIFT = "apps/mootx01/Sources/MootInstallerCore/Generated/EmbeddedArtifacts.swift"
PLUGIN_MANIFESTS = [
    "distribution/plugin/.claude-plugin/plugin.json",
    "distribution/plugin/.codex-plugin/plugin.json",
    "distribution/plugin/.cursor-plugin/plugin.json",
    "distribution/plugin/.plugin/plugin.json",
    "distribution/plugin/plugin.json",
    "distribution/plugin/gemini-extension.json",
]
# One manifest embedded in the bundle whose version reflects the bundle's
# incoming plugin version (the value the generator stamped for every host).
BUNDLE_PROBE_KEY = "claude-code/.claude-plugin/plugin.json"

VERSION_RE = re.compile(
    r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
# Matches `"version" : "X"` in the manifests (spaces around the colon are the
# packager's exact byte format — preserved by capturing only the value).
MANIFEST_VER_RE = re.compile(r'("version"\s*:\s*")([^"]+)(")')


def rd(rel: str) -> str:
    return (ROOT / rel).read_text()


def wr(rel: str, text: str) -> None:
    (ROOT / rel).write_text(text)


def ce_version() -> str:
    """The CE product version = the binary's [package] version in Cargo.toml."""
    in_pkg = False
    for line in rd(CARGO_TOML).splitlines():
        s = line.strip()
        if s.startswith("["):
            in_pkg = s == "[package]"
        elif in_pkg and s.startswith("version"):
            m = re.search(r'"([^"]+)"', s)
            if m:
                return m.group(1)
    raise SystemExit("sync: could not read CE [package] version from Cargo.toml")


def manifest_version(rel: str) -> str:
    m = MANIFEST_VER_RE.search(rd(rel))
    if not m:
        raise SystemExit(f"sync: {rel}: no \"version\" field found")
    return m.group(2)


def bundle_incoming_version() -> str:
    """The version the generator stamped inside the embedded bundle."""
    bundle = json.loads(rd(INSTALL_BUNDLE))
    content = bundle["packages"][BUNDLE_PROBE_KEY]
    if isinstance(content, dict):  # tolerate {content: "..."} wrapping
        content = content.get("content", content)
    ver = json.loads(content)["version"] if isinstance(content, str) else content["version"]
    return ver


def stamp_value(rel: str, new: str) -> bool:
    """Set every manifest "version" field to `new`. Returns True if changed."""
    text = rd(rel)
    stamped, n = MANIFEST_VER_RE.subn(lambda m: m.group(1) + new + m.group(3), text)
    if n == 0:
        raise SystemExit(f"sync: {rel}: no \"version\" field to stamp")
    if stamped != text:
        wr(rel, stamped)
        return True
    return False


def stamp_token(rel: str, old: str, new: str) -> int:
    """Literal-replace version token `old`→`new`; return occurrences replaced."""
    text = rd(rel)
    n = text.count(old)
    if n:
        wr(rel, text.replace(old, new))
    return n


def run_verify(version: str) -> int:
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts/release/verify_version.py"), version]
    ).returncode


def main() -> None:
    target = ce_version()
    if not VERSION_RE.match(target):
        raise SystemExit(f"sync: CE version {target!r} is not supported SemVer")

    print(f"sync: CE product version is {target} — forcing plugin to match.")
    changed = False

    # --- Manifests + README + CHANGELOG (regex, format-preserving) ---
    for rel in PLUGIN_MANIFESTS:
        if stamp_value(rel, target):
            changed = True
            print(f"  stamped {rel}")

    readme = rd(README)
    readme2 = re.sub(
        r"Version \d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?",
        f"Version {target}",
        readme,
        count=1,
    )
    if readme2 != readme:
        wr(README, readme2); changed = True; print(f"  stamped {README}")

    chlog = rd(PLUGIN_CHANGELOG)
    chlog2 = re.sub(
        r"## \[\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\]",
        f"## [{target}]",
        chlog,
        count=1,
    )
    if chlog2 != chlog:
        wr(PLUGIN_CHANGELOG, chlog2); changed = True; print(f"  stamped {PLUGIN_CHANGELOG}")

    # --- Embedded copies (literal token replace; both must stay byte-identical) ---
    incoming = bundle_incoming_version()
    if incoming != target:
        if not VERSION_RE.match(incoming):
            raise SystemExit(f"sync: embedded bundle version {incoming!r} is not semver")
        nj = stamp_token(INSTALL_BUNDLE, incoming, target)
        ns = stamp_token(EMBEDDED_SWIFT, incoming, target)
        if nj != ns:
            raise SystemExit(
                f"sync: embedded copies disagree on token count "
                f"({INSTALL_BUNDLE} {nj} vs {EMBEDDED_SWIFT} {ns}) — inspect before committing"
            )
        if nj:
            changed = True
            print(f"  stamped embedded copies: {incoming} → {target} ({nj} tokens each)")

    if not changed:
        print(f"sync: already in sync at {target} — nothing to do.")
        return

    print(f"sync: verifying at {target}…")
    if run_verify(target) != 0:
        raise SystemExit("sync: post-sync verify FAILED — do not commit; inspect the ✗ lines.")
    print(f"\nsync: OK — plugin version now matches CE {target} across all surfaces.")


if __name__ == "__main__":
    main()
