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

## Interactive skills

The Claude command workflows have Codex skill equivalents under `.agents/skills/`:

| Claude invocation | Codex invocation | Purpose |
| --- | --- | --- |
| `/mootx01-start` | `$mootx01-start` | Orient and discover available MOOT capabilities. |
| `/prepare-for-compact` | `$prepare-for-compact` | File and verify a checkpoint before compaction. |
| `/recover-from-compact` | `$recover-from-compact` | Select the right handoff and reconcile current state. |
| `/start-clean` | `$start-clean` | Preserve context for a fresh task. |
| `mootx01-plans` skill | `$mootx01-plans` | Preserve approved plans and their revision links. |

These are repository adapter sources. To use them in another project, copy the
skill directories together into that project's `.agents/skills/`, or into the
user's `~/.agents/skills/` for personal use. `start-clean` references its sibling
`prepare-for-compact`; keep both. Merely storing this adapter inside a larger
checkout does not install its skills for tasks elsewhere in that checkout.
These additions do not regenerate the distributed plugin or embedded installer
bundle; they are available here for the packaging workflow to incorporate.

Invoke the skills by name or through the skill picker. Skills preserve and
recover state; they do not implement a new slash command, trigger compaction,
or close/archive tasks. Supported skill layout is documented in
[OpenAI's skills guide](https://developers.openai.com/codex/skills/).

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
`./.mcp.json`, and `./skills/`. Run `mootx01 install --target codex --mode plugin`
to register the bundled plugin. `mootx01 upgrade` checks for an installed,
enabled Codex plugin and refreshes it from the bundled package. Disabled plugins
remain disabled with refresh deferred. After verified registration, the installer
can remove an older default direct `[mcp_servers.mootx01]` entry; custom wiring
is retained. Start a new Codex task to load updated skills and tools.
