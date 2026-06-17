# MOOTx01

**Long-term memory for AI.**

*Observe · Remember · Dream · Convene*

> The frontier intelligence is rented. The memory is yours.

![status](https://img.shields.io/badge/status-1.0.0--beta-orange)
![platforms](https://img.shields.io/badge/platforms-Apple%20Silicon%20·%20PC%2FLinux-blue)
![ports](https://img.shields.io/badge/ports-Swift%20%2B%20Rust%20(byte--identical)-success)
![interface](https://img.shields.io/badge/interface-ARIA%20over%20MCP-purple)
![license](https://img.shields.io/badge/license-open%20core-lightgrey)

## What it is

MOOTx01 gives your AI a memory that lasts. Every AI today forgets when a chat ends. You start over. You re-explain. You re-introduce yourself. MOOTx01 stores what was said so the next chat starts where the last one left off. It runs on your machine. Any AI that speaks the Model Context Protocol can read from it.

## What it fixes

Your AI has a short memory. It only holds what fits in one conversation. Close the chat and the memory is gone. Switch from Claude to ChatGPT and it is gone again. MOOTx01 stores what was said in a place your AI can read at any time. The memory belongs to you. You can take it from one AI to another and keep going.

## What it looks like

You wire MOOTx01 into your AI client by running:

```
mootx01 install
```

Restart your AI agent and it will teach itself MOOTx01's language as if they had been best friends for years. After a few minutes your AI agent will be fluently using MOOTx01.

You can try things like:

- "Ping Moot"
- "Take Moot for a test drive"
- "Explore Moot's ability"

The full language is called ARIA. Nine verbs in total. Behind the scenes, your AI uses commands like these:

```jsonc
// store
moot_file_memory { "content": "We ship the importer behind a flag.", "location": "project/alpha" }

// retrieve
moot_memory_search { "query": "what did we decide about the importer?" }
```

## Where to go next

- **Install it.** See [Quickstart](#quickstart-100-beta) below. One command on macOS, Linux, or Windows.
- **Read the story.** [`ABOUT.md`](ABOUT.md) covers why MOOTx01 exists, what a moot is, and why memory belongs to you.
- **See the architecture.** [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md) is the readable map of the whole repository.
- **Visit the live site.** [mootx01.ai](https://mootx01.ai)

---

## Quickstart (1.0.0-beta)

> **1.0.0-beta — early access.** Installable now, **not yet security-hardened**. The full security sweep (Roadmap §4) precedes the general-availability binary. For early adopters and builders.

### 1 · Install the binary

Prebuilt, no toolchain, no clone.

**macOS / Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.sh | sh
```

**Windows** (PowerShell)
```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; iex "& { $(irm https://raw.githubusercontent.com/codedaptive/mootx01-ce/stable/1.0.x/install.ps1) }"
```

Installs to `~/.mootx01/bin`. Re-run to upgrade.

### 2 · Wire it in

```bash
mootx01 install        # interactive — registers MOOTx01 with Claude, Claude Code, or any MCP client
```

This also starts **`moot-mgr`**, the management console, as a background service (launchd · systemd-user · Task Scheduler). It opens a read-only dashboard at **http://127.0.0.1:4200** — health, per-estate state, the write pipeline, an activity log, and a live **Topology** view — plus a gated admin surface. Opt out with `--no-manager`.

### 3 · Prefer to build from source?
 `swift build -c release --package-path apps/aria-mcp-server` (macOS 26+), or `cargo build --release` in `apps/aria-mcp-server/rust` (PC/Linux). The console builds from `apps/moot-mgr` the same way.

## How it works

MOOTx01 is an SDK of composable kits; **GeniusLocusKit** composes them into a working estate, the **Brain** layer makes it dream, and **ARIA** is the one interface in front of all of it.

```
Observe / Remember →  LocusKit (spatial memory + knowledge graph)
                      VectorKit (on-device embeddings + ANN / hybrid search)
                      CorpusKit (content-plus-vector RAG bundles)
Dream              →  NeuronKit (hybrid recall, the dreaming daemon, Bradley-Terry, SolverBandit)
                      CognitionKit (named, composable behaviour recipes)
Compose / Convene  →  GeniusLocusKit (N estates, the matrix layer, federation)
Speak              →  ARIA (MCP server + native app surfaces) — one noun, nine verbs, four adjectives
```

The readable map of the whole repository is [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md).

## For developers

If you're building an application and you want it to have **temporal knowledge** — memory that survives sessions, links to AI, and participates in the user's life — you can embed MOOTx01 directly. Most apps don't have a memory substrate because writing one is hard: the math debt is steep and the speed optimization is harder. You don't have to. MOOTx01 ships as a **kit family**; your application gets its own first-person MOOT and shares whatever the user authorizes with the user's personal MOOT. You focus on what your application does — the substrate is already done.

The interface is **ARIA**: consistent across implementations, surfaces, and languages — the same vocabulary whether you embed as a library, query through an MCP server, or call a native API. In most cases you don't need to rewrite anything: if your app already speaks MCP, your AI can read from it through ARIA and bring what it learns into the user's MOOT. **The app isn't rebuilt — it gains a MOOT beside it.**

---

## For builders: the kit stack

```
Behaviour:
    NeuronKit       AI algorithms: reasoning functions plus autonomic daemons
    CognitionKit    Behaviour layer: named, composable workflows

Composition:
    GeniusLocusKit  Unified substrate: LocusKit + CorpusKit + Brain layer; N estates

Standalone substrate:
    LocusKit        Spatial memory system plus knowledge graph (one estate)
    VectorKit       On-device embeddings plus nearest-neighbour search
    CorpusKit       Content-plus-vector RAG bundles

Grounding:
    EideticLib      Deterministic text-to-anchor (FDC code + Wikidata Q-ID)
    LatticeLib      Frame Decimal Classification: assembler, canon, lookup

Typed math:
    EngramLib       Typed 256-bit Engram API

Foundation:
    SubstrateTypes  Pure substrate types (zero compute)
    SubstrateKernel Hot-path bit ops, write gate, clock
    SubstrateML     Learning + graph algorithms
    SubstrateLib    Orchestration: verbs + row-state automaton
    PersistenceKit  Storage backends: SQLite, PostgreSQL, InMemory
    ConvergenceKit  Sync implementations: CloudKit, Federation, None
    QueueKit        Fill-and-drain job queue: RAM and database backends
    IntellectusLib  Zero-dependency telemetry floor (gated self-report faculty)
    ObserverSink    Telemetry sink + SQLite stats store (the console's read source)
    AriaLexiconLib  Reified ARIA grammar: verbs, nouns, adjectives (zero-dependency)
    VaultKit        Encrypted, portable, file-based estate export/import
```

**Access layer (ARIA):** `aria-mcp` (MCP server — expose any estate to Claude, Claude Code, or any MCP client) · `ARIA_MacOS` / `ARIA_iOS` / `ARIA_Rust` (demonstration apps) · **`moot-mgr`** (the management & monitoring console: a resident multi-estate host with estate provisioning + lifecycle, a self-report dashboard, and a live node-link Topology view — cross-platform web + macOS).

### Build status

Two dimensions are tracked. **Build** = functional with tests green. **Security Review** = the security, quality-control, and hardening gate — **it has not run on any kit yet**, so Review is pending across the board. Build status reflects functionality only; nothing here has been hardened or audited.

| Kit | Build | Security Review |
|-----|-------|--------|
| AriaLexiconLib · CognitionKit · ConvergenceKit · CorpusKit · EideticLib · EngramLib · GeniusLocusKit · IntellectusLib · LatticeLib · LocusKit · NeuronKit · ObserverSink · PersistenceKit · QueueKit · SubstrateKernel · SubstrateLib · SubstrateML · SubstrateTypes · VaultKit · VectorKit | ✅ Built (Swift + Rust) | ⏳ Pending |

Per-kit detail (what each is *for*) lives in [`packages/PACKAGES.md`](packages/PACKAGES.md) and the per-kit specs under [`docs/reference/`](docs/reference/).

## Implementations

Every kit ships in two equal-status implementations, conformance-gated against shared test vectors — neither leads, both must agree bit for bit:

- **Swift** — Apple Silicon, macOS 26+, iOS 26+
- **Rust** — PC/Linux x86_64 and Linux aarch64

Three further ports are on the major-release line:

- **Python** — community edition at v1.0, auto-generated from the stable core. Standalone, single-machine **by design**: the Python build does not federate (federation is trust-critical) and is materially slower on the heavy linear-algebra paths. Right for single-machine use; contributions that exercise the standalone port are welcome.
- **Go** — shortly after v1.0, Enterprise Edition only.
- **C** — the "DOOM edition," v1.5/v2.0, Enterprise Edition only. Built for maximum portability: it runs on anything.

The engineering cookbook lives in [`docs/engineering/`](docs/engineering/); the conformance harness in [`docs/validation/substrate_math_performance/test-harness/`](docs/validation/substrate_math_performance/test-harness/).

## Roadmap

Intended sequence, not committed dates. Items 1–3 shipped in the 1.0.0-beta; 4–8 are ahead.

1. **Finish the Brain layer** — complete NeuronKit (hybrid recall, the dreaming daemon, Bradley-Terry, SolverBandit) and CognitionKit (the behaviour recipes). Everything below them is built. **✅ Shipped (1.0.0-beta).**
2. **Ship the ARIA MCP reference server** — so anyone can compile it and use their MOOT from an agentic chat or coding harness. **✅ Shipped (1.0.0-beta).**
3. **Ship the management & monitoring console (`moot-mgr`)** — the resident host that creates and manages multiple estates (stepped provisioning, per-estate backend, full lifecycle) with a flow-down self-report layer surfaced as a read-only dashboard (health, per-estate state, the write pipeline, an activity log, and a live node-link **Topology** view) plus a gated admin surface. One cross-platform codebase: a loopback web dashboard plus a macOS menu-bar agent. **✅ Shipped (1.0.0-beta).**
4. **Full security sweep** — a complete security, quality-control, and hardening pass across the substrate, the MCP server, and the console. No kit has cleared this gate yet.
5. **Hardened GA binary** — the curl-installable binary ships at 1.0.0-beta for early adopters (see Quickstart); the *general-availability, security-hardened* binary of the MCP server and the console follows the full security sweep (§4) — the first artifact aimed at the wider, non-developer audience is the first one hardened.
6. **Sidecar & embedded examples** — a reference set of apps showing the sidecar and embedding patterns.
7. **Federation** — bounded cross-estate sharing: grant-scoped handshakes that share only what a grant names, with formally bounded noise on aggregate queries. Federation is an access-surface capability (ARIA), not a change to the substrate.
8. **Apple Intelligence integration** — surface a MOOT through Apple's on-device intelligence and App Intents, so capture and recall work natively across the Apple ecosystem.

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
│                 Mootx01-App (Apple app) · moot-math-benchmark · moot-agent-skills
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
