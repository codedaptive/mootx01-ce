# Claude Code MOOTx01 Adapter

Claude Code reads `CLAUDE.md` project instructions and `.claude/rules/*.md`
rules. It can also use skills and slash commands. This adapter includes all
four surfaces:

- `CLAUDE.md` - always-on project instruction block.
- `.claude/rules/mootx01-memory.md` - modular always-on rule.
- `.claude/skills/mootx01-memory/SKILL.md` - task-specific skill.
- `.claude/commands/mootx01-start.md` - optional slash command prompt.

Copy the contents of this directory into a repository root or user-level
Claude configuration location. Keep only the surfaces you want active.

