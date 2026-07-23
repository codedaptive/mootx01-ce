---
name: mootx01-memory
description: Use MOOTx01 for prior decisions, user preferences, project history, source-backed recall, corpus synthesis, contradiction checks, session continuity, durable writeback, and post-import dreaming.
---

# MOOTx01 Memory Skill

Use this skill when the task may benefit from long-term memory or substrate
analysis.

## MOOT Reflex

Before answering any request that may depend on prior context, user preferences,
project history, past decisions, continuity, or remembered source material, query
MOOTx01 first.

After durable decisions, corrections, preferences, milestones, or useful project
facts, write them back with the appropriate MOOTx01 tool.

If MOOTx01 tools are expected but unavailable, say so plainly. Never imply recall
happened unless you actually queried it.

## Trigger Words

Use this skill for prompts containing or implying:

- remember
- last time
- previous
- continue
- what did we decide
- where did we leave off
- based on my preferences
- summarize what we know
- compare to earlier
- source-backed
- import this corpus

## Protocol

1. Verify availability with `moot_estate_ping`.
2. Orient with `moot_estate_status`.
3. Recover continuity with `moot_read_journal`.
4. Recall with `moot_memory_search`, `moot_recall_precise`, `moot_recall_shaped`, `moot_recall_distilled`, or `moot_fact_search`.
5. Analyze with `moot_list_lenses`, relevant `moot_lens_*` tools, or `moot_synthesize`.
6. Write durable results with `moot_file_memory`, `moot_file_fact`, `moot_link_memories`, and `moot_write_journal`.
7. Correct stale knowledge with confirm/update/withdraw/retire tools.
8. Imports and captures index themselves; after a bulk import, poll `moot_drain_status` until encoding settles. Use `moot_reindex` only to recover a lost index and `moot_dream` only to re-trigger a cycle on demand.

## Cost Rule

Ask MOOTx01 to reduce the search space before asking the LLM to reason over
large text. Use the LLM for judgment, explanation, planning, and writing after
MOOTx01 has recalled, ranked, filtered, linked, or synthesized.

## Disclosure

Never say you remembered or recalled something from MOOTx01 unless you used the
tool. If MOOTx01 is unavailable or recall is thin, say so.

