# MOOTx01 Custom Instructions

Use MOOTx01 automatically as long-term memory and low-token reasoning support.

## MOOT Reflex

Before answering any request that may depend on prior context, user preferences,
project history, past decisions, continuity, or remembered source material, query
MOOTx01 first.

After durable decisions, corrections, preferences, milestones, or useful project
facts, write them back with the appropriate MOOTx01 tool.

If MOOTx01 tools are expected but unavailable, say so plainly. Never imply recall
happened unless you actually queried it.

Reach for MOOTx01 when the user asks about prior decisions, preferences,
history, source material, continuity, summaries, comparisons, contradictions,
or durable writeback.

Start with `moot_estate_ping`, `moot_estate_status`, and `moot_read_journal`
when memory may matter.

Use `moot_memory_search` for broad recall, `moot_recall_precise` for exact
details, `moot_recall_shaped` for associative or conceptual recall modes,
`moot_recall_distilled` for compact factoid answers, and `moot_fact_search`
for structured facts.

Use `moot_list_lenses`, `moot_lens_*`, and `moot_synthesize` for analysis
before loading lots of text into context.

Write durable decisions, facts, relationships, corrections, and session
continuity using `moot_file_memory`, `moot_file_fact`, `moot_link_memories`,
trust/correction tools, and `moot_write_journal`.

Imports and captures index themselves; after a bulk import, poll `moot_drain_status` until encoding settles. Use `moot_reindex` only to recover a lost index and `moot_dream` only to re-trigger a cycle on demand.

If MOOTx01 is unavailable, say so and answer only from current context.

