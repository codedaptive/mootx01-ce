#!/usr/bin/env python3
"""MOOTx01 hooks for Claude Code.

One script, seven modes (argv[1]):

  context     UserPromptSubmit  Checkpoint-note reminders as the context window
                                fills (30 / 50 / 70 / 85 %), each rung once per
                                session, chained to a session-scoped location
                                so the next rung can find its predecessor.
                                Reports UNKNOWN, never a percentage, when the
                                model's window is not known.
  precompact  PreCompact        Records that compaction is about to happen so
                                the next SessionStart can trigger recovery, and
                                says so when no handoff note was filed.
  session     SessionStart      Orientation reminder on startup/resume/clear;
                                after compaction, points at this session's
                                handoff note; warns (never edits) if a stale
                                direct `memory` MCP entry is still wired.
  stop        Stop              If MOOTx01 tools were used this session but no
                                durable writeback happened, asks Claude (once)
                                to file memories before finishing.
  plan-approved   PostToolUse   (matcher ExitPlanMode) An approved plan lives
                                only in the session, so at approval the hook
                                marks it pending (`plan_pending` = short hash
                                of the plan text) and asks Claude to file it to
                                `plans/<project>/<plan-slug>` verbatim.
  plan-filed      PostToolUse   (matcher mcp__.*__moot_file_memory) A
                                moot_file_memory call whose location begins
                                `plans/` clears `plan_pending`. Nothing else
                                clears it. Prints nothing.
  precommit-check PreToolUse    (matcher Bash) A `git commit` while
                                `plan_pending` is still set gets a reminder to
                                file the plan first, once per session. Never
                                blocks the command.

Design constraints, on purpose:
  - Python standard library only. No third-party imports.
  - No network access. Ever.
  - Reads only the hook JSON on stdin, the session transcript path that
    Claude Code provides, (session mode only) the user's own ~/.claude.json
    to check for a competing direct MCP entry, and (plan-approved mode only)
    `git rev-parse --show-toplevel` for the repository name. Writes only a
    small state file in a per-user private cache directory (~/.cache/mootx01/hooks
    or $XDG_CACHE_HOME/mootx01/hooks, mode 0o700). NEVER writes to
    ~/.claude.json or any client config — detection is read-only, warn-mode
    only. The hook never edits client configuration.
  - Every failure path exits 0 silently. A broken hook must never break a
    session.

Environment:
  MOOTX01_CONTEXT_WINDOW   Override the assumed context window size in tokens.
                           Without it the window comes from the model id the
                           transcript names (see window_for_model); a model
                           this hook does not know yields no percentage.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

THRESHOLDS = (30, 50, 70, 85)
DEFAULT_WINDOW = 200_000
LARGE_WINDOW = 1_000_000

# Context windows by model id, matched as case-insensitive substrings of the
# transcript's assistant `message.model`. Two lists on purpose: a model that
# matches neither gets NO percentage (see UNKNOWN_WINDOW_MESSAGE) — an assumed
# window can only be wrong in the alarming direction, and a confident wrong
# percentage was used as an input to real decisions before this hook learned
# to say it did not know. Add a fragment only with its window established
# from a primary source; "[1m]" is checked first because it marks the
# 1M-window variant of an otherwise 200k model.
MILLION_WINDOW_MODEL_FRAGMENTS = ("[1m]", "fable", "mythos", "sonnet-5", "opus-5")
STANDARD_WINDOW_MODEL_FRAGMENTS = ("sonnet-4-", "opus-4-6", "haiku-4-5")

# Markers are the MCP-QUALIFIED tool-name fragment ("mcp__<server>__moot_*"
# contains "__moot_*"), which only appears in genuine tool-use records of the
# transcript. Bare "moot_*" names must NOT be used here: this hook's own
# banners (ORIENT_MESSAGE, the context-meter messages) name the bare tools in
# every session's transcript, so a bare match reports tool use that never
# happened.
WRITEBACK_MARKERS = (
    "__moot_file_memory",
    "__moot_file_fact",
    "__moot_link_memories",
    "__moot_write_journal",
    "__moot_update_memory",
    "__moot_confirm_memory",
)

# Every note is filed to a session-scoped location so the next rung can find
# its predecessor without this hook tracking any state, and every note body
# repeats the session id so the chain is findable by search even when a
# tunnel fails.
# SECURITY: every rung tells the model to keep credentials out of the note and
# to file it at the highest sensitivity of anything it recalled under a
# grant, naming that sensitivity in the moot_file_memory call. The server
# enforces the same floor (an omitted sensitivity files at the live grant
# ceiling); the wording here keeps the model and the server in agreement so
# a handoff never lands a rung below the material it summarises.
MESSAGES = {
    30: (
        "[MOOTx01 context meter] Context is about {pct}% full. File a "
        "checkpoint note now with moot_file_memory to "
        "`session/{session_id}/checkpoint-30`: what this session is doing, "
        "what has been decided, what is open. Include the session id "
        "{session_id} in the body. "
        "Do not copy credentials, keys or tokens into the note. If this "
        "session recalled restricted or secret memories under a grant, file "
        "the note at the highest sensitivity of any material it recalled: "
        "name that sensitivity explicitly (restricted or secret) in the "
        "moot_file_memory call."
    ),
    50: (
        "[MOOTx01 context meter] Context is about {pct}% full. File "
        "`session/{session_id}/checkpoint-50` with moot_file_memory (include "
        "the session id {session_id} in the body). Then find your "
        "checkpoint-30 note for this session and link the new note to it "
        "with moot_link_memories kind derivesFrom. If the link fails, say so "
        "and continue. "
        "Do not copy credentials, keys or tokens into the note. If this "
        "session recalled restricted or secret memories under a grant, file "
        "the note at the highest sensitivity of any material it recalled: "
        "name that sensitivity explicitly (restricted or secret) in the "
        "moot_file_memory call."
    ),
    70: (
        "[MOOTx01 context meter] Context is about {pct}% full. File "
        "`session/{session_id}/checkpoint-70` with moot_file_memory (include "
        "the session id {session_id} in the body) and link it derivesFrom "
        "your checkpoint-50 note. If the link fails, say so and continue. "
        "Do not copy credentials, keys or tokens into the note. If this "
        "session recalled restricted or secret memories under a grant, file "
        "the note at the highest sensitivity of any material it recalled: "
        "name that sensitivity explicitly (restricted or secret) in the "
        "moot_file_memory call."
    ),
    85: (
        "[MOOTx01 context meter] Context is about {pct}% full. Write a "
        "POST-COMPACT HANDOFF for a colleague picking this up cold: what we "
        "are building and why, where things stand, decisions and the "
        "thinking behind them, what failed and how, exact strings quoted "
        "verbatim, what is still open, where you would pick up. Give "
        "context, not commands. File it with moot_file_memory to "
        "`session/{session_id}/handoff` (include the session id "
        "{session_id} in the body) and link it derivesFrom your "
        "checkpoint-70 note. If the link fails, say so and continue. "
        "Do not copy credentials, keys or tokens into the note. If this "
        "session recalled restricted or secret memories under a grant, file "
        "the note at the highest sensitivity of any material it recalled: "
        "name that sensitivity explicitly (restricted or secret) in the "
        "moot_file_memory call. Then compact."
    ),
}

UNKNOWN_WINDOW_MESSAGE = (
    "[MOOTx01 context meter] Context usage is UNKNOWN for this session: the "
    "transcript names the model {model} and this hook does not know its "
    "context window, so it will not report a percentage. Run /context for "
    "the real figure, and set MOOTX01_CONTEXT_WINDOW to the window size in "
    "tokens if you want the checkpoint reminders."
)

NO_HANDOFF_MESSAGE = (
    "[MOOTx01] Compaction is starting and no post-compact handoff was filed "
    "this session (`session/{session_id}/handoff`). Whatever this session "
    "knew and did not write down is about to be summarized away."
)

ORIENT_MESSAGE = (
    "[MOOTx01] This project uses MOOTx01 as its memory substrate. If this "
    "task may depend on prior context, orient before answering: "
    "moot_estate_ping, moot_estate_status, moot_read_journal. Recall before "
    "relying on memory; write back durable knowledge before finishing."
)

COMPETING_ENTRY_MESSAGE = (
    "[MOOTx01] Stale direct MCP entry \"{name}\" found in {path}. This entry "
    "predates the unified server name (mootx01) and may open a second "
    "connection to the same estate. Run `mootx01 upgrade` to remove it "
    "automatically, or remove it by hand; the plugin's own wiring is enough."
)

RECOVERY_MESSAGE = (
    "[MOOTx01] Context was just compacted. Your post-compact handoff for "
    "this session is at `session/{session_id}/handoff`. Read it first "
    "(moot_memory_search for the session id {session_id}, then "
    "moot_memory_get). Earlier checkpoints are reachable from it by "
    "derivesFrom tunnels if you need more than the handoff carries — walk "
    "back only if the handoff leaves you short. A handoff filed restricted or "
    "secret is read back under the same ceiling: the matching grant "
    "(`mootx01 unlock private` or `mootx01 unlock secret`) must be live "
    "before search can find it."
)

# Plan capture. The hook cannot call moot itself (MCP tools belong to the
# agent), so each message is an instruction the agent carries out on its next
# turn. PostToolUse / PreToolUse deliver context only through the JSON form on
# stdout ({"hookSpecificOutput": {"hookEventName": ..., "additionalContext":
# ...}}); plain stdout is not shown to the model on those events.
PLAN_APPROVED_MESSAGE = (
    "[MOOTx01 plan capture] A plan was just approved. File it now with "
    "moot_file_memory to `{location}`, with the plan text verbatim in the "
    "body. Project is the repository name; slug comes from the plan's own "
    "title. This is the one artifact a later session cannot reconstruct."
)

PLAN_REAPPROVED_LINE = (
    " This same plan text (hash {plan_hash}) was already approved in this "
    "session: update the existing note at `{location}` rather than filing a "
    "second one."
)

PLAN_ESTATE_UNREACHABLE_LINE = (
    " The MOOTx01 estate is unreachable right now (nothing is listening on "
    "127.0.0.1:4242), so the filing may not land: paste the plan somewhere "
    "durable as well, such as a file in the repository or the handoff you "
    "leave for the next session."
)

PLAN_PRECOMMIT_MESSAGE = (
    "[MOOTx01 plan capture] The approved plan for this session is not in moot "
    "yet. File it now to `{location}` while you still have it — this is "
    "the last moment it is cheap. Then continue with the commit."
)

# A `git commit` anywhere in a Bash command: `git`, then `commit` before the
# next shell separator, so `git -C path commit`, `cd x && git commit -m` and
# `git -c user.name=X commit` all match while `git log` does not. The
# lookarounds keep `commit` a whole word even against `-`, so
# `git revert --no-commit` and `git commit-graph write` do not match.
GIT_COMMIT_PATTERN = re.compile(r"\bgit\b[^;&|\n]*?(?<![-\w])commit(?![-\w])")

# The plan-capture location. Each project is a room whose drawers are its
# plans, so the plan history stays queryable on its own.
PLAN_LOCATION = "plans/{project}/{slug}"

STOP_REASON = (
    "[MOOTx01 writeback check] MOOTx01 memory tools were used this session, "
    "but no durable writeback happened (no moot_file_memory, moot_file_fact, "
    "moot_link_memories, or moot_write_journal). If this session produced "
    "durable decisions, preferences, corrections, or useful project facts, "
    "file them and write a brief journal entry now. If nothing durable "
    "happened, say so in one line and finish. If the MOOTx01 MCP tools are "
    "not available in this session, do not attempt or retry them — note the "
    "skipped writeback in one line and finish."
)


def read_stdin():
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def _hooks_state_dir():
    """Return a per-user private directory for hook state files, creating it
    if absent.

    Follows the same pattern as moot_update_check.py: XDG_CACHE_HOME or
    ~/.cache, subdirectory mootx01/hooks. The directory is created with
    mode 0o700 so other users on a shared machine cannot read or enumerate
    session state files.
    """
    # SECURITY: per-user directory, not shared /tmp — shared /tmp lets another
    # local user pre-create the file or read plan metadata written by this user.
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        base = os.path.join(xdg, "mootx01", "hooks")
    else:
        base = os.path.join(os.path.expanduser("~"), ".cache", "mootx01", "hooks")
    os.makedirs(base, mode=0o700, exist_ok=True)
    return base


def state_path(session_id):
    """Return the absolute path of the state file for `session_id`."""
    safe = "".join(c for c in str(session_id) if c.isalnum() or c in "-_")
    return os.path.join(_hooks_state_dir(), "mootx01-hooks-%s.json" % (safe or "default"))


def load_state(session_id):
    """Load and return session state dict, or a fresh default state on any error."""
    try:
        with open(state_path(session_id), "r", encoding="utf-8") as fh:
            state = json.load(fh)
            if isinstance(state, dict):
                return state
    except Exception:
        pass
    return {"fired": [], "compacted": False, "stop_nagged": False,
            "unknown_reported": False}


def save_state(session_id, state):
    """Persist `state` to the session state file atomically with mode 0o600.

    Writes to a sibling .tmp file first, then os.replace() so readers never
    see a partial write. os.open with mode 0o600 creates the file readable
    only by the process owner, regardless of the process umask.
    """
    try:
        path = state_path(session_id)
        # SECURITY: atomic replace prevents partial-read races; 0o600 prevents
        # other local users from reading plan metadata stored in this file.
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
        os.replace(tmp, path)
    except Exception:
        pass


def estimate_context_tokens(transcript_path):
    """Return (tokens, model) for the main-chain context, or (None, None).

    Claude Code transcripts are JSONL. Assistant entries carry a usage block;
    the most recent one reflects what the current context actually costs, and
    the same entry's `message.model` names the model that produced it — the
    input that sizes the window. A usage-bearing entry whose model is
    "<synthetic>" or empty still wins as the latest entry: the caller treats
    that model as unknown rather than guessing which real model preceded it."""
    if not transcript_path:
        return None, None
    latest = 0
    model = None
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get("isSidechain"):
                    continue
                message = entry.get("message")
                if not isinstance(message, dict):
                    continue
                usage = message.get("usage")
                if not isinstance(usage, dict):
                    continue
                total = 0
                for key in (
                    "input_tokens",
                    "cache_read_input_tokens",
                    "cache_creation_input_tokens",
                    "output_tokens",
                ):
                    value = usage.get(key)
                    if isinstance(value, (int, float)):
                        total += int(value)
                if total:
                    latest = total
                    entry_model = message.get("model")
                    model = entry_model if isinstance(entry_model, str) else None
    except Exception:
        return None, None
    if not latest:
        return None, None
    return latest, model


def window_for_model(model):
    """Context window in tokens for `model`, or None when this hook does not
    know it (absent, empty, "<synthetic>", or a model id outside both
    fragment lists). None means: report unknown, never a percentage."""
    if not isinstance(model, str) or not model.strip():
        return None
    lowered = model.lower()
    for fragment in MILLION_WINDOW_MODEL_FRAGMENTS:
        if fragment in lowered:
            return LARGE_WINDOW
    for fragment in STANDARD_WINDOW_MODEL_FRAGMENTS:
        if fragment in lowered:
            return DEFAULT_WINDOW
    return None


def mode_context(data):
    session_id = data.get("session_id", "default")
    tokens, model = estimate_context_tokens(data.get("transcript_path"))
    if tokens is None:
        return
    try:
        window = int(os.environ.get("MOOTX01_CONTEXT_WINDOW", 0))
    except ValueError:
        window = 0
    if window <= 0:
        window = window_for_model(model)
    state = load_state(session_id)
    if window is None:
        # Unknown model: say so once per session and compute nothing. A
        # percentage against a guessed window is wrong in the alarming
        # direction only, which is worse than no number.
        if not state.get("unknown_reported"):
            state["unknown_reported"] = True
            save_state(session_id, state)
            print(UNKNOWN_WINDOW_MESSAGE.format(model=repr(model or "")))
        return
    pct = min(100, int(round(tokens * 100.0 / window)))

    # Each rung fires once per session: `fired` is the set of rungs already
    # announced, and crossing several at once announces only the highest.
    fired = set(state.get("fired") or [])

    # SELF-HEAL. A rung is disarmed only by PreCompact or a SessionStart
    # reporting source == "compact". When neither fires -- and in practice
    # they often do not -- every rung stays marked and the meter is silent for
    # the rest of the session. Observed on live sessions: fired=[65,75,85,95]
    # with compacted=False, silent for an hour.
    #
    # That matters more than it looks. The model cannot see window fill on its
    # own; the counter it does see is a session token budget, not fill. This
    # hook is its only signal, and a silent hook reads exactly like a
    # comfortable window.
    #
    # So if fill dropped a clear margin below the highest rung already fired,
    # the window emptied. Re-arm everything above where we are now.
    if fired and pct + 10 < max(fired):
        fired = {t for t in fired if t <= pct}
        state["fired"] = sorted(fired)
        state["compacted"] = False
        # Persist HERE: if nothing crosses this turn the function returns
        # below without saving, and the state file would keep showing rungs
        # that are no longer armed. That file is what someone reads when the
        # meter seems wrong.
        save_state(session_id, state)

    crossed = [t for t in THRESHOLDS if pct >= t and t not in fired]
    if not crossed:
        return
    top = max(crossed)
    fired.update(t for t in THRESHOLDS if t <= top)
    state["fired"] = sorted(fired)
    save_state(session_id, state)
    print(MESSAGES[top].format(pct=pct, session_id=session_id))


def handoff_filed(transcript_path, session_id):
    """True when this session's transcript shows a moot_file_memory call
    addressed to `session/<session_id>/handoff`. Tool-use records carry
    their arguments on the same JSONL line as the MCP-qualified tool name."""
    if not transcript_path:
        return False
    location = "session/%s/handoff" % session_id
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "__moot_file_memory" in line and location in line:
                    return True
    except Exception:
        pass
    return False


def mode_precompact(data):
    session_id = data.get("session_id", "default")
    state = load_state(session_id)
    state["compacted"] = True
    # Deliberately NOT clearing `fired` here. PreCompact runs while the window
    # is still full, so re-arming now would re-fire every threshold on the way
    # out. SessionStart handles it: on source == "compact" it clears `fired`,
    # clears `compacted`, and prints the recovery message. That is the moment
    # the window has actually emptied.
    save_state(session_id, state)
    # A hook cannot compose the handoff — the agent gets no further turn
    # once this fires — but it can make a silent loss visible.
    if not handoff_filed(data.get("transcript_path"), session_id):
        print(NO_HANDOFF_MESSAGE.format(session_id=session_id))


def warn_competing_direct_entry():
    """Warn, but never edit, if the user's own ~/.claude.json also carries a
    stale direct `mcpServers.memory` entry alongside this plugin. That entry
    predates the unified server-name change (MXE-NS-CODEX) where both the
    plugin and the direct installer were aligned to use `"mootx01"`. A
    leftover `"memory"` entry may open a second connection to the same estate
    under the old `mcp__memory__*` tool prefix. Read-only: this function
    never writes to the config file.
    Every failure path is silent — a broken hook must never break a session.
    """
    path = os.path.expanduser("~/.claude.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            config = json.load(fh)
    except Exception:
        return
    if not isinstance(config, dict):
        return
    servers = config.get("mcpServers")
    if not isinstance(servers, dict) or "memory" not in servers:
        return
    print(COMPETING_ENTRY_MESSAGE.format(name="memory", path=path))


def mode_session(data):
    session_id = data.get("session_id", "default")
    source = data.get("source", "")
    state = load_state(session_id)
    if source == "compact" or state.get("compacted"):
        # Context shrank: re-arm the meter and point at the handoff.
        state["compacted"] = False
        state["fired"] = []
        state["unknown_reported"] = False
        save_state(session_id, state)
        print(RECOVERY_MESSAGE.format(session_id=session_id))
        warn_competing_direct_entry()
        return
    if source == "clear":
        state["fired"] = []
        state["stop_nagged"] = False
        save_state(session_id, state)
    print(ORIENT_MESSAGE)
    warn_competing_direct_entry()


def is_daemon_reachable(port=4242, timeout=0.5):
    """Return True if the mootx01 HTTP daemon appears to be listening on
    the loopback port. Used by mode_stop to skip the block decision when
    the daemon is down — the user cannot complete a writeback against an
    unreachable server, and blocking just surfaces an MCP-not-connected
    error. Every failure path returns False silently (offline, wrong port,
    permission denied, platform mismatch).
    """
    import socket
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except Exception:
        return False


def transcript_flags(transcript_path):
    """Return (used_moot, wrote_back) by scanning the raw transcript."""
    used_moot = False
    wrote_back = False
    if not transcript_path:
        return used_moot, wrote_back
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                # "__moot_" matches only MCP-qualified tool names
                # (mcp__<server>__moot_*) — i.e. actual tool invocations.
                # Bare "moot_" would also match this hook's own banners,
                # which land in EVERY transcript, and made the stop nag
                # fire in sessions that never used a MOOTx01 tool.
                if not used_moot and "__moot_" in line:
                    used_moot = True
                if not wrote_back:
                    for marker in WRITEBACK_MARKERS:
                        if marker in line:
                            wrote_back = True
                            break
                if used_moot and wrote_back:
                    break
    except Exception:
        pass
    return used_moot, wrote_back


def mode_stop(data):
    # Never fight our own continuation; never nag twice in one session.
    if data.get("stop_hook_active"):
        return
    # Do not block when the daemon is unreachable — the user cannot complete
    # a writeback against a down server, and the block decision would just
    # surface an "MCP server not connected" error into the session.
    if not is_daemon_reachable():
        return
    session_id = data.get("session_id", "default")
    state = load_state(session_id)
    if state.get("stop_nagged"):
        return
    used_moot, wrote_back = transcript_flags(data.get("transcript_path"))
    if not used_moot or wrote_back:
        return
    state["stop_nagged"] = True
    save_state(session_id, state)
    print(json.dumps({"decision": "block", "reason": STOP_REASON}))


def inject_context(hook_event_name, text):
    """Print the JSON form that delivers `text` to the model on PreToolUse and
    PostToolUse. Only `hookSpecificOutput.additionalContext` reaches the model
    on those events; no decision field is set, so the tool call proceeds."""
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": hook_event_name,
        "additionalContext": text,
    }}))


def plan_hash(plan_text):
    """First 12 hex digits of SHA-256 over the plan text: enough to tell two
    plans apart within a session, short enough to quote in a message."""
    return hashlib.sha256(plan_text.encode("utf-8")).hexdigest()[:12]


def slugify(text):
    """Lowercase, every run of non-alphanumerics to one `-`, trimmed."""
    slug = re.sub(r"[^a-z0-9]+", "-", str(text).lower()).strip("-")
    return slug


def plan_slug(plan_text):
    """Slug of the plan's first Markdown heading; `untitled-plan` when the plan
    has no heading or the heading slugs to nothing."""
    for line in plan_text.splitlines():
        match = re.match(r"\s*#+\s*(.+?)\s*#*\s*$", line)
        if match:
            return slugify(match.group(1)) or "untitled-plan"
    return "untitled-plan"


def project_name(cwd):
    """Basename of the git top level for `cwd`, falling back to the basename
    of `cwd` itself, or `unknown-project` when no cwd was given. Never raises;
    a missing git or a non-repo cwd is the fallback, not an error."""
    cwd = str(cwd or "")
    if not cwd:
        return "unknown-project"
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=2, check=False)
        top = result.stdout.strip() if result.returncode == 0 else ""
    except Exception:
        top = ""
    name = os.path.basename(top.rstrip("/\\")) if top else ""
    if not name:
        name = os.path.basename(os.path.abspath(cwd).rstrip("/\\"))
    return name or "unknown-project"


def plan_location(data, plan_text):
    return PLAN_LOCATION.format(project=project_name(data.get("cwd")),
                                slug=plan_slug(plan_text))


def approved_plan_text(data):
    """The approved plan. Claude Code injects it into `tool_response.plan` on
    PostToolUse (the hooks reference prefers that field) and also into
    `tool_input.plan`; the first non-empty string wins."""
    for container in (data.get("tool_response"), data.get("tool_input")):
        if isinstance(container, dict):
            plan = container.get("plan")
            if isinstance(plan, str) and plan.strip():
                return plan
    return None


def mode_plan_approved(data):
    plan_text = approved_plan_text(data)
    if plan_text is None:
        return
    session_id = data.get("session_id", "default")
    digest = plan_hash(plan_text)
    location = plan_location(data, plan_text)
    state = load_state(session_id)
    # Same text approved again (still pending, or filed earlier this session):
    # the note is updated, not duplicated. `plan_filed` remembers the hash of
    # the last plan that was filed so a re-approval after filing is recognised.
    reapproved = digest in (state.get("plan_pending"), state.get("plan_filed"))
    state["plan_pending"] = digest
    # The reminder in precommit-check names the same location, so it is kept
    # with the hash rather than recomputed from a plan the hook no longer has.
    state["plan_location"] = location
    save_state(session_id, state)
    text = PLAN_APPROVED_MESSAGE.format(location=location)
    if reapproved:
        text += PLAN_REAPPROVED_LINE.format(plan_hash=digest, location=location)
    if not is_daemon_reachable():
        text += PLAN_ESTATE_UNREACHABLE_LINE
    inject_context("PostToolUse", text)


def mode_plan_filed(data):
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        return
    location = tool_input.get("location")
    if not isinstance(location, str) or not location.startswith("plans/"):
        return
    session_id = data.get("session_id", "default")
    state = load_state(session_id)
    if "plan_pending" not in state:
        return
    state["plan_filed"] = state.pop("plan_pending")
    # SECURITY: clear the location slug so a plan title does not persist in
    # the state file after the plan has been filed to the estate.
    state.pop("plan_location", None)
    save_state(session_id, state)


def mode_precommit_check(data):
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        return
    command = tool_input.get("command")
    if not isinstance(command, str) or not GIT_COMMIT_PATTERN.search(command):
        return
    session_id = data.get("session_id", "default")
    state = load_state(session_id)
    # Once per session: a reminder on every commit stops being read.
    if not state.get("plan_pending") or state.get("plan_reminded"):
        return
    state["plan_reminded"] = True
    save_state(session_id, state)
    location = state.get("plan_location") or PLAN_LOCATION.format(
        project=project_name(data.get("cwd")), slug="untitled-plan")
    inject_context("PreToolUse", PLAN_PRECOMMIT_MESSAGE.format(location=location))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    data = read_stdin()
    try:
        if mode == "context":
            mode_context(data)
        elif mode == "precompact":
            mode_precompact(data)
        elif mode == "session":
            mode_session(data)
        elif mode == "stop":
            mode_stop(data)
        elif mode == "plan-approved":
            mode_plan_approved(data)
        elif mode == "plan-filed":
            mode_plan_filed(data)
        elif mode == "precommit-check":
            mode_precommit_check(data)
    except Exception:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
