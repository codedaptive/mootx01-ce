# MOOTx01

A monorepo of composable personal knowledge kits for Apple Silicon and PC/Linux.

The kits are organised into two products:

**MOOTx01** is the personal knowledge substrate. A family of composable kits covering math primitives, storage, sync, queuing, the access grammar, spatial memory, vector search, RAG, classification, grounding, and orchestration. They can be used independently or composed into the full GeniusLocusKit estate. The full product is GeniusLocusKit in union with the two BrainKits, NeuronKit and CognitionKit.

**ARIA** is the access layer. An MCP server (ARIA_MCP) and demonstration app targets (ARIA_MacOS, ARIA_iOS, ARIA_Rust) that expose MOOTx01 estates to AI tools and end users.

Start here: [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md) is the readable front door to the whole repository.

---

## MOOTx01 Kit Stack

```
Behaviour:
    NeuronKit      AI algorithms: reasoning functions plus autonomic daemons
    CognitionKit   Behaviour layer: named, composable workflows

Composition:
    GeniusLocusKit Unified substrate: LocusKit + CorpusKit + Brain layer; N estates

Standalone substrate:
    LocusKit       Spatial memory system plus knowledge graph (one estate)
    VectorKit      On-device embeddings plus nearest-neighbour search
    CorpusKit         Content-plus-vector RAG bundles

Grounding:
    EideticLib      Deterministic text-to-anchor (FDC code + Wikidata Q-ID)
    LatticeLib      Frame Decimal Classification: assembler, canon, lookup

Typed math:
    EngramLib      Typed 256-bit Engram API

Foundation:
    SubstrateTypes   Pure substrate types (zero compute)
    SubstrateKernel  Hot-path bit ops, write gate, clock
    SubstrateML      Learning + graph algorithms
    SubstrateLib     Orchestration: verbs + row-state automaton
    PersistenceKit     Storage backends: SQLite, PostgreSQL, InMemory
    ConvergenceKit        Sync implementations: CloudKit, Federation, None
    QueueKit       Fill-and-drain job queue: RAM and database backends
    AriaLexiconLib    Reified ARIA grammar: verbs, nouns, adjectives (zero-dependency)
```

---

## ARIA Access Layer

```
ARIA_MCP       MCP server: exposes any MOOTx01 estate to AI tools
ARIA_MacOS     macOS demonstration app
ARIA_iOS       iOS demonstration app (Rev 3.0, after macOS stable)
ARIA_Rust      Rust demonstration app (required for conformance parity)
```

---

## Kit Summary

Two status dimensions are tracked. **Build** is whether the kit is functional with its tests green. **Review** is the security, quality-control, and slop-review gate. That gate has not run on any kit yet, so Review is pending across the board: build status reflects functionality only, and nothing here has been hardened or audited.

### MOOTx01

| Kit | Use it to build | Build | Security Review |
|-----|-----------------|-------|--------|
| **AriaLexiconLib** | The reified ARIA grammar: verbs, nouns, adjectives, and the acceptance matrix, with zero dependencies | ✅ Built (Swift + Rust) | ⏳ Pending |
| **CognitionKit** | Behaviour recipes: named, composable workflows (18 recipes, descriptor conformance-gated) | ✅ Built (Swift + Rust) | ⏳ Pending |
| **ConvergenceKit** | Sync abstraction: CloudKit, Federation, None behind one protocol | ✅ Built (Swift + Rust) | ⏳ Pending |
| **CorpusKit** | A private RAG database: content-plus-vector bundles, hybrid retrieval, no cloud dependency | ✅ Built (Swift + Rust) | ⏳ Pending |
| **EideticLib** | Deterministic text-to-anchor: term in, FDC code plus Wikidata Q-ID out; ships with a frozen reference snapshot | ✅ Built (Swift + Rust) | ⏳ Pending |
| **EngramLib** | Typed 256-bit Engram API on SubstrateLib | ✅ Built (Swift + Rust) | ⏳ Pending |
| **GeniusLocusKit** | Spatial memory + RAG + knowledge graph: nine verbs, Brain layer, N estates | ✅ Built (Swift + Rust) | ⏳ Pending |
| **IntellectusLib** | Zero-dependency telemetry floor: the stat model, the sink protocol, and the gated self-report faculty each kit uses to record its own layer's stats (off is free — a single atomic-bool check) | ✅ Built (Swift + Rust) | ⏳ Pending |
| **LatticeLib** | Frame Decimal Classification: original Dewey-like spine, clean-room from Wikidata CC0, assembler + canon + lookup | ✅ Built (Swift + Rust) | ⏳ Pending |
| **LocusKit** | A spatial memory system: wings, rooms, drawers, typed tunnels, KG facts, bitmap-indexed content, full audit trail | ✅ Built (Swift + Rust) | ⏳ Pending |
| **NeuronKit** | AI algorithms: hybrid recall, dreaming daemon, Bradley-Terry, SolverBandit | ✅ Built (Swift + Rust) | ⏳ Pending |
| **ObserverSink** | The reusable telemetry sink + stats store: a PersistenceKit-backed `StatsSink` that serialises self-report samples into a local, sync-disabled SQLite stats database with retention — the read-plane data source for the management console | ✅ Built (Swift + Rust) | ⏳ Pending |
| **PersistenceKit** | Storage abstraction: SQLite, PostgreSQL, InMemory backends behind one protocol | ✅ Built (Swift + Rust) | ⏳ Pending |
| **QueueKit** | A fill-and-drain job queue: RAM and database backends, serial dispatch, audit-ordered claims | ✅ Built (Swift + Rust) | ⏳ Pending |
| **SubstrateKernel** | Hot-path bit operations: SimHash/Hamming kernels, content + seal hashing, bitmap fields, kernel dispatch (scalar/SIMD/Metal) | ✅ Built (Swift + Rust) | ⏳ Pending |
| **SubstrateLib** | Substrate orchestration: the nine verbs, the row-state automaton, and the AuditGate over the three substrate sub-packages | ✅ Built (Swift + Rust) | ⏳ Pending |
| **SubstrateML** | Cold-path learning + graph algorithms: community detection, eigenvalue centrality, NMF, association rules, anomaly, matrix decay | ✅ Built (Swift + Rust) | ⏳ Pending |
| **SubstrateTypes** | The data bedrock: Fingerprint256, HLC, the audit CRDT, and the value types every kit speaks — zero compute | ✅ Built (Swift + Rust) | ⏳ Pending |
| **VaultKit** | Encrypted vault export/import: the `moot_vault_*` bridge for portable, file-based estate snapshots | ✅ Built (Swift + Rust) | ⏳ Pending |
| **VectorKit** | On-device semantic search: embed locally, store model-tagged vectors, query by ANN (HNSW) or hybrid BM25-plus-vector | ✅ Built (Swift + Rust) | ⏳ Pending |

### ARIA

| Target | Purpose | Build | Review |
|--------|---------|-------|--------|
| **ARIA_MCP** | MCP server: expose any estate to Claude, Claude Code, OB1, or any MCP client | 🔧 In progress (LAUNCH-04) | ⏳ Pending |
| **ARIA_MacOS** | macOS demonstration: shows the sidecar pattern over the SDK | 🔲 After ARIA_MCP | ⏳ Pending |
| **ARIA_iOS** | iOS demonstration: Rev 3.0, after macOS stable | 🔲 After ARIA_MacOS | ⏳ Pending |
| **ARIA_Rust** | Rust demonstration: required for conformance parity with Swift demos | 🔲 After ARIA_MacOS | ⏳ Pending |
| **moot-mgr** | Management & monitoring console: the resident multi-estate host — estate provisioning + lifecycle, the self-report monitoring dashboard (server/estates/pipeline/activity), and the live node-link Topology view; cross-platform web + macOS menu-bar | 🔧 Foundation built | ⏳ Pending |

**Legend.** ✅ Built means functional with tests green. 🔧 In progress means a stream is live against it. 🔲 means planned, with the mission or gating dependency shown. ⏳ Review pending means the kit has not yet cleared the security, quality-control, and slop-review gate; no kit has cleared it yet.

---

## Implementations

Most MOOTx01 kits ship in two equal-status implementations, conformance-gated against shared test vectors:

- **Swift** for Apple Silicon, macOS 15+, iOS 18+
- **Rust** for PC/Linux x86_64 and Linux aarch64

LatticeLib is currently Swift-only; its Rust port is pending. The remaining built kits ship both Swift and Rust ports.

Three further implementations are on the major-release line:

- **Python**, arriving in the community edition at v1.0, auto-generated from the stable core and matured through community testing and validation. It is a standalone, single-machine build by design: the Python build does not federate, and will not. We like Python and use it, but do not consider it the right tool for this job — federation is trust-critical, and the standalone Python build is meant for the single-machine use cases where that bar does not apply. It is also materially slower on the heavy linear-algebra paths than the Swift, Rust, and compiled builds. Contributions that exercise and validate the standalone port are welcome.
- **Go**, available shortly after v1.0, in the Enterprise Edition only. Contact us for details.
- **C**, the "DOOM edition," planned for v1.5 or v2.0, in the Enterprise Edition only. Built for maximum portability — it runs on anything. Availability to be announced.

The engineering cookbook lives in `docs/engineering/`; the conformance test harness lives in `docs/validation/substrate_math_performance/test-harness/`.

---

## Roadmap

The near-term path to a usable release, in order:

1. **Finish the Brain layer.** Complete NeuronKit (the AI algorithms — hybrid recall, the dreaming daemon, Bradley-Terry, SolverBandit) and CognitionKit (the named, composable behaviour recipes). These are the last two kits in the stack; everything below them is built.
2. **Ship the ARIA MCP reference server.** A reference implementation of the MCP server that exposes a MOOTx01 estate over the ARIA grammar, so anyone can compile it and use their MOOT from an agentic chat or coding harness — Claude, Claude Code, or any MCP-capable client.
3. **Ship the management & monitoring console (`moot-mgr`).** The operator's application for running and watching MOOTs. It is the resident host that **creates and manages multiple estates** — a stepped provisioning flow with a per-estate backend (SQLite, PostgreSQL, or in-memory) and full lifecycle (mount, quiesce, drain, destroy) — and a **self-reporting monitoring layer** where each kit records the facts about its own layer, behind a flow-down on/off switch, into a local stats database. That data surfaces as a read-only dashboard (server health, per-estate state, the write pipeline, an activity log, and a live node-link **Topology** view of the knowledge graph) plus a gated admin surface for the privileged actions. It is built cross-platform — a web dashboard served over loopback plus a macOS menu-bar agent — so it serves both the Swift and the PC/Linux builds from one codebase.
4. **Full security sweep.** A complete security, quality-control, and hardening pass across the substrate, the MCP server, and the management console. No kit has cleared this gate yet; this is where that happens, before any of it is put in front of people who did not build it themselves.
5. **Binary package for non-compiler users.** A precompiled, installable binary of the MCP reference server and the management console, so people who do not want to build from source can install a hardened binary and run it. The binary follows the security sweep deliberately: the first artifact aimed at non-developers is also the first one that has been hardened.
6. **Multilple Side Car and Small Expriement apps with embedded** A reference set of application to increase awareness of the sidecar and embedding possibilities in the system
7. And a rather large number of idea roadblock by several days getting the house in order for you'all to be able to navigate all this

This roadmap describes intended sequence, not committed dates.

---

## Repository Structure

Each kit is a Swift Package with its Rust port nested under `rust/`, conformance-gated against shared vectors.

```
mootx01/
├── packages/
│   ├── libs/
│   │   ├── SubstrateTypes/    Pure substrate types (zero compute)
│   │   ├── SubstrateKernel/   Hot-path bit ops, write gate, clock
│   │   ├── SubstrateML/       Learning + graph algorithms
│   │   ├── SubstrateLib/      Orchestration: verbs + row-state automaton
│   │   ├── EngramLib/         Typed Engram API
│   │   ├── AriaLexiconLib/    Reified ARIA grammar
│   │   ├── LatticeLib/        Frame Decimal Classification (Swift + Rust)
│   │   ├── EideticLib/        Text-to-anchor utility
│   │   ├── IntellectusLib/    Zero-dependency telemetry floor (gated self-report faculty)
│   │   └── ObserverSink/      Telemetry sink + SQLite stats store (read-plane source)
│   ├── kits/
│   │   ├── LocusKit/          Spatial memory + KG
│   │   ├── VectorKit/         Vector search
│   │   ├── PersistenceKit/    Storage backends
│   │   ├── ConvergenceKit/    Sync implementations
│   │   ├── QueueKit/          Fill-and-drain job queue
│   │   ├── CorpusKit/         RAG bundles
│   │   ├── GeniusLocusKit/    Composition + Brain layer
│   │   ├── NeuronKit/         AI algorithms
│   │   ├── CognitionKit/      Behaviour recipes (18 recipes)
│   │   └── VaultKit/          Encrypted vault export/import (moot_vault_*)
│   ├── PACKAGES.md            Package catalog
├── apps/
│   ├── ARIA_MCP/              MCP server exposing ARIA over the network
│   ├── moot-mgr/             Management & monitoring console (resident host; in progress)
│   └── MatrixSprint/          Cross-language benchmark harness (in progress)
├── examples/
│   ├── SDK/                   SDK samples
│   └── Sidecar_Demo_macOS/    macOS sidecar demo
├── installer/                 First-run installer
├── docs/
│   ├── start-here/            Orientation guides for new readers
│   ├── concepts/              Canonical definitions, topology, kit map, case studies
│   │   ├── ARIA.md                ARIA interface overview
│   │   └── ARIA_LEXICON.md        ARIA grammar (one noun, nine verbs, four adjectives)
│   ├── reference/             Per-kit SPECs and INTERFACEs + cross-cutting specs
│   ├── decisions/             Architecture decision records (ADRs)
│   ├── engineering/           Cookbooks and methodology
│   ├── validation/            Claims ledger, design constraints, test harness
│   ├── archive/               Superseded specs and historical material
│   ├── templates/             SPEC and INTERFACE templates for per-kit docs
├── ABOUT.md                   What MOOTx01 is and why  
├── CONTRIBUTING.md            Contributing to MOOTx01
├── EDITIONS.md                Open core + commercial edition
├── LICENSING.md               Licensing model in plain language
├── LICENSE                    Full legal grant
├── README.md                  This file  
└── SCHEMA_STATUS.md           NOTICE SCHEMA not yet frozen 
```

---

## Key Documents

| Document | Purpose |
|----------|---------|
| `docs/concepts/TOPOLOGY.md` | Readable front door: products, stack, MDCC, license, surfaces, sidecar |
| `docs/concepts/MOOTX01_AND_ARIA_CANON.md` | Durable definitions of MOOTx01 and ARIA |
| `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md` | Authoritative substrate specification |
| `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md` | The kit-graph architecture and mission sequence |
| `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md` | Reference cookbook for all algorithms |
| `docs/concepts/ARIA.md`, `docs/concepts/ARIA_LEXICON.md` | The ARIA interface and its grammar |

---

## Standards

- Swift 6 strict concurrency throughout
- Zero external Swift package dependencies in kits (except sqlite-vec in PersistenceKit-SQLite)
- Raw SQLite via PersistenceKit, no Core Data
- Date storage as TEXT (ISO8601), never REAL
- No Bool stored properties on entities, bitmap fields only
- Metal framework for GPU compute (Apple Silicon)
- Apple OSLog, subsystem `com.mootx01.kit`
