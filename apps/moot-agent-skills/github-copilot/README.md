# MOOTx01 Memory — GitHub Copilot

Active long-term memory and a low-token reasoning substrate for GitHub Copilot.

## Install (personal — all projects)

```bash
mootx01 install
```

The installer wires the MCP server and drops the skill to `~/.agents/skills/mootx01-memory/SKILL.md`,
which Copilot discovers automatically.

## Install (project — checked in)

Copy the adapter files into your repository root:

```bash
cp -r .github/ /path/to/your/project/
```

Then commit `.github/copilot-instructions.md` and `.github/skills/mootx01-memory/SKILL.md`.

## How it works

- **`copilot-instructions.md`** — always-on context loaded by Copilot for every interaction in this repo.
- **`skills/mootx01-memory/SKILL.md`** — lazy-loaded skill activated when memory-related tasks are detected.
- **MCP server** — `mootx01 serve` exposes the full ARIA tool surface to Copilot.

## Documentation

https://mootx01.ai
