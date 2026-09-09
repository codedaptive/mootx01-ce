---
name: mootx01-plans
description: Preserve an approved multi-step plan verbatim in MOOT, link it to handoffs, or retrieve a previous plan when resuming. Applies to agreed plans, not unapproved proposals or worker briefs.
---

# MOOTx01 plans

Preserve the agreed plan while its full text is available. Record the objective,
units of work, dependency order, and rationale verbatim. A brief for one worker
is not the whole plan; do not file it as one or infer missing approval.

Use MCP exclusively for estate access. Ping, then search for an existing plan
using its title, project/repo, and plan slug. Fetch likely matches by returned
drawer ID and compare the full text before filing another copy.

For a new approved plan, call `moot_file_memory` with:

- `location: plans/<project>/<plan-slug>`;
- `subject`: one sentence identifying the plan and approval, at most 120 chars;
- `content`: the complete approved text, preceded by repo, title, approval
  context, and written timestamp so the body remains searchable.

Read the returned ID back with `moot_memory_get`; retain that ID for handoffs.
Locations are filing hints, not IDs. Re-approval of identical text reuses the
verified drawer. Since original memory content is immutable, a changed approved
plan is a new version: file its complete text and link the new drawer to the old
with `moot_link_memories(from_id: <new-id>, to_id: <old-id>, kind: supersedes)`.
Do not pretend `moot_update_memory` replaces the plan's body.

Record progress and mid-plan rulings in linked status/checkpoint memories,
distinguishing done, in flight, and untouched. Preserve the original approved
text. Link each status to its plan with `derivesFrom`; link a handoff to the plan
the same way. Use `from_id` and `to_id` with returned drawer IDs.

Before a planned commit, check whether the approved plan is already filed. If
available but not filed, preserve it now. A filing outage does not block an
otherwise authorized commit: print the full plan in chat and report the failed
write. If filing returned an ID but verification failed, report that distinction
and retain the ID instead of blindly creating a duplicate.

When resuming, retrieve the plan linked from the chosen handoff or search by
project/title. Resolve ambiguous versions from approval evidence and links;
do not assume the newest capture is the operative plan. Reconcile progress with
current repository state before making claims about completion.
