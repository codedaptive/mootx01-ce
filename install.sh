#!/bin/sh
#
# mootx01 standalone installer.
#
# Downloads a prebuilt mootx01 binary from GitHub Releases and places it on
# your PATH. No Swift toolchain, no build tools, no clone required.
#
#   curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.sh | sh
#
# Then wire it into your AI clients (interactive menu):
#   mootx01 install
#
# Upgrade:   re-run the curl command.
# Uninstall: curl -fsSL .../install.sh | sh -s -- --uninstall
#            (removes the binary + PATH symlink; run `mootx01 uninstall`
#             first to strip the MCP-client config entries.)
#
# Environment:
#   MOOTX01_VERSION      release tag to install (default: latest)
#   MOOTX01_INSTALL_DIR  binary location   (default: ~/.mootx01/bin)
#   MOOTX01_BIN_DIR      PATH symlink dir   (default: ~/.local/bin)
#
# NOTE on distribution: this points at the PUBLIC open-core repo
# `codedaptive/mootx01-ce`, which publishes the release assets. The private
# `codedaptive/mootx01-ee` repo is the development source; it is cloned to the
# CE repo for public distribution and is never installed from directly.
set -eu

REPO="${MOOTX01_REPO:-codedaptive/mootx01-ce}"
INSTALL_DIR="${MOOTX01_INSTALL_DIR:-$HOME/.mootx01/bin}"
BIN_DIR="${MOOTX01_BIN_DIR:-$HOME/.local/bin}"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$BIN_DIR/mootx01" "$BIN_DIR/moot-mgr"
  rm -rf "$HOME/.mootx01"
  echo "mootx01 + moot-mgr removed ($HOME/.mootx01, $BIN_DIR/mootx01, $BIN_DIR/moot-mgr)."
  echo "MCP-client config entries are left intact; run \`mootx01 uninstall\` before this to remove them."
  exit 0
fi

# 1. Detect platform → the target string the release assets use
#    (mootx01-<version>-<os>-<arch>.tar.gz; see .github/workflows/release.yml).
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Darwin) os="macos" ;;
  Linux)  os="linux" ;;
  *) echo "mootx01: unsupported OS '$os'." >&2; exit 1 ;;
esac
case "$arch" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64)  arch="x86_64" ;;
  *) echo "mootx01: unsupported architecture '$arch'." >&2; exit 1 ;;
esac
target="${os}-${arch}"

# Linux/Windows ship the Rust `mootx01` vertical, which hosts the estate via
# `mootx01 serve` exactly like macOS (CI smoke-tests `serve` on Linux). The
# `moot-mgr` console ships on every platform: the Swift build on macOS and the
# headless Rust build on Linux (x86_64/arm64) and Windows. Its admin control
# channel is a Unix-domain socket on Unix and a named pipe on Windows.

# Calculate and verify release checksums before extracting downloaded archives.

sha256_file() {
  # Compute a SHA-256 hex digest for the given file. Tries sha256sum (Linux)
  # and then shasum -a 256 (macOS). Fails closed — aborts if neither is found,
  # rather than proceeding with an unverified binary.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "mootx01: sha256sum or shasum is required to verify release integrity." >&2
    exit 1
  fi
}

verify_checksum() {
  # Verify $1 (a downloaded file) against the expected SHA-256 recorded in
  # $2 (checksums.txt) under the asset name $3. Fails closed on any mismatch
  # or when the asset is absent from checksums.txt.
  file="$1"
  checksums_file="$2"
  asset_name="$3"

  expected="$(awk -v name="$asset_name" '$2 == name { print $1; found=1; exit } END { if (!found) exit 1 }' "$checksums_file")" \
    || { echo "mootx01: no checksum found for $asset_name in checksums.txt." >&2; exit 1; }
  actual="$(sha256_file "$file")"

  if [ "$actual" != "$expected" ]; then
    echo "mootx01: checksum mismatch for $asset_name." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

# verify_minisign verifies a detached Ed25519 minisign signature of the
# checksums.txt file against the public key bundled at scripts/minisign.pub.
# This provides an independent trust root beyond the TLS transport used to
# fetch the release from GitHub.
#
# Fail-closed in two ways:
#   1. If scripts/minisign.pub contains the PLACEHOLDER sentinel, the
#      operator has not yet committed a real keypair. Exit non-zero.
#   2. If the `minisign` binary is not present on PATH, exit non-zero with
#      installation instructions. Do NOT skip verification — omitting it
#      would silently remove the independent trust root.
#
# Linux/POSIX-only. macOS uses Developer ID / Gatekeeper (not called there).
verify_minisign() {
  checksums_file="$1"
  sig_file="$2"
  pub_key_file="$3"

  # Guard 1: placeholder key — verification is wired but pending operator setup.
  if grep -q '^PLACEHOLDER' "$pub_key_file" 2>/dev/null; then
    echo "mootx01: minisign public key is a PLACEHOLDER — signature verification not yet active." >&2
    echo "mootx01: to activate, generate a real keypair:" >&2
    echo "  minisign -G -p scripts/minisign.pub -s /path/to/minisign.sec" >&2
    echo "mootx01: then commit scripts/minisign.pub and add MINISIGN_SECRET_KEY to GitHub secrets." >&2
    exit 1
  fi

  # Guard 2: minisign must be installed.
  if ! command -v minisign >/dev/null 2>&1; then
    echo "mootx01: minisign is required for release signature verification but was not found." >&2
    echo "mootx01: install minisign:" >&2
    echo "  Debian/Ubuntu:  apt-get install minisign" >&2
    echo "  Arch:           pacman -S minisign" >&2
    echo "  Fedora:         dnf install minisign" >&2
    echo "  Homebrew (any): brew install minisign" >&2
    echo "  From source:    https://github.com/jedisct1/minisign" >&2
    echo "mootx01: minisign verifies the Ed25519 release signature — do not bypass this check." >&2
    exit 1
  fi

  # Verify the detached signature. -V = verify, -p = public key, -m = signed file.
  # The .minisig file must be adjacent to the file it signs (standard minisign convention).
  minisign -V -p "$pub_key_file" -m "$checksums_file" -x "$sig_file" \
    || { echo "mootx01: minisign signature verification FAILED for checksums.txt." >&2; \
         echo "mootx01: the release may have been tampered with — do not proceed." >&2; exit 1; }
}

# 2. Resolve the version. Use the releases/latest *web* redirect (no API rate
#    limit) and fall back to the API. Matches codegraph's approach.
version="${MOOTX01_VERSION:-}"
if [ -z "$version" ]; then
  version="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" \
    | sed -n 's#.*/releases/tag/##p' | tr -d '\r')"
fi
if [ -z "$version" ]; then
  version="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
fi
[ -n "$version" ] || { echo "mootx01: could not resolve latest version; set MOOTX01_VERSION (e.g. MOOTX01_VERSION=v1.0.0)." >&2; exit 1; }
case "$version" in v*) ;; *) version="v$version" ;; esac

# 3. Download the archive, checksums.txt, and the detached minisign signature.
#    Verification order (fail closed at each step before proceeding to the next):
#      1. SHA-256 checksum — verifies asset integrity against checksums.txt.
#      2. minisign Ed25519 signature — verifies checksums.txt against the
#         project's signing key (Linux/POSIX independent trust root). macOS uses
#         Developer ID / Gatekeeper instead; this step is applied on Linux only.
#      3. Extraction.
#
#    Every archive carries two bare binaries at the root — `mootx01` and
#    `moot-mgr` (the management console). This script handles the macOS/Linux
#    tarballs; the Windows .zip is the PowerShell installer's domain (release.yml).
asset="mootx01-${version}-${target}.tar.gz"
url="https://github.com/$REPO/releases/download/$version/$asset"
checksums_url="https://github.com/$REPO/releases/download/$version/checksums.txt"
echo "Installing mootx01 $version ($target)..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/mootx01.tar.gz" || { echo "mootx01: download failed: $url" >&2; exit 1; }
curl -fsSL "$checksums_url" -o "$tmp/checksums.txt" || { echo "mootx01: download failed: $checksums_url" >&2; exit 1; }
# Download the detached minisign signature for checksums.txt. The .minisig file
# is produced during release by signing checksums.txt with the project's
# Ed25519 key (see .github/workflows/release.yml — requires MINISIGN_SECRET_KEY secret).
checksums_sig_url="https://github.com/$REPO/releases/download/$version/checksums.txt.minisig"
curl -fsSL "$checksums_sig_url" -o "$tmp/checksums.txt.minisig" \
  || { echo "mootx01: download failed: $checksums_sig_url" >&2; exit 1; }

# Step 1: SHA-256 checksum — verifies asset integrity against checksums.txt.
verify_checksum "$tmp/mootx01.tar.gz" "$tmp/checksums.txt" "$asset"

# Step 2: minisign Ed25519 signature verification — Linux/POSIX only.
# macOS uses Developer ID / Gatekeeper (the binary itself is signed and
# notarized; verifying the tarball signature is redundant with Gatekeeper).
if [ "$os" != "macos" ]; then
  # Locate the bundled public key relative to this installer script.
  _script_dir="$(dirname "$0")"
  _pub_key="${_script_dir}/scripts/minisign.pub"
  verify_minisign "$tmp/checksums.txt" "$tmp/checksums.txt.minisig" "$_pub_key"
fi

# Step 3: Extract. Archives carry `mootx01` (required) and `moot-mgr`
# (optional — installed when present).
tar -xzf "$tmp/mootx01.tar.gz" -C "$tmp"
[ -f "$tmp/mootx01" ] || { echo "mootx01: archive did not contain the expected binary." >&2; exit 1; }

# 4. Place the binaries and symlink them onto PATH (same layout `mootx01
#    install` uses, so curl-install and source-install converge).
mkdir -p "$INSTALL_DIR"
install -m 0755 "$tmp/mootx01" "$INSTALL_DIR/mootx01"
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/mootx01" "$BIN_DIR/mootx01"
echo "Installed  $INSTALL_DIR/mootx01"
echo "Linked     $BIN_DIR/mootx01"

# moot-mgr (the management & monitoring console) ships in the macOS and Linux
# archives; place it the same way whenever the extracted tree carries it.
mgr_installed=0
if [ -f "$tmp/moot-mgr" ]; then
  install -m 0755 "$tmp/moot-mgr" "$INSTALL_DIR/moot-mgr"
  ln -sf "$INSTALL_DIR/moot-mgr" "$BIN_DIR/moot-mgr"
  echo "Installed  $INSTALL_DIR/moot-mgr"
  echo "Linked     $BIN_DIR/moot-mgr"
  mgr_installed=1
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "$BIN_DIR is not on your PATH. Add it:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac
echo ""
echo "Next: wire mootx01 into your AI clients (interactive menu):"
echo "  mootx01 install"
echo ""
echo "Vault (import/export to disk) is ON by default. For a more secure position:"
echo "  mootx01 install --vault-off   # disables import/export"
if [ "$mgr_installed" = "1" ]; then
  echo ""
  if [ "$os" = "macos" ]; then
    svc="a launchd service"
  else
    svc="a systemd-user service"
  fi
  echo "Management console: \`mootx01 install\` registers moot-mgr as $svc"
  echo "(starts now, restarts at login) — dashboard at http://127.0.0.1:4200."
  echo "Or run it yourself any time with \`moot-mgr serve\`."
fi
