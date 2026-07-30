---
name: mootx01-memory
description: Use proactively before answering when a task involves memory, "last time", "remember", prior decisions, user preferences, project history, source material, continuity/resume, grounded synthesis, contradiction checks, corpus import, durable writeback, or post-import dreaming through MOOTx01.
---

# MOOTx01 Memory Skill

Use MOOTx01 as an active memory and reasoning layer, not as a passive wiki.

## MOOT Reflex

Before answering any request that may depend on prior context, user preferences,
project history, past decisions, continuity, or remembered source material, query
MOOTx01 first.

After durable decisions, corrections, preferences, milestones, or useful project
facts, write them back with the appropriate MOOTx01 tool.

If MOOTx01 tools are expected but unavailable, say so plainly. Never imply recall
happened unless you actually queried it.

## Workflow

1. Orient:
   - `moot_estate_ping`
   - `moot_estate_status`
   - `moot_read_journal` when continuity matters
   - `moot_estate_map` when structure matters

2. Recall:
   - `moot_memory_search` for broad recall.
   - `moot_recall_precise` for exact facts, paths, versions, names, numbers, and near-duplicates.
   - `moot_recall_shaped` for associative, conceptual, or other fusion-steered recall.
   - `moot_recall_distilled` for the same search ranking with compact distilled payloads (token-economical prose + per-hit token counts).
   - `moot_fact_search` for structured facts.

3. Analyze:
   - `moot_list_lenses` to discover available cognition tools.
   - Use relevant `moot_lens_*` tools for graph, theme, drift, contradiction, trust, cue, prediction, temporal, and information-theoretic analysis.
   - Use `moot_synthesize` for grounded summaries.

4. Write back:
   - `moot_file_memory` for durable observations and decisions.
   - `moot_file_fact` for stable triples.
   - `moot_link_memories` for durable relationships.
   - `moot_confirm_memory`, `moot_update_memory`, `moot_withdraw_memory`, or `moot_retire_fact` for trust and correction.
   - `moot_write_journal` for session continuity.

5. Dream:
   - Imports and captures index themselves; after a bulk import, poll `moot_drain_status` until encoding settles. Use `moot_reindex` only to recover a lost index and `moot_dream` only to re-trigger a cycle on demand.
   - Run `moot_dream` after bulk import, major filing, or substantial memory growth.
   - Run `moot_distill` to populate on-row distilled representations; captures also distill automatically as the encode queue drains.

## Answer Discipline

Separate what MOOTx01 recalled, what MOOTx01 synthesized, and what you infer.
If recall is thin or unavailable, say so plainly.

