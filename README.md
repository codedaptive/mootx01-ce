# MOOTx01

**Long-term memory for AI.**

Persistent, private memory shared across your AI clients and local agents.

> The frontier intelligence is rented. The memory is yours.

[![release](https://img.shields.io/github/v/release/codedaptive/mootx01-ce?label=release&color=success)](https://github.com/codedaptive/mootx01-ce/releases/latest)
[![downloads](https://img.shields.io/github/downloads/codedaptive/mootx01-ce/total?color=blue)](https://github.com/codedaptive/mootx01-ce/releases)
[![macOS pkg](https://img.shields.io/badge/macOS-.pkg%20installer%20(notarized)-blue?logo=apple)](https://github.com/codedaptive/mootx01-ce/releases/latest)
[![Windows setup](https://img.shields.io/badge/Windows-setup.exe%20·%20winget-0078D4?logo=windows)](https://github.com/codedaptive/mootx01-ce/releases/latest)
[![Homebrew](https://img.shields.io/badge/Homebrew-codedaptive%2Fmootx01--ce-FBB040?logo=homebrew&logoColor=white)](https://github.com/codedaptive/homebrew-mootx01-ce)
[![Linux](https://img.shields.io/badge/Linux-x86__64%20·%20aarch64-FCC624?logo=linux&logoColor=black)](https://github.com/codedaptive/mootx01-ce/releases/latest)
[![SDKs](https://img.shields.io/badge/SDKs-4%20Apache--2.0%20library%20repos-8A2BE2)](TECHNICAL_OVERVIEW.md#developer-sdks)
![channel](https://img.shields.io/badge/channel-1.1.0--beta--03-orange)
![signed](https://img.shields.io/badge/releases-minisign%20signed-success)
![platforms](https://img.shields.io/badge/platforms-Apple%20Silicon%20·%20PC%2FLinux-blue)
![ports](https://img.shields.io/badge/ports-Swift%20%2B%20Rust%20(byte--identical)-success)
![interface](https://img.shields.io/badge/interface-ARIA%20over%20MCP-purple)
![license](https://img.shields.io/badge/license-open%20core-lightgrey)

> Every release asset ships with a minisign-signed `checksums.txt` so you can
> verify what you install.

> **Branch channel:** `develop/1.1.x` is currently versioned
> `1.1.0-beta-04`. It is the fast-moving beta for 1.1 feature work, not the
> supported production release. The installers and `releases/latest` links
> below install the current stable 1.0 line; use a source build from this
> checkout to exercise 1.1 work in progress.

## Personal MOOTs are always free

A personal MOOT belongs to one person. That person may use it at home or at
work, and across their personal devices, without a license fee. A company may
install a separate, isolated personal MOOT for every employee. Individuals and
companies may also compile, sign, and deploy their own single-user MOOTx01-App
builds for free.

Commercial licensing begins when the MOOTx01 product core becomes shared
multiuser infrastructure, part of a client-facing application, or a service
that hosts MOOTs for clients for a fee. The official Apple App Store build is a
separate, optional convenience purchase, currently expected to be about $3 per
major `x.0.0` release. That purchase pays for the maintained App Store
distribution, not for the right to run a personal MOOT.

**People are free. Systems are licensed. Assurance is Enterprise.** See the
[plain-language licensing guide](LICENSING.md) and the binding
[`LICENSE`](LICENSE).

## 1.1 development beta

This branch is where compatible 1.1 capabilities land and are qualified before
promotion. It moves continuously: APIs, migrations, documentation, and feature
flags can change between commits. `beta-03` records the three pushes made to
`candidate/1.1.x` since that branch was created. Pin the commit you test, use a
disposable or backed-up estate, and report the version and commit with every
beta issue.

Current 1.1 work includes the native MOOTx01-App, CorpusKit shared-content
architecture, Apple surfaces and on-demand federation, and the foundation for
continuous Obsidian synchronization. The roadmap distinguishes implemented
behavior from planned work.

Build the beta directly:

```bash
# Swift — macOS 26+
swift build -c release --package-path apps/mootx01 --product mootx01
SWIFT_BIN="$(swift build -c release --package-path apps/mootx01 --show-bin-path)"
"$SWIFT_BIN/mootx01" --version

# Rust — Linux or Windows
cargo build --locked --release --manifest-path apps/mootx01/rust/Cargo.toml
apps/mootx01/rust/target/release/mootx01 --version
```

The plugin packages committed on this branch are development artifacts. The
public marketplace plugin remains on the stable 1.0 channel.

## Install in 60 seconds

Pick your platform, run two commands, done.

| Platform | Install |
|---|---|
| **macOS** (installer) | Download the notarized [`.pkg`](https://github.com/codedaptive/mootx01-ce/releases/latest) and double-click — a setup assistant walks you through it |
| **macOS / Linux** (Homebrew) | `brew install codedaptive/mootx01-ce/mootx01` |
| **macOS / Linux** (script) | `curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.sh \| sh` |
| **Windows** (installer) | Download [`setup.exe`](https://github.com/codedaptive/mootx01-ce/releases/latest) and double-click |
| **Windows** (winget) | `winget install Codedaptive.MOOTx01` |
| **Windows** (script) | See [PowerShell install](#1--install-the-binary) below |
| **Linux** (tarball) | Grab the [`tar.gz`](https://github.com/codedaptive/mootx01-ce/releases/latest) for x86_64 or aarch64 |

Then wire it into your AI clients and verify:

```bash
mootx01 install
mootx01 status
```

That's it. The installer finds your MCP clients (Claude Code, Cursor, Codex,
and more), registers MOOTx01 at the deepest level each client supports, and
starts the local services. Full details, addresses, and verification steps in
the [Quickstart](#quickstart) below.

Then ask your AI to try memory:

```text
Remember that this project ships the importer behind a flag.
```

```text
Search my MOOT for what we decided about the importer.
```

## What it is

MOOTx01 gives your AI a memory that lasts.

Every AI today has the same basic problem: when the chat ends, the useful context often disappears with it. You start over. You re-explain the same project rules. You re-introduce old decisions. You switch from one AI tool to another and the memory does not come with you.

MOOTx01 stores useful memory in a local estate your AI can read from later. It runs on your machine by default. Any AI client that speaks the Model Context Protocol can connect to it through ARIA, the MOOTx01 memory language.

The model can change. Your memory stays yours.

## What it fixes

Your AI has a context window. That is what it can think with right now.

MOOTx01 gives it a memory estate. That is what it can remember from later.

Use MOOTx01 when you want your AI to:

- remember project decisions,
- recall prior conversations,
- keep durable facts and notes,
- link related ideas,
- search across sessions,
- stop asking you to rebuild the past every time.

MOOTx01 is not just a vector database. It stores memory as a substrate: memories, facts, links, journals, trust state, recall indexes, graph structure, reasoning lenses, and background consolidation signals.

In plain English: it keeps what happened, finds what matters, and helps your AI use that memory when it matters.

## Drop-in replacement for Anthropic's memory system

MOOTx01 implements Anthropic's `memory_20250818` tool contract — the same six commands Claude already knows — but backed by a governed estate instead of flat files. Every model-written memory lands as unconfirmed and auditable. Deletes are soft and reversible. Edits preserve full history.   
Enable it with:   

- `mootx01 enable memory-tool` for MCP and Interactive use.   
- `pip install moot-memory` for the Messages API.   

See the [Memory Adapter README](apps/moot-memory-adapter/README.md) for details.

## What it looks like

Behind the scenes, the AI uses ARIA tools like these:

```jsonc
// store a memory
moot_file_memory {
  "content": "We ship the importer behind a flag.",
  "location": "project/alpha"
}

// retrieve memory
moot_memory_search {
  "query": "what did we decide about the importer?"
}
```

```text
Show me the current status of my MOOT estate.
```

## Where to go next

- **Install it.** See [Install in 60 seconds](#install-in-60-seconds) above or the full [Quickstart](#quickstart) below.
- **Understand it fast.** Read [`docs/start-here/END_USER_EXPLAINER.md`](docs/start-here/END_USER_EXPLAINER.md).
- **Have an AI install it.** Give the AI [`AI_START_HERE.md`](AI_START_HERE.md).
- **Read the story.** [`ABOUT.md`](ABOUT.md) explains why MOOTx01 exists and why memory belongs to you.
- **Build on it.** Start with [`moot-memory`](https://github.com/codedaptive/moot-memory), [`moot-semantics`](https://github.com/codedaptive/moot-semantics), [`moot-system`](https://github.com/codedaptive/moot-system), or [`moot-core`](https://github.com/codedaptive/moot-core). [`SDK.MD`](SDK.MD) maps all 17 Apache-2.0 packages; [`SDK_QUICKSTART.md`](docs/start-here/SDK_QUICKSTART.md) covers the product-tree composition path.
- **Build the native Apple app.** [`apps/Mootx01-App/README.md`](apps/Mootx01-App/README.md) covers the macOS/iOS app, Apple intelligence and automation, sync, LAN serving, federation, build steps, and current development boundaries.
- **Understand CorpusKit 1.1.** [`packages/kits/CorpusKit/README.md`](packages/kits/CorpusKit/README.md) explains standalone and attached modes, canonical content identity, providers, migration, and the Swift/Rust test lanes.
- **Operate it.** [`apps/moot-mgr/README.md`](apps/moot-mgr/README.md) covers the dashboard, read API, control plane, configuration, and troubleshooting.
- **Maintain an Obsidian vault.** [`docs/start-here/OBSIDIAN_VAULT.md`](docs/start-here/OBSIDIAN_VAULT.md) documents today's explicit workflow and the planned 1.1 continuous mode.
- **Use two memory backends.** [`apps/moot-bridge/README.md`](apps/moot-bridge/README.md) explains the optional primary/secondary MCP bridge and its failure model.
- **Inspect benchmark evidence.** [`apps/moot-math-benchmark/README.md`](apps/moot-math-benchmark/README.md) separates reproducible performance data from conformance and memory-quality evaluation.
- **Evaluate the tech.** [`TECHNICAL_OVERVIEW.md`](TECHNICAL_OVERVIEW.md) covers the architecture, integration models, kit stack, implementations, security record, and repository map.
- **See the architecture.** [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md) is the readable map of the repository.
- **Visit the live site.** [mootx01.ai](https://mootx01.ai)

---

## Quickstart

### 1 · Install the binary

Prebuilt, no toolchain, no clone. Native installers are the easiest path:

**macOS — native installer (recommended)**

Download the notarized `.pkg` for your architecture from the
[latest release](https://github.com/codedaptive/mootx01-ce/releases/latest)
and double-click. A SwiftUI setup assistant handles the rest.

**macOS / Linux — Homebrew**

```bash
brew install codedaptive/mootx01-ce/mootx01
```

Upgrades arrive with `brew upgrade`.

**macOS / Linux — script**

```bash
curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.sh | sh
```

**Windows — native installer (recommended)**

Download `setup.exe` for your architecture from the
[latest release](https://github.com/codedaptive/mootx01-ce/releases/latest)
and double-click, or use the Windows Package Manager:

```powershell
winget install Codedaptive.MOOTx01
```

**Windows — script** (PowerShell)

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
irm https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.ps1 -OutFile install.ps1
# Review install.ps1 before running it, then:
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

(Downloads the script to disk so you can review it before running it.
The TLS line is required on Windows PowerShell 5.1. The
`-ExecutionPolicy Bypass` flag is needed because Windows blocks script
files by default; it applies to this one run only and changes no
system setting.)

Script and tarball installs land in:

```text
~/.mootx01/bin
```

To upgrade any script or tarball install, run `mootx01 upgrade` — it
downloads the latest release (SHA-256 verified), converges the plugin
packages and tool permissions, and restarts the background services.
Re-running the install script works too. Every release asset is covered
by a minisign-signed `checksums.txt` on the release page.

### 2 · Wire it in

```bash
mootx01 install
```

The installer registers MOOTx01 with supported MCP clients and starts the local services when supported.

By default:

| Surface | Address |
|---|---|
| MOOTx01 resident daemon | `http://127.0.0.1:4242` |
| `moot-mgr` dashboard | `http://127.0.0.1:4200` |

Both are loopback addresses. They are meant for your own machine, not the public internet. For security they will reject connection from other devices.

#### If you want a more secure local setup

Use direct stdio when one AI client should launch its own MOOTx01 subprocess
instead of connecting to the resident HTTP listener:

```bash
mootx01 install --target codex --mode server --no-daemon --vault-off
```

For Codex, this writes a command entry to `~/.codex/config.toml`:

```toml
[mcp_servers.mootx01]
command = "/absolute/path/to/mootx01"
args = ["serve"]
env = { MOOTX01_HTTP_PORT = "", MOOTX01_VAULT = "0" }
```

Direct stdio normally limits the MCP transport to the parent client's process
pipes. Clearing `MOOTX01_HTTP_PORT` prevents an inherited shell setting from
turning that child back into an HTTP server. `mootx01 serve` will, however, forward to a resident daemon over
localhost when that daemon already owns the same estate. Stop or disable the
existing resident service first if you require socket-free MCP operation, then
restart the AI client and confirm its MOOTx01 entry contains `command` and
`args`, not `url`.

This mode gives up the shared resident's background governor, central
telemetry, and `moot-mgr` visibility. See
[`INSTALLING_MOOTX01.md`](docs/start-here/INSTALLING_MOOTX01.md#direct-stdio-for-a-tighter-local-transport)
for service-stop and verification steps.

### 3 · Verify it

```bash
mootx01 status
```

If the manager is installed:

```bash
moot-mgr status
```

Open the dashboard:

```text
http://127.0.0.1:4200
```

If your AI client supports MCP tool discovery, confirm it can see MOOTx01 tools such as:

- `moot_estate_ping`
- `moot_estate_status`
- `moot_memory_search`
- `moot_file_memory`

### 4 · Make the AI use memory automatically

Installing the runtime gives the AI the tools. The next step teaches the client *when* to reach for memory. `mootx01 install` wires this at the deepest level each client supports — three integration depths:

| Depth | What it installs | Clients |
|---|---|---|
| **Server** | MCP tools only | every MCP client |
| **Skills** | a `SKILL.md` adapter that teaches the AI when to use memory | clients with a skills surface |
| **Plugin** | a native plugin package for the client | clients with a plugin format (Claude Code, Cursor, …) |

`install` picks the deepest available and falls back automatically (plugin → skills → server). Why the plugin depth is worth having: [`apps/moot-agent-skills/PLUGIN.MD`](apps/moot-agent-skills/PLUGIN.MD).

The plugin is also installable straight from your client's marketplace — in Claude Code:

```
claude plugin marketplace add codedaptive/mootx01-plugin
claude plugin install mootx01@mootx01
``` The per-client adapters and plugin sources live in:

```text
apps/moot-agent-skills/        # claude · cursor · codex · continue · cline · roo · openai-agents · generic
apps/moot-agent-skills/README.md
```

## How it works

MOOTx01 combines durable storage, semantic and graph recall, background
consolidation, and the ARIA interface in one local memory substrate.

Applications can use it as a local sidecar, embed its libraries directly,
or connect through MCP.

See the [Technical Overview](TECHNICAL_OVERVIEW.md) for the architecture,
implementations, kit stack, security model, and repository map.

## Security

Security-relevant changes go through an independent adversarial review before
merge. The full review record lives in the
[Technical Overview](TECHNICAL_OVERVIEW.md#security). To report a
vulnerability, see [`SECURITY.md`](SECURITY.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

*MOOTx01 is a [Codedaptive](https://codedaptive.com) project. With thanks to Dennis E. Taylor, author of the Bobiverse — the replicants and their moots showed the shape of what we needed, and why.*
