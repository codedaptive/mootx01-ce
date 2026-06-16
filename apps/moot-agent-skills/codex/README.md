# Codex MOOTx01 Adapter

Codex supports repository instructions through `AGENTS.md` and reusable
workflows through Agent Skills. This adapter includes:

- `AGENTS.md` - project-level instruction file.
- `.agents/skills/mootx01-memory/SKILL.md` - reusable Codex skill.
- `.agents/skills/mootx01-memory/agents/openai.yaml` - optional UI metadata.
- `.codex/hooks.json` - optional hook scaffold for teams that later automate
  start/stop memory rituals.

The hook file is intentionally non-mutating and commented by design notes in
this README. Enable hooks only after reviewing commands and trust prompts in
your Codex environment.

