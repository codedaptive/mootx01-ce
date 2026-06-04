#!/usr/bin/env bash
#
# test_install_sh.sh — smoke test for install.sh.
#
# Exercises install.sh in MOOTX01_DRY_RUN=1 mode against a sandboxed
# HOME and INSTALL_PREFIX. Seven tests:
#
#   1. Empty sandbox — all five clients skipped, zero merges.
#   2. Mock Claude Desktop app bundle — one client wired, four skipped.
#   3. --local flag — Claude Code wired to ./.mcp.json, others skipped.
#   4. Permissions step global dry-run — log names correct settings path.
#   5. Permissions step --local dry-run — log names local settings path.
#   6. --no-permissions — permissions step skipped entirely.
#   7. Permissions merge Python logic — idempotent, preserves existing
#      entries, no duplicates after two runs.
#
# Tests 1-2 are the bash leg of AIRA-INSTALL-P1 verification.
# Test 3 is the AIRA-INSTALL-P2 --local coverage.
# Tests 4-7 are the AIRA-INSTALL-P3 auto-allow permissions coverage.
# The Swift ClientDetectionTests cover isPresent behaviour; this
# script covers the install.sh detection-gate and permissions flow.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INSTALLER_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Strip the real PATH down to system-only so command -v claude returns
# nothing in the sandboxed run.
SAFE_PATH="/usr/bin:/bin"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_installer() {
    # Pass all arguments through so callers can inject flags like --local.
    bash "$INSTALLER_DIR/install.sh" "$@" > "$SANDBOX/install.log" 2>&1
}

assert_grep() {
    local needle="$1"
    if ! grep -qF "$needle" "$SANDBOX/install.log"; then
        echo "FAIL: expected log to mention: $needle" >&2
        echo "----- log -----" >&2
        cat "$SANDBOX/install.log" >&2
        echo "---------------" >&2
        exit 1
    fi
}

assert_no_grep() {
    local needle="$1"
    if grep -qF "$needle" "$SANDBOX/install.log"; then
        echo "FAIL: expected log NOT to mention: $needle" >&2
        echo "----- log -----" >&2
        cat "$SANDBOX/install.log" >&2
        echo "---------------" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Test 1: empty sandbox — all five clients skipped, zero merges
# ---------------------------------------------------------------------------

mkdir -p "$SANDBOX/home1"
mkdir -p "$SANDBOX/root1"   # empty app root — no mocked app bundles

if ! HOME="$SANDBOX/home1" \
     MOOTX01_INSTALL_PREFIX="$SANDBOX/prefix1" \
     MOOTX01_DRY_RUN=1 \
     MOOTX01_DETECT_ROOT="$SANDBOX/root1" \
     PATH="$SAFE_PATH" \
     run_installer; then
    echo "FAIL: install.sh exited non-zero in test 1 (empty sandbox):" >&2
    cat "$SANDBOX/install.log" >&2
    exit 1
fi

# All five clients must appear in the log (skip messages)
assert_grep "Claude Desktop"
assert_grep "Claude Code"
assert_grep "Cursor"
assert_grep "Cline"
assert_grep "Continue"

# All five must be tagged as skipped
assert_grep "skipping Claude Desktop"
assert_grep "skipping Claude Code"
assert_grep "skipping Cursor"
assert_grep "skipping Cline"
assert_grep "skipping Continue"

# Skipped summary must appear
assert_grep "Skipped:"
assert_grep "Install them and re-run to wire."

# No merge/wire actions must have occurred
assert_no_grep "would merge"
assert_no_grep "merged"

# Build step must be announced (suppressed under dry-run but logged)
assert_grep "Building mootx01-mcp"

echo "test 1 (empty sandbox, all skipped): ok"

# ---------------------------------------------------------------------------
# Test 2: mock Claude Desktop only — one wired, four skipped
# ---------------------------------------------------------------------------

mkdir -p "$SANDBOX/home2"
mkdir -p "$SANDBOX/root2/Applications/Claude.app"  # mock Claude Desktop bundle

if ! HOME="$SANDBOX/home2" \
     MOOTX01_INSTALL_PREFIX="$SANDBOX/prefix2" \
     MOOTX01_DRY_RUN=1 \
     MOOTX01_DETECT_ROOT="$SANDBOX/root2" \
     PATH="$SAFE_PATH" \
     run_installer; then
    echo "FAIL: install.sh exited non-zero in test 2 (mock Claude Desktop):" >&2
    cat "$SANDBOX/install.log" >&2
    exit 1
fi

# Claude Desktop must be wired (dry-run merge log)
assert_grep "Wiring Claude Desktop"
assert_grep "would merge"

# The other four must be skipped
assert_grep "skipping Claude Code"
assert_grep "skipping Cursor"
assert_grep "skipping Cline"
assert_grep "skipping Continue"

# Skipped summary must name the four skipped clients
assert_grep "Skipped:"

echo "test 2 (mock Claude Desktop, one wired): ok"

# ---------------------------------------------------------------------------
# Test 3: --local flag — Claude Code wired to .mcp.json, others skipped
# ---------------------------------------------------------------------------

mkdir -p "$SANDBOX/home3"
mkdir -p "$SANDBOX/root3"   # empty app root — no mocked app bundles
mkdir -p "$SANDBOX/bin3"
# Provide a mock 'claude' binary so detect_client "Claude Code" "command:claude"
# returns true in the sandboxed PATH.
printf '#!/bin/sh\n' > "$SANDBOX/bin3/claude"
chmod +x "$SANDBOX/bin3/claude"

if ! HOME="$SANDBOX/home3" \
     MOOTX01_INSTALL_PREFIX="$SANDBOX/prefix3" \
     MOOTX01_DRY_RUN=1 \
     MOOTX01_DETECT_ROOT="$SANDBOX/root3" \
     PATH="$SANDBOX/bin3:$SAFE_PATH" \
     run_installer --local; then
    echo "FAIL: install.sh --local exited non-zero in test 3:" >&2
    cat "$SANDBOX/install.log" >&2
    exit 1
fi

# Header must declare local-scope active
assert_grep "local-scope: 1"

# The [local] override log must appear
assert_grep "[local] wiring Claude Code to ./.mcp.json"

# Claude Code must be wired (dry-run merge log) — to .mcp.json, not .claude.json
assert_grep "Wiring Claude Code"
assert_grep ".mcp.json"

# The global .claude.json path must NOT appear in any "would merge" line.
# With --local the resolved config_path is $PWD/.mcp.json, so .claude.json
# has no business appearing anywhere in the installer log.
assert_no_grep ".claude.json"

# All non-Claude-Code clients must be skipped (no bundles in root3)
assert_grep "skipping Claude Desktop"
assert_grep "skipping Cursor"
assert_grep "skipping Cline"
assert_grep "skipping Continue"

echo "test 3 (--local flag, Claude Code wired to .mcp.json): ok"

# ---------------------------------------------------------------------------
# Test 4: global permissions — dry-run shows correct target path
# ---------------------------------------------------------------------------

mkdir -p "$SANDBOX/home4"
mkdir -p "$SANDBOX/root4"
mkdir -p "$SANDBOX/bin4"
# Mock claude so Claude Code is detected.
printf '#!/bin/sh\n' > "$SANDBOX/bin4/claude"
chmod +x "$SANDBOX/bin4/claude"

if ! HOME="$SANDBOX/home4" \
     MOOTX01_INSTALL_PREFIX="$SANDBOX/prefix4" \
     MOOTX01_DRY_RUN=1 \
     MOOTX01_DETECT_ROOT="$SANDBOX/root4" \
     PATH="$SANDBOX/bin4:$SAFE_PATH" \
     run_installer; then
    echo "FAIL: install.sh exited non-zero in test 4 (global permissions dry-run):" >&2
    cat "$SANDBOX/install.log" >&2
    exit 1
fi

# Permissions step must appear in the log.
assert_grep "Wiring ARIA tool permissions"
# Dry-run message must name the global settings path.
assert_grep ".claude/settings.json"
assert_grep "would add ARIA tools to permissions.allow"
# The global path sits under $HOME/.claude/settings.json.
assert_grep "$SANDBOX/home4/.claude/settings.json"

echo "test 4 (global permissions dry-run): ok"

# ---------------------------------------------------------------------------
# Test 5: --local permissions — dry-run targets ./.claude/settings.json
# ---------------------------------------------------------------------------

mkdir -p "$SANDBOX/home5"
mkdir -p "$SANDBOX/root5"
# Reuse the claude mock from test 4.

if ! HOME="$SANDBOX/home5" \
     MOOTX01_INSTALL_PREFIX="$SANDBOX/prefix5" \
     MOOTX01_DRY_RUN=1 \
     MOOTX01_DETECT_ROOT="$SANDBOX/root5" \
     PATH="$SANDBOX/bin4:$SAFE_PATH" \
     run_installer --local; then
    echo "FAIL: install.sh exited non-zero in test 5 (--local permissions dry-run):" >&2
    cat "$SANDBOX/install.log" >&2
    exit 1
fi

# Permissions step must appear.
assert_grep "Wiring ARIA tool permissions"
assert_grep "would add ARIA tools to permissions.allow"
# The local path ends in .claude/settings.json under $PWD (not $HOME).
assert_grep ".claude/settings.json"
# The global home path must NOT appear as the permissions target when --local.
assert_no_grep "$SANDBOX/home5/.claude/settings.json"

echo "test 5 (--local permissions dry-run, local path): ok"

# ---------------------------------------------------------------------------
# Test 6: --no-permissions — permissions step is skipped entirely
# ---------------------------------------------------------------------------

mkdir -p "$SANDBOX/home6"
mkdir -p "$SANDBOX/root6"

if ! HOME="$SANDBOX/home6" \
     MOOTX01_INSTALL_PREFIX="$SANDBOX/prefix6" \
     MOOTX01_DRY_RUN=1 \
     MOOTX01_DETECT_ROOT="$SANDBOX/root6" \
     PATH="$SANDBOX/bin4:$SAFE_PATH" \
     run_installer --no-permissions; then
    echo "FAIL: install.sh exited non-zero in test 6 (--no-permissions):" >&2
    cat "$SANDBOX/install.log" >&2
    exit 1
fi

# Skip message must appear.
assert_grep "Skipping permissions step (--no-permissions)"
# No permissions wiring must have been attempted.
assert_no_grep "Wiring ARIA tool permissions"
assert_no_grep "would add ARIA tools to permissions.allow"

echo "test 6 (--no-permissions skips step): ok"

# ---------------------------------------------------------------------------
# Test 7: permissions merge idempotency and key preservation (Python direct)
#
# Exercises the set-union merge logic used by write_permissions() without
# going through install.sh's build/place steps. Verifies:
#   a) all ARIA tools are written to permissions.allow
#   b) pre-existing allow entries (including non-ARIA tools) are preserved
#   c) re-running the merge produces no duplicates
# ---------------------------------------------------------------------------

SETTINGS_TMP="$(mktemp)"
trap 'rm -f "$SETTINGS_TMP"; rm -rf "$SANDBOX"' EXIT

# Pre-existing settings: one ARIA tool already present plus an unrelated entry.
printf '{"someKey":"keep-me","permissions":{"allow":["mcp__mootx01__moot_capture_drawer","OtherTool"]}}\n' \
    > "$SETTINGS_TMP"

# The merge Python extracted from write_permissions() — run it twice.
run_merge() {
    SETTINGS_PATH="$SETTINGS_TMP" python3 - <<'PY'
import json, os, sys
settings_path = os.environ["SETTINGS_PATH"]
ARIA_TOOLS = [
    "mcp__mootx01__moot_capture_drawer",
    "mcp__mootx01__moot_reanchor_drawer",
    "mcp__mootx01__moot_mutate_drawer",
    "mcp__mootx01__moot_withdraw_drawer",
    "mcp__mootx01__moot_expunge_drawer",
    "mcp__mootx01__moot_drawer_recall",
    "mcp__mootx01__moot_capture_tunnel",
    "mcp__mootx01__moot_mutate_tunnel",
    "mcp__mootx01__moot_withdraw_tunnel",
    "mcp__mootx01__moot_expunge_tunnel",
    "mcp__mootx01__moot_tunnel_recall",
    "mcp__mootx01__moot_mutate_kgFact",
    "mcp__mootx01__moot_withdraw_kgFact",
    "mcp__mootx01__moot_expunge_kgFact",
    "mcp__mootx01__moot_kgFact_recall",
    "mcp__mootx01__moot_diaryEntry_recall",
    "mcp__mootx01__moot_mutate_proposal",
    "mcp__mootx01__moot_withdraw_proposal",
    "mcp__mootx01__moot_expunge_proposal",
    "mcp__mootx01__moot_proposal_recall",
    "mcp__mootx01__moot_mutate_association",
    "mcp__mootx01__moot_expunge_association",
    "mcp__mootx01__moot_association_recall",
    "mcp__mootx01__moot_learn_learnedReference",
    "mcp__mootx01__moot_mutate_learnedReference",
    "mcp__mootx01__moot_withdraw_learnedReference",
    "mcp__mootx01__moot_expunge_learnedReference",
    "mcp__mootx01__moot_learnedReference_recall",
    "mcp__mootx01__moot_cross_estate_recall",
    "mcp__mootx01__moot_list_recipes",
    "mcp__mootx01__moot_grounded_synthesis",
    "mcp__mootx01__moot_run_migration_benchmark",
    "mcp__mootx01__moot_confirm_migration_promotion",
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
        data = json.loads(content)
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
with open(settings_path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
}

run_merge
run_merge  # second run must not duplicate any entry

python3 - <<PY
import json, sys
with open("$SETTINGS_TMP") as f:
    data = json.load(f)
allow = data["permissions"]["allow"]
dupes = [t for t in set(allow) if allow.count(t) > 1]
if dupes:
    print("FAIL: duplicate entries in permissions.allow:", dupes, file=sys.stderr)
    sys.exit(1)
assert data.get("someKey") == "keep-me", "FAIL: unrelated key was clobbered"
assert "mcp__mootx01__moot_capture_drawer" in allow, "FAIL: ARIA tool missing"
assert "OtherTool" in allow, "FAIL: pre-existing non-ARIA tool was removed"
assert len(allow) == 54, f"FAIL: expected 54 entries (53 ARIA + OtherTool; moot_capture_drawer was pre-existing so no dup), got {len(allow)}"
PY

echo "test 7 (permissions merge idempotency and key preservation): ok"

echo "test_install_sh.sh: ok"
