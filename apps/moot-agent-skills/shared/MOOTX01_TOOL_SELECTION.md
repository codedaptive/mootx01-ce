# MOOTx01 Tool Selection

Use this table to choose the cheapest useful substrate action before spending
LLM context tokens.

## Tool Names, Namespacing, and Availability

- Prefer the visible MOOTx01 tool names below when the harness exposes them directly.
- If the harness namespaces MCP tools (e.g. `mcp__mootx01__moot_memory_search`,
  `mootx01.moot_memory_search`, or another server-prefixed variant), use the
  equivalent namespaced tool — preserve the intent, not the literal string.
- If MOOTx01 tools are expected but unavailable, say so plainly and answer only from
  current context. Never claim memory recall happened unless a MOOTx01 query actually ran.

## Orientation

- `moot_estate_ping` - check server and estate reachability.
- `moot_estate_status` - inspect memory count, wings, facts, sync/status, and protocol hints.
- `moot_estate_map` - browse structure and memory counts by location.
- `moot_help` - discover callable operations or inspect one operation's contract. Use when an operation is absent, a required argument is unclear, or the server reports a compatibility error. With no arguments returns the available operations; `{"tool":"moot_memory_search"}` requests one operation's full contract.
- `moot_monitoring_set` - configure daemon telemetry monitoring and confirm its effective state. Pass `{"enabled":true}` to turn on background signal collection.
- `moot_read_journal` - resume recent agent continuity.
- `moot_list_lenses` - discover available reasoning lenses and recipes.
- `moot_list_recipes` - browse the full recipe catalog with descriptions and required capabilities.

## Recall

- `moot_memory_search` - ordinary memory recall; broad, high-recall search.
- `moot_memory_recall_transcript` - find previous conversations containing the answer to a question, including earlier decisions and troubleshooting. Use when the user references a prior session or conversation.
- `moot_recall_precise` - exact recall when names, numbers, paths, dates, versions, identifiers, or near-duplicates matter. Supports named reduction compositions for re-ranking.
- `moot_recall_shaped` - shaped recall with fusion presets (balanced, precise, conceptual, broad, lexical, associative, consensus, temporal, structural, anti_redundant, and others). Use when the recall mode matters more than a specific query string.
- `moot_recall_distilled` - dense recall from the distilled factoid layer. Returns compact factoids with confidence scores.
- `moot_memory_get` - fetch one or more memories by id. Supports `depth`: `subject` (dense row only), `distilled` (dense row plus distilled text), `skim` (source-order distilled preview with a 512 UTF-8 byte target; intact groups may exceed it, and you fetch distilled or full for the remainder), or `full` (complete record including verbatim content).
- `moot_fact_search` - structured entity/relation/fact lookup.
- `moot_fact_timeline` - trace how structured facts changed over time.

## Writing

- `moot_file_memory` - file a durable memory with content, a one-sentence subject (≤120 chars, written for the next AI that scans it), and location.
- `moot_move_memory` - reanchor a memory to a different location or wing.
- `moot_file_fact` - store a stable subject-predicate-object assertion.
- `moot_write_journal` - record session continuity and handoff notes.
- `moot_link_memories` - create typed relationships between memories. Accepted kinds: relates, precedes, contradicts, supports, refines, exemplifies, extends, supersedes, references, blocks, validates, derivesFrom, covers, elaborates, respondsTo.

## Trust And Correction

- `moot_confirm_memory` - mark verified memory as trusted.
- `moot_update_memory` - contest, reject, resolve, supersede, revive, accept, or confirm with a note.
- `moot_withdraw_memory` - soft-remove stale content from active circulation.
- `moot_erase_memory` - permanent deletion only when explicitly required and confirmed.
- `moot_retire_fact` - retire a stale or false structured fact.
- `moot_propose_contradictions` - resolve explicitly selected contradiction candidates from a prior `moot_hunt_contradictions` analysis. Pass the `analysis_ref` and the `candidate_ids` to act on.

## Graph And Associations

- `moot_connection_search` - inspect outgoing links from a memory.
- `moot_connection_map` - inspect incoming links to a memory.
- `moot_lens_keystones` - find load-bearing graph memories.
- `moot_lens_constellation` - find communities/clusters.
- `moot_lens_free_association` - walk from a seed memory.
- `moot_lens_successors` - find likely successor memories.

## Analysis Lenses

- `moot_lens_theme_weather` - rising and fading themes.
- `moot_lens_latent_themes` - emergent topic factors.
- `moot_lens_bias` - learned preference and dismissal patterns.
- `moot_lens_drift` - before/after change.
- `moot_lens_contradiction` - outliers and tensions.
- `moot_lens_trust_synthesis` - trust-ordered synthesis.
- `moot_lens_partial_cue` - vague cue recall: feels-like, about-this, from-then.
- `moot_lens_anticipate` - likely actions/outcomes.
- `moot_lens_overlap` and `moot_lens_divergence` - authorized federated comparison.
- `moot_lens_associations`, `moot_lens_apriori`, `moot_lens_concepts` - association rules and formal concepts.
- `moot_lens_node_motion` - how a single memory has moved over time: volatility, topic trajectory, reanchor detection.
- `moot_lens_cohesion` - flag memories whose content cohesion with peers is anomalously low.
- `moot_lens_moment`, `moot_lens_rhythm`, `moot_lens_precedence`, `moot_lens_complexity` - temporal and information-theoretic analysis.

## Distillation And Maintenance

- `moot_reindex` - recovery tool: backfill BM25 and vector indexes after an index loss or for estates created before encode-on-capture. Not needed after imports; they index themselves.
- `moot_palace_import` - import a MemPalace directly into the estate (drawers, tunnels, KG triples). The import triggers its own indexing and dreaming; poll `moot_drain_status` to watch encoding settle.

## Synthesis And Dreaming

- `moot_synthesize` - grounded summary, patterns, recommendations, key insights.
- `moot_dream` - rebuild co-occurrence/temporal matrix signals and mine latent associations after bulk import or major growth.

## Vaults

- `moot_vault_import` - import Markdown vault content into an estate.
- `moot_vault_export` - export estate to a Markdown vault projection.
- `moot_vault_status` - inspect vault manifest state.
- `moot_vault_reconcile` - detect drift between vault projection and manifest.
- `moot_vault_job` - poll long-running import/export jobs.

## Migration

- `moot_migration_run` - benchmark migration plans against a corpus with the zero-silent-loss gate. Returns ranked survivors with branch ids.
- `moot_migration_confirm` - promote the winning migration branch and discard losers. Requires explicit confirmation.

## Federation

- `moot_federated_recall` - grant-authorized recall across locally-open estates.
