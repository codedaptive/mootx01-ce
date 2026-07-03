---
name: mootx01-memory
description: Use proactively before answering when a task involves memory, "last time", "remember", prior decisions, user preferences, project history, source material, continuity/resume, grounded synthesis, contradiction checks, corpus import, durable writeback, or post-import dreaming through MOOTx01.
---

# MOOTx01 Memory Skill

Use MOOTx01 as an active memory and reasoning layer, not as a passive wiki. Reach
for it whenever a task may depend on long-term memory or substrate analysis.

## MOOT Reflex

Before answering any request that may depend on prior context, user preferences,
project history, past decisions, continuity, or remembered source material, query
MOOTx01 first.

After durable decisions, corrections, preferences, milestones, or useful project
facts, write them back with the appropriate MOOTx01 tool.

If MOOTx01 tools are expected but unavailable, say so plainly. Never imply recall
happened unless you actually queried it.

If the MOOTx01 MCP server fails to start or its tools are absent, the most
likely cause is that the `mootx01` binary is not installed on this machine —
the plugin ships configuration only, not the binary. Tell the user and offer
the fix: `brew install codedaptive/mootx01-ce/mootx01` (macOS/Linux) or
`winget install Codedaptive.MOOTx01` (Windows), then restart the client.

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
   - `moot_recall_distilled` for compact factoid answers from the distilled tier.
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
   - Run `moot_reindex` after batch import, then `moot_dream` after bulk import, major filing, or substantial memory growth.

## Cost Rule

Ask MOOTx01 to reduce the search space before asking the LLM to reason over large
text. Use the LLM for judgment, explanation, planning, and writing after MOOTx01 has
recalled, ranked, filtered, linked, or synthesized.

## Answer Discipline

Separate what MOOTx01 recalled, what MOOTx01 synthesized, and what you inferred. If
recall is thin or unavailable, say so plainly. Never claim you remembered or recalled
something from MOOTx01 unless you actually used the tool.
