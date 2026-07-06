# MOOTx01 Memory Instructions

Use MOOTx01 automatically as this repository's long-term memory and reasoning
substrate.

## NEVER touch the database directly

MOOTx01 stores its data in SQLite files under the estate data directory. You
MUST NOT read, query, modify, or inspect these files directly — no sqlite3
commands, no cat/head/hexdump on .db files, no filesystem inspection of the
estate storage. All access goes through the MCP tools listed below. The database
schema, file layout, and internal encoding are private implementation details
that change between versions.

If a tool returns unexpected results, try a different query or a different tool
(moot_memory_search, moot_recall_precise, moot_recall_shaped, moot_fact_search).
If all tools fail, report the problem to the user — do not attempt to diagnose
or repair the database yourself.

## MOOT Reflex

Before answering any request that may depend on prior context, user preferences,
project history, past decisions, continuity, or remembered source material, query
MOOTx01 first.

After durable decisions, corrections, preferences, milestones, or useful project
facts, write them back with the appropriate MOOTx01 tool.

If MOOTx01 tools are expected but unavailable, say so plainly. Never imply recall
happened unless you actually queried it.

## When To Use

Reach for MOOTx01 when the user asks about:

- prior decisions,
- user preferences,
- previous sessions,
- project history,
- source material,
- corpus knowledge,
- unresolved contradictions,
- grounded summaries or comparisons,
- durable writeback.

## How To Use

1. Start with `moot_estate_ping` and `moot_estate_status` when memory may matter.
2. Use `moot_read_journal` to resume continuity.
3. Use `moot_memory_search` for broad recall.
4. Use `moot_recall_precise` for exact paths, versions, names, numbers, dates, and near-duplicates.
5. Use `moot_recall_shaped` for associative, conceptual, or other fusion-steered recall.
6. Use `moot_recall_distilled` for compact factoid answers from the distilled tier.
7. Use `moot_fact_search` for structured facts.
8. Use `moot_list_lenses`, `moot_lens_*`, and `moot_synthesize` for analysis before loading many memories into context.
9. Use `moot_file_memory`, `moot_file_fact`, `moot_link_memories`, and `moot_write_journal` to persist durable knowledge.
10. Use correction tools instead of silently rewriting history.
11. Run `moot_reindex` after batch import, then `moot_dream` after bulk import or major memory growth.

## Vault Import

When importing a vault (moot_vault_import), ALWAYS specify a meaningful wing
and room structure. Never let MOOT infer placement from content — it will
default to "Agentic Memory" which is wrong for imported material. Decide the
wing and room taxonomy BEFORE importing. Example: wing=CodexSecurity,
room=mootx01-ce. Vault imports are long-running (~2 seconds per document). Do
NOT cancel or re-issue an import that appears slow — poll moot_vault_job.

## Do Not Use The CLI For Data Access

Use only MCP tools for reading and writing estate data. Do not use the
mootx01 query CLI, mootx01 status, or any other shell command to access
estate content. The CLI is an operator tool, not an AI data-access path. If an
MCP tool returns unexpected results, try a different MCP tool or query — do not
fall back to the CLI or the database.

If MOOTx01 is unavailable, say so plainly and answer only from current context.

