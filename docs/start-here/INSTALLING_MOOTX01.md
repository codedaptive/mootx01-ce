---
title: "Installing MOOTx01"
subtitle: "What install does, how the resident daemon works, and how to verify your setup"
author: "MOOTx01 maintainers"
date: "2026-06-07"
---

> This guide covers `mootx01 install` on **macOS, Linux, and Windows**. The detailed walkthrough
> below is written for macOS, the most full-featured path; the **[Linux and Windows](#linux-and-windows)**
> section near the end covers what differs on those platforms. Read this before filing a bug —
> most first-run questions are answered here.

## Before you begin

- One of: **macOS 15+** (Swift build), **Linux** x86_64/arm64, or **Windows** x86_64 (both Rust builds) — all host a local estate; see [Linux and Windows](#linux-and-windows) for those paths
- At least one supported AI client installed: **Claude Desktop**, **Claude Code**,
  **Cursor**, **Cline**, or **Continue**
- The `mootx01` binary built or downloaded from the release archive and
  placed somewhere on your filesystem

---

## What `mootx01 install` does

Running `mootx01 install` performs four things, in order:

1. **Copies the binary to a stable location.** The `mootx01` binary is placed at
   `~/.mootx01/bin/mootx01` and a convenience symlink is created at
   `~/.local/bin/mootx01`. After this, the binary's location does not change
   when you update, so client configs do not need to be rewritten.

2. **Wires your AI clients.** The installer detects which supported clients are
   installed on your machine and writes an MCP server entry into each client's
   config. Clients that aren't installed are skipped without error. See
   [How clients connect](#how-clients-connect) below for what entry each client
   receives.

3. **Starts the resident daemon.** The daemon is registered as a background
   service under `com.mootx01.daemon`. It starts immediately and restarts at
   login if it exits. See [The resident daemon](#the-resident-daemon) below.

4. **Starts the management console.** `moot-mgr` is registered as a separate
   background service under `com.mootx01.mgr`. It runs a local dashboard at
   `http://127.0.0.1:4200` where you can observe what the daemon is doing.
   This requires the `moot-mgr` binary to be present alongside `mootx01` in
   the release archive — if you built only `mootx01`, the console step is
   skipped with a note.

At the end, run `mootx01 status` to confirm everything came up.

---

## The resident daemon

The resident daemon is the part of MOOTx01 that runs continuously in the
background. Think of it as the part that keeps your memory estate live and
running maintenance — the "dreaming" work that computes patterns, updates
connections, and prepares recall for the questions you'll ask tomorrow.

It listens on `http://127.0.0.1:4242` (loopback only — nothing leaves your
machine). Supported AI clients are wired to this address so they all share
the same running daemon rather than each spawning their own instance.

**Why this matters:** when you have Claude Code open in one project and
Cursor open in another, both are talking to the same estate. The memory
you add in one session is visible in the other immediately. The background
work runs once, not once per client.

The daemon enforces a single-writer rule: if you try to start a second
resident daemon pointing at the same estate, the second one exits and logs
a message rather than corrupting your data.

---

## How clients connect

The installer uses a different connection strategy per client based on
what each client's config format supports:

| Client | Transport | What's written |
|---|---|---|
| **Claude Code** | HTTP | `http://127.0.0.1:4242` wired as an HTTP MCP server entry |
| **Cursor** | HTTP | Same daemon URL |
| **Cline** | HTTP | Same daemon URL |
| **Continue** | HTTP | Same daemon URL (YAML format: `streamable-http`) |
| **Claude Desktop** | stdio | Spawns a local `mootx01` process; does not share the resident daemon |

**Claude Desktop is the exception.** Its config format does not support
connecting directly to a local HTTP MCP server without a bridge tool. The
installer uses the stdio path for it instead, which is reliable but means
Claude Desktop spawns its own short-lived MCP instance per conversation.
That instance has access to your estate but does not run the background
maintenance work. If you want continuous maintenance, run Claude Code, Cursor,
Cline, or Continue alongside — the daemon runs as long as those clients
are active.

If you use Claude Code and want the MCP entry scoped to a single project
rather than your global config, pass `--location local` to the installer.
The entry lands in `.mcp.json` in the current directory instead of
`~/.claude.json`.

---

## Install flags

Two flags let you skip parts of the install:

**`--no-daemon`** — skips registering the resident daemon service. The
installer still wires your clients, but they will connect over stdio
(each spawning its own instance) rather than sharing the resident daemon.
Use this if you want to manage the daemon lifecycle yourself or are
installing in an environment where background services are not appropriate.

**`--no-manager`** — skips registering the `moot-mgr` management console.
The daemon still runs; you just won't have the dashboard. The monitoring
commands (`moot-mgr monitoring on|off`) still work when the console is
running separately via `moot-mgr serve`.

**`-y` / `--yes`** — skips the interactive client picker and installs into
all detected clients automatically. Useful for scripted installs.

---

## Turning on monitoring

The management console (`moot-mgr`) observes the running daemon. By default,
detailed monitoring is **off** — the daemon records only basic health data,
which keeps overhead low.

To turn monitoring on:

```
moot-mgr monitoring on
```

To turn it off:

```
moot-mgr monitoring off
```

To check the current state:

```
moot-mgr monitoring status
```

The on/off switch takes effect on the running daemon immediately — no restart
required. When monitoring is on, the daemon's activity (including its
background work) appears in the dashboard at `http://127.0.0.1:4200`.

Monitoring state is stored in the management console's own database, not in
your estate. Turning it off does not affect your memory data.

---

## Verifying your setup

After install, run:

```
mootx01 status
```

This reports whether the estate is present, the daemon is running, and
the MCP endpoint is reachable.

To see the management console's view of the daemon:

```
moot-mgr status
```

Or open `http://127.0.0.1:4200` in a browser (when monitoring is on, this
shows live activity).

---

## Linux and Windows

MOOTx01 runs a full local estate on Linux and Windows too: the **Rust** build of `mootx01` hosts
the same MCP server as the Swift build on macOS (CI smoke-tests `mootx01 serve` on Linux). The flow
mirrors the macOS walkthrough above — only the install command, the binary set, and the
background-service mechanism differ.

**Install the binary.**

- *Linux:* `curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/main/install.sh | sh`
  downloads the Linux `mootx01`, places it at `~/.mootx01/bin/mootx01`, and symlinks
  `~/.local/bin/mootx01` — the same layout as macOS.
- *Windows:* run the PowerShell installer:
  `iex "& { $(irm https://raw.githubusercontent.com/codedaptive/mootx01-ce/main/install.ps1) }"`.
  Note: on Windows `install.ps1` both downloads the binary **and** wires clients over **stdio**
  (each spawns its own instance — no shared daemon). To get the resident HTTP daemon shared across
  clients, run `mootx01 install` afterward — it registers the Task Scheduler service and rewires
  clients to the daemon.

**Wire your AI clients.** `mootx01 install` detects and wires the same supported clients as on
macOS — the Rust CLI writes the identical MCP entries (Claude Desktop still uses the stdio path).
On Linux/macOS the download script tells you to run this next; on Windows it's the step that turns
the stdio install into the resident-daemon install.

**Background service** — registered automatically by `mootx01 install`, with no admin elevation:

- *Linux:* a per-user **systemd** unit at `~/.config/systemd/user/mootx01.service`, enabled via
  `systemctl --user enable --now` with `loginctl enable-linger` so the daemon runs without an open
  login session. A `mootx01-mgr.service` is added when a `moot-mgr` binary sits beside `mootx01`;
  the Linux x86_64/arm64 archives include `moot-mgr`, so the mgr service registers automatically.
  On hosts without systemd, the installer prints the unit text and manual start instructions
  instead (sysvinit/openrc are not auto-registered in v1).
- *Windows:* a per-user **Task Scheduler** logon task named `mootx01`, created with
  `schtasks /SC ONLOGON` and started immediately. A `mootx01-mgr` task is registered alongside it,
  since the Windows archive ships `moot-mgr.exe` beside `mootx01`.

**The dashboard.** The macOS `moot-mgr` is a SwiftUI app; on **Linux and Windows** `moot-mgr` is a
**headless** server (the Rust build) that serves the same web dashboard at `http://127.0.0.1:4200`.
It ships in the Linux x86_64/arm64 and Windows release archives, so `mootx01 install` registers its
service automatically on every platform. Its admin control channel is a Unix-domain socket on
Linux/macOS and a named pipe on Windows — both owner-only, never on the network.

**Verify** the same way everywhere:

```
mootx01 status
```

plus `http://127.0.0.1:4200` when the manager is running. Everything stays on loopback
(`127.0.0.1`) — nothing leaves your machine.

---

## Edge cases

**Only one resident daemon per estate.** If you run `mootx01 serve` manually
while the installed daemon is already running, the second process will detect
the first and exit rather than starting. The log message says which PID holds
the estate. Stop the existing daemon (`launchctl bootout gui/$(id -u)/com.mootx01.daemon`)
before starting a manual instance.

**The binary is copied, not run in place.** Client configs point at
`~/.mootx01/bin/mootx01`, not at wherever you ran the installer from.
If you move or delete the original binary after installing, clients are
unaffected. If you want to update the binary, re-run `mootx01 install` —
the existing client configs are updated in place, not duplicated.

**`~/.local/bin` not on PATH.** The installer creates a symlink at
`~/.local/bin/mootx01` so you can run `mootx01` by name in a shell.
If this directory isn't on your PATH, you'll see a note at the end of
install. The MCP clients use the absolute path from their configs and are
unaffected — only shell invocations of `mootx01` by name require the PATH
update. Add it with:
```
export PATH="$HOME/.local/bin:$PATH"
```

**Reinstalling is safe.** Re-running `mootx01 install` replaces the binary,
rewrites the client entries in place, and restarts both services. It does not
create duplicates or touch your estate data.

**The daemon runs at login.** After the first install, the daemon starts
automatically when you log in to macOS. You do not need to start it manually.
If it stops for any reason (crash, explicit stop), launchd restarts it.

---

## Environment knobs

These environment variables let you override daemon behavior when running
`mootx01 serve` manually. The installed daemon has them pre-set via the
launchd service definition — you do not need to set them yourself for the
normal installed case.

| Variable | Default | What it controls |
|---|---|---|
| `MOOTX01_HTTP_PORT` | `4242` | Loopback port the daemon listens on |
| `MOOTX01_HTTP_MAX_BODY_BYTES` | `4194304` (4 MiB) | Maximum MCP request body the daemon accepts |
| `MOOTX01_BRAIN_TICK_MS` | `5000` | How often the background maintenance loop (the autonomic governor) samples, in milliseconds |
| `MOOTX01_MONITORING_POLL_MS` | `5000` | How often the daemon checks whether monitoring is enabled |

Setting `MOOTX01_HTTP_PORT` switches `mootx01 serve` into resident HTTP mode.
Without it, `mootx01 serve` runs over stdio (the per-client ephemeral mode).

---

## Uninstalling

```
mootx01 uninstall
```

This removes the MCP entries from all client configs, removes the binaries from
`~/.mootx01/bin/` and the symlinks from `~/.local/bin/`, and removes the background service for
your platform:

- **macOS** — the launchd services (`com.mootx01.daemon`, `com.mootx01.mgr`)
- **Linux** — the systemd-user units (`mootx01.service`, and `mootx01-mgr.service` if it was installed)
- **Windows** — the Task Scheduler logon task `mootx01` (and `mootx01-mgr` only if it was installed)

Your estate data is **not** deleted — your memory is preserved. It lives at:

- **macOS** — `~/Library/Application Support/com.mootx01.ce/`
- **Linux** — `~/.local/share/mootx01/` (or `$XDG_DATA_HOME/mootx01/`)
- **Windows** — `%LOCALAPPDATA%\MOOTx01\`

Delete that directory manually if you want a complete removal.
