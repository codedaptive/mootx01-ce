# MOOTx01

**Long-term memory for AI.**

*Observe · Remember · Dream · Convene*

> The frontier intelligence is rented. The memory is yours.

[![release](https://img.shields.io/github/v/release/codedaptive/mootx01-ce?label=release&color=success)](https://github.com/codedaptive/mootx01-ce/releases/latest)
[![downloads](https://img.shields.io/github/downloads/codedaptive/mootx01-ce/total?color=blue)](https://github.com/codedaptive/mootx01-ce/releases)
[![macOS pkg](https://img.shields.io/badge/macOS-.pkg%20installer%20(notarized)-blue?logo=apple)](https://github.com/codedaptive/mootx01-ce/releases/latest)
[![Windows setup](https://img.shields.io/badge/Windows-setup.exe%20·%20winget-0078D4?logo=windows)](https://github.com/codedaptive/mootx01-ce/releases/latest)
[![Homebrew](https://img.shields.io/badge/Homebrew-codedaptive%2Fmootx01--ce-FBB040?logo=homebrew&logoColor=white)](https://github.com/codedaptive/homebrew-mootx01-ce)
[![Linux](https://img.shields.io/badge/Linux-x86__64%20·%20aarch64-FCC624?logo=linux&logoColor=black)](https://github.com/codedaptive/mootx01-ce/releases/latest)
[![SDKs](https://img.shields.io/badge/SDKs-4%20Apache--2.0%20library%20repos-8A2BE2)](#developer-sdks)
![signed](https://img.shields.io/badge/releases-minisign%20signed-success)
![platforms](https://img.shields.io/badge/platforms-Apple%20Silicon%20·%20PC%2FLinux-blue)
![ports](https://img.shields.io/badge/ports-Swift%20%2B%20Rust%20(byte--identical)-success)
![interface](https://img.shields.io/badge/interface-ARIA%20over%20MCP-purple)
![license](https://img.shields.io/badge/license-open%20core-lightgrey)

> Every release asset ships with a minisign-signed `checksums.txt` so you can
> verify what you install.

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
- **Build on it.** [`docs/start-here/SDK_QUICKSTART.md`](docs/start-here/SDK_QUICKSTART.md) shows the open → capture → recall loop, and [`SDK.MD`](SDK.MD) maps the standalone Apache-2.0 SDK repos.
- **Operate it.** [`apps/moot-mgr/README.md`](apps/moot-mgr/README.md) covers the dashboard, read API, control plane, configuration, and troubleshooting.
- **Maintain an Obsidian vault.** [`docs/start-here/OBSIDIAN_VAULT.md`](docs/start-here/OBSIDIAN_VAULT.md) documents today's explicit workflow and the planned 1.1 continuous mode.
- **Use two memory backends.** [`apps/moot-bridge/README.md`](apps/moot-bridge/README.md) explains the optional primary/secondary MCP bridge and its failure model.
- **Inspect benchmark evidence.** [`apps/moot-math-benchmark/README.md`](apps/moot-math-benchmark/README.md) separates reproducible performance data from conformance and memory-quality evaluation.
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

MOOTx01 is an SDK of composable kits. **GeniusLocusKit** composes them into a working estate, the **Brain** layer prepares memory, and **ARIA** is the one interface in front of all of it.

```text
Observe / Remember -> LocusKit (spatial memory + knowledge graph)
                      VectorKit (on-device embeddings + ANN / hybrid search)
                      CorpusKit (content-plus-vector RAG bundles)

Dream             -> NeuronKit (hybrid recall, dreaming daemon, Bradley-Terry, SolverBandit)
                     CognitionKit (named, composable behaviour recipes)

Compose / Convene -> GeniusLocusKit (N estates, matrix layer, federation)

Speak             -> ARIA (MCP server + native app surfaces)
```

The readable map of the whole repository is [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md).

## For developers

If you are building an application and you want it to have temporal knowledge — memory that survives sessions, links to AI, and participates in the user's life — you can embed MOOTx01 directly.

Most apps do not have a memory substrate because writing one is hard. The math debt is steep. The speed optimization is harder. MOOTx01 ships as a kit family, so your application can gain memory without rebuilding the substrate from scratch.

Your app can use MOOTx01 in three common ways:

- **Sidecar:** the app keeps its own store, and a MOOT runs beside it.
- **Embedded:** the app links the kits directly.
- **MCP surface:** the app exposes or consumes memory through ARIA over MCP.

The interface is ARIA: consistent across implementations, surfaces, and languages. The same vocabulary works whether you embed MOOTx01 as a library, query it through an MCP server, or call it through a native API.

### Developer SDKs

**The engines are open. The intelligence is the product.**

Seventeen libraries and kits from the MOOTx01 Framework are open source under
Apache 2.0 — published today, not on a timer — through four standalone venue
repositories, installable directly with SwiftPM or Cargo:

| Repo | The engines it gives you |
|---|---|
| [`moot-memory`](https://github.com/codedaptive/moot-memory) | Spatial memory + knowledge graph, on-device vector search, RAG bundles |
| [`moot-semantics`](https://github.com/codedaptive/moot-semantics) | The ARIA grammar, FDC lattice, deterministic text-to-anchor grounding |
| [`moot-system`](https://github.com/codedaptive/moot-system) | Storage (SQLite · PostgreSQL · InMemory), queueing, sync, telemetry |
| [`moot-core`](https://github.com/codedaptive/moot-core) | The typed substrate: 256-bit Engram math, kernel, learning + graph algorithms |

Those engines let you build your own memory system — and they're the same ones
MOOTx01 runs on. What this repository adds is the intelligence: composed recall
across estates, the dreaming and trust Brain, twenty-plus reasoning lenses,
and the ARIA voice that lets any MCP client use it with zero integration code.

The full map — every package, install snippets, what the product layer adds,
and the decision guide — is in [`SDK.MD`](SDK.MD).

## For builders: the kit stack

```text
Behaviour (this repo):
    NeuronKit       AI algorithms: reasoning functions plus autonomic daemons
    CognitionKit    Behaviour layer: named, composable workflows

Composition (this repo):
    GeniusLocusKit  Unified substrate: LocusKit + CorpusKit + Brain layer; N estates

Standalone substrate (SDK: moot-memory):
    LocusKit        Spatial memory system plus knowledge graph
    VectorKit       On-device embeddings plus nearest-neighbour search
    CorpusKit       Content-plus-vector RAG bundles

Grounding (SDK: moot-semantics):
    EideticLib      Deterministic text-to-anchor (FDC code + Wikidata Q-ID)
    LatticeLib      Frame Decimal Classification: assembler, canon, lookup
    AriaLexiconLib  Reified ARIA grammar

Typed math (SDK: moot-core):
    EngramLib       Typed 256-bit Engram API

Foundation (SDK: moot-core / moot-system):
    SubstrateTypes  Pure substrate types
    SubstrateKernel Hot-path bit ops, write gate, clock
    SubstrateML     Learning + graph algorithms
    SubstrateLib    Orchestration: verbs + row-state automaton
    PersistenceKit  Storage backends: SQLite, PostgreSQL, InMemory
    ConvergenceKit  Sync implementations: CloudKit, Federation, None
    QueueKit        Fill-and-drain job queue
    IntellectusLib  Telemetry floor
    ObserverSink    Telemetry sink + SQLite stats store
    LoopbackHTTP    Minimal loopback HTTP transport

Product surface (this repo):
    AriaMcpKit      ARIA-over-MCP server surface
    VaultKit        Encrypted, portable estate export/import
```

## Implementations

Every kit ships in two equal-status implementations, conformance-gated against shared test vectors:

- **Swift** — Apple Silicon, macOS 26+, iOS 26+
- **Rust** — PC/Linux x86_64 and Linux aarch64

Neither port leads. Both must agree bit for bit.

## Security

Security-relevant changes go through an independent adversarial review before merge, verified against the live code and gated on that pass.
Users who prefer process-pipe MCP transport can install in
[direct stdio mode](#if-you-want-a-more-secure-local-setup) instead of keeping
the resident HTTP listener.
The [continuous security review record](docs/validation/audits/AUDIT_CONTINUOUS_SECURITY_REVIEW_2026-07-22.md)
documents **537 remediated security finding records** from June 25 through
July 22, 2026. The linked [finding ledger](docs/validation/audits/SECURITY_FINDING_REMEDIATION_LEDGER_2026-07-22.md)
names every issue and its fix or closing commit.

## Roadmap

Version 1.1.x
- **Docs and Specs** — Clean up agentic baggage in the documentation. Remove the noise and organize for humans
- **Improved Sidecar and embedded examples** — reference app patterns.    
- **Continuous Obsidian vault (insecure mode)** — an optional resident watcher automates eligible import, export, and resync for a normal Obsidian vault. Private/non-exportable, restricted, and secret data are blocked from automation; private transfers remain explicit and authorization-gated.
- **Apple iOS Native App**  — Full App with Shortcut Support and App Intents for Mootx01 sharing to External Apps
- **Apple Intelligence integration** — native capture and recall across Apple surfaces.  
- **Apple iCloud Sync** Seemless default estate sharing between iOS and MacOs
  
Version 1.2.x
- **Federation** — bounded cross-estate sharing.
- **MiniLLM Support** — moot side local language model for schedule driven llm house keeping and data mining of the estates

Version 1.3.x
- **mootgres**  — full postgres extension to offload moot computations to a postgres server.


## Repository structure

```
mootx01/
├── packages/
│   ├── libs/     SubstrateTypes · SubstrateKernel · SubstrateML · SubstrateLib · EngramLib
│   │             AriaLexiconLib · LatticeLib · EideticLib · IntellectusLib · ObserverSink · LoopbackHTTP
│   ├── kits/     LocusKit · VectorKit · PersistenceKit · ConvergenceKit · QueueKit
│   │             CorpusKit · GeniusLocusKit · NeuronKit · CognitionKit · VaultKit · AriaMcpKit
│   └── PACKAGES.md
├── apps/         aria-mcp-server (MCP server) · mootx01 (CLI) · moot-mgr (console)
│                 moot-bridge (transport bridge) · Mootx01-App (Apple app)
│                 Mootx01-Setup (macOS install assistant) · moot-math-benchmark
│                 moot-agent-skills (client adapters)
├── examples/     SDK · SidecarDemo · MootNotepad · MootTodo · MootCalendarIngest
└── docs/         start-here · concepts · reference · decisions · engineering · validation · archive
```

## Key documents

| Document | Purpose |
|----------|---------|
| [`ABOUT.md`](ABOUT.md) | What MOOTx01 is and why — the full story |
| [`AI_START_HERE.md`](AI_START_HERE.md) | For an AI assistant: explain MOOTx01 and install it for the user |
| [`docs/start-here/END_USER_EXPLAINER.md`](docs/start-here/END_USER_EXPLAINER.md) | Plain-language explainer for a non-technical user |
| [`docs/start-here/INSTALL_SURFACE.md`](docs/start-here/INSTALL_SURFACE.md) | Install fact sheet: addresses, flow, platform matrix, verification |
| [`docs/start-here/SDK_QUICKSTART.md`](docs/start-here/SDK_QUICKSTART.md) | Build on the substrate: open an estate, capture → recall (Swift + Rust) |
| [`docs/start-here/OBSIDIAN_VAULT.md`](docs/start-here/OBSIDIAN_VAULT.md) | Stable on-demand vault workflow and planned 1.1 continuous mode |
| [`docs/start-here/AI_INSTALL_MANIFEST.json`](docs/start-here/AI_INSTALL_MANIFEST.json) | Machine-readable install facts for AI agents (commands, ports, verification, adapters) |
| [`apps/moot-mgr/README.md`](apps/moot-mgr/README.md) | Operator console, dashboard/read API, control plane, and troubleshooting |
| [`apps/moot-bridge/README.md`](apps/moot-bridge/README.md) | Optional two-backend MCP bridge: routing, configuration, security, and failure behavior |
| [`apps/moot-math-benchmark/README.md`](apps/moot-math-benchmark/README.md) | Reproducible benchmark program, evidence requirements, and result submission |
| [`llms.txt`](llms.txt) | Compact repository and standalone-SDK discovery map for AI agents |
| [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md) | Readable front door: products, stack, surfaces, sidecar |
| [`docs/concepts/MOOTX01_AND_ARIA_CANON.md`](docs/concepts/MOOTX01_AND_ARIA_CANON.md) | Durable definitions of MOOTx01 and ARIA |
| [`docs/concepts/ARIA_LEXICON.md`](docs/concepts/ARIA_LEXICON.md) | The ARIA grammar: one noun, nine verbs, four adjectives |
| [`SDK.MD`](SDK.MD) | The framework SDKs: four Apache-2.0 venues, what they give you, what the product adds |
| [`apps/moot-agent-skills/PLUGIN.MD`](apps/moot-agent-skills/PLUGIN.MD) | Why the plugin install depth matters — server vs. skills vs. plugin |
| [`docs/reference/PLUGIN_SPEC.md`](docs/reference/PLUGIN_SPEC.md) | Plugin distribution specification |
| [`docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md`](docs/reference/) | Authoritative substrate specification |
| [`EDITIONS.md`](EDITIONS.md) · [`LICENSING.md`](LICENSING.md) | Open core + commercial editions, in plain language |

## Standards

Swift 6 strict concurrency · zero external Swift dependencies in kits (except sqlite-vec in PersistenceKit-SQLite) · raw SQLite via PersistenceKit, no Core Data · dates as TEXT/ISO8601 · no Bool stored properties on entities (bitmap fields) · Metal for GPU compute on Apple Silicon · every computation deterministic.

---

*MOOTx01 is a [Codedaptive](https://codedaptive.com) project. With thanks to Dennis E. Taylor, author of the Bobiverse — the replicants and their moots showed the shape of what we needed, and why.*
