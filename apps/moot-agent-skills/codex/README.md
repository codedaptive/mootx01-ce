# Codex MOOTx01 Adapter

This adapter gives Codex one plugin-owned MOOTx01 MCP connection, repository
instructions, the `mootx01-memory` skill, and Codex-native lifecycle hooks.

The hook adapter uses only documented stable event fields. It never opens
`transcript_path`, never edits generated files under `$CODEX_HOME/memories`, and
stores minimal per-session flags under `~/.mootx01/codex-memory/sessions` with
user-private permissions. Its lifecycle coverage is:

- `SessionStart` and `PostCompact`: orientation and compaction recovery;
- `PostToolUse`: MOOT read/write observation without retaining tool payloads;
- `Stop`: a per-turn one-shot durable-writeback gate;
- `SessionEnd`: session-state removal;
- `UserPromptSubmit`: silent unless bounded automatic recall was explicitly enabled.

## Memory modes

Enable the default augmenting posture, which leaves Codex native memories alone:

```sh
mootx01 enable codex-memory --mode augment
```

Use MOOTx01 only and reversibly disable Codex memory generation/use:

```sh
mootx01 enable codex-memory --mode moot-only
```

`moot-only` backs up `config.toml`, snapshots only the three managed settings,
and restores only those keys on disable so later unrelated user edits survive.
Automatic recall is separately opt-in with `--automatic-recall`; it uses
currently-believed, user-confirmed, trustworthy, normal/elevated distilled results, tight result
and character caps, short transport timeouts, provenance, and an injection-safe
data wrapper.

Inspect or reverse the posture:

```sh
mootx01 codex-memory doctor
mootx01 disable codex-memory
```

## Chronicle bridge

Chronicle import is explicit and one-way:

```sh
mootx01 codex-memory import-chronicle
```

Only generated Markdown under `$CODEX_HOME/memories_extensions/chronicle` is
read. Files are SHA-256 deduplicated and filed as unconfirmed memories with
source provenance. Screenshots and temporary capture data are excluded, and the
command never writes inside `CODEX_HOME`.

## Installation ownership

The Codex plugin manifest explicitly points to `./.codex/hooks.json`,
`./.mcp.json`, and `./skills/`. Run `mootx01 install --target codex --mode plugin` after an
upgrade so the installer can refresh the package and remove an older default
direct `[mcp_servers.mootx01]` entry when the enabled plugin owns the connection.
