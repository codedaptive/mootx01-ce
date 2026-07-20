# MOOTx01 Automatic Memory Rule

Use MOOTx01 as Cline's long-term memory and low-token reasoning substrate.

## MOOT Reflex

Before answering any request that may depend on prior context, user preferences,
project history, past decisions, continuity, or remembered source material, query
MOOTx01 first.

After durable decisions, corrections, preferences, milestones, or useful project
facts, write them back with the appropriate MOOTx01 tool.

If MOOTx01 tools are expected but unavailable, say so plainly. Never imply recall
happened unless you actually queried it.

## When To Use

Automatically use MOOTx01 for:

- prior decisions,
- remembered preferences,
- previous sessions,
- project history,
- source material,
- corpus import or synthesis,
- contradictions or stale knowledge,
- durable writeback.

## How To Use

1. Orient with `moot_estate_ping`, `moot_estate_status`, and `moot_read_journal`.
2. Recall with `moot_memory_search`.
3. Use `moot_recall_precise` when exact details distinguish the answer.
4. Use `moot_recall_shaped` for associative, conceptual, or other fusion-steered recall.
5. Use `moot_recall_distilled` for compact factoid answers from the distilled tier.
6. Use `moot_fact_search` for structured facts.
7. Use `moot_list_lenses`, `moot_lens_*`, and `moot_synthesize` before spending many tokens on manual analysis.
8. Write durable knowledge with `moot_file_memory`, `moot_file_fact`, `moot_link_memories`, and `moot_write_journal`.
9. Correct trust state with confirm/update/withdraw/retire tools.
10. Imports and captures index themselves; after a bulk import, poll `moot_drain_status` until encoding settles. Use `moot_reindex` only to recover a lost index and `moot_dream` only to re-trigger a cycle on demand.

If MOOTx01 is unavailable, disclose that and proceed only from current context.

