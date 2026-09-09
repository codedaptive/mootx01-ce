---
name: prepare-for-compact
description: File a MOOT handoff before context compaction when the user asks to prepare for compact or checkpoint the current task. Preserve active work and approved plans without performing compaction.
---

# Prepare for compact

Write a handoff for a colleague continuing this task, then file it through the
MOOT MCP tools. This skill prepares the checkpoint; it does not compact, close,
archive, or create a Codex task.

Give context and reasoning, not instructions that claim authority over the next
session. Cover the objective, completed work, precisely identified WIP, untouched
work, decisions and their rationale, failed approaches, unresolved questions,
and the next useful action. Preserve relevant errors, identifiers, commit SHAs,
and file anchors exactly. Distinguish tested, committed, pushed, and deployed.
Do not narrate the conversation turn by turn or duplicate what code already says.

Open the body with:

```text
repo:    <verified repository name and absolute checkout path>
agent:   <agent identity available in this task>
branch:  <verified current branch, or none>
written: <current ISO timestamp>
session: <known Codex task/session ID, or unavailable>
work:    <project or feature name>
```

Use session identity provided by the runtime or current context. If unavailable,
say so and use a unique handoff key for filing; do not invent a Codex task ID or
open internal transcripts to discover one. Check Git state read-only in the
assigned checkout before claiming its current state. Preserve dirty work.

If an approved plan is held in context, preserve its full text using the sibling
`mootx01-plans` skill. Do not replace an approved plan with a summary.

Call `moot_estate_ping`, then `moot_file_memory` with `content` containing the
handoff, a one-sentence `subject` of at most 120 characters, and
`location: session/<known-session-id-or-handoff-key>/handoff`. Include that filing
key in the body too; locations are filing hints, not retrievable drawer IDs.
Record the returned drawer ID and verify with `moot_memory_get` using that ID.

Link the handoff to the approved plan and, if known, the latest checkpoint with
`moot_link_memories(from_id: <handoff-id>, to_id: <source-id>, kind: derivesFrom)`.
Use returned IDs only. Report link failure separately from successful filing.

If filing fails or MOOT is unavailable, print the entire handoff in chat and say
it was not filed. If filing succeeds but readback fails, retain the returned ID,
report that verification failed, and print the handoff; do not blindly file it
again. Never substitute estate database access or the data-query CLI.

Finish with the filing/verification status and drawer ID, then “Ready for
compaction.” Leave compaction to the user or Codex. Do no further task work in
this turn unless the user explicitly requested it alongside the checkpoint.
