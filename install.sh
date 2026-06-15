#!/bin/sh
#
# mootx01 standalone installer.
#
# Downloads a prebuilt mootx01 binary from GitHub Releases and places it on
# your PATH. No Swift toolchain, no build tools, no clone required.
#
#   curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/main/install.sh | sh
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

# Linux/Windows archives carry `mootx01` only — the Rust vertical, which hosts the
# estate via `mootx01 serve` exactly like macOS (CI smoke-tests `serve` on Linux).
# The `moot-mgr` console binary ships in the macOS archive; on Linux the headless
# manager is built from source.

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

# 3. Download + extract. The macOS release tarball contains two bare binaries
#    at its root — `mootx01` and `moot-mgr` (the management console); Linux
#    archives carry `mootx01` only (release.yml: `tar -czf ASSET mootx01 [moot-mgr]`).
asset="mootx01-${version}-${target}.tar.gz"
url="https://github.com/$REPO/releases/download/$version/$asset"
echo "Installing mootx01 $version ($target)..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/mootx01.tar.gz" || { echo "mootx01: download failed: $url" >&2; exit 1; }
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

# moot-mgr (the management & monitoring console) ships only in the macOS
# archive; place it the same way when the extracted tree carries it.
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
if [ "$mgr_installed" = "1" ]; then
  echo ""
  echo "Management console: \`mootx01 install\` registers moot-mgr as a background"
  echo "launchd service (starts now, restarts at login) — dashboard at"
  echo "http://127.0.0.1:4200. Or run it yourself any time with \`moot-mgr serve\`."
fi
