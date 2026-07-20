#!/usr/bin/env python3
"""MOOTx01 update check for Claude Code (SessionStart).

This is the ONLY hook in this adapter that touches the network, and it is
kept in its own file so that boundary is easy to audit. `moot_hooks.py`
remains network-free.

What it does, exactly:
  1. At most once per 24 hours, makes one HTTPS GET to the GitHub
     releases API for codedaptive/mootx01-ce and reads the latest tag.
  2. Compares it to the locally installed version (`mootx01 --version`).
  3. If a newer version exists, prints a one-line notice (injected as
     session context) — once per new version, not once per session.

What it never does:
  - Send any identifier, telemetry, or user data. The request carries only
    an honest User-Agent string.
  - Execute, download, or install anything. It prints a sentence.
  - Make noise on failure. Offline, rate-limited, CLI missing, repo
    private — every failure path exits 0 silently.

Disable it either way:
  - export MOOTX01_NO_UPDATE_CHECK=1
  - or delete this hook's block from .claude/settings.json

Environment overrides (testing / self-hosted):
  MOOTX01_UPDATE_URL          alternate release-info URL (must return JSON
                              with a "tag_name" field)
  MOOTX01_BIN                 alternate path to the mootx01 binary
  MOOTX01_FORCE_UPDATE_CHECK  set to 1 to bypass the 24h throttle
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

DEFAULT_URL = "https://api.github.com/repos/codedaptive/mootx01-ce/releases/latest"
RELEASES_PAGE = "https://github.com/codedaptive/mootx01-ce/releases"
USER_AGENT = "mootx01-update-check"
THROTTLE_SECONDS = 24 * 60 * 60
TIMEOUT_SECONDS = 3

# Per-user cache directory — never the shared /tmp, which is world-writable
# and lets another user pre-create the file to inject text into the model
# context via the cached "latest version" field.
def _user_cache_dir():
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        return os.path.join(xdg, "mootx01")
    return os.path.join(os.path.expanduser("~"), ".cache", "mootx01")

_cache_dir = _user_cache_dir()
os.makedirs(_cache_dir, mode=0o700, exist_ok=True)
CACHE_PATH = os.path.join(_cache_dir, "update-check.json")

VERSION_RE = re.compile(r"(\d+(?:\.\d+)*)((?:[-.][0-9A-Za-z]+)*)")


def load_cache():
    try:
        with open(CACHE_PATH, "r", encoding="utf-8") as fh:
            cache = json.load(fh)
            if isinstance(cache, dict):
                return cache
    except Exception:
        pass
    return {}


def save_cache(cache):
    try:
        with open(CACHE_PATH, "w", encoding="utf-8") as fh:
            json.dump(cache, fh)
    except Exception:
        pass


def parse_version(text):
    """Return ((numeric core tuple), is_prerelease) or None."""
    if not text:
        return None
    match = VERSION_RE.search(text.strip())
    if not match:
        return None
    core = tuple(int(part) for part in match.group(1).split("."))
    prerelease = bool(match.group(2))
    return core, prerelease


def is_newer(remote, local):
    """True when remote is strictly newer than local (conservative)."""
    rcore, rpre = remote
    lcore, lpre = local
    length = max(len(rcore), len(lcore))
    rcore += (0,) * (length - len(rcore))
    lcore += (0,) * (length - len(lcore))
    if rcore != lcore:
        return rcore > lcore
    # Same numeric core: a stable release is newer than a local prerelease.
    return lpre and not rpre


def installed_version():
    """Return (parsed, display_string) for the local install, or None."""
    binary = os.environ.get("MOOTX01_BIN") or shutil.which("mootx01")
    if not binary:
        return None
    try:
        out = subprocess.run(
            [binary, "--version"],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
        if out.returncode != 0:
            return None
        raw = (out.stdout or out.stderr or "").strip()
        match = VERSION_RE.search(raw)
        if not match:
            return None
        parsed = parse_version(match.group(0))
        if not parsed:
            return None
        return parsed, match.group(0)
    except Exception:
        return None


def latest_version_tag():
    url = os.environ.get("MOOTX01_UPDATE_URL", DEFAULT_URL)
    try:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            payload = json.load(response)
        tag = payload.get("tag_name")
        if isinstance(tag, str) and tag.strip():
            return tag.strip()
    except Exception:
        pass
    return None


def main():
    if os.environ.get("MOOTX01_NO_UPDATE_CHECK"):
        sys.exit(0)

    import time

    now = time.time()
    cache = load_cache()
    force = bool(os.environ.get("MOOTX01_FORCE_UPDATE_CHECK"))

    if not force and now - float(cache.get("checked_at") or 0) < THROTTLE_SECONDS:
        tag = cache.get("latest_tag")
    else:
        tag = latest_version_tag()
        cache["checked_at"] = now
        if tag:
            cache["latest_tag"] = tag
        save_cache(cache)

    if not tag:
        sys.exit(0)

    local = installed_version()
    remote = parse_version(tag)
    if not local or not remote or not is_newer(remote, local[0]):
        sys.exit(0)

    if cache.get("notified_tag") == tag:
        sys.exit(0)
    cache["notified_tag"] = tag
    save_cache(cache)

    # `mootx01 upgrade` is the primary path (verified download + service
    # restart + plugin/permission convergence); the releases page is kept
    # as the fallback for users who prefer package managers.
    print(
        "[MOOTx01] A newer MOOTx01 release is available: %s (installed: "
        "%s). Briefly mention this to the user once at a natural moment — "
        "do not interrupt the current task. Upgrade with `mootx01 upgrade` "
        "(or see %s)."
        % (tag, local[1], RELEASES_PAGE)
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
