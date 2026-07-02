# MOOTx01

**Long-term memory for AI.**

*Observe · Remember · Dream · Convene*

> The frontier intelligence is rented. The memory is yours.

![status](https://img.shields.io/badge/status-1.0.5--beta-orange)
![platforms](https://img.shields.io/badge/platforms-Apple%20Silicon%20·%20PC%2FLinux-blue)
![ports](https://img.shields.io/badge/ports-Swift%20%2B%20Rust%20(byte--identical)-success)
![interface](https://img.shields.io/badge/interface-ARIA%20over%20MCP-purple)
![license](https://img.shields.io/badge/license-open%20core-lightgrey)
![security](https://img.shields.io/badge/security-audit%20in%20progress-yellow)

> **Security audit in progress.** MOOTx01 is under active security review and
> hardening ahead of its first stable release. Pre-release builds may change as
> findings are addressed; treat the current line as a release candidate, not a
> final release.

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

## What it looks like

Install MOOTx01, wire it into your AI client, restart the client, and verify that the tools are visible.

```bash
mootx01 install
```

Then ask your AI to try memory:

```text
Remember that this project ships the importer behind a flag.
```

```text
Search my MOOT for what we decided about the importer.
```

```text
Show me the current status of my MOOT estate.
```

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

## Where to go next

- **Install it.** See [Quickstart](#quickstart-105-beta) below.
- **Understand it fast.** Read [`docs/start-here/END_USER_EXPLAINER.md`](docs/start-here/END_USER_EXPLAINER.md).
- **Have an AI install it.** Give the AI [`AI_START_HERE.md`](AI_START_HERE.md).
- **Read the story.** [`ABOUT.md`](ABOUT.md) explains why MOOTx01 exists and why memory belongs to you.
- **Build on it.** [`docs/start-here/SDK_QUICKSTART.md`](docs/start-here/SDK_QUICKSTART.md) shows the open → capture → recall loop.
- **See the architecture.** [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md) is the readable map of the repository.
- **Visit the live site.** [mootx01.ai](https://mootx01.ai)

---

## Quickstart (1.0.5-beta)

> **1.0.5-beta — early access.** Installable now. Pre-release line; the general-availability binary follows. For early adopters and builders.

### 1 · Install the binary

Prebuilt, no toolchain, no clone.

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.sh | sh
```

**Windows** (PowerShell)

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
irm https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.ps1 -OutFile install.ps1
# review install.ps1, then:
.\install.ps1
```

(Download-then-run, not `irm | iex` — the script itself should be reviewable
before anything executes. The TLS line is required on Windows PowerShell 5.1.)

Installs to:

```text
~/.mootx01/bin
```

Re-run to upgrade.

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

`install` picks the deepest available and falls back automatically (plugin → skills → server). The per-client adapters and plugin sources live in:

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

## For builders: the kit stack

```text
Behaviour:
    NeuronKit       AI algorithms: reasoning functions plus autonomic daemons
    CognitionKit    Behaviour layer: named, composable workflows

Composition:
    GeniusLocusKit  Unified substrate: LocusKit + CorpusKit + Brain layer; N estates

Standalone substrate:
    LocusKit        Spatial memory system plus knowledge graph
    VectorKit       On-device embeddings plus nearest-neighbour search
    CorpusKit       Content-plus-vector RAG bundles

Grounding:
    EideticLib      Deterministic text-to-anchor (FDC code + Wikidata Q-ID)
    LatticeLib      Frame Decimal Classification: assembler, canon, lookup

Typed math:
    EngramLib       Typed 256-bit Engram API

Foundation:
    SubstrateTypes  Pure substrate types
    SubstrateKernel Hot-path bit ops, write gate, clock
    SubstrateML     Learning + graph algorithms
    SubstrateLib    Orchestration: verbs + row-state automaton
    PersistenceKit  Storage backends: SQLite, PostgreSQL, InMemory
    ConvergenceKit  Sync implementations: CloudKit, Federation, None
    QueueKit        Fill-and-drain job queue
    IntellectusLib  Telemetry floor
    ObserverSink    Telemetry sink + SQLite stats store
    AriaLexiconLib  Reified ARIA grammar
    AriaMcpKit      ARIA-over-MCP server surface
    LoopbackHTTP    Minimal loopback HTTP transport
    VaultKit        Encrypted, portable estate export/import
```

## Implementations

Every kit ships in two equal-status implementations, conformance-gated against shared test vectors:

- **Swift** — Apple Silicon, macOS 26+, iOS 26+
- **Rust** — PC/Linux x86_64 and Linux aarch64

Neither port leads. Both must agree bit for bit.

## Roadmap

Version 1.1.x
- **Docs and Specs** — Clean up agentic baggage in the documentation. Remove the noise and organize for humans
- **Improved Sidecar and embedded examples** — reference app patterns.    
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
| [`docs/start-here/AI_INSTALL_MANIFEST.json`](docs/start-here/AI_INSTALL_MANIFEST.json) | Machine-readable install facts for AI agents (commands, ports, verification, adapters) |
| [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md) | Readable front door: products, stack, surfaces, sidecar |
| [`docs/concepts/MOOTX01_AND_ARIA_CANON.md`](docs/concepts/MOOTX01_AND_ARIA_CANON.md) | Durable definitions of MOOTx01 and ARIA |
| [`docs/concepts/ARIA_LEXICON.md`](docs/concepts/ARIA_LEXICON.md) | The ARIA grammar: one noun, nine verbs, four adjectives |
| [`docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md`](docs/reference/) | Authoritative substrate specification |
| [`EDITIONS.md`](EDITIONS.md) · [`LICENSING.md`](LICENSING.md) | Open core + commercial editions, in plain language |

## Standards

Swift 6 strict concurrency · zero external Swift dependencies in kits (except sqlite-vec in PersistenceKit-SQLite) · raw SQLite via PersistenceKit, no Core Data · dates as TEXT/ISO8601 · no Bool stored properties on entities (bitmap fields) · Metal for GPU compute on Apple Silicon · every computation deterministic.

---

*MOOTx01 is a [Codedaptive](https://codedaptive.com) project. With thanks to Dennis E. Taylor, author of the Bobiverse — the replicants and their moots showed the shape of what we needed, and why.*
