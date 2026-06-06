#!/bin/sh
#
# mootx01 standalone installer.
#
# Downloads a prebuilt mootx01 binary from GitHub Releases and places it on
# your PATH. No Swift toolchain, no build tools, no clone required.
#
#   curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ee/main/install.sh | sh
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
# NOTE on distribution: curl-install requires the release assets (and this
# script) to be reachable on a PUBLIC repo. `codedaptive/mootx01-ee` is the
# development repo; for public distribution point REPO at the public
# (open-core / CE) repo that publishes the releases.
set -eu

REPO="${MOOTX01_REPO:-codedaptive/mootx01-ee}"
INSTALL_DIR="${MOOTX01_INSTALL_DIR:-$HOME/.mootx01/bin}"
BIN_DIR="${MOOTX01_BIN_DIR:-$HOME/.local/bin}"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$BIN_DIR/mootx01"
  rm -rf "$HOME/.mootx01"
  echo "mootx01 binary removed ($HOME/.mootx01 and $BIN_DIR/mootx01)."
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

# The MCP server (`mootx01 serve`) is macOS-only; Linux builds carry the
# install/uninstall/db/status/query subcommands but not the server.
if [ "$os" = "linux" ]; then
  echo "Note: the mootx01 MCP server (\`serve\`) is macOS-only; the Linux build" >&2
  echo "      provides the management subcommands but cannot host an estate." >&2
fi

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

# 3. Download + extract. The release tarball contains the bare `mootx01`
#    binary at its root (release.yml: `tar -czf ASSET mootx01`).
asset="mootx01-${version}-${target}.tar.gz"
url="https://github.com/$REPO/releases/download/$version/$asset"
echo "Installing mootx01 $version ($target)..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/mootx01.tar.gz" || { echo "mootx01: download failed: $url" >&2; exit 1; }
tar -xzf "$tmp/mootx01.tar.gz" -C "$tmp"
[ -f "$tmp/mootx01" ] || { echo "mootx01: archive did not contain the expected binary." >&2; exit 1; }

# 4. Place the binary and symlink it onto PATH (same layout `mootx01 install`
#    uses, so curl-install and source-install converge).
mkdir -p "$INSTALL_DIR"
install -m 0755 "$tmp/mootx01" "$INSTALL_DIR/mootx01"
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/mootx01" "$BIN_DIR/mootx01"

echo "Installed  $INSTALL_DIR/mootx01"
echo "Linked     $BIN_DIR/mootx01"
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
