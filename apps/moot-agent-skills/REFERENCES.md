# Public Format References

This harness kit is a draft starting point. It follows the documented public
configuration surfaces below as of 2026-06-12.

## Claude Code

- `CLAUDE.md` project instructions.
- `.claude/rules/*.md` modular rules.
- `.claude/skills/*/SKILL.md` skills.
- `.claude/commands/*.md` slash command prompts.

Reference: https://code.claude.com/docs/en/memory

## Codex

- `AGENTS.md` project instructions.
- `.agents/skills/*/SKILL.md` Agent Skills.
- Optional `agents/openai.yaml` skill metadata.
- Optional `.codex/hooks.json` lifecycle hooks.

References:

- https://developers.openai.com/codex/skills
- https://developers.openai.com/codex/guides/agents-md
- https://developers.openai.com/codex/hooks

## Cursor

- `.cursor/rules/*.mdc` project rules.
- `.cursorrules` legacy fallback.

Reference: https://cursor.com/docs

## Cline

- `.clinerules/*.md` workspace rules.
- Cline also detects `.cursorrules`, `.windsurfrules`, and `AGENTS.md`.

Reference: https://docs.cline.bot/customization/cline-rules

## Roo Code

- `.roo/rules/*.md` workspace rules.
- `.roorules` fallback.

Reference: https://roocodeinc.github.io/Roo-Code/features/custom-instructions/

## Devin Desktop / Windsurf

- `.devin/rules/*.md` preferred workspace rules.
- `.windsurf/rules/*.md` legacy fallback.
- `.windsurfrules` legacy single-file fallback.
- `AGENTS.md` can also be inferred as rules.

Reference: https://docs.devin.ai/desktop/cascade/memories

## Continue

- `.continue/rules/*.md` local workspace rules with YAML frontmatter.

Reference: https://docs.continue.dev/customize/deep-dives/rules

## Generic / OpenAI Agents

Any harness that supports custom system/developer instructions can use the
prompt blocks under `generic/` or `openai-agents/`, provided MOOTx01 tools are
registered through MCP or the harness's native tool API.

