---
name: start-clean
description: Preserve a cold-start MOOT handoff when the user wants to end this session and continue in a fresh Codex task. Record enough context for a different model or machine to resume.
---

# Start clean

Prepare and file a self-contained handoff for a fresh task with no inherited
conversation. Follow the identification, filing, readback, plan-linking, and
failure handling in [prepare-for-compact](../prepare-for-compact/SKILL.md).

Lead with two paragraphs explaining what is being built and why. Follow with
verified state, decisions and reasoning, failed approaches, exact strings and
source anchors, open questions, and the proposed next action. Put the immediate
interrupted work last. Include the assigned checkout, WIP ownership, and any
unresolved user decision so another task can orient without guessing.

Preserve the approved plan in full and link its drawer to the handoff. Do not
assume a local or gitignored plan file will exist on the next machine. Explain
operator corrections and why an earlier approach was abandoned where relevant.

Use the filing/readback outcome to choose the final wording. On verified success,
report the handoff ID and that the handoff is ready for a fresh task. On failure,
print the full handoff and report exactly what was and was not saved.

Tell the user to invoke `$mootx01-start` and `$recover-from-compact` in the next
task, supplying the handoff ID. Do not emit Claude slash commands or claim the
session was cleared. Creating, closing, or archiving a Codex task is a separate
action requiring the user's request; this skill only preserves the handoff.
