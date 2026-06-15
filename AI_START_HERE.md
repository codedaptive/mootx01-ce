<!-- File: AI_START_HERE.md -->

# AI Start Here: Explain and Install MOOTx01 CE

You are an AI assistant encountering the MOOTx01 CE repository for the first time.

A user has said something like:

> This looks cool. Can you explain it to me and install it for me?

Your job is to give the user an excellent first experience: explain MOOTx01 CE clearly, choose the right install path, run only appropriate commands, verify the install, and leave the user knowing what changed.

Use this document before improvising.

## Mission

Help the user:

1. Understand what MOOTx01 CE is.
2. Decide whether they want the product install or SDK/developer path.
3. Install it safely if they choose product install.
4. Verify that it works.
5. Understand how to use it next.

## Plain Explanation

Use this explanation when the user asks what MOOTx01 CE is:

MOOTx01 CE is a local memory layer for AI assistants. It gives AI tools a place to remember useful things across sessions without relying on a vendor cloud memory system by default. It runs on the user's machine, stores a local memory estate, and exposes that memory through ARIA, the interface language MOOTx01 uses for capture, recall, facts, links, journals, and estate status.

The short version:

- The AI still thinks in its normal context window.
- MOOTx01 gives it longer-lived memory.
- The memory belongs to the user.
- AI clients connect through MCP.
- Developers can also build on the underlying kits.

Do not describe MOOTx01 CE as only a vector database. It includes local storage, recall, graph relationships, audit/state handling, background maintenance, and a shared AI-facing interface.

## What Not To Promise

Do not promise:

- cloud sync,
- public hosting,
- production hardening beyond what the repo says,
- stable SDK surfaces unless current SDK docs say they are stable,
- network exposure beyond loopback,
- that every AI client supports every MCP transport,
- that beta behavior is final.

If asked about stability, say that CE beta should be treated as early-access software: usable, inspectable, and local-first, but still evolving.

## First Response To The User

Start with a short explanation and then ask only the required questions.

Good response shape:

MOOTx01 CE is a local memory layer for AI. It lets supported AI clients use a local memory estate through MCP, so useful project facts, decisions, notes, and recall can survive beyond one chat. I can install it for you, but first I need to check your platform and which AI client you want wired.

Ask:

1. What operating system are you on?
2. Which AI client do you want to use with it?
3. Do you want the normal product install, or are you evaluating the SDK/source?

Do not give the user a long architecture lecture before answering their actual install request.

## Product Or SDK

Use this decision table.

| User Intent | Route |
|---|---|
| "Install this so my AI can use it" | Product install |
| "Wire this into Claude, Codex, Cursor, Cline, Continue, or another MCP client" | Product install |
| "I want to build an app with MOOTx01" | SDK/developer path |
| "I want to understand the architecture" | Docs path |
| "I want to modify kits or run tests" | Source/developer path |

If the user is an end user, prefer product install.

If the user is a developer, explain both paths:

- Product path: install `mootx01`, run the resident service, wire AI clients.
- SDK path: use the packages/kits and examples as integration references.

## Known Default Local Addresses

Use these defaults unless current code or explicit user configuration says otherwise.

| Component | Default Address |
|---|---|
| MOOTx01 resident ARIA/MCP daemon | `http://127.0.0.1:4242` |
| moot-mgr dashboard/read API | `http://127.0.0.1:4200` |

Both are loopback addresses.

Do not use `7077` unless current code explicitly says to. Treat old `7077` references as stale or historical.

## Safety Rules

Follow these rules strictly:

- Do not use `sudo` unless current install docs explicitly require it.
- Do not expose MOOTx01 on a public network interface.
- Do not edit shell startup files without user approval.
- Do not rewrite AI client configs by hand unless the installer fails or the user asks.
- Do not delete local estate data unless the user explicitly asks.
- Do not kill processes blindly to free a port.
- Do not claim installation succeeded until you verify it.
- Do not keep running commands after the user asks you to stop.
- Do not make repo edits during an install unless the user asked to modify the repo.

## Install Flow

### 1. Identify Platform

Check the platform before choosing commands.

Unix-style check:

    uname -a

Windows check:

    $PSVersionTable
    [System.Environment]::OSVersion.VersionString

### 2. Use The Current Product Install Route

Use the current install instructions from the repository.

Typical Unix-style product install shape:

    curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/main/install.sh | sh
    mootx01 install

On Windows, use the repository's PowerShell installer if present.

Before running a remote install script, tell the user that the command downloads and runs the installer from the MOOTx01 CE repository.

### 3. Run The Installer

Run the product install command for the platform.

If `mootx01 install` asks which AI clients to configure, help the user choose.

If the user wants automatic configuration, use the installer's automatic option if documented.

### 4. Verify The Binary

Run:

    mootx01 status

If `mootx01` is not found, check whether the install location is on `PATH`.

Common local binary locations may include:

    ~/.mootx01/bin
    ~/.local/bin

Do not edit shell startup files without user approval.

### 5. Verify The Resident Daemon

Expected default daemon endpoint:

    http://127.0.0.1:4242

Use `mootx01 status` first.

If needed, check whether the port is listening.

Unix-style check:

    lsof -nP -iTCP:4242 -sTCP:LISTEN

Do not kill whatever owns the port without asking the user.

### 6. Verify The Dashboard

If `moot-mgr` is installed, run:

    moot-mgr status

Expected dashboard default:

    http://127.0.0.1:4200

If the dashboard does not load but the daemon works, explain that MOOTx01 can still be usable through MCP even if the dashboard is not running.

### 7. Verify AI Client Wiring

Restart the AI client after install.

Then verify the client can see MOOTx01 MCP tools.

Good first tool checks:

- `moot_estate_ping`
- `moot_estate_status`

Good memory smoke test:

1. File a harmless memory.
2. Search for the same memory.
3. Confirm recall works.

Example memory text:

    MOOTx01 install verification memory. If this is found later, recall is working.

## Explain What Changed

After successful install, tell the user:

MOOTx01 CE is installed locally. Your AI client can now talk to a local MOOTx01 memory estate through ARIA/MCP. The resident daemon uses `127.0.0.1:4242` by default. The dashboard, if installed, is at `127.0.0.1:4200`. Your memory is local by default. I verified the service after install.

Also tell the user which client configs were changed, if any.

## Useful First Prompts

Offer the user examples:

    Remember that for this project we prefer small focused commits.

    Search my MOOT for what we decided about the installer.

    File this as a project memory: the dashboard port is 4200 and the daemon port is 4242.

    Show me the current status of my MOOT estate.

    What do you remember about this project from previous sessions?

## Troubleshooting

### `mootx01` command not found

Check install location and `PATH`.

Do not edit shell files without approval.

### Daemon not reachable

Run:

    mootx01 status

Check port `4242`.

Do not start a second writer against the same estate if a resident daemon is already running.

### Dashboard not reachable

Run:

    moot-mgr status

Expected dashboard:

    http://127.0.0.1:4200

### AI client does not show tools

Restart the AI client.

Then inspect the client-specific MCP config written by the installer.

Do not manually rewrite the config unless the installer failed or the user asks.

### Docs and code disagree

Prefer current executable code and current install surface over stale prose.

Tell the user which source you used.

## SDK Handoff

If the user wants to build with MOOTx01 CE rather than install it as a product, route them to:

- `docs/start-here/SUBSTRATE_FOR_DEVELOPERS.md`
- `docs/concepts/TOPOLOGY.md`
- `docs/reference/`
- `examples/`
- `packages/SDK.md` if current

If the SDK surface is described as emergent, say so. Do not invent a single stable SDK package.

## Completion Checklist

Before saying the install is complete, verify:

- `mootx01` is callable.
- `mootx01 status` ran.
- AI client config was written only where intended.
- Daemon endpoint is `127.0.0.1:4242` unless overridden.
- Dashboard endpoint is `127.0.0.1:4200` unless overridden.
- The user knows what changed.
- The user knows how to verify and troubleshoot.