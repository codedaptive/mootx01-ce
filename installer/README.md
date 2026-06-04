# MOOTx01 installer

This directory contains the **LAUNCH-05** installer: a Swift wrapper
binary (`mootx01-mcp`) and a bash installer (`install.sh`) that
together get a non-technical user to a reachable MOOT through a
client they already use. macOS only for the Monday cut.

## What it does

`install.sh`:

1. Builds `mootx01-mcp` in release mode from `installer/Package.swift`.
2. Copies the binary to `~/.local/share/MOOTx01/bin/mootx01-mcp`.
3. For each supported client, **detects** whether it is installed before
   touching its config. Clients that are not found are skipped, and a
   summary is printed at the end (`"Skipped: X. Install them and re-run to wire."`).
4. Merges an `mcpServers["mootx01"]` entry into each **detected** client:

   | Client | Config file | Detection probe |
   |---|---|---|
   | **Claude Desktop** | `~/Library/Application Support/Claude/claude_desktop_config.json` | `/Applications/Claude.app` |
   | **Claude Code** | `~/.claude.json` | `command -v claude` (CLI on PATH) |
   | **Cursor** | `~/.cursor/mcp.json` | `/Applications/Cursor.app` |
   | **Cline** | `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` | `~/.vscode/extensions/saoudrizwan.claude-dev-*` |
   | **Continue** | `~/.continue/mcpServers/mootx01.yaml` | `~/.continue/` directory |

5. **Pre-approves ARIA tools** in `~/.claude/settings.json` (or
   `./.claude/settings.json` when `--local` is used) by writing all
   53 ARIA tool names into `permissions.allow`. This prevents
   per-tool approval prompts when Claude Code or Claude Desktop first
   call ARIA tools. The merge is additive — existing entries in the
   file are preserved.
6. Reports that the detected client(s) should be restarted.

The merge is idempotent: re-running the installer replaces the
existing `"mootx01"` entry rather than appending duplicates, and
preserves every other key in the user's config files.

`mootx01-mcp` itself does first-run: when launched by a client and
the estate database is absent under
`~/Library/Application Support/MOOTx01/estate.sqlite`, it calls
`LocusKit.Estate.create` to bootstrap a fresh MOOT on the
MDCC default and then opens the estate and serves the
JSON-RPC stdio loop. There is no post-install daemon and nothing
for the user to run by hand.

## Running it

```bash
bash installer/install.sh
```

Then restart Claude Desktop / Claude Code / your client of choice.
You will see "mootx01" in the client's MCP servers list and can
use any ARIA verb tool against the MOOT.

### Project-local install (Claude Code only)

Claude Code supports a project-scoped MCP config at `.mcp.json` in the
project root. Use `--local` to wire the server there instead of the
global `~/.claude.json`:

```bash
cd /path/to/your/project
bash installer/install.sh --local
```

This writes the `mcpServers["mootx01"]` entry into `./.mcp.json`. Only
Claude Code is affected — all other detected clients are still wired to
their global config files. The flag is idempotent: re-running it
replaces the existing entry rather than appending duplicates.

## Removing it

```bash
bash installer/uninstall.sh           # remove binary + config entries
bash installer/uninstall.sh --purge   # also delete the MOOT data dir
bash installer/uninstall.sh --local   # remove entry from ./.mcp.json (Claude Code only)
```

Pass `--local` when you installed with `--local`; it removes the entry
from `./.mcp.json` in the current directory instead of from
`~/.claude.json`. `--local` and `--purge` can be combined.

The default refuses to delete the data directory — the user's
substrate database is their data and is not the installer's to
discard.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `MOOTX01_INSTALL_PREFIX` | `~/.local/share/MOOTx01` | Where the binary is placed. |
| `MOOTX01_DATA_DIR` | `~/Library/Application Support/MOOTx01` | Where the estate database lives. Read at `mootx01-mcp` launch. |
| `MOOTX01_DRY_RUN` | `0` | When `1`, the installer prints every command it would run but does not touch the filesystem. Used by `tests/test_install_sh.sh`. |
| `MOOTX01_DETECT_ROOT` | `(empty)` | Test-only. When set, prepended to absolute app-bundle detect paths so tests can sandbox `/Applications` checks without touching the real filesystem. |

## Auto-allow permissions

After wiring client configs, the installer merges the full list of
ARIA tool names into the Claude Code settings file under
`permissions.allow`. This removes the per-tool approval prompt that
Claude Code and Claude Desktop show on first use of a new MCP tool.

**Affected settings file:**

| Install mode | Settings file |
|---|---|
| Default (global) | `~/.claude/settings.json` |
| With `--local` | `./.claude/settings.json` in the current directory |

**Approved tools:** all 53 tools the `mootx01` MCP server exposes —
lexicon tools (drawer, tunnel, kgFact, diaryEntry, proposal,
association, learnedReference), the federation tool
(`moot_cross_estate_recall`), CognitionKit recipe tools, reasoning-lens
and analytics tools, and VaultKit tools.

**The merge is additive.** Any existing entries in `permissions.allow`
(including entries for other MCP servers or built-in Claude Code tools)
are preserved. Re-running the installer never duplicates entries.

**To opt out**, pass `--no-permissions`:

```bash
bash installer/install.sh --no-permissions
```

With this flag the `~/.claude/settings.json` file is not touched.
Users will see per-tool approval prompts for each ARIA tool on first
use.

**Note:** Only Claude Code and Claude Desktop use `~/.claude/settings.json`
for tool permissions. Cursor, Cline, and Continue are wired for MCP server
discovery but do not share this settings file; their tool-approval UIs are
independent.

**Prerequisites:** The permissions step requires `python3` on your PATH.
On a clean macOS system without developer tools it may not be present.
If `python3` is not found, the installer exits before writing any client
configs. Install the Xcode Command Line Tools (`xcode-select --install`)
or Homebrew's Python, then re-run.

**If `settings.json` contains invalid JSON:** The installer refuses to
touch the file and prints an error. All client MCP configs are still
wired normally. Fix the JSON (or delete the file — it will be recreated
on next use) and re-run `bash installer/install.sh` to add the ARIA
permissions.

**Combining flags:** `--local` and `--no-permissions` can be combined.
The result is project-scoped MCP wiring (`.mcp.json`) with no permissions
written anywhere. Per-tool approval prompts will appear for each ARIA
tool on first use in that project.

## Testing

Two test legs cover the installer:

```bash
# Path math, config-entry shape, detection logic (Swift / XCTest + Swift Testing)
swift test --package-path installer

# install.sh control flow (bash, dry-run against a sandbox HOME)
bash installer/Tests/test_install_sh.sh
```

Both run clean on macOS 15 with the Swift toolchain installed.

## Layout

```
installer/
├── Package.swift                          # Swift package
├── Sources/
│   ├── MootInstallerCore/                 # path + config helpers
│   │   ├── Paths.swift
│   │   └── ClientConfig.swift
│   └── mootx01-mcp/                       # the stdio MCP executable
│       └── MootMCPMain.swift
├── Tests/
│   ├── MootInstallerCoreTests/
│   │   ├── PathsTests.swift
│   │   ├── ClientConfigTests.swift
│   │   └── ClientDetectionTests.swift
│   └── test_install_sh.sh                 # bash smoke test
├── install.sh                             # the installer
├── uninstall.sh                           # the reverse
├── templates/                             # per-client snippets
│   ├── claude_desktop.json
│   ├── claude_code.json
│   ├── cursor.json
│   ├── cline.json
│   └── continue.yaml
└── README.md
```

## What it deliberately does not do

- It does not modify `apps/ARIA_MCP/Sources/aria-mcp/AriaMCPMain.swift`.
  The bare `aria-mcp` executable is the LAUNCH-04 in-memory spike
  and is preserved as-is; `mootx01-mcp` is a separate binary that
  consumes the public `AriaMCP` library on top of a persistent
  backend.
- It does not auto-update or call out to the network at install
  time. The MDCC default ships inside the kits per the LAUNCH_PLAN
  EideticLib policy — installation is a local-only act.
- It does not configure remote clients or non-macOS clients on
  Monday. Cross-platform support is fast-follow.
