#!/usr/bin/env python3
"""MOOTx01 hooks for Claude Code.

One script, four modes (argv[1]):

  context     UserPromptSubmit  Escalating memory-writeback reminders as the
                                context window fills (65 / 75 / 85 / 95 %).
  precompact  PreCompact        Records that compaction is about to happen so
                                the next SessionStart can trigger recovery.
  session     SessionStart      Orientation reminder on startup/resume/clear;
                                continuity-recovery injection after compaction;
                                warns (never edits) if a competing direct
                                `mootx01` MCP entry is also wired (ADR-024 §3).
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
    only (ADR-024 §3: "the hook never edits config").
  - Every failure path exits 0 silently. A broken hook must never break a
    session.

Environment:
  MOOTX01_CONTEXT_WINDOW   Override the assumed context window size in tokens
                           (default 200000).
"""

import json
import os
import sys
import tempfile

THRESHOLDS = (65, 75, 85, 95)
DEFAULT_WINDOW = 200_000

WRITEBACK_MARKERS = (
    "moot_file_memory",
    "moot_file_fact",
    "moot_link_memories",
    "moot_write_journal",
    "moot_update_memory",
    "moot_confirm_memory",
)

MESSAGES = {
    65: (
        "[MOOTx01 context meter] Context is about {pct}% full. Natural "
        "checkpoint: if durable decisions, preferences, corrections, or "
        "useful project facts have accumulated, file them now with "
        "moot_file_memory / moot_file_fact and link related memories."
    ),
    75: (
        "[MOOTx01 context meter] Context is about {pct}% full. Write back "
        "durable knowledge now rather than later: moot_file_memory for "
        "decisions and observations, moot_file_fact for stable triples, "
        "moot_write_journal for continuity."
    ),
    85: (
        "[MOOTx01 context meter] Context is about {pct}% full and compaction "
        "is approaching. Before continuing the task, file every durable "
        "memory, fact, and link from this session and write a journal entry "
        "with moot_write_journal so continuity survives compaction."
    ),
    95: (
        "[MOOTx01 context meter] URGENT: context is about {pct}% full. "
        "Compaction may occur at any moment and unsaved context will be "
        "lost. Immediately file durable memories (moot_file_memory), facts "
        "(moot_file_fact), links (moot_link_memories), and a journal entry "
        "(moot_write_journal). Do this before any other work."
    ),
}

ORIENT_MESSAGE = (
    "[MOOTx01] This project uses MOOTx01 as its memory substrate. If this "
    "task may depend on prior context, orient before answering: "
    "moot_estate_ping, moot_estate_status, moot_read_journal. Recall before "
    "relying on memory; write back durable knowledge before finishing."
)

COMPETING_ENTRY_MESSAGE = (
    "[MOOTx01] Direct MCP entry \"{name}\" found in {path} in addition to the "
    "mootx01@mootx01 plugin — Claude Code may open two connections to the same "
    "estate. Run `mootx01 install` to remove the redundant direct entry (or "
    "remove it by hand); the plugin's own wiring is enough."
)

RECOVERY_MESSAGE = (
    "[MOOTx01] Context was just compacted. Details from earlier in this "
    "session may have been summarized away. Recover continuity now: call "
    "moot_read_journal and moot_memory_search for the current task before "
    "proceeding, and re-verify any paths, names, or decisions you are "
    "about to rely on."
)

STOP_REASON = (
    "[MOOTx01 writeback check] MOOTx01 memory tools were used this session, "
    "but no durable writeback happened (no moot_file_memory, moot_file_fact, "
    "moot_link_memories, or moot_write_journal). If this session produced "
    "durable decisions, preferences, corrections, or useful project facts, "
    "file them and write a brief journal entry now. If nothing durable "
    "happened, say so in one line and finish."
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
    return {"fired": [], "compacted": False, "stop_nagged": False}


def save_state(session_id, state):
    try:
        with open(state_path(session_id), "w", encoding="utf-8") as fh:
            json.dump(state, fh)
    except Exception:
        pass


def estimate_context_tokens(transcript_path):
    """Return the latest main-chain context footprint in tokens, or None.

    Claude Code transcripts are JSONL. Assistant entries carry a usage block;
    the most recent one reflects what the current context actually costs.
    """
    if not transcript_path:
        return None
    latest = 0
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
    except Exception:
        return None
    return latest or None


def mode_context(data):
    session_id = data.get("session_id", "default")
    tokens = estimate_context_tokens(data.get("transcript_path"))
    if tokens is None:
        return
    try:
        window = int(os.environ.get("MOOTX01_CONTEXT_WINDOW", DEFAULT_WINDOW))
    except ValueError:
        window = DEFAULT_WINDOW
    if window <= 0:
        window = DEFAULT_WINDOW
    pct = min(100, int(round(tokens * 100.0 / window)))

    state = load_state(session_id)
    fired = set(state.get("fired") or [])
    crossed = [t for t in THRESHOLDS if pct >= t and t not in fired]
    if not crossed:
        return
    top = max(crossed)
    fired.update(t for t in THRESHOLDS if t <= top)
    state["fired"] = sorted(fired)
    save_state(session_id, state)
    print(MESSAGES[top].format(pct=pct))


def mode_precompact(data):
    session_id = data.get("session_id", "default")
    state = load_state(session_id)
    state["compacted"] = True
    save_state(session_id, state)


def warn_competing_direct_entry():
    """ADR-024 §3: warn (never edit) if the user's own ~/.claude.json also
    carries a direct `mcpServers.mootx01` entry alongside this plugin. That
    entry is the CLI installer's wiring (a stdio `serve`/`proxy` command, or
    an HTTP entry) written before or after the plugin was installed; either
    order can leave two live connections to the same estate (ADR-024
    context). Read-only: this function never writes to the config file.
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
    if not isinstance(servers, dict) or "mootx01" not in servers:
        return
    print(COMPETING_ENTRY_MESSAGE.format(name="mootx01", path=path))


def mode_session(data):
    session_id = data.get("session_id", "default")
    source = data.get("source", "")
    state = load_state(session_id)
    if source == "compact" or state.get("compacted"):
        # Context shrank: re-arm the meter and recover continuity.
        state["compacted"] = False
        state["fired"] = []
        save_state(session_id, state)
        print(RECOVERY_MESSAGE)
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
                if not used_moot and "moot_" in line:
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
