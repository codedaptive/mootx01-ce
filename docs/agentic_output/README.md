# Agentic Output

This directory is the designated holding area for output produced by AI / agentic
coding assistants while contributing to MOOTx01.

## The rule

If you use an AI agent (Claude Code, Codex, or similar) to work on this project,
**all of its documentation output and tracking artifacts must be confined to this
directory** — planning notes, analysis, impact/blast-radius reports, task lists,
completion summaries, and any other working record the agent produces.

Do **not** place agent working output anywhere else under `docs/`. The rest of the
`docs/` tree is the project's canonical, human-curated documentation; agent working
notes do not belong there.

## What happens to it

Maintainers periodically review the material here and fold the useful parts into the
real documentation. Treat this directory as a **staging area, not a permanent home**:
anything that belongs in the canonical docs will be migrated there by a maintainer;
the rest may be cleared.

## Why

Keeping agent output in one place keeps the canonical docs clean and reviewable,
makes AI-assisted contributions easy to audit, and gives maintainers a single place
to harvest from when updating the real documentation.

## Conventions

- Use descriptive filenames (e.g. `2026-06-15_topic_analysis.md`), and date-stamp
  where it helps a maintainer triage.
- One concern per file; keep working logs separate from proposed doc changes.
