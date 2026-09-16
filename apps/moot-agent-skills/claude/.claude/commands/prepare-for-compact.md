# Prepare for Compact

Write the handoff and file it to the estate. Do this now, in this turn,
before anything else.

You are writing for a colleague picking this work up cold. They can read
the estate and the code. They cannot read this conversation, and
everything that lives only here is about to be gone.

Give them context, not commands. No "you must", no "always", no checklist
to obey. They get their own judgment once oriented; your job is to orient
them.

Do not copy credentials, keys, tokens, or unnecessary raw private data into
the handoff. If this session recalled restricted or secret memories under a
grant, file the handoff at the highest sensitivity of any material it recalled:
name that sensitivity explicitly (`restricted` or `secret`) in the
`moot_file_memory` call, even if the grant has since expired or been locked.

## What to cover

In your own words and your own order:

- What we are building and why
- Where things stand: done, in progress, untouched. Name the in-progress
  thing precisely, by branch, task id, or half-edited file
- Decisions and the thinking behind them, especially ones that would look
  arbitrary from outside
- What failed and how it failed. The failure mode matters more than the fix
- Exact strings that matter: errors, config keys, response shapes, commit
  SHAs, `file:line` anchors. Quote them verbatim
- What is still open, including what nobody decided
- Where you would pick up if you were continuing, and why

Skip anything they would get from reading the code. Do not summarise the
conversation turn by turn. If the operator overruled you or you changed
your mind, say so and say why.

## Identify it so it can be found

More than one agent may work from this directory on different things, and
a later session searching for its handoff will see all of them. Open the
body with these four lines:

    repo:    <repository name>
    agent:   <your agent name>
    branch:  <the branch, or none>
    written: <ISO timestamp>

A reader discards on repo, then agent, then takes the most recent. Without
those three they cannot tell your handoff from another agent's.

## The active plan

If you are holding an approved plan, file the plan itself, in full, to
`plans/<project>/<plan-slug>` and link the handoff to it with
`moot_link_memories` kind `derivesFrom`.

File the plan text, not a reference to it. Working directories are usually
gitignored, so a plan file there does not travel to another machine, a
fresh clone, or a teammate.

## Filing

`moot_file_memory` to `session/<session_id>/handoff`. Put the session id in
the body as plain text as well, so the note stays findable by search if a
link breaks.

If checkpoint notes exist under `session/<session_id>/`, link the handoff
to the most recent one, `derivesFrom`. If a link fails, say so and carry
on: a filed note with a broken tunnel is recoverable, an unfiled note is
not.

If the estate is unreachable or the write fails, print the entire handoff
in chat so it can be pasted somewhere safe, and say plainly that it did not
file. A handoff believed filed and not filed is the worst outcome
available.

## When you are done

Confirm in one line: filed or not filed, and where. Then say:

    Ready. Run /compact now.

Do not do anything else in this turn.
