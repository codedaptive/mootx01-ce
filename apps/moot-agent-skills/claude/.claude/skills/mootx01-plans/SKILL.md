---
name: mootx01-plans
description: Use when a plan is approved, when about to commit work that came from a plan, when asked what was planned for a project, or when resuming and looking for a previous session's plan. File the plan to the estate at approval, verbatim, before it is lost with the session.
---

# MOOTx01 Plans

An approved plan lives in the session and nowhere else. It is the single
most expensive thing to reconstruct after a compact, and the obvious place
to write it, the working directory, is usually gitignored: it does not
travel to another machine, a fresh clone, or a teammate.

So file it to the estate at approval, while it is free.

## What counts as a plan

A **plan** is the multi-step thing agreed with the operator: several units
of work, their dependency order, and the reasoning that produced the split.

It is not a task and it is not a brief.

| Artifact | Held by | Already recorded |
| --- | --- | --- |
| Plan | the interactive orchestrator | nowhere, and that is the gap |
| Task | the tracker | ticket, issue, task file |
| Brief | a dispatched worker | ephemeral, deliberately |

A dispatched worker does not know the plan. Its brief carries what to build
and nothing about the units either side of it, which is the point of the
brief rule. If you are holding a brief rather than a plan, this does not
apply to you: filing a brief into `plans/` puts something in the drawer
that is not a plan and makes the drawer less useful.

## At approval

The moment a plan is agreed:

```
moot_file_memory(
  location = "plans/<project>/<plan-slug>",
  content  = <the plan text, verbatim>
)
```

`<project>` is the repository name. `<plan-slug>` comes from the plan's own
title.

**Verbatim, not summarised.** A summary is what the next session would have
written for itself; the plan is what it cannot reconstruct. Include every
step, the dependency order, and the reasoning behind the ordering.

Re-approving a plan updates that note rather than filing a second one.

## Before a commit

Before running `git commit` on work that came from a plan, check the plan
is filed. If it is not, file it now, while you still have it. That is the
last moment it is cheap.

Then commit. Do not hold the commit for it.

## Keep it current

Record which parts are done, which are in flight, which are untouched, and
anything the operator ruled on mid-plan that changed the plan. Update as
the plan progresses rather than only at the end.

A plan note that says everything is untouched, three steps in, is worse
than no note: it is confidently wrong.

## Link it to the handoff

When you write a handoff, link it to the plan:

```
moot_link_memories(from = <handoff>, to = <plan>, kind = "derivesFrom")
```

A session resuming cold reads the handoff, follows the link, and has the
decomposition without anyone having remembered to carry it.

## Reading one back

```
moot_memory_search("plans <project>")
```

The drawer gives you the plan history for a project on its own terms: what
was planned, in order, **including plans that were approved and never
finished**. That last set is hard to recover any other way, and it is
usually the interesting one.

If you are resuming and the handoff mentions a plan, read the plan before
starting work. The handoff tells you where things stand; the plan tells you
what the shape was meant to be.

## When the estate is unreachable

Say so plainly and put the plan in the conversation so it can be pasted
somewhere durable. A plan believed filed and not filed is worse than one
you knew to copy by hand.
