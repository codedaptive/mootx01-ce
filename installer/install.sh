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
# When set, absolute app-bundle detect paths are prefixed with this root.
# Empty string (the default) probes the real filesystem.
# Used by test_install_sh.sh to sandbox app-bundle detection.
DETECT_ROOT="${MOOTX01_DETECT_ROOT:-}"
# When 1 (set via --local), Claude Code is wired to ./.mcp.json in the
# current working directory instead of ~/.claude.json. All other clients
# remain global. Claude Code is the only supported client with a
# project-scoped config; the flag has no effect on the others.
LOCAL_SCOPE=0
# When 1 (set via --no-permissions), the write_permissions step is skipped.
# ARIA tools will remain subject to per-tool approval prompts in Claude clients.
NO_PERMISSIONS=0

# Client config paths, parallel to MCPClients.supported in
# installer/Sources/MootInstallerCore/ClientConfig.swift. The Swift
# list is the source of truth for the executable; this shell list is
# what install.sh actually merges into. They must stay in sync.
#
# Bash 3.2 (the macOS-default shell) lacks associative arrays, so the
# four columns are kept as parallel indexed arrays. Add a new client
# by appending to all four lists at the same index.
#
# CLIENT_DETECT entries match the detectPath values in MCPClient.supported:
#   - Absolute path  → checked with [ -e path ]
#   - "command:<cmd>" → checked with command -v <cmd>
#   - "glob:<dir>:<prefix>" → checks if any entry in <dir> starts with <prefix>
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
CLIENT_DETECT=(
    "/Applications/Claude.app"
    "command:claude"
    "/Applications/Cursor.app"
    "glob:$HOME/.vscode/extensions:saoudrizwan.claude-dev-"
)
# Continue uses YAML, not JSON, so it is templated separately below.
CONTINUE_DIR="$HOME/.continue/mcpServers"
CONTINUE_CONFIG="$CONTINUE_DIR/mootx01.yaml"
# Continue detection: probe for ~/.continue directory existence.
CONTINUE_DETECT_DIR="$HOME/.continue"

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

# detect_client <label> <probe>
#
# Returns 0 (true) if the client identified by <probe> appears to be
# installed, 1 (false) otherwise. Detection is always read-only;
# the MOOTX01_DRY_RUN flag does not suppress it.
#
# Probe formats:
#   /absolute/path         → file or directory existence check
#   command:<cmd>          → command -v <cmd> (CLI on PATH)
#   glob:<dir>:<prefix>    → any entry in <dir> starts with <prefix>
detect_client() {
    local label="$1"   # unused inside this function; callers use it for log messages
    local probe="$2"

    if [[ "$probe" == command:* ]]; then
        local cmd="${probe#command:}"
        command -v "$cmd" >/dev/null 2>&1
        return $?
    elif [[ "$probe" == glob:* ]]; then
        # strip "glob:" prefix, then split on first ":"
        local rest="${probe#glob:}"
        local dir="${rest%%:*}"
        local prefix="${rest#*:}"
        if [[ ! -d "$dir" ]]; then
            return 1
        fi
        # look for any directory entry with the given prefix
        local found=0
        while IFS= read -r -d $'\0' entry; do
            local name
            name="$(basename "$entry")"
            if [[ "$name" == "${prefix}"* ]]; then
                found=1
                break
            fi
        done < <(find "$dir" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
        return $((1 - found))
    else
        # absolute path — existence check.
        # MOOTX01_DETECT_ROOT (test-only) is prepended to absolute paths
        # so tests can sandbox app-bundle detection without touching /Applications.
        local check_path
        if [[ -n "$DETECT_ROOT" && "$probe" == /* ]]; then
            check_path="${DETECT_ROOT}${probe}"
        else
            check_path="$probe"
        fi
        [[ -e "$check_path" ]]
        return $?
    fi
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

# ---------------------------------------------------------------------------
# Claude settings permissions merge
# ---------------------------------------------------------------------------

write_permissions() {
    if [[ "$NO_PERMISSIONS" == "1" ]]; then
        log ""
        log "Skipping permissions step (--no-permissions)."
        return 0
    fi

    # Resolve the settings file path. When --local was used, Claude Code is
    # wired to a project-scoped .mcp.json, so the matching settings target is
    # the project-local .claude/settings.json. Otherwise the global file under
    # $HOME is the right target; that is what Claude Desktop and Claude Code
    # both read for their global permissions.allow list.
    local settings_path
    if [[ "$LOCAL_SCOPE" == "1" ]]; then
        settings_path="$PWD/.claude/settings.json"
    else
        settings_path="$HOME/.claude/settings.json"
    fi

    log ""
    log "Wiring ARIA tool permissions ($settings_path)"
    run mkdir -p "$(dirname "$settings_path")"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "  (dry run) would add ARIA tools to permissions.allow in $settings_path"
        return 0
    fi

    require_python3

    # Set-union the full ARIA tool list into permissions.allow.
    # The merge is additive: existing entries (including non-ARIA tools) are
    # preserved. Running the installer twice does not duplicate entries.
    # Tool name format: mcp__{server}__{tool}, where server is SERVER_NAME
    # ("mootx01") and tool is the MCP-facing name from ToolProjection.swift,
    # RecipeTools.swift, LensTools.swift, and VaultTools.swift.
    SETTINGS_PATH="$settings_path" \
        python3 - <<'PY'
import json, os, sys

settings_path = os.environ["SETTINGS_PATH"]

# Complete list of ARIA MCP tools the mootx01 server exposes.
# Sourced from apps/ARIA_MCP/Sources/AriaMCP/:
#   ToolProjection.swift  — lexicon projection of AriaLexicon acceptance matrix
#   RecipeTools.swift     — CognitionKit behaviour-recipe surface
#   LensTools.swift       — reasoning-lens and analytics tools
#   VaultTools.swift      — VaultKit export/import/status/reconcile tools
ARIA_TOOLS = [
    # --- Lexicon tools: Drawer ---
    "mcp__mootx01__moot_capture_drawer",
    "mcp__mootx01__moot_reanchor_drawer",
    "mcp__mootx01__moot_mutate_drawer",
    "mcp__mootx01__moot_withdraw_drawer",
    "mcp__mootx01__moot_expunge_drawer",
    "mcp__mootx01__moot_drawer_recall",
    # --- Lexicon tools: Tunnel ---
    "mcp__mootx01__moot_capture_tunnel",
    "mcp__mootx01__moot_mutate_tunnel",
    "mcp__mootx01__moot_withdraw_tunnel",
    "mcp__mootx01__moot_expunge_tunnel",
    "mcp__mootx01__moot_tunnel_recall",
    # --- Lexicon tools: KGFact ---
    "mcp__mootx01__moot_mutate_kgFact",
    "mcp__mootx01__moot_withdraw_kgFact",
    "mcp__mootx01__moot_expunge_kgFact",
    "mcp__mootx01__moot_kgFact_recall",
    # --- Lexicon tools: DiaryEntry ---
    "mcp__mootx01__moot_diaryEntry_recall",
    # --- Lexicon tools: Proposal ---
    "mcp__mootx01__moot_mutate_proposal",
    "mcp__mootx01__moot_withdraw_proposal",
    "mcp__mootx01__moot_expunge_proposal",
    "mcp__mootx01__moot_proposal_recall",
    # --- Lexicon tools: Association ---
    "mcp__mootx01__moot_mutate_association",
    "mcp__mootx01__moot_expunge_association",
    "mcp__mootx01__moot_association_recall",
    # --- Lexicon tools: LearnedReference ---
    "mcp__mootx01__moot_learn_learnedReference",
    "mcp__mootx01__moot_mutate_learnedReference",
    "mcp__mootx01__moot_withdraw_learnedReference",
    "mcp__mootx01__moot_expunge_learnedReference",
    "mcp__mootx01__moot_learnedReference_recall",
    # --- Federation tool (ToolDispatcher.crossEstateRecallToolName) ---
    "mcp__mootx01__moot_cross_estate_recall",
    # --- Recipe tools (RecipeTools.swift) ---
    "mcp__mootx01__moot_list_recipes",
    "mcp__mootx01__moot_grounded_synthesis",
    "mcp__mootx01__moot_run_migration_benchmark",
    "mcp__mootx01__moot_confirm_migration_promotion",
    # --- Lens tools (LensTools.swift) ---
    "mcp__mootx01__moot_keystones",
    "mcp__mootx01__moot_constellation",
    "mcp__mootx01__moot_free_association",
    "mcp__mootx01__moot_theme_weather",
    "mcp__mootx01__moot_latent_themes",
    "mcp__mootx01__moot_bias",
    "mcp__mootx01__moot_drift",
    "mcp__mootx01__moot_contradiction",
    "mcp__mootx01__moot_trust_grounded_synthesis",
    "mcp__mootx01__moot_partial_cue_recall",
    "mcp__mootx01__moot_anticipate",
    "mcp__mootx01__moot_tunnel_successor",
    "mcp__mootx01__moot_mind_overlap",
    "mcp__mootx01__moot_estate_divergence",
    "mcp__mootx01__moot_association_rules",
    "mcp__mootx01__moot_formal_concepts",
    # --- Vault tools (VaultTools.swift) ---
    "mcp__mootx01__moot_vault_export",
    "mcp__mootx01__moot_vault_import",
    "mcp__mootx01__moot_vault_status",
    "mcp__mootx01__moot_vault_reconcile",
]

data = {}
if os.path.exists(settings_path):
    with open(settings_path, "r", encoding="utf-8") as fh:
        content = fh.read().strip()
    if content:
        try:
            data = json.loads(content)
        except json.JSONDecodeError as exc:
            sys.stderr.write(
                f"install.sh: refusing to merge into invalid JSON at {settings_path}: {exc}\n"
            )
            sys.exit(2)
        if not isinstance(data, dict):
            sys.stderr.write(
                f"install.sh: refusing to merge into non-object JSON at {settings_path}\n"
            )
            sys.exit(2)

# Set-union ARIA tools into permissions.allow; every other key is preserved.
permissions = data.get("permissions")
if not isinstance(permissions, dict):
    permissions = {}

existing = permissions.get("allow")
if not isinstance(existing, list):
    existing = []

existing_set = set(existing)
for tool in ARIA_TOOLS:
    if tool not in existing_set:
        existing.append(tool)
        existing_set.add(tool)

permissions["allow"] = existing
data["permissions"] = permissions

out = json.dumps(data, indent=2, sort_keys=True) + "\n"
with open(settings_path, "w", encoding="utf-8") as fh:
    fh.write(out)
PY
    log "  added ARIA tools to permissions.allow in $settings_path"
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
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local) LOCAL_SCOPE=1; shift ;;
            --no-permissions) NO_PERMISSIONS=1; shift ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    log "MOOTx01 installer"
    log "  repo:       $REPO_ROOT"
    log "  prefix:     $INSTALL_PREFIX"
    log "  server:     $SERVER_NAME"
    log "  dry-run:    $DRY_RUN"
    log "  local-scope: $LOCAL_SCOPE"
    log "  no-permissions: $NO_PERMISSIONS"

    require_macos
    build_binary
    place_binary

    local skipped=()

    local i=0
    while [[ $i -lt ${#CLIENT_LABELS[@]} ]]; do
        local label="${CLIENT_LABELS[$i]}"
        local probe="${CLIENT_DETECT[$i]}"
        # Resolve effective config path: when --local is set, Claude Code
        # (index 1 in the parallel arrays) is wired to ./.mcp.json instead
        # of ~/.claude.json. All other clients remain global-only.
        local config="${CLIENT_CONFIGS[$i]}"
        if [[ "$LOCAL_SCOPE" == "1" && "$label" == "Claude Code" ]]; then
            config="$PWD/.mcp.json"
            log "  [local] wiring Claude Code to ./.mcp.json"
        fi
        if detect_client "$label" "$probe"; then
            merge_json_config "$config" "$label"
        else
            log ""
            log "  skipping $label (not detected)"
            skipped+=("$label")
        fi
        i=$((i + 1))
    done

    if detect_client "Continue" "$CONTINUE_DETECT_DIR"; then
        write_continue_yaml
    else
        log ""
        log "  skipping Continue (not detected)"
        skipped+=("Continue")
    fi

    write_permissions

    log ""
    if [[ ${#skipped[@]} -gt 0 ]]; then
        local skip_list
        skip_list="$(printf '%s, ' "${skipped[@]}")"
        skip_list="${skip_list%, }"
        log "Skipped: ${skip_list}. Install them and re-run to wire."
        log ""
    fi
    log "Done. Restart your MCP client(s) to pick up the new server."
    log "First-run is automatic on the next client launch:"
    log "  the mootx01-mcp binary creates a fresh MOOT under"
    log "  ~/Library/Application Support/MOOTx01/ if none exists yet."
}

main "$@"
