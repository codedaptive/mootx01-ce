# Start Clean

Write a cold-start handoff and file it to the estate. Do this now, in this
turn, before anything else.

This session is ending. The next one begins clean, possibly on a different
model, possibly days later, with nothing carried over. That is different
from a compact, where the thread is inherited.

So lead with orientation, not with immediacy. What we are building and why
comes first, in two paragraphs. What we happened to be doing at the moment
it stopped comes last.

## What to cover

- **What we are building and why.** Two paragraphs, not a line. This is the
  part a resume handoff can skip and a cold start cannot
- Where things stand: done, in progress, untouched. Name the in-progress
  thing precisely, by branch, task id, or half-edited file
- Decisions and the thinking behind them, especially ones that would look
  arbitrary from outside
- What failed and how it failed. A session that knows how a thing broke
  recognises it again
- Exact strings: errors, config keys, response shapes, commit SHAs,
  `file:line` anchors. Quote them verbatim. A paraphrased error is neither
  searchable nor recognisable
- What is still open, including what nobody decided
- Where you would pick up, and why you think so

Give them context, not commands. Skip anything they would get from reading
the code.

## Identify it so it can be found

Open the body with:

    repo:    <repository name>
    agent:   <your agent name>
    branch:  <the branch, or none>
    written: <ISO timestamp>

A later session discards on repo, then agent, then takes the most recent.
More than one agent may work from this directory, and a wrong handoff reads
as perfectly coherent context for work nobody was doing.

## The active plan

If you are holding an approved plan, file the plan itself, in full, to
`plans/<project>/<plan-slug>` and link the handoff to it `derivesFrom`.

File the plan text, not a reference. The next session may be on another
machine, and a plan file in a gitignored working directory does not travel.

## Filing

`moot_file_memory` to `session/<session_id>/handoff`, with the session id in
the body as plain text too.

If the estate is unreachable or the write fails, print the whole handoff in
chat so it can be pasted somewhere durable, and say plainly that it did not
file.

## When you are done

Confirm in one line where it went. Then say:

    Cold start handoff filed. Safe to close this session.
    In the new one: /mootx01-start then /recover-from-compact.

Do not do anything else in this turn.
