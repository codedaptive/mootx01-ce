#!/usr/bin/env bash
#
# install.sh — MOOTx01 installer (LAUNCH-05 Part 1).
#
# Builds the mootx01-mcp release binary, places it under the user's
# data directory, and merges an `mcpServers` entry named "mootx01"
# into every supported MCP client's configuration file.
#
# The merge is in-place and idempotent: re-running the installer
# replaces the existing entry rather than appending duplicates.
# Client config files that do not exist yet are created with the
# minimal `{ "mcpServers": { ... } }` shape; existing config keys
# are preserved untouched.
#
# Per LAUNCH_PLAN.md §"The Monday cut", Monday targets macOS only.
# The script exits early with a clear message on other platforms.
#
# First-run (LAUNCH-05 Part 2) is NOT done here. mootx01-mcp itself
# does the first-run on the next launch by a client: if the estate
# database is absent it calls LocusKit.Estate.create to bootstrap a
# fresh MOOT on the MDCC default, then opens it and serves stdio.
# That keeps the install side dead-simple ("install, restart your
# client, you have a MOOT") and avoids any post-install daemon.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
INSTALL_PREFIX="${MOOTX01_INSTALL_PREFIX:-$HOME/.local/share/MOOTx01}"
BIN_DIR="$INSTALL_PREFIX/bin"
BINARY_NAME="mootx01-mcp"
BINARY_PATH="$BIN_DIR/$BINARY_NAME"
SERVER_NAME="mootx01"
DRY_RUN="${MOOTX01_DRY_RUN:-0}"

# Client config paths, parallel to MCPClients.supported in
# Installer/Sources/MootInstallerCore/ClientConfig.swift. The Swift
# list is the source of truth for the executable; this shell list is
# what install.sh actually merges into. They must stay in sync.
#
# Bash 3.2 (the macOS-default shell) lacks associative arrays, so the
# three columns are kept as parallel indexed arrays. Add a new client
# by appending to all three lists at the same index.
CLIENT_LABELS=(
    "Claude Desktop"
    "Claude Code"
    "Cursor"
    "Cline"
)
CLIENT_CONFIGS=(
    "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    "$HOME/.claude.json"
    "$HOME/.cursor/mcp.json"
    "$HOME/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"
)
# Continue uses YAML, not JSON, so it is templated separately below.
CONTINUE_DIR="$HOME/.continue/mcpServers"
CONTINUE_CONFIG="$CONTINUE_DIR/mootx01.yaml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    printf '%s\n' "$*" >&2
}

die() {
    log "install.sh: $*"
    exit 1
}

require_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        die "Monday cut is macOS only. Detected $(uname -s). Aborting."
    fi
}

require_python3() {
    if ! command -v python3 >/dev/null 2>&1; then
        die "python3 not found on PATH. Required for JSON config merge."
    fi
}

require_swift() {
    if ! command -v swift >/dev/null 2>&1; then
        die "swift not found on PATH. Install Xcode or the Swift toolchain."
    fi
}

run() {
    # Echoes the command, then runs it. Suppresses execution under
    # MOOTX01_DRY_RUN=1 so test_install_sh.sh can verify the call
    # graph without actually touching the filesystem or invoking
    # swift build. Arguments are passed as real argv (no eval), so
    # paths containing spaces survive intact.
    log "+ $*"
    if [[ "$DRY_RUN" != "1" ]]; then
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Build and place the binary
# ---------------------------------------------------------------------------

build_binary() {
    log ""
    log "Building mootx01-mcp (release)..."
    require_swift
    run swift build -c release --package-path "$SCRIPT_DIR" --product mootx01-mcp
}

place_binary() {
    log ""
    log "Installing $BINARY_NAME to $BIN_DIR/"
    run mkdir -p "$BIN_DIR"
    if [[ "$DRY_RUN" != "1" ]]; then
        local built="$SCRIPT_DIR/.build/release/$BINARY_NAME"
        [[ -f "$built" ]] || die "build artifact missing at $built"
        cp -f "$built" "$BINARY_PATH"
        chmod 755 "$BINARY_PATH"
    fi
    log "  binary: $BINARY_PATH"
}

# ---------------------------------------------------------------------------
# JSON config merge (Python so we can do it without jq)
# ---------------------------------------------------------------------------

merge_json_config() {
    local config_path="$1"
    local label="$2"
    log ""
    log "Wiring $label ($config_path)"
    run mkdir -p "$(dirname "$config_path")"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  (dry run) would merge \"$SERVER_NAME\" entry into $config_path"
        return 0
    fi
    require_python3
    BINARY_PATH="$BINARY_PATH" \
    SERVER_NAME="$SERVER_NAME" \
    CONFIG_PATH="$config_path" \
        python3 - <<'PY'
import json, os, sys
config_path = os.environ["CONFIG_PATH"]
server_name = os.environ["SERVER_NAME"]
binary_path = os.environ["BINARY_PATH"]

# Load existing config or start fresh. We tolerate a missing or
# empty file (treat as {}) but refuse to clobber a file that exists
# and is not valid JSON — that almost certainly means the user has
# something we shouldn't touch.
data = {}
if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8") as fh:
        content = fh.read().strip()
    if content:
        try:
            data = json.loads(content)
        except json.JSONDecodeError as exc:
            sys.stderr.write(
                f"install.sh: refusing to merge into invalid JSON at {config_path}: {exc}\n"
            )
            sys.exit(2)
        if not isinstance(data, dict):
            sys.stderr.write(
                f"install.sh: refusing to merge into non-object JSON at {config_path}\n"
            )
            sys.exit(2)

servers = data.get("mcpServers")
if not isinstance(servers, dict):
    servers = {}

# Replace any existing entry under our server name so re-running
# the installer is idempotent (no duplicate keys, no appended copies).
servers[server_name] = {
    "command": binary_path,
    "args": [],
    "env": {},
}
data["mcpServers"] = servers

# Pretty-print with 2-space indent and a trailing newline; matches
# the convention every MCP client follows when it writes its own
# config and keeps the diff small for review.
out = json.dumps(data, indent=2, sort_keys=True) + "\n"
with open(config_path, "w", encoding="utf-8") as fh:
    fh.write(out)
PY
    log "  merged \"$SERVER_NAME\" -> $config_path"
}

write_continue_yaml() {
    log ""
    log "Wiring Continue ($CONTINUE_CONFIG)"
    run mkdir -p "$CONTINUE_DIR"
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  (dry run) would write $CONTINUE_CONFIG"
        return 0
    fi
    cat > "$CONTINUE_CONFIG" <<EOF
name: $SERVER_NAME
version: 0.1.0
schema: v1
mcpServers:
  - name: $SERVER_NAME
    command: $BINARY_PATH
    args: []
EOF
    log "  wrote $CONTINUE_CONFIG"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "MOOTx01 installer"
    log "  repo:       $REPO_ROOT"
    log "  prefix:     $INSTALL_PREFIX"
    log "  server:     $SERVER_NAME"
    log "  dry-run:    $DRY_RUN"

    require_macos
    build_binary
    place_binary

    local i=0
    while [[ $i -lt ${#CLIENT_LABELS[@]} ]]; do
        merge_json_config "${CLIENT_CONFIGS[$i]}" "${CLIENT_LABELS[$i]}"
        i=$((i + 1))
    done
    write_continue_yaml

    log ""
    log "Done. Restart your MCP client(s) to pick up the new server."
    log "First-run is automatic on the next client launch:"
    log "  the mootx01-mcp binary creates a fresh MOOT under"
    log "  ~/Library/Application Support/MOOTx01/ if none exists yet."
}

main "$@"
