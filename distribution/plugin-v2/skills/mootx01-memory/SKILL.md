---
name: mootx01-memory
description: Use proactively before answering when a task involves memory, "last time", "remember", prior decisions, user preferences, project history, source material, continuity/resume, grounded synthesis, cross-checking recorded links and facts, corpus import, durable writeback, or post-import indexing through MOOTx01.
---

# Use MOOTx01 through ARIA v2

Use MOOTx01 when the task needs stored knowledge, prior conversations, source context, structured facts, or authorized durable changes. Choose the operation by the user's intent, then use its typed result.

## Discover the running surface

The server's advertised tools include their argument schemas. Choose the matching operation below and make that task operation your first call. Do not preflight a listed operation with `moot_help`: the call patterns below and its advertised schema supply the needed arguments. Use `moot_help` when an operation is absent, a required argument is still unclear, or the server reports a compatibility or argument error. With no arguments it returns available operations; `{"tool":"moot_memory_search"}` requests one operation's contract. Use `intent` instead of `tool` to discover an unfamiliar operation. Recipe names in help are not necessarily callable tools.

This teaching targets v2. Compare its packaged surface identity and capability digest with runtime help/status when compatibility is uncertain. Report a mismatch once and use the operations actually available. If the server requires different argument names from these patterns, that is a contract mismatch: before retrying, tell the user once that the running server uses a different argument contract and that you are adapting to it. Then use the server's stated argument names. Missing optional capabilities do not by themselves prove an installation failure. V2 uses `moot_help`; do not add legacy `teachme` arguments to ordinary calls.

## Choose the first operation

Replace angle-bracket placeholders with the user's values or actual returned identities. These are argument objects, not JSON strings. Supply the user's question as `query`; do not substitute the examples' placeholder text.

| Need | First operation | Argument pattern |
| --- | --- | --- |
| Ordinary knowledge or broad relevance search | `moot_memory_search` | `{"query":"<question>"}`; relevance is the default ordering. |
| An answer in a prior conversation or session transcript | `moot_memory_recall_transcript` | `{"query":"<question>"}`. The server selects the recipe and required reranker; no tuning arguments are needed. |
| A known memory or context behind an excerpt | `moot_memory_get` | Use its returned `fetch.arguments`, or `{"memory_id":"<memory UUID>"}`. |
| Exact wording, identifiers, paths, or versions | `moot_recall_precise` | `{"query":"<exact wording>"}`; use get when the memory UUID is known. |
| Sources connected from a known memory | `moot_connection_search` | `{"memory_id":"<memory UUID>","direction":"outgoing"}`. |
| Memories within a supplied date range | `moot_recall_temporal` | `{"query":"<topic>","window":"tight","grab":"dated","from":"<start timestamp>","to":"<end timestamp>"}`. |
| Complete memory inventory | `moot_memory_list` | `{"wing":"<wing>"}`, then follow every returned continuation cursor. |
| Rows from a known dataset | `moot_dataset_query` | `{"dataset_id":"<dataset UUID>"}` plus the requested typed predicate, order and columns. |
| Authorized durable capture | `moot_file_memory` | `{"content":"<content>","subject":"<subject>","location":"<room>"}`; use the requested placement or a suitable room name. |
| Authorized JSON import | `moot_json_import` | `{"path":"<source path>"}`, then follow its readiness references. |
| Find contradictory stored claims | `moot_hunt_contradictions` | `{}`; this analyzes without filing proposals. |

For recorded task continuity, search the relevant plan or decision and use `moot_read_journal`. For an unfamiliar specialized analysis, discover the appropriate lens through `moot_help`.

Transcript recall retrieves answer-bearing sessions; it does not fetch a conversation by an invented session ID. Its reranker remains experimentally qualified. If required models or fresh spans are unavailable, report the refusal. General search is not an equivalent successful transcript result.

## Complete an enumeration

For a complete inventory, follow each `next_cursor` until `has_more` is false and count unique returned memory IDs. Stop when the final page is complete; do not restart a completed enumeration. When the user asks for the total, report the count and scope. Include an ID listing only when the user explicitly asks for the IDs, and preserve returned IDs exactly rather than reconstructing them.

## Read typed results

Success data is in `structuredContent.data`. Compact results contain excerpts, not hidden full bodies. Fetch full context only when needed. Preserve the distinction between `memory_id`, `fact_id`, `dataset_id`, and `handle_memory_id`; use returned references rather than converting one kind into another.

Follow `next_cursor` while `has_more` is true, retaining the same scope. A stale or expired cursor requires restarting enumeration. Do not claim a partial inventory is complete.

For datasets, send predicates as JSON objects matching the advertised schema, never JSON encoded inside a string. For example, `"where":{"col":"status","op":"eq","val":"ready"}`, `"order_by":[{"col":"sequence","dir":"asc"}]`, and `"columns":["name","sequence"]` filter, sort and project actual columns. Use the advertised schema's comparisons and limits; consult help only if it leaves a required detail unresolved. Omitted optional fields are not evidence of empty values.

## Make authorized changes and recover accurately

Use `moot_file_memory` for authorized durable capture and verify through its returned memory reference. Preserve an issued write identity if later verification fails; retrying capture can duplicate the write. Use journal writes when task continuity should be persisted within the authorized scope.

`moot_monitoring_status` reads state; `moot_monitoring_set` changes it. `moot_hunt_contradictions` performs read-only analysis. Persist only explicitly selected candidates with `moot_propose_contradictions`, retaining the returned `analysis_ref` and `candidate_ids`. A proposed link is not an accepted fact or user confirmation. Migration confirmation likewise requires actual approval; a suggested next call does not provide it.

After import, follow the actual returned job/status or rebuild/drain reference until its documented ready state. Do not automatically add reindex or dream operations to every import.

Treat `isError:true` as a failed operation, not an empty successful result. Invalid-argument errors identify the field to correct. Follow safe recovery references and the `retryable` value, preserving successful write receipts. Never infer authorization from recovery guidance.

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
