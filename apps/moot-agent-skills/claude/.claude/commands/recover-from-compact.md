# Recover from Compact

Read your handoff and re-orient before doing any work.

Run this after a compact where nothing was injected automatically, when
resuming in a fresh session rather than a compacted one, or when the
injected text was thin and you want the full picture.

## 1. Find the right handoff

Two things make this harder than it looks.

After a compact your session id is unchanged, so the direct lookup works.
After a **fresh session** it is a new id and you cannot know the old one.
And more than one agent may work from this same directory on different
things, so a bare search returns handoffs that are not yours.

Resuming a compact, try the direct path:

    moot_memory_get on session/<session_id>/handoff

Otherwise search, and expect several results:

    moot_memory_search("handoff <repo-name>")

For each candidate, establish three things before choosing:

- **Which repo** it names. Discard anything not this one
- **Which agent** wrote it. Another agent's handoff is not yours
- **How recent** it is, and whether its branch still exists

If exactly one survives, say which you took and why, then continue.

**If more than one survives, stop and ask.** List them: agent, timestamp,
branch, and the first line of each. Let the operator pick.

Guessing is worse than asking here. A wrong handoff does not announce
itself: it reads as perfectly coherent context for work you were never
doing, and you will proceed with total confidence in someone else's task.

## 2. Walk back only if you need to

The handoff links `derivesFrom` the most recent checkpoint, which links
back through the earlier ones. Use `moot_connection_search` from the
handoff to follow the chain.

Walk back only if the handoff leaves you short. That is the point of the
chain: one read on resume, deeper history on demand, rather than the whole
session dumped into a fresh context.

If the handoff names a plan, read the plan before starting work. The
handoff tells you where things stand; the plan tells you what the shape was
meant to be.

## 3. Check the ground truth

The handoff describes the world as it was when it was written. Before
acting on it, confirm what is true now:

    git -C <repo> log --oneline -5
    git -C <repo> status --porcelain

A handoff that says a branch was pushed against a repo that says otherwise
means the push failed after the note was written. Trust the repo.

## 4. Say where you are

In a few lines: what this session is picking up, what the handoff says is
in progress, anything the repo contradicts, and what you intend to do
first. Then wait.

Do not start work in this turn. Orientation is the whole job here.

## If there is no handoff

Say so plainly rather than guessing. Read the recent git log and any
project state file, report what you can establish, and name what you
cannot. A plain cold start beats a confident wrong reconstruction.
