# MOOTx01 Automatic Memory

Use MOOTx01 as Roo's automatic memory and reasoning substrate.

## Triggers

Use MOOTx01 automatically when a task involves memory, continuity, source
material, preferences, prior decisions, grounded synthesis, contradiction
checks, or durable writeback.

## Protocol

- Start with `moot_estate_ping`, `moot_estate_status`, and `moot_read_journal` when memory may matter.
- Use `moot_memory_search` for broad recall.
- Use `moot_recall_precise` for exact details and near-duplicates.
- Use `moot_fact_search` for structured facts.
- Use lenses and `moot_synthesize` for analysis.
- Write durable knowledge with `moot_file_memory`, `moot_file_fact`, `moot_link_memories`, and `moot_write_journal`.
- Correct stale knowledge instead of silently overwriting it.
- Run `moot_dream` after bulk import or significant memory growth.

Disclose unavailable or thin recall.

