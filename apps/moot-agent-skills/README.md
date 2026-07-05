# MOOTx01 Agent Adapters

This directory teaches AI clients to use MOOTx01 as memory.

Installing the MOOTx01 runtime gives an AI client the tools. Installing one of these adapters teaches the AI when to use those tools.

That difference matters.

Without the adapter, the user may have to ask for memory every time. With the adapter, the AI should reach for MOOTx01 when memory, continuity, recall, contradiction checking, preference learning, or durable writeback matters.

## What The Adapter Teaches

The AI should use MOOTx01 to:

- check what was decided before,
- recall project context,
- file durable memories,
- link related memories,
- keep facts and journal entries,
- search before guessing,
- synthesize from remembered context,
- write back useful new knowledge.

MOOTx01 is not a passive wiki. A wiki stores text for the model to reread.

MOOTx01 stores memory as mathematically cross-referenced collections of: memories, facts, links, journals, trust state, recall indexes, graph structure, reasoning lenses, and dream-built association signals.

This ensures your agent can spend cheap memory operations before spending expensive context-window tokens.

## Install Order

Use this order:

1. Install or expose MOOTx01 as an MCP server.
2. Verify the client can see the MOOTx01 tools.
3. Copy the matching adapter into the client config.
4. Merge with existing instructions instead of replacing them.
5. Test that the AI recalls, files, and links memory.

Do not install the adapter before the runtime works.

## Contents

- `shared/` - source language used across adapters.
- `claude/` - Claude Code files, including lifecycle hooks (context meter,
  compaction recovery, writeback check).
- `codex/` - Codex files, including lifecycle hooks.
- `gemini/` - Gemini CLI context files.
- `cursor/` - Cursor rules.
- `cline/` - Cline rules.
- `roo/` - Roo Code rules.
- `windsurf/` - Devin Desktop / Windsurf rules.
- `continue/` - Continue rules.
- `openai-agents/` - prompt blocks for OpenAI Agents or Responses-style apps.
- `generic/` - fallback custom instructions.

## Where Each Adapter Installs

Most adapters can be copied into a project root for one project, or into the client's user-level config location for all projects. Claude hook wiring is an exception: install `.claude/hooks/*.py` and `.claude/settings.json` only in a trusted project-local `.claude/` directory because the provided settings execute scripts through `$CLAUDE_PROJECT_DIR`. Do not merge these hook settings into a user-level/global Claude configuration unless you first rewrite every hook command to an absolute, trusted user-config path.

| Client | Destination files |
|---|---|
| `claude/` | User-level safe: `CLAUDE.md`, `.claude/rules/*.md`, `.claude/skills/mootx01-memory/SKILL.md`, `.claude/commands/mootx01-start.md`. Project-local only unless hook commands are rewritten to absolute trusted paths: `.claude/hooks/moot_hooks.py`, `.claude/hooks/moot_update_check.py`, `.claude/settings.json` (merge the `hooks` block only into a project-local settings file) |
| `codex/` | `AGENTS.md`, `.agents/skills/mootx01-memory/{SKILL.md, agents/openai.yaml}`, `.codex/hooks.json` |
| `gemini/` | `GEMINI.md` (project root or `~/.gemini/GEMINI.md`) |
| `cursor/` | `.cursor/rules/*.mdc` or legacy `.cursorrules` |
| `cline/` | `.clinerules/*.md` |
| `roo/` | `.roo/rules/*.md` or legacy `.roorules` |
| `windsurf/` | `.windsurf/rules/*.md`, `.devin/rules/*.md`, or legacy `.windsurfrules` |
| `continue/` | `.continue/rules/*.md` |
| `openai-agents/` | paste prompt files into app prompt slots |
| `generic/` | paste `custom-instructions.md` into custom instructions |

## Safety Rules

- Merge, do not overwrite existing instruction files.
- Back up existing instruction files before editing.
- Get user approval before changing an existing user config.
- Prefer small native rule files over loading all shared docs into context.
- Keep `shared/` nearby as reference, not as bulk prompt content.

## Test Prompts

After installing an adapter, test with:

```text
What did we decide last time about the importer?
```

```text
Where were we?
```

```text
Summarize what we know about this project from memory.
```

```text
We decided X; remember that and link it to the earlier Y decision.
```

A working setup should show four behaviors:

- recall old memory,
- resume continuity without being handed context,
- summarize from memory,
- write a new linked memory.

## Expected Tool Surface

These adapters assume the MOOTx01 MCP surface exposes tools with these meanings:

- estate health and status,
- memory search and precise recall,
- memory filing and updates,
- memory confirmation, withdrawal, and erasure,
- memory links and connection search,
- fact filing and fact search,
- journal read and write,
- reasoning lenses and synthesis,
- dream or background consolidation,
- vault import, export, status, reconcile, and job checks,
- federated search where available.

If a harness namespaces MCP tools, use the matching namespaced tool.

## Tool Name Assumptions

These adapters assume the MOOTx01 MCP surface exposes these tool names:

- `moot_estate_ping`
- `moot_estate_status`
- `moot_estate_map`
- `moot_read_journal`
- `moot_write_journal`
- `moot_memory_search`
- `moot_recall_precise`
- `moot_recall_shaped`
- `moot_recall_distilled`
- `moot_recollect`
- `moot_file_memory`
- `moot_move_memory`
- `moot_update_memory`
- `moot_confirm_memory`
- `moot_withdraw_memory`
- `moot_erase_memory`
- `moot_link_memories`
- `moot_connection_search`
- `moot_connection_map`
- `moot_file_fact`
- `moot_fact_search`
- `moot_retire_fact`
- `moot_fact_timeline`
- `moot_list_lenses`
- `moot_list_recipes`
- `moot_synthesize`
- `moot_consolidate`
- `moot_dream`
- `moot_reindex`
- `moot_palace_import`
- `moot_run_migration`
- `moot_confirm_migration`
- `moot_vault_import`
- `moot_vault_export`
- `moot_vault_status`
- `moot_vault_reconcile`
- `moot_vault_job`
- `moot_federated_search`

If a harness namespaces MCP tools, preserve the intent and use the matching
namespaced tool.

