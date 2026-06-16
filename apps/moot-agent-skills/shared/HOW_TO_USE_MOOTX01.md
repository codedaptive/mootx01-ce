# How To Use MOOTx01

You are connected to MOOTx01, a long-term memory and reasoning substrate for AI
agents.

Do not treat MOOTx01 as a wiki, notes folder, or passive search index. Treat it
as a low-token reasoning layer that can remember, retrieve, rank, link,
confirm, contest, synthesize, and analyze information before you spend
expensive context-window tokens.

Your job is to use MOOTx01 actively.

## Core Principle

Before answering from memory, ask MOOTx01.

Before summarizing a large body of knowledge, ask MOOTx01 to reduce it.

Before assuming a prior decision, preference, fact, contradiction, or project
state, search MOOTx01.

Before ending meaningful work, write back what should persist.

MOOTx01 is not just storage. It contains memories, structured facts, links
between memories, journals, trust state, estate maps, recall indexes, reasoning
lenses, and a dreaming layer that can build associations outside the LLM context
window.

Use it to make yourself cheaper, more accurate, and less forgetful.

## Session Start

At the start of a session, check whether MOOTx01 is alive and what it knows.

Use:

- `moot_estate_ping` to verify the server is reachable.
- `moot_estate_status` to inspect the estate summary.
- `moot_read_journal` to recover recent agent continuity.
- `moot_estate_map` to see the structure of wings, rooms, and memory counts.
- `moot_list_lenses` to discover available reasoning tools.

If a tool supports `teachme:true`, use it when unsure. This asks MOOTx01 to
explain that tool without mutating the estate.

If MOOTx01 is unavailable, say so plainly. Do not pretend to remember.

## Recall

Use `moot_memory_search` for ordinary recall.

Use it when the user asks about prior decisions, project history, preferences,
source material, plans, unresolved issues, or anything that may already be
known.

Good queries are short and specific.

Use `moot_recall_precise` when exactness matters: dates, paths, numbers, names,
versions, identifiers, and near-duplicates.

Use recall before reasoning. Do not load unnecessary memories into context and
ask yourself to sort them if MOOTx01 can rank them first.

## Structured Facts

Use `moot_file_fact` for stable subject-predicate-object knowledge.

Use `moot_fact_search` when the question is about known entities,
relationships, settings, ownership, status, or decisions.

Use `moot_retire_fact` when a structured fact becomes stale or false.

Use `moot_fact_timeline` when the evolution of belief matters.

Facts are not a replacement for memories. Facts are for stable claims. Memories
preserve context.

## Writing Memory

Use `moot_file_memory` when something should be remembered.

File small, focused memories. A good memory is usually one decision,
observation, correction, source-backed finding, preference, or useful synthesis.

Include a meaningful `location`, such as:

- `project/importer/decisions`
- `user/preferences/codex`
- `mootx01/architecture`
- `wwdc2026/swiftui/drag-drop`

Use `kind` when helpful: `prose`, `code`, `transcript`, `list`,
`structuredJSON`, or `imageCaption`.

Use `event_time` for historical ingestion.

Use `impatient:true` only when the memory must be immediately searchable.
Otherwise let background indexing do the cheaper work.

## Journaling

Use `moot_write_journal` at the end of meaningful sessions.

Journal entries are for continuity: what happened, what changed, what remains
unresolved, and what a future agent should know before continuing.

Use `moot_read_journal` at the start of work or when resuming a thread.

## Linking Memories

Use `moot_link_memories` to connect related memories.

Relationship kinds include `supports`, `contradicts`, `refines`, `extends`,
`precedes`, `exemplifies`, and `relates`.

A wiki forces the LLM to infer structure by rereading. MOOTx01 lets you store
structure directly.

## Trust And Correction

Do not silently overwrite history.

If a memory is verified, use `moot_confirm_memory`.

If a memory is wrong, stale, contested, superseded, or resolved, use
`moot_update_memory`.

If a memory should leave active circulation but remain recoverable, use
`moot_withdraw_memory`.

Use `moot_erase_memory` only when permanent deletion is explicitly required and
confirmed.

Prefer correction over deletion. A useful memory estate preserves how belief
changed.

## Reasoning Lenses

Use reasoning lenses when the user needs understanding, not just recall.

Call `moot_list_lenses` to see available tools.

Common uses:

- Keystone or centrality lenses find load-bearing memories.
- Constellation or community lenses understand clusters.
- Theme lenses find emerging topics.
- Drift lenses compare before and after a change.
- Contradiction lenses find memories that do not fit.
- Trust synthesis prefers higher-confidence evidence.
- Partial-cue recall handles vague "it was like..." prompts.
- Prediction or successor lenses anticipate likely next steps.
- Bias or preference lenses detect learned preference patterns.

A lens is not a search query. It is an analytical pass over the estate.

Prefer a lens over asking the LLM to reread many memories and invent analysis
from scratch.

## Synthesis

Use `moot_synthesize` when the user asks for a grounded summary,
recommendation, pattern, or set of key insights.

When answering, distinguish:

- What MOOTx01 recalled.
- What MOOTx01 synthesized.
- What you infer as the LLM.

Do not present inference as stored fact.

## Dreaming

Use `moot_dream` after bulk import, major filing, or substantial memory growth.

Dreaming rebuilds MOOTx01's association layer, including co-occurrence and
temporal matrix signals. It can also mine latent alignments into proposed links
and write a cycle diary.

This is one of the main ways MOOTx01 beats a wiki.

A wiki waits for the LLM to reread and reconnect ideas every time. MOOTx01 can
precompute associations before the next question arrives.

After importing or filing many memories, run `moot_dream` before relying on
matrix-aware recall, association recall, or deep synthesis.

## Vaults And Source Material

Use vault tools for bulk source import/export and reconciliation.

- `moot_vault_import` imports a Markdown vault into an estate.
- `moot_vault_export` exports an estate to a Markdown vault.
- `moot_vault_status` checks vault state.
- `moot_vault_reconcile` detects drift.
- `moot_vault_job` polls long-running import/export jobs.

Raw source material remains authoritative. MOOTx01 can project, index,
classify, and connect it, but do not confuse a generated synthesis with the
original source.

After a large import, verify completion with the job result and estate map. Do
not judge success only by the first search result.

## Cost Discipline

Your context window is expensive. MOOTx01 operations are the cheap first pass.

Use MOOTx01 to narrow search space, rank candidates, find exact matches, detect
contradictions, identify trusted memories, surface graph structure, summarize
grounded patterns, preserve continuity, and precompute associations.

Then use the LLM for judgment, explanation, planning, writing, abstraction,
user-facing synthesis, and creative recombination.

Do not spend tokens doing work MOOTx01 can do structurally.

## Operating Rule

Recall first.

Reason second.

Write back what matters.

Link what belongs together.

Confirm what is trusted.

Contest what is uncertain.

Dream after major change.

Do not make the next AI rediscover what this AI already learned.

