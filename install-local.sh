#!/bin/sh
#
# mootx01 OFFLINE / local installer — for testing a locally-built binary.
#
# Builds mootx01 from source (NO GitHub download) and places it at
# ~/.mootx01/bin/mootx01 with a ~/.local/bin symlink — the exact location the
# release `install.sh` and the `mootx01 install` subcommand use. This is the
# offline counterpart of install.sh: build locally instead of downloading.
#
#   ./install-local.sh           # build + place the binary
#   ./install-local.sh --wire    # build + place + run `mootx01 install`
#                                 #   (wires it into your AI clients)
#
# Iteration: after a code change, re-run `./install-local.sh` to refresh the
# installed binary in place. Your MCP client config already points at
# ~/.mootx01/bin/mootx01, so just restart the client to pick up the new build —
# no need to re-wire (skip --wire) unless the client list changed.
#
# Environment:
#   MOOTX01_INSTALL_DIR  binary location   (default: ~/.mootx01/bin)
#   MOOTX01_BIN_DIR      PATH symlink dir   (default: ~/.local/bin)
set -eu

INSTALL_DIR="${MOOTX01_INSTALL_DIR:-$HOME/.mootx01/bin}"
BIN_DIR="${MOOTX01_BIN_DIR:-$HOME/.local/bin}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "Building mootx01 (release) from $ROOT/installer ..."
swift build -c release --package-path "$ROOT/installer" --product mootx01
BIN="$ROOT/installer/.build/release/mootx01"
[ -x "$BIN" ] || { echo "mootx01: build did not produce $BIN" >&2; exit 1; }

mkdir -p "$INSTALL_DIR"
install -m 0755 "$BIN" "$INSTALL_DIR/mootx01"
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/mootx01" "$BIN_DIR/mootx01"

echo "Installed  $INSTALL_DIR/mootx01   (local build)"
echo "Linked     $BIN_DIR/mootx01"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "$BIN_DIR is not on your PATH. Add it:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

if [ "${1:-}" = "--wire" ]; then
  echo ""
  echo "Wiring mootx01 into your AI clients (mootx01 install)..."
  exec "$INSTALL_DIR/mootx01" install
fi

echo ""
echo "Binary refreshed. Restart your MCP client to pick it up."
echo "First time? Wire clients with:  mootx01 install   (or re-run with --wire)"
