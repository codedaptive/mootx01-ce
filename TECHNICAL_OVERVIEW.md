# MOOTx01 Technical Overview

How MOOTx01 is built, organized, validated, and extended.

[![SDKs](https://img.shields.io/badge/SDKs-4%20Apache--2.0%20library%20repos-8A2BE2)](#developer-sdks)
![ports](https://img.shields.io/badge/ports-Swift%20%2B%20Rust%20(byte--identical)-success)
![interface](https://img.shields.io/badge/interface-ARIA%20over%20MCP-purple)

This is the technical companion to the [README](README.md), which covers what
MOOTx01 is and how to get it working. Package-level integration instructions
live in [`SDK.MD`](SDK.MD); the authoritative architectural map is
[`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md).

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
[direct stdio mode](README.md#if-you-want-a-more-secure-local-setup) instead of keeping
the resident HTTP listener.
The [continuous security review record](docs/validation/audits/AUDIT_CONTINUOUS_SECURITY_REVIEW_2026-07-22.md)
documents **537 remediated security finding records** from June 25 through
July 22, 2026. The linked [finding ledger](docs/validation/audits/SECURITY_FINDING_REMEDIATION_LEDGER_2026-07-22.md)
names every issue and its fix or closing commit.

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
| [`ROADMAP.md`](ROADMAP.md) | The public path from personal agentic memory to Federation and Postgres scale |
| [`AI_START_HERE.md`](AI_START_HERE.md) | For an AI assistant: explain MOOTx01 and install it for the user |
| [`docs/start-here/END_USER_EXPLAINER.md`](docs/start-here/END_USER_EXPLAINER.md) | Plain-language explainer for a non-technical user |
| [`docs/start-here/INSTALL_SURFACE.md`](docs/start-here/INSTALL_SURFACE.md) | Install fact sheet: addresses, flow, platform matrix, verification |
| [`docs/start-here/SDK_QUICKSTART.md`](docs/start-here/SDK_QUICKSTART.md) | Build on the substrate: open an estate, capture → recall (Swift + Rust) |
| [`docs/start-here/OBSIDIAN_VAULT.md`](docs/start-here/OBSIDIAN_VAULT.md) | Current on-demand vault workflow and planned 1.1 continuous mode |
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
| [`docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md`](docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md) | Authoritative substrate specification |
| [`EDITIONS.md`](EDITIONS.md) · [`LICENSING.md`](LICENSING.md) | Open core + commercial editions, in plain language |

## Standards

Swift 6 strict concurrency · external dependencies declared per package (including swift-crypto, postgres-nio, swift-nio-ssl, and sqlite-vec where used) · raw SQLite via PersistenceKit, no Core Data · dates as TEXT/ISO8601 · no Bool stored properties on entities (bitmap fields) · Metal for GPU compute on Apple Silicon · every computation deterministic.
