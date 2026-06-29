# MOOTx01 CE Install Surface

This document is the install fact sheet for humans and AI assistants.

Use it as the source of truth for what a product install is expected to do.

> **Machine-readable companion:** `docs/start-here/AI_INSTALL_MANIFEST.json` carries these same
> facts as structured JSON for an AI agent to parse. Keep the two in sync — this document is
> authoritative for humans.

## Default Local Addresses

| Component | Purpose | Default |
|---|---|---|
| `mootx01` resident daemon | ARIA/MCP endpoint for AI clients | `http://127.0.0.1:4242` |
| `moot-mgr` | dashboard/read API/management surface | `http://127.0.0.1:4200` |

Both should bind to `127.0.0.1` by default.

Do not use `7077` unless current code explicitly says so. It was a retired or stale port in older text.

## Product Install Goal

A product install should leave the user with:

- a callable `mootx01` command,
- a local MOOTx01 estate or the ability to create one,
- supported AI clients wired to the local MOOTx01 MCP surface,
- a resident daemon when supported,
- `moot-mgr` dashboard when available,
- a clear verification result.

## User-Facing Install Flow

A complete install is **two phases**. Phase 1 installs the runtime and gives the AI the
tools; Phase 2 makes the AI actually *use* them. Stopping after Phase 1 leaves a user whose
tools are installed but whose AI does not instinctively reach for them.

### Phase 1 — Install the runtime

1. Download or build the product binary.
2. Run `mootx01 install`.
3. Choose which AI clients to wire.
4. Start or register the resident daemon if supported.
5. Start or register `moot-mgr` if supported.
6. Verify with `mootx01 status` (and the session-start tool checks under Verification below).
7. Restart AI clients if needed.

### Phase 2 — Activate MOOTx01 agent behavior

8. Install the matching harness adapter from `apps/moot-agent-skills/<client>/` into the
   client's rules/skills config — **only after** Phase 1 verifies. This is what teaches the
   AI to reach for MOOTx01 automatically (memory, recall, facts, links, grounded synthesis)
   instead of waiting to be told. **Merge, don't overwrite** — append the MOOTx01 blocks to
   any existing config rather than replacing it, and **get the user's explicit approval before
   changing an existing instruction file.** Keep `apps/moot-agent-skills/shared/` nearby as
   reference; do not load all of it into context.
9. Confirm with the three prompts in `apps/moot-agent-skills/README.md`.

## Platform Matrix

| Platform | Product Route | Notes |
|---|---|---|
| macOS | Swift product install | Full local product path; launchd may be used for background services. |
| Linux | Rust product route where provided | Use the Rust/Linux release lane. Service behavior may use user-level systemd when implemented. |
| Windows | Rust/PowerShell route where provided | Use the repository's Windows install script and current Rust binary if available. |
| Source build | Developer route | Use package-specific build instructions; do not assume product install behavior. |

AI assistants should check the current repository scripts and release notes before installing.

## Expected Commands

Normal source install from the checked-out repository:

    # macOS 26+
    swift build -c release --package-path apps/aria-mcp-server

    # PC/Linux
    cd apps/aria-mcp-server/rust && cargo build --release

    mootx01 install

Do not pipe a mutable remote installer into a shell. Use prebuilt binaries only when they are pinned to a release artifact and authenticated before any installer code runs.

Status check:

    mootx01 status

Dashboard check:

    moot-mgr status

Open dashboard:

    http://127.0.0.1:4200

Manual resident daemon start, when instructed by the repo or installer:

    mootx01 serve --http 4242

Do not run a manual daemon if a resident daemon is already running for the same estate unless the docs say it is safe. MOOTx01 is designed around a single-writer rule for an estate.

## What `mootx01 install` May Touch

Depending on platform and options, install may touch:

- the MOOTx01 binary install location,
- shell PATH guidance,
- AI client MCP configuration,
- local MOOTx01 data directory,
- background service registration,
- `moot-mgr` service registration,
- local dashboard files or static assets.

Before changing client configs, an AI assistant should tell the user which clients will be configured.

## AI Client Wiring

Supported clients may be wired in one of two ways.

| Transport | Meaning |
|---|---|
| HTTP MCP | Client connects to resident daemon, usually `http://127.0.0.1:4242`. |
| stdio MCP | Client starts a local `mootx01` process directly. |

Prefer the installer's supported path. Do not hand-edit client configs unless the installer fails or the user asks.

After wiring, restart the AI client.

## Verification Checklist

A successful install should satisfy most or all of these checks.

Binary/status:

    mootx01 status

Expected result: reports daemon, estate, or client status, or gives clear next steps.

Manager status:

    moot-mgr status

Expected result: reports dashboard or manager status if installed.

Dashboard:

    http://127.0.0.1:4200

Expected result: dashboard loads if `moot-mgr` is running.

AI client tool check:

    moot_estate_ping

Expected result: returns a live estate or server response.

Optional memory smoke test:

1. File a harmless memory.
2. Search for the same phrase.
3. Confirm the memory is found.

Suggested test memory:

    MOOTx01 install verification memory. If this is found later, recall is working.

## Environment Variables

Common install or runtime environment knobs may include:

| Variable | Purpose |
|---|---|
| `MOOTX01_HTTP_PORT` | Resident daemon HTTP port, default `4242`. |
| `MOOTX01_DATA_DIR` | Data directory override. |
| `MOOTX01_HTTP_MAX_BODY_BYTES` | Maximum HTTP MCP request body. |
| `MOOTX01_BRAIN_TICK_MS` | Background maintenance cadence. |
| `MOOTX01_MONITORING_POLL_MS` | How often the daemon checks whether monitoring is enabled (default `5000`). |
| `MOOT_MGR_HTTP_PORT` | Dashboard/read API port, default `4200`. |

Use the current code and docs for exact platform support.

## Uninstall Or Disable

Use the repository's current uninstall route.

Typical shape:

    mootx01 uninstall

Do not run a remote installer script to uninstall unless it is pinned to an authenticated release artifact and verified before execution.

Before uninstalling, tell the user whether the command removes only binaries, configs, and services, or whether it also removes local estate data.

Do not delete memory data unless the user explicitly asks.

## Common Failure Modes

### Port already in use

Expected defaults:

- daemon: `4242`
- dashboard: `4200`

Find the owner before taking action.

Do not kill unknown processes without user approval.

### Client config written but tools missing

Restart the AI client.

Then inspect the client config.

### Dashboard unavailable but daemon works

The product can still function through MCP even if `moot-mgr` is not running.

### Daemon unavailable but binary installed

Run:

    mootx01 status

Then follow the platform's service-start instructions.

## AI Assistant Rules

When using this file:

- Explain before installing.
- Verify after installing.
- Prefer repository scripts over invented commands.
- Prefer current code over stale prose.
- Keep all default services on loopback.
- Never promise cloud behavior.
- Never call installation complete without a status check.