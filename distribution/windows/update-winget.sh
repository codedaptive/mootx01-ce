#!/usr/bin/env bash
#
# distribution/windows/update-winget.sh
#
# Update the winget manifest files with a new version and SHA256 hashes
# from a published GitHub release. Called by release.yml after assets are
# published, and can be run manually.
#
# Usage:
#   ./update-winget.sh <version>        # e.g. 1.0.19 (no leading v)
#
# The script downloads the two Windows setup EXE assets from the release,
# computes their SHA256, and rewrites the three manifest YAML files in
# distribution/windows/winget/ with the new version, URLs, and hashes.
#
# Requirements: curl, python3, sha256sum (Linux) or shasum (macOS)
#
set -euo pipefail

REPO="codedaptive/mootx01-ce"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINGET_DIR="$SCRIPT_DIR/winget"

VERSION="${1:?Usage: update-winget.sh <version> (e.g. 1.0.19, no leading v)}"
# Strip leading v if present
VERSION="${VERSION#v}"
TAG="v${VERSION}"

echo "Updating winget manifests for ${VERSION} (tag ${TAG})..."

# ── 1. Download and hash the two setup EXEs ───────────────────────────────
BASE_URL="https://github.com/$REPO/releases/download/$TAG"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

hash_asset() {
  local asset="$1"
  local url="$BASE_URL/$asset"
  echo "  Downloading $asset..." >&2
  if ! curl -fsSL "$url" -o "$TMP/$asset"; then
    echo "  ✗ Could not download $url" >&2
    echo "0000000000000000000000000000000000000000000000000000000000000000"
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$TMP/$asset" | awk '{print toupper($1)}'
  else
    shasum -a 256 "$TMP/$asset" | awk '{print toupper($1)}'
  fi
}

X64_EXE="mootx01-${VERSION}-windows-x86_64-setup.exe"
ARM64_EXE="mootx01-${VERSION}-windows-arm64-setup.exe"

SHA_X64="$(hash_asset "$X64_EXE")"
echo "  ✓ x86_64: $SHA_X64"
SHA_ARM64="$(hash_asset "$ARM64_EXE")"
echo "  ✓ arm64:  $SHA_ARM64"

# ── 2. Rewrite the manifest files ────────────────────────────────────────
# Line-by-line rewrite in Python. Each YAML key is on its own line, so we
# match by key prefix and replace the value. The installer manifest has two
# Architecture blocks (x64 then arm64) — we track which one we're in to
# assign the correct URL and SHA256.

python3 - "$WINGET_DIR" "$VERSION" "$TAG" "$SHA_X64" "$SHA_ARM64" "$REPO" <<'PYEOF'
import sys, os

winget_dir, version, tag, sha_x64, sha_arm64, repo = sys.argv[1:]

base_url = f"https://github.com/{repo}/releases/download/{tag}"
x64_url = f"{base_url}/mootx01-{version}-windows-x86_64-setup.exe"
arm64_url = f"{base_url}/mootx01-{version}-windows-arm64-setup.exe"

def bump_version(filename):
    """Replace PackageVersion: <old> with PackageVersion: <new>."""
    path = os.path.join(winget_dir, filename)
    with open(path) as f:
        lines = f.readlines()
    out = []
    for line in lines:
        if line.startswith("PackageVersion:"):
            out.append(f"PackageVersion: {version}\n")
        else:
            out.append(line)
    with open(path, 'w') as f:
        f.writelines(out)

# Version manifest and locale manifest: just bump the version
bump_version("Codedaptive.MOOTx01.yaml")
bump_version("Codedaptive.MOOTx01.locale.en-US.yaml")

# Installer manifest: version + URLs + SHA256s
installer_path = os.path.join(winget_dir, "Codedaptive.MOOTx01.installer.yaml")
with open(installer_path) as f:
    lines = f.readlines()

out = []
current_arch = None
for line in lines:
    stripped = line.strip()
    if line.startswith("PackageVersion:"):
        out.append(f"PackageVersion: {version}\n")
    elif stripped.startswith("- Architecture: x64"):
        current_arch = "x64"
        out.append(line)
    elif stripped.startswith("- Architecture: arm64"):
        current_arch = "arm64"
        out.append(line)
    elif stripped.startswith("InstallerUrl:") and current_arch:
        indent = line[:len(line) - len(line.lstrip())]
        url = x64_url if current_arch == "x64" else arm64_url
        out.append(f"{indent}InstallerUrl: {url}\n")
    elif stripped.startswith("InstallerSha256:") and current_arch:
        indent = line[:len(line) - len(line.lstrip())]
        sha = sha_x64 if current_arch == "x64" else sha_arm64
        out.append(f"{indent}InstallerSha256: {sha}\n")
    else:
        out.append(line)

with open(installer_path, 'w') as f:
    f.writelines(out)

print(f"  Updated all manifests to {version}")
PYEOF

echo ""
echo "Winget manifests updated in $WINGET_DIR"
