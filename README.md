# MOOTx01

**Long-term memory for AI.**

*Observe · Remember · Dream · Convene*

> The frontier intelligence is rented. The memory is yours.

![status](https://img.shields.io/badge/status-0.8--alpha-orange)
![platforms](https://img.shields.io/badge/platforms-Apple%20Silicon%20·%20PC%2FLinux-blue)
![ports](https://img.shields.io/badge/ports-Swift%20%2B%20Rust%20(byte--identical)-success)
![interface](https://img.shields.io/badge/interface-ARIA%20over%20MCP-purple)
![license](https://img.shields.io/badge/license-open%20core-lightgrey)

MOOTx01 is the layer your AI is missing — the **subconscious** between the context window and the archive. It captures every conversation **verbatim**, **consolidates it while you sleep**, and hands back ranked, theme-aware memory the moment you ask. It runs **where you do** — your laptop, your phone, your home server — and any AI that speaks the Model Context Protocol reads from it through **ARIA**. The intelligence is rented; the memory is owned.

> Full story: [`ABOUT.md`](ABOUT.md) · live site: [mootx01.ai](https://mootx01.ai) · readable front door to the code: [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md)

---

## The gap

Your AI has a **context window**. It is sharp, expensive, and short — everything in it has to be there *right now*, paid for by the token. When the conversation ends, the window closes and the next one starts from nothing. That is short-term memory. It is what your AI *thinks with*. It is not what your AI *remembers from*.

To paper over the forgetting, the industry built **RAG** — a vector database in deep storage that the AI searches on demand. RAG works as far as it goes, but it is the basement archive: the AI filters everything at the moment you ask, on every call, from chaos. Slow, expensive, context-dependent.

What's missing isn't a feature — it's a **layer**. The one you use every night: while you sleep, your subconscious runs cheap deterministic passes over the day, surfaces what mattered, strengthens what repeats, lets the rest fade. By morning, memory is already prepared. **Your AI doesn't have that layer. MOOTx01 is it.**

## Four behaviors

| | |
|---|---|
| **Observe** | Capture every conversation exactly as it happened, in the words it happened in — verbatim, no paraphrase, no silent rewrite. |
| **Remember** | Return ranked, filtered, theme-aware *signal* — not chaotic data — through one consistent grammar. |
| **Dream** | A consolidation layer reweighs what mattered overnight; themes surface, connections strengthen, the answer is prepared *before* you ask. |
| **Convene** | MOOTs gather — home + work, you + your spouse, an app + you — bounded by exactly what you authorize. Nothing centralized, nothing rented. |

## Why MOOTx01

- **Yours, not rented.** It runs on your machine. Your memory belongs where you put it — never parked in someone else's cloud, readable by whoever owns the servers, gone if the vendor changes their mind.
- **Verbatim.** What you said stays said, in the words you said it.
- **Portable across every AI.** Claude, ChatGPT, a local model you run yourself — anything that speaks MCP reads your MOOT through ARIA. Switch tools next month; your memory comes with you.
- **It dreams.** A real consolidation layer (the Brain) prepares recall overnight, so the AI reasons on prepared signal instead of searching the basement on every call.
- **It convenes.** Bounded, private, automatic federation between MOOTs — no central coordinator. You decide what crosses.
- **Apple Silicon *and* PC/Linux, byte-identical.** Swift and Rust ports, conformance-gated against shared test vectors. Neither port leads; both must agree, bit for bit.
- **Deterministic and auditable.** Full audit trail, CRDT convergence, no hidden state. Every computation is reproducible.

## The name

A **moot** was the old assembly where a community brought its memory together — witnessed events, sworn oaths, who decided what last winter. The record lived in the gathering. Modern English kept the word but lost the meaning. We're taking it back, because the older meaning is what memory actually is: observed over time, kept exactly as it was, available across every AI you use.

**You are x01.** Hex 01, first person — the hero of your story, and your MOOT is the gathering of it. There is no MOOTx02; you don't get upgraded to a later you. Your spouse is x01 in theirs, your calendar app is x01 in its domain, and when you authorize it, the MOOTs convene.

---

## Quickstart (0.8-alpha)

> **Status:** 0.8-alpha early access — installable now, **not yet security-hardened**. The full security sweep (Roadmap §4) precedes the general-availability binary; this alpha is for early adopters and builders.

**Install** — prebuilt binary, no toolchain, no clone:

```bash
curl -fsSL https://raw.githubusercontent.com/codedaptive/mootx01-ce/main/install.sh | sh
mootx01 install        # wire it into Claude, Claude Code, or any MCP client (interactive)
```

Downloads the latest mootx01 release to `~/.mootx01/bin`. Upgrade by re-running; uninstall with `… | sh -s -- --uninstall`.

**Management console (macOS)** — the same install drops `moot-mgr`, the management & monitoring console, and `mootx01 install` registers it as a background **launchd** service (starts immediately, restarts at login):

```bash
mootx01 install        # also starts the console in the background
# dashboard → http://127.0.0.1:7077      manual control → moot-mgr serve
```

A read-only dashboard (health, per-estate state, the write pipeline, an activity log, and a live node-link **Topology** view) plus a gated admin surface for estate provisioning and lifecycle. macOS only at 0.8-alpha. Opt out with `mootx01 install --no-manager`.

*Prefer source?* `swift build -c release --package-path apps/ARIA_MCP` (macOS 26+), or `cargo build --release` in `apps/ARIA_MCP/rust` (PC/Linux). The console builds from `apps/moot-mgr` the same way.

Then, from your agent — the ARIA grammar, one verb on a noun:

```jsonc
// file a memory — captured verbatim into your MOOT
moot_file_memory { "content": "We decided to ship the importer behind a flag.", "location": "project/alpha" }

// recall — ranked, filtered, theme-aware signal (not raw chunks)
moot_memory_search { "query": "what did we decide about the importer?" }
```

Same vocabulary whether you embed MOOTx01 as a library, query it through MCP, or call it through a native API.

## How it works

MOOTx01 is a substrate of composable kits; **GeniusLocusKit** composes them into a working estate, the **Brain** layer makes it dream, and **ARIA** is the one interface in front of all of it.

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

**Access layer (ARIA):** `ARIA_MCP` (MCP server — expose any estate to Claude, Claude Code, or any MCP client) · `ARIA_MacOS` / `ARIA_iOS` / `ARIA_Rust` (demonstration apps) · **`moot-mgr`** (the management & monitoring console: a resident multi-estate host with estate provisioning + lifecycle, a self-report dashboard, and a live node-link Topology view — cross-platform web + macOS).

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

Intended sequence, not committed dates:

1. **Finish the Brain layer** — complete NeuronKit (hybrid recall, the dreaming daemon, Bradley-Terry, SolverBandit) and CognitionKit (the behaviour recipes). Everything below them is built.
2. **Ship the ARIA MCP reference server** — so anyone can compile it and use their MOOT from an agentic chat or coding harness.
3. **Ship the management & monitoring console (`moot-mgr`)** — the resident host that creates and manages multiple estates (stepped provisioning, per-estate backend, full lifecycle) with a flow-down self-report layer surfaced as a read-only dashboard (health, per-estate state, the write pipeline, an activity log, and a live node-link **Topology** view) plus a gated admin surface. One cross-platform codebase: a loopback web dashboard plus a macOS menu-bar agent.
4. **Full security sweep** — a complete security, quality-control, and hardening pass across the substrate, the MCP server, and the console. No kit has cleared this gate yet.
5. **Hardened GA binary** — the curl-installable binary ships at 0.8-alpha for early adopters (see Quickstart); the *general-availability, security-hardened* binary of the MCP server and the console follows the full security sweep (§4) — the first artifact aimed at the wider, non-developer audience is the first one hardened.
6. **Sidecar & embedded examples** — a reference set of apps showing the sidecar and embedding patterns.

## Repository structure

```
mootx01/
├── packages/
│   ├── libs/     SubstrateTypes · SubstrateKernel · SubstrateML · SubstrateLib · EngramLib
│   │             AriaLexiconLib · LatticeLib · EideticLib · IntellectusLib · ObserverSink
│   ├── kits/     LocusKit · VectorKit · PersistenceKit · ConvergenceKit · QueueKit
│   │             CorpusKit · GeniusLocusKit · NeuronKit · CognitionKit · VaultKit
│   └── PACKAGES.md
├── apps/         ARIA_MCP (MCP server) · moot-mgr (management console) · MatrixSprint (benchmarks)
├── installer/    First-run installer
└── docs/         start-here · concepts · reference · decisions · engineering · validation · archive
```

## Key documents

| Document | Purpose |
|----------|---------|
| [`ABOUT.md`](ABOUT.md) | What MOOTx01 is and why — the full story |
| [`docs/concepts/TOPOLOGY.md`](docs/concepts/TOPOLOGY.md) | Readable front door: products, stack, surfaces, sidecar |
| [`docs/concepts/MOOTX01_AND_ARIA_CANON.md`](docs/concepts/MOOTX01_AND_ARIA_CANON.md) | Durable definitions of MOOTx01 and ARIA |
| [`docs/concepts/ARIA_LEXICON.md`](docs/concepts/ARIA_LEXICON.md) | The ARIA grammar: one noun, nine verbs, four adjectives |
| [`docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md`](docs/reference/) | Authoritative substrate specification |
| [`EDITIONS.md`](EDITIONS.md) · [`LICENSING.md`](LICENSING.md) | Open core + commercial editions, in plain language |

## Standards

Swift 6 strict concurrency · zero external Swift dependencies in kits (except sqlite-vec in PersistenceKit-SQLite) · raw SQLite via PersistenceKit, no Core Data · dates as TEXT/ISO8601 · no Bool stored properties on entities (bitmap fields) · Metal for GPU compute on Apple Silicon · every computation deterministic.

---

*MOOTx01 is a [Codedaptive](https://codedaptive.com) project. With thanks to Dennis E. Taylor, author of the Bobiverse — the replicants and their moots showed the shape of what we needed, and why.*
