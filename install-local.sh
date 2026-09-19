#!/bin/sh
#
# mootx01 OFFLINE / local installer — for testing a locally-built binary.
#
# Builds mootx01 from source and places it at ~/.mootx01/bin/mootx01 with a
# ~/.local/bin exec wrapper — the exact layout the release `install.sh` and the
# `mootx01 install` subcommand produce, SPM resource bundles included. This is
# the offline counterpart of install.sh for the binaries; the encoder models
# are release assets either way and are fetched and hash-verified below.
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

# The PATH entry is an exec WRAPPER, not a symlink: the Swift runtime resolves
# each Bundle.module target's SPM resource bundle (<Target>_<Target>.bundle)
# from the directory of the path the binary was INVOKED as, without following a
# symlink at that path. A symlinked ~/.local/bin/mootx01 looks for the bundles
# in ~/.local/bin, finds nothing, and fatalErrors on the first resource touch.
# Same shape install.sh writes and Installer.writePathWrapper writes — keep the
# three in step.
write_path_wrapper() {
  _target="$1"; _entry="$2"
  rm -f "$_entry"
  cat > "$_entry" <<WRAP
#!/bin/sh
# mootx01 PATH wrapper — exec the real binary from its install dir so
# SPM resource bundles (<Target>_<Target>.bundle) resolve beside the
# executable. A symlink here breaks that lookup. Written by install-local.sh;
# install.sh and Installer.writePathWrapper write the same shape.
exec "$_target" "\$@"
WRAP
  chmod 0755 "$_entry"
}

# Place a freshly built binary, the SPM resource bundles built beside it, and a
# PATH wrapper. The bundles are what separates this from a bare `cp`: a build
# directory holds them next to the executable, and an install that leaves them
# behind crashes the first time anything classifies or searches.
place() {  # $1 = product name, $2 = built binary path
  [ -x "$2" ] || { echo "$1: build did not produce $2" >&2; exit 1; }
  install -m 0755 "$2" "$INSTALL_DIR/$1"
  write_path_wrapper "$INSTALL_DIR/$1" "$BIN_DIR/$1"
  echo "Installed  $INSTALL_DIR/$1   (local build)"
  echo "Wrapped    $BIN_DIR/$1"
  for _bundle in "$(dirname "$2")"/*.bundle; do
    [ -e "$_bundle" ] || continue
    _bname="$(basename "$_bundle")"
    rm -rf "${INSTALL_DIR:?}/$_bname"
    cp -R "$_bundle" "$INSTALL_DIR/$_bname"
    echo "Installed  $INSTALL_DIR/$_bname"
  done
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
  # Both crates write into one target directory when CARGO_TARGET_DIR is set
  # (the Makefile and scripts/moot-test set it to $ROOT/.cargo-target). When it
  # is not — a bare ./install-local.sh — cargo uses its per-workspace default,
  # which puts each binary under its own crate's target/.
  if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    place mootx01  "$CARGO_TARGET_DIR/release/mootx01"
    place moot-mgr "$CARGO_TARGET_DIR/release/moot-mgr"
  else
    place mootx01  "$ROOT/apps/mootx01/rust/target/release/mootx01"
    place moot-mgr "$ROOT/apps/moot-mgr/rust/target/release/moot-mgr"
  fi
fi

# The encoder and fact-extraction models are release assets, not build output,
# so a source build has to fetch them the same way CI does. fetch-release.sh is
# idempotent — a already-verified layout exits 0 without downloading — so this
# costs nothing on the re-run-after-a-code-change path this script is built for.
if [ "$(uname -s)" = "Darwin" ]; then
  _model_platform=apple
else
  _model_platform=linux
fi
_models_root="$(dirname "$INSTALL_DIR")/share/mootx01/models"
sh "$ROOT/tools/encoder-models/fetch-release.sh" "$_model_platform" \
  "$_models_root/arctic-embed-s-w60"
sh "$ROOT/tools/encoder-models/fetch-release.sh" "$_model_platform" \
  "$_models_root/nuextract-tiny-v1.5" nuextract-tiny-v1.5

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
