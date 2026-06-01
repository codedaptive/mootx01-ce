# MOOTx01 installer

This directory contains the **LAUNCH-05** installer: a Swift wrapper
binary (`mootx01-mcp`) and a bash installer (`install.sh`) that
together get a non-technical user to a reachable MOOT through a
client they already use. macOS only for the Monday cut.

## What it does

`install.sh`:

1. Builds `mootx01-mcp` in release mode from `Installer/Package.swift`.
2. Copies the binary to `~/.local/share/MOOTx01/bin/mootx01-mcp`.
3. Merges an `mcpServers["mootx01"]` entry into every supported
   client's configuration file:
   - **Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json`
   - **Claude Code** — `~/.claude.json`
   - **Cursor** — `~/.cursor/mcp.json`
   - **Cline** — `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json`
   - **Continue** — `~/.continue/mcpServers/mootx01.yaml`
4. Reports that the client(s) should be restarted.

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
bash Installer/install.sh
```

Then restart Claude Desktop / Claude Code / your client of choice.
You will see "mootx01" in the client's MCP servers list and can
use any ARIA verb tool against the MOOT.

## Removing it

```bash
bash Installer/uninstall.sh           # remove binary + config entries
bash Installer/uninstall.sh --purge   # also delete the MOOT data dir
```

The default refuses to delete the data directory — the user's
substrate database is their data and is not the installer's to
discard.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `MOOTX01_INSTALL_PREFIX` | `~/.local/share/MOOTx01` | Where the binary is placed. |
| `MOOTX01_DATA_DIR` | `~/Library/Application Support/MOOTx01` | Where the estate database lives. Read at `mootx01-mcp` launch. |
| `MOOTX01_DRY_RUN` | `0` | When `1`, the installer prints every command it would run but does not touch the filesystem. Used by `tests/test_install_sh.sh`. |

## Testing

Two test legs cover the installer:

```bash
# Path math, config-entry shape (Swift / swift-testing)
swift test --package-path Installer

# install.sh control flow (bash, dry-run against a sandbox HOME)
bash Installer/Tests/test_install_sh.sh
```

Both run clean on macOS 15 with the Swift toolchain installed.

## Layout

```
Installer/
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
│   │   └── ClientConfigTests.swift
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

- It does not modify `ARIA_MCP/Sources/aria-mcp/AriaMCPMain.swift`.
  The bare `aria-mcp` executable is the LAUNCH-04 in-memory spike
  and is preserved as-is; `mootx01-mcp` is a separate binary that
  consumes the public `AriaMCP` library on top of a persistent
  backend.
- It does not auto-update or call out to the network at install
  time. The MDCC default ships inside the kits per the LAUNCH_PLAN
  EideticLib policy — installation is a local-only act.
- It does not configure remote clients or non-macOS clients on
  Monday. Cross-platform support is fast-follow.
