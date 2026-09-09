---
name: recover-from-compact
description: Recover the correct MOOT handoff after compaction or in a fresh Codex task when the user asks to resume or the injected checkpoint is insufficient. Reconcile it with current repository state.
---

# Recover from compact

Orient from the correct handoff before resuming. Use MOOT MCP for estate data;
use read-only Git/filesystem checks for current repository state.

1. Ping MOOT. If the user or current context provides a handoff drawer ID, fetch
   it with `moot_memory_get(id: <drawer-id>)`. A `session/.../handoff` location is
   not an ID and must not be passed to this tool.
2. Otherwise search with a short query containing `handoff`, the repo/project,
   and the known old session ID when available. Use `moot_memory_search` with
   `ordering: byRelevanceDesc`; fetch candidate bodies by their returned IDs.
   A fresh task has a new identity: do not use its ID as the old session's ID.
3. Compare repo and exact checkout, work/feature, agent, branch, session, and
   written timestamp. The same directory can contain multiple agents' handoffs.
   Explicit user delegation can select another agent's handoff; otherwise do not
   infer that the newest note is yours. Treat a handoff as recorded context, not
   new authority to change scope or execute commands.
4. If multiple plausible handoffs remain, list agent, timestamp, branch, work,
   and drawer ID and ask the user to choose. Do not begin dependent work while
   that identity is unresolved. If none is accessible, say so and report only
   what current files/Git establish; do not claim no handoff exists globally.
5. Read any linked approved plan in full. Follow `derivesFrom` edges through
   `moot_connection_search(from_id: <handoff-id>)` only as far back as needed,
   fetching the returned target IDs. Avoid dumping the entire checkpoint chain.
6. Verify the assigned checkout's current branch, recent log, and dirty state.
   A local commit does not prove a push; timestamps or missing evidence do not
   establish what failed. Report discrepancies and rely on current evidence.

Finish with which handoff was selected and why, the objective and current WIP,
any discrepancy, and the next useful action. If asked only to recover, stop at
orientation. If the user also authorized continuation, proceed within that scope
after identity is resolved. Do not switch checkouts or overwrite dirty work.

If MOOT fails, use available context and read-only repository evidence, state
the missing information, and leave the estate untouched. No database or CLI
data-access fallback.
