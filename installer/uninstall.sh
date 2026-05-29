#!/usr/bin/env bash
#
# uninstall.sh — reverse of install.sh.
#
# Removes the mootx01-mcp binary, deletes the `mcpServers["mootx01"]`
# entry from every supported client config, and deletes the Continue
# YAML snippet. Leaves the MOOT data directory (~/Library/Application
# Support/MOOTx01/) intact unless --purge is passed; the user's
# substrate database is theirs and the uninstaller refuses to touch
# it by default.

set -euo pipefail

INSTALL_PREFIX="${MOOTX01_INSTALL_PREFIX:-$HOME/.local/share/MOOTx01}"
BINARY_PATH="$INSTALL_PREFIX/bin/mootx01-mcp"
SERVER_NAME="mootx01"
PURGE_DATA=0

DATA_DIR="$HOME/Library/Application Support/MOOTx01"

# Parallel-indexed list; bash 3.2 compatible. Keep ordered the same
# as install.sh.
CLIENT_CONFIGS=(
    "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    "$HOME/.claude.json"
    "$HOME/.cursor/mcp.json"
    "$HOME/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"
)
CONTINUE_CONFIG="$HOME/.continue/mcpServers/mootx01.yaml"

log() { printf '%s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge) PURGE_DATA=1; shift ;;
        *) log "uninstall.sh: unknown argument: $1"; exit 1 ;;
    esac
done

log "MOOTx01 uninstaller"
log "  prefix:  $INSTALL_PREFIX"
log "  purge:   $PURGE_DATA"

# Remove the binary.
if [[ -f "$BINARY_PATH" ]]; then
    log "removing $BINARY_PATH"
    rm -f "$BINARY_PATH"
fi

# Remove the server entry from every JSON client config that still has one.
for config_path in "${CLIENT_CONFIGS[@]}"; do
    [[ -f "$config_path" ]] || continue
    SERVER_NAME="$SERVER_NAME" CONFIG_PATH="$config_path" python3 - <<'PY'
import json, os, sys
config_path = os.environ["CONFIG_PATH"]
server_name = os.environ["SERVER_NAME"]
with open(config_path, "r", encoding="utf-8") as fh:
    content = fh.read().strip()
if not content:
    sys.exit(0)
try:
    data = json.loads(content)
except json.JSONDecodeError:
    sys.stderr.write(f"uninstall.sh: skipping invalid JSON at {config_path}\n")
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
servers = data.get("mcpServers")
if isinstance(servers, dict) and server_name in servers:
    del servers[server_name]
    data["mcpServers"] = servers
    out = json.dumps(data, indent=2, sort_keys=True) + "\n"
    with open(config_path, "w", encoding="utf-8") as fh:
        fh.write(out)
    sys.stderr.write(f"  removed \"{server_name}\" from {config_path}\n")
PY
done

# Remove the Continue YAML snippet.
if [[ -f "$CONTINUE_CONFIG" ]]; then
    log "removing $CONTINUE_CONFIG"
    rm -f "$CONTINUE_CONFIG"
fi

# Purge the data directory only if explicitly requested.
if [[ "$PURGE_DATA" == "1" && -d "$DATA_DIR" ]]; then
    log "purging $DATA_DIR (--purge)"
    rm -rf "$DATA_DIR"
fi

log "done."
