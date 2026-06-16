# mootx01 — the unified CLI

This directory builds **`mootx01`**, the single command-line binary an end user
installs. One tool, three roles:

- **`mootx01 install`** — detect the user's installed MCP clients and wire each
  one to the resident daemon; on macOS, register the `moot-mgr` console as a
  launchd background service. Idempotent — re-running replaces the `mootx01`
  entry and preserves every other key in a client's config.
- **`mootx01 serve`** — the resident MCP daemon (HTTP on `127.0.0.1:4242` by
  default) that owns the single-writer estate and runs background maintenance.
- **`mootx01 proxy --http <url>`** — a stdio↔HTTP bridge for clients whose config
  can't take a raw HTTP URL (Claude Desktop), so they route through the one
  resident daemon and share its single-writer guarantee and telemetry.

Shipped cross-platform: macOS (Apple Silicon), Linux (x86_64 / aarch64), and
Windows (x86_64). The Swift build targets macOS 26+; the Rust port is under
`rust/`.

## Installing

End users don't build this directly — the prebuilt binary is installed by the
one-liner. Full guide:
[`docs/start-here/INSTALLING_MOOTX01.md`](../../docs/start-here/INSTALLING_MOOTX01.md).

```bash
curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.sh | sh
mootx01 install        # wire it into your MCP clients (interactive)
```

The binary lands in `~/.mootx01/bin`. Re-run to upgrade; uninstall with
`… | sh -s -- --uninstall`.

## Client wiring

`mootx01 install` writes per-client config
(see `Sources/MootInstallerCore/ClientConfig.swift` and ADR-LOOPBACKHTTP-001):

| Client | How it's wired |
|---|---|
| Claude Code, Cursor, Cline, Continue | local HTTP MCP entry → resident daemon (`http://127.0.0.1:4242`) |
| Claude Desktop | `mootx01 proxy --http` bridge → the same resident daemon |

Every wired client shares the one resident daemon; none spawns its own estate
writer.

## Removing it

`… | sh -s -- --uninstall` removes the binary and the client config entries. By
design it does **not** delete your estate database — your substrate data is
yours, not the installer's to discard.
