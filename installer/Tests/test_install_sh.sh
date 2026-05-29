#!/usr/bin/env bash
#
# test_install_sh.sh — smoke test for install.sh.
#
# Exercises install.sh in MOOTX01_DRY_RUN=1 mode against a sandboxed
# HOME and INSTALL_PREFIX. Verifies that:
#
#   1. The script runs to completion under dry-run without touching
#      the user's real config directories.
#   2. Every supported client config path is announced in the run
#      log so a future client added to MCPClients.supported but not
#      to install.sh's CLIENT_IDS would be caught by the diff.
#   3. The Continue YAML path is announced.
#
# This is the bash leg of LAUNCH-05 verification. The Swift
# MootInstallerCoreTests cover the path math and config shape; this
# script covers the install.sh control flow.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INSTALLER_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
export MOOTX01_INSTALL_PREFIX="$SANDBOX/prefix"
export MOOTX01_DRY_RUN=1
mkdir -p "$HOME"

log_file="$SANDBOX/install.log"
if ! bash "$INSTALLER_DIR/install.sh" > "$log_file" 2>&1; then
    echo "install.sh exited non-zero under dry-run:" >&2
    cat "$log_file" >&2
    exit 1
fi

assert_grep() {
    local needle="$1"
    if ! grep -qF "$needle" "$log_file"; then
        echo "FAIL: expected log to mention: $needle" >&2
        echo "----- log -----" >&2
        cat "$log_file" >&2
        echo "---------------" >&2
        exit 1
    fi
}

# Every client install.sh declares should show up in the run log.
assert_grep "Claude Desktop"
assert_grep "Claude Code"
assert_grep "Cursor"
assert_grep "Cline"
assert_grep "Continue"

# Sandbox HOME must appear in the resolved paths.
assert_grep "$HOME"

# The build step must be announced (and skipped under dry-run).
assert_grep "Building mootx01-mcp"

echo "test_install_sh.sh: ok"
