#!/bin/sh
#
# mootx01 OFFLINE / local installer — for testing a locally-built binary.
#
# Builds mootx01 from source (NO GitHub download) and places it at
# ~/.mootx01/bin/mootx01 with a ~/.local/bin symlink — the exact location the
# release `install.sh` and the `mootx01 install` subcommand use. This is the
# offline counterpart of install.sh: build locally instead of downloading.
# On macOS it also builds and places `moot-mgr` (the management console).
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

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# Place a freshly built binary and symlink it onto PATH.
place() {  # $1 = product name, $2 = built binary path
  [ -x "$2" ] || { echo "$1: build did not produce $2" >&2; exit 1; }
  install -m 0755 "$2" "$INSTALL_DIR/$1"
  ln -sf "$INSTALL_DIR/$1" "$BIN_DIR/$1"
  echo "Installed  $INSTALL_DIR/$1   (local build)"
  echo "Linked     $BIN_DIR/$1"
}

# Platform contract (same split the release lane uses): the Swift port on macOS
# (Apple Silicon), the Rust port off-Apple. Both produce `mootx01` (the CLI) and
# `moot-mgr` (the management console).
mgr_installed=1
if [ "$(uname -s)" = "Darwin" ]; then
  echo "Building mootx01 + moot-mgr (Swift, release) ..."
  swift build -c release --package-path "$ROOT/apps/mootx01"  --product mootx01
  swift build -c release --package-path "$ROOT/apps/moot-mgr" --product moot-mgr
  place mootx01  "$ROOT/apps/mootx01/.build/release/mootx01"
  place moot-mgr "$ROOT/apps/moot-mgr/.build/release/moot-mgr"
else
  echo "Building mootx01 + moot-mgr (Rust, release) ..."
  cargo build --release --locked --manifest-path "$ROOT/apps/mootx01/rust/Cargo.toml"
  cargo build --release --locked --manifest-path "$ROOT/apps/moot-mgr/rust/Cargo.toml"
  place mootx01  "$ROOT/apps/mootx01/rust/target/release/mootx01"
  place moot-mgr "$ROOT/apps/moot-mgr/rust/target/release/moot-mgr"
fi

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
if [ "$mgr_installed" = "1" ]; then
  echo "Management console:  moot-mgr serve   (http://127.0.0.1:4200)"
fi
