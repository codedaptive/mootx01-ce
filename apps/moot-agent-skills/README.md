# MOOTx01 Harness Support Kit

This directory contains starter implementations that teach AI harnesses to use
MOOTx01 as an automatic memory and reasoning substrate.

The package is intentionally redundant across platforms. Each harness has its
own native file layout, while `shared/` is the source-of-truth language to keep
behavior consistent.

## Design Goal

Make the AI instinctively reach for MOOTx01 when memory, continuity, recall,
grounded synthesis, contradiction checking, preference learning, or durable
writeback matters.

MOOTx01 is not a passive wiki. A wiki stores text for the model to reread.
MOOTx01 stores memory as a substrate: memories, facts, links, journals, trust
state, recall indexes, graph structure, reasoning lenses, and dream-built
association signals. The agent should spend cheap substrate operations before
spending expensive context-window tokens.

## Contents

- `shared/` - harness-neutral instructions and policy blocks.
- `claude/` - Claude Code `CLAUDE.md`, rules, skill, and command stubs.
- `codex/` - Codex `AGENTS.md`, Agent Skill, and hook notes.
- `cursor/` - Cursor `.cursor/rules/*.mdc` and legacy `.cursorrules`.
- `cline/` - Cline `.clinerules/*.md`.
- `roo/` - Roo Code `.roo/rules/*.md` and `.roorules`.
- `windsurf/` - Devin Desktop/Windsurf `.devin/rules`, `.windsurf/rules`, and legacy `.windsurfrules`.
- `continue/` - Continue `.continue/rules/*.md`.
- `openai-agents/` - prompt blocks for OpenAI Agents/Responses-style apps.
- `generic/` - minimal fallback for any harness with only custom instructions.

## Recommended Installation Pattern

1. Install or expose MOOTx01 as an MCP server in the target harness.
2. Copy the relevant platform folder contents into a project or user-level
   configuration location.
3. Keep the shared documents nearby as reference, but avoid loading all of them
   into every model context if the platform supports smaller rule files.
4. Test with three prompts:
   - "What did we decide last time about the importer?"
   - "Summarize what we know about this project from memory."
   - "We decided X; remember that and link it to the earlier Y decision."

## Where each adapter installs

Each folder targets its client's native files. Copy into the **project root** for one project,
or the client's **user-level** config directory for all projects (see the client's own docs for
its user-level path).

| Client | Destination files (relative to project root) |
|---|---|
| `claude/` | `CLAUDE.md`, `.claude/rules/*.md`, `.claude/skills/mootx01-memory/SKILL.md`, `.claude/commands/mootx01-start.md` |
| `codex/` | `AGENTS.md`, `.agents/skills/mootx01-memory/{SKILL.md, agents/openai.yaml}`, `.codex/hooks.json` |
| `cursor/` | `.cursor/rules/*.mdc` (or legacy `.cursorrules`) |
| `cline/` | `.clinerules/*.md` |
| `roo/` | `.roo/rules/*.md` (or legacy `.roorules`) |
| `windsurf/` | `.windsurf/rules/*.md` / `.devin/rules/*.md` (or legacy `.windsurfrules`) |
| `continue/` | `.continue/rules/*.md` |
| `openai-agents/` | paste `system-prompt.md` / `developer-message.md` / `tool-contract.md` into your app's prompt slots |
| `generic/` | paste `custom-instructions.md` into the harness's custom-instructions field |

## Installation rules (read before copying)

- **Merge, do not overwrite.** If a destination already exists (the user has their own
  `CLAUDE.md`, `AGENTS.md`, rules, …), **append** the MOOTx01 block — never replace the file.
- **Back up first.** Copy any existing instruction file aside before editing it.
- **Get approval.** Do not change a user's existing instruction files without their explicit
  approval. Brand-new files the user doesn't have yet may be added freely.
- **Don't over-load context.** Prefer the client's small rule files; keep `shared/` as
  reference, not as bulk context.

## Tool Name Assumptions

These adapters assume the MOOTx01 MCP surface exposes these tool names:

- `moot_estate_ping`
- `moot_estate_status`
- `moot_estate_map`
- `moot_read_journal`
- `moot_write_journal`
- `moot_memory_search`
- `moot_recall_precise`
- `moot_file_memory`
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
- `moot_synthesize`
- `moot_dream`
- `moot_vault_import`
- `moot_vault_export`
- `moot_vault_status`
- `moot_vault_reconcile`
- `moot_vault_job`
- `moot_federated_search`

If a harness namespaces MCP tools, preserve the intent and use the matching
namespaced tool.

