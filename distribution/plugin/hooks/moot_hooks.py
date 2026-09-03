#!/usr/bin/env python3
"""MOOTx01 hooks for Claude Code.

One script, four modes (argv[1]):

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

Design constraints, on purpose:
  - Python standard library only. No third-party imports.
  - No network access. Ever.
  - Reads only the hook JSON on stdin, the session transcript path that
    Claude Code provides, and (session mode only) the user's own
    ~/.claude.json to check for a competing direct MCP entry. Writes only a
    small state file in the system temp directory. NEVER writes to
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

import json
import os
import sys
import tempfile

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
MESSAGES = {
    30: (
        "[MOOTx01 context meter] Context is about {pct}% full. File a "
        "checkpoint note now with moot_file_memory to "
        "`session/{session_id}/checkpoint-30`: what this session is doing, "
        "what has been decided, what is open. Include the session id "
        "{session_id} in the body."
    ),
    50: (
        "[MOOTx01 context meter] Context is about {pct}% full. File "
        "`session/{session_id}/checkpoint-50` with moot_file_memory (include "
        "the session id {session_id} in the body). Then find your "
        "checkpoint-30 note for this session and link the new note to it "
        "with moot_link_memories kind derivesFrom. If the link fails, say so "
        "and continue."
    ),
    70: (
        "[MOOTx01 context meter] Context is about {pct}% full. File "
        "`session/{session_id}/checkpoint-70` with moot_file_memory (include "
        "the session id {session_id} in the body) and link it derivesFrom "
        "your checkpoint-50 note. If the link fails, say so and continue."
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
        "checkpoint-70 note. If the link fails, say so and continue. Then "
        "compact."
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
    "back only if the handoff leaves you short."
)

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


def state_path(session_id):
    safe = "".join(c for c in str(session_id) if c.isalnum() or c in "-_")
    return os.path.join(tempfile.gettempdir(), "mootx01-hooks-%s.json" % (safe or "default"))


def load_state(session_id):
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
    try:
        with open(state_path(session_id), "w", encoding="utf-8") as fh:
            json.dump(state, fh)
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
    except Exception:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
