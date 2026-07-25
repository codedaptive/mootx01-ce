# mootx01 — the unified CLI

This directory builds **`mootx01`**, the single command-line binary an end user
installs. One tool, three roles:

- **`mootx01 install`** — detect the user's installed MCP clients and wire each
  one to the resident daemon; on macOS, register the `moot-mgr` console as a
  launchd background service. `--no-daemon` instead writes direct stdio
  entries. Idempotent — re-running replaces the `mootx01` entry and preserves
  every other key in a client's config.
- **`mootx01 serve`** — a stdio MCP server by default. `--http <port>` or
  `MOOTX01_HTTP_PORT` selects the resident HTTP daemon that owns the
  single-writer estate and runs background maintenance.
- **`mootx01 proxy --http <url>`** — a stdio↔HTTP bridge for clients whose config
  can't take a raw HTTP URL (Claude Desktop), so they route through the one
  resident daemon and share its single-writer guarantee and telemetry.

Shipped cross-platform: macOS (Apple Silicon), Linux (x86_64 / aarch64), and
Windows (x86_64). The Swift build targets macOS 26+; the Rust port is under
`rust/`.

## Installing

End users should follow the source install path in the full guide:
[`docs/start-here/INSTALLING_MOOTX01.md`](../../docs/start-here/INSTALLING_MOOTX01.md).

```bash
# macOS 26+
swift build -c release --package-path apps/aria-mcp-server

# PC/Linux
cd apps/aria-mcp-server/rust && cargo build --release

mootx01 install        # wire it into your MCP clients (interactive)
```

Do not pipe a mutable remote installer into a shell. Use prebuilt binaries only
when they are pinned to a release artifact and authenticated before any installer
code runs.

## Client wiring

`mootx01 install` writes per-client config
(see `Sources/MootInstallerCore/ClientConfig.swift` and the loopback HTTP contract):

| Client | How it's wired |
|---|---|
| Claude Code, Cursor, Cline, Continue, Codex, and other HTTP-capable clients | local HTTP MCP entry → resident daemon (`http://127.0.0.1:4242`) |
| Claude Desktop | `mootx01 proxy --http` bridge → the same resident daemon |

That is the default shared-resident setup. For a tighter local transport, use:

```bash
mootx01 install --target codex --mode server --no-daemon --vault-off
```

The installer then writes a direct `mootx01 serve` command entry, clears
`MOOTX01_HTTP_PORT`, and does not register the resident service. Stop a
resident installed by an earlier run if the requirement is socket-free MCP
operation; a stdio server otherwise forwards to that live resident to preserve
the single-writer estate.

## Removing it

`sh ./install.sh --uninstall` from an authenticated checkout removes the binaries and `~/.mootx01`. It **leaves
your MCP-client config entries intact** — run `mootx01 uninstall` first if you
want those removed too. It does **not** touch your estate database; your
substrate data is yours, not the installer's to discard.
