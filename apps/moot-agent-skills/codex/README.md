# Codex MOOTx01 Adapter

Codex supports repository instructions through `AGENTS.md` and reusable
workflows through Agent Skills. This adapter includes:

- `AGENTS.md` - project-level instruction file.
- `.agents/skills/mootx01-memory/SKILL.md` - reusable Codex skill.
- `.agents/skills/mootx01-memory/agents/openai.yaml` - optional UI metadata.
- `.codex/hooks.json` - optional lifecycle hooks that remind the agent to
  orient from MOOTx01 at session start and to write back durable knowledge
  at stop.

The hook file is intentionally non-mutating: both hooks only print reminder
text, never touch files, and never call the network. Enable hooks only after
reviewing the commands and trust prompts in your Codex environment.

Notes on Codex hook behavior:

- The Stop hook emits JSON (`systemMessage`) because Codex ignores plain
  text on stdout for Stop events. SessionStart accepts plain stdout, which
  is injected as context.
- Depending on your Codex version, hooks may need to be enabled in
  `config.toml` (a top-level `hooks = "<path>/hooks.json"` entry and, on
  older experimental builds, `codex_hooks = true` under `[features]`).
- Some Codex versions have not honored repo-local `.codex/` hook config in
  interactive sessions (openai/codex issue #17532). If the hooks do not
  fire, configure them at the user level instead.

