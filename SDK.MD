# The MOOTx01 Framework SDKs

**The engines are open. The intelligence is the product.**

Seventeen libraries and kits from the MOOTx01 Framework are open source under
the Apache License 2.0 — published today, not on a timer. They are the engines
MOOTx01 itself runs on: memory storage, knowledge graph, vector search, RAG
bundles, deterministic grounding, persistence, sync, and the typed substrate
underneath all of it.

If you want to build your own memory system, have at it. These are real,
production-grade engines, not a teaser. If you want the system that already
knows what to trust, when to recall, what to consolidate, and how to talk to
your AI out of the box — that is MOOTx01, and it lives in this repository.

This document is the detailed map. The short version is in the
[README](TECHNICAL_OVERVIEW.md#developer-sdks).

---

## The four venue repositories

Each venue is generated from the canonical MOOTx01 source tree by the library
publisher. Every release records its exact source commit in `SOURCE.md` and
its load manifest in `docs/PUBLISH_REPORT.md` — full provenance, per release.
Both implementations ship in every venue: Swift and Rust, byte-identical,
conformance-gated against shared test vectors.

### [`moot-core`](https://github.com/codedaptive/moot-core) — the typed substrate

| Package | What it is |
|---|---|
| `SubstrateTypes` | Pure substrate types — the shared vocabulary of the whole framework |
| `SubstrateKernel` | Hot-path bit operations, the write gate, the clock |
| `SubstrateML` | Learning and graph algorithms |
| `SubstrateLib` | Orchestration: verbs and the row-state automaton |
| `EngramLib` | The typed 256-bit Engram API — the framework's core unit of memory math |
| `IntellectusLib` | The telemetry floor |

**Use it when:** you want the deterministic, typed foundation — the same
bit-level contracts MOOTx01 is built on — under your own system.

### [`moot-system`](https://github.com/codedaptive/moot-system) — storage and services

| Package | What it is |
|---|---|
| `PersistenceKit` | Storage backends: SQLite, PostgreSQL, InMemory |
| `QueueKit` | Fill-and-drain job queue |
| `ConvergenceKit` | Sync implementations: CloudKit, Federation, None |
| `ObserverSink` | Telemetry sink plus SQLite stats store |
| `LoopbackHTTP` | Minimal loopback HTTP transport |

**Use it when:** you need durable storage, background work, sync, or telemetry
with the same determinism guarantees as the rest of the framework.

### [`moot-memory`](https://github.com/codedaptive/moot-memory) — the memory engines

| Package | What it is |
|---|---|
| `LocusKit` | Spatial memory system plus knowledge graph |
| `VectorKit` | On-device embeddings plus nearest-neighbour and hybrid search |
| `CorpusKit` | Content-plus-vector RAG bundles |

**Use it when:** you are building memory, search, or retrieval into your own
application — this is the layer most builders want first.

### [`moot-semantics`](https://github.com/codedaptive/moot-semantics) — vocabulary and grounding

| Package | What it is |
|---|---|
| `AriaLexiconLib` | The reified ARIA grammar — one noun, nine verbs, four adjectives |
| `LatticeLib` | Frame Decimal Classification: assembler, canon, lookup |
| `EideticLib` | Deterministic text-to-anchor (FDC code + Wikidata Q-ID) |

**Use it when:** you want deterministic semantic grounding — the same text in,
the same anchor out, every time, no model in the loop.

---

## Installing

SwiftPM — depend on a venue directly:

```swift
.package(url: "https://github.com/codedaptive/moot-memory.git", from: "1.0.5")
```

Cargo — git dependency; each repo's `docs/PACKAGE_MAP.md` lists the crate names:

```toml
[dependencies]
locuskit = { git = "https://github.com/codedaptive/moot-memory", tag = "v1.0.5" }
```

No clone of this repository is required. The venues are self-contained.

---

## What the SDKs give you

With the four venues you can build, on your own terms:

- **Store and structure** — a spatial memory store with a knowledge graph,
  persisted to SQLite or PostgreSQL, synced or standalone
- **Find** — on-device embeddings, approximate-nearest-neighbour and hybrid
  search, content-plus-vector retrieval bundles
- **Ground** — deterministic anchoring of text to stable identifiers, with a
  formal classification lattice
- **Compute** — 256-bit typed memory math, graph and learning algorithms, a
  deterministic kernel

That is a complete engine room. Storage, retrieval, grounding, math. Apache
licensed, commercial use welcome, no Competing Use restriction, no timer.

## What MOOTx01 adds

MOOTx01 — this repository — is what happens when those engines get a brain and
a voice. The product core adds:

**Composed recall — `GeniusLocusKit`.** Not one memory store but N estates,
with grants, a matrix layer, and recall that composes across them. The SDKs
give you a memory; MOOTx01 gives you an estate of them that behaves as one.

**The Brain — `NeuronKit`.** Hybrid recall fusion across signals. Shaped
recall for associative, fusion-steered retrieval. A distilled tier for
compact factoid answers. The dreaming daemon that consolidates memory in the
background — strengthening what matters, linking what relates. Bradley-Terry
trust scoring so the system knows what it believes. Contradiction and drift
detection so it notices when the story changes.

**Judgment — `CognitionKit`.** Twenty-plus reasoning lenses — themes, drift,
contradiction, precedence, keystones, free association, trust synthesis — and
named, composable behaviour recipes that turn tool calls into workflows.

**The voice — `AriaMcpKit`.** Sixty-plus `moot_*` tools over the Model Context
Protocol. Any MCP client — Claude Code, Cursor, Codex, and the rest — speaks
to your memory with zero integration code.

**Portability — `VaultKit`.** Encrypted, portable estate export and import.
Your memory moves when you do.

**The product experience.** The `mootx01` CLI and installer with three
integration depths (server → skills → plugin), native client plugins, the
`moot-mgr` dashboard, the resident daemon, and native installers for macOS,
Windows, and Linux.

## The decision test

Ask one question: *do you want to build a memory system, or do you want your
AI to have one?*

- **Build one** → the SDKs. You get the same engines MOOTx01 uses, under
  Apache 2.0, and every design decision is yours.
- **Have one** → [install MOOTx01](README.md#install-in-60-seconds). Two
  commands, and every MCP client on your machine has long-term memory with a
  brain behind it.
- **Both** → common in practice: embed `moot-memory` in your product, run
  MOOTx01 beside it as the user-facing memory estate. The ARIA vocabulary is
  the same on both sides.

## Licensing, in one paragraph

Which license governs is determined by where you obtain the code. Code from a
venue repository is Apache-2.0 — everything that license permits, including
commercial and hosted use. The same package source obtained as part of this
repository is governed by this repository's FSL grant (FSL-1.1-ALv2:
source-available, free to build and share, pay to profit, each version
converting to Apache 2.0 two years after release). The product core —
GeniusLocusKit, NeuronKit, CognitionKit, VaultKit, and the applications — is
FSL in this repository. The full plain-language model and tier ladder is in
[`LICENSING.md`](LICENSING.md); the editions story is in
[`EDITIONS.md`](EDITIONS.md).

---

*The MOOTx01 Framework venues are generated and published from the canonical
source tree with per-release provenance. MOOTx01 is a
[Codedaptive](https://codedaptive.com) project.*
