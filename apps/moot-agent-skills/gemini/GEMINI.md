# MOOTx01 Memory Instructions

Use MOOTx01 as the automatic memory and reasoning substrate for this project.

## MOOT Reflex

Before answering any request that may depend on prior context, user preferences,
project history, past decisions, continuity, or remembered source material, query
MOOTx01 first.

After durable decisions, corrections, preferences, milestones, or useful project
facts, write them back with the appropriate MOOTx01 tool.

If MOOTx01 tools are expected but unavailable, say so plainly. Never imply recall
happened unless you actually queried it.

Before answering memory-dependent questions, query MOOTx01. Reach for it when
the user asks about prior decisions, preferences, project history, source
material, unresolved issues, or continuing earlier work.

## Startup

When relevant:

1. `moot_estate_ping`
2. `moot_estate_status`
3. `moot_read_journal`
4. `moot_estate_map`
5. `moot_list_lenses` when analysis is needed

If MOOTx01 is unavailable, say so and answer only from current context.

## Recall And Analysis

- Use `moot_memory_search` for broad recall.
- Use `moot_recall_precise` for exact dates, versions, names, paths, numbers, and near-duplicates.
- Use `moot_recall_shaped` for associative, conceptual, or other fusion-steered recall.
- Use `moot_recall_distilled` for compact factoid answers from the distilled tier.
- Use `moot_fact_search` for structured facts.
- Use `moot_synthesize` for grounded summaries.
- Use reasoning lenses before asking the LLM to analyze many memories manually.

## Writeback

Before ending meaningful work:

- File durable decisions and observations with `moot_file_memory`.
- Store stable triples with `moot_file_fact`.
- Link related memories with `moot_link_memories`.
- Confirm, update, withdraw, or retire stale knowledge as needed.
- Write continuity with `moot_write_journal`.
- Run `moot_reindex` after batch import, then `moot_dream` after bulk import or major memory growth.

Never claim MOOTx01 recall unless you actually queried it.
