# Claude Code MOOTx01 Adapter

Claude Code reads `CLAUDE.md` project instructions and `.claude/rules/*.md`
rules. It can also use skills, slash commands, and lifecycle hooks. This
adapter covers all six surfaces:

- `CLAUDE.md` - always-on project instruction block.
- `.claude/rules/mootx01-memory.md` - modular always-on rule.
- `.claude/skills/mootx01-memory/SKILL.md` - task-specific skill.
- `.claude/commands/mootx01-start.md` - optional slash command prompt.
- `.claude/hooks/moot_hooks.py` - hook script (context meter, compaction
  recovery, writeback check).
- `.claude/settings.json` - hook wiring.

Copy the contents of this directory into a repository root or user-level
Claude configuration location. Keep only the surfaces you want active.

**Merging:** if the project already has a `.claude/settings.json`, merge the
`"hooks"` block from this adapter into it instead of replacing the file.
Everything else installs as new files.

## Try It

Install, restart Claude Code in the project, and ask:

```text
Where were we?
```

Claude should orient itself from MOOTx01 — journal, estate status, recent
memories — and answer with continuity you did not have to paste in. That is
the adapter working.

## What The Hooks Do

The instruction files teach Claude *when* to reach for MOOTx01. The hooks
make memory behavior happen at the moments instruction files cannot see:

1. **Session start** (`SessionStart`) — injects a one-paragraph orientation
   reminder on startup and resume, so every session begins memory-aware.
2. **Context meter** (`UserPromptSubmit`) — estimates how full the context
   window is from the session transcript and injects escalating writeback
   reminders as it crosses 65%, 75%, 85%, and 95%. Each threshold fires once
   per session. At 95% the reminder is urgent: file memories and a journal
   entry before anything else, because compaction is imminent.
3. **Compaction recovery** (`PreCompact` + `SessionStart` on compact) — when
   Claude Code compacts the conversation, the next turn begins with an
   injected instruction to recover continuity from the MOOTx01 journal and
   re-verify anything it is about to rely on. The context meter re-arms so
   the thresholds work again in the post-compaction context.
4. **Writeback check** (`Stop`) — when a session used MOOTx01 tools but
   never wrote anything durable back, Claude is asked — once per session,
   at the moment it tries to finish — to file memories and a journal entry
   or state plainly that nothing durable happened.

## Hook Safety Properties

The hook script is deliberately auditable:

- Python standard library only; no third-party dependencies.
- No network access.
- Reads only the hook JSON Claude Code provides on stdin and the session
  transcript path inside it.
- Writes only a small threshold-state file in the system temp directory.
- Every failure path exits 0 silently — a broken hook never breaks a session.

Read `moot_hooks.py` before enabling it. It is short on purpose.

## Configuration

- `MOOTX01_CONTEXT_WINDOW` — the context meter assumes a 200,000-token
  window. Export this environment variable to match your model if it
  differs (for example `export MOOTX01_CONTEXT_WINDOW=500000`).
- The context percentages are estimates derived from the transcript's token
  usage records. Treat them as a fuel gauge, not a lab instrument.
