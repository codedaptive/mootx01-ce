# MOOTx01 Session Ritual

Use these lightweight rituals in any AI harness, even when the harness has no
native hooks.

## Start

When the task might depend on memory:

1. `moot_estate_ping`
2. `moot_estate_status`
3. `moot_read_journal`
4. `moot_memory_search` or `moot_recall_precise` with a focused query
5. `moot_estate_map` if project or corpus structure matters
6. `moot_list_lenses` if analysis is needed

## During Work

Before answering:

- Recall first if prior context matters.
- Use facts for entity/relation lookups.
- Use lenses for analysis.
- Use synthesis for grounded summaries.
- Say when recall is thin or unavailable.

When new durable knowledge appears:

- File the memory.
- Store stable facts.
- Link related memories.
- Confirm or update trust state.

## After Bulk Ingest

1. Import with `moot_vault_import` or `moot_palace_import`.
2. Poll with `moot_vault_job` (vault imports) or check estate status (palace imports).
3. If the estate was just bulk-imported, poll `moot_drain_status` until the encode queue settles. Imports index themselves; do not run `moot_reindex` as a routine step.
4. Verify with `moot_estate_map`.
5. Run `moot_dream`.
6. Optionally run `moot_distill` to populate the distilled tier (`moot_consolidate` accepted as an ACK-gated alias).
7. Search or synthesize only after the estate has been indexed and dreamt.

## End

Before ending meaningful work:

1. Ask what changed.
2. File durable decisions and observations.
3. File stable facts.
4. Link related memories.
5. Update, withdraw, or retire stale claims.
6. Write a journal entry.
7. Run `moot_dream` after major memory growth.

End-state rule: leave the estate better organized than you found it.

