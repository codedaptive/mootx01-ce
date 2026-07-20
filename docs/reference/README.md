---
title: Reference Directory Index
version: 1.0.2
status: active
date: 2026-07-20
description: Index of the reference contract surface — the SPEC and INTERFACE documents for every kit, lib, protocol, and canonical encoder.
authors: MOOTx01 maintainers
relates_to:
  - VERSIONING.md
---

# Reference

Specifications and interfaces. Each kit or lib publishes a paired
`<NAME>_SPEC.md` (the behavioural contract) and `<NAME>_INTERFACE.md`
(the public API surface); cross-cutting protocols and canonical encoders
carry a single spec. This is the contract surface: what each package
publishes and what it promises to consumers. Conceptual framing lives in
[`../concepts/`](../concepts/); the rationale behind each contract lives
in [`../decisions/`](../decisions/); this directory is the authoritative
"what does it do, signed in writing" layer.

The catalog is ordered bottom-up, mirroring the kit stack in
[`../concepts/TOPOLOGY.md`](../concepts/TOPOLOGY.md).

## Foundation libraries

| Package | Spec | Interface | What it is |
|---|---|---|---|
| SubstrateTypes | [SPEC](SUBSTRATETYPES_SPEC.md) | [INTERFACE](SUBSTRATETYPES_INTERFACE.md) | Value types (HLC, Fingerprint256, Row, the matrix carriers) plus algebra primitives (SimHash, Hamming, ORReduce, FNV). Zero-dependency. |
| SubstrateKernel | [SPEC](SUBSTRATEKERNEL_SPEC.md) | [INTERFACE](SUBSTRATEKERNEL_INTERFACE.md) | Kernel dispatch over hardware backends: scalar, SIMD, NEON, Metal, BNNS. |
| SubstrateML | [SPEC](SUBSTRATEML_SPEC.md) | [INTERFACE](SUBSTRATEML_INTERFACE.md) | Learning and graph algorithms (Bradley-Terry, NMF, FFT, centrality, anomaly) plus the ambient-signal extractors. |
| SubstrateLib | [SPEC](SUBSTRATELIB_SPEC.md) | [INTERFACE](SUBSTRATELIB_INTERFACE.md) | Orchestration: the audit write-gate, G-Set audit log, fold/decay, SHA-256, HammingNN. |
| AriaLexiconLib | [SPEC](ARIALEXICONLIB_SPEC.md) | [INTERFACE](ARIALEXICONLIB_INTERFACE.md) | The reified ARIA grammar — one noun, nine verbs, four adjectives, and the verb-noun acceptance matrix. Zero-dependency. |
| IntellectusLib | [SPEC](INTELLECTUSLIB_SPEC.md) | [INTERFACE](INTELLECTUSLIB_INTERFACE.md) | The telemetry/stat primitives the observability surfaces emit through. |
| LoopbackHTTP | [SPEC](LOOPBACKHTTP_SPEC.md) | [INTERFACE](LOOPBACKHTTP_INTERFACE.md) | The loopback-pinned POSIX socket and HTTP/1.1 + SSE transport primitive. |
| ObserverSink | [SPEC](OBSERVERSINK_SPEC.md) | [INTERFACE](OBSERVERSINK_INTERFACE.md) | The PersistenceKit-backed telemetry sink that persists stat samples into SQLite. |
| EngramLib | [SPEC](ENGRAMLIB_SPEC.md) | [INTERFACE](ENGRAMLIB_INTERFACE.md) | The typed 256-bit Engram API over SubstrateLib — similarity, nearest-neighbour, threshold, union. |
| EideticLib | [SPEC](EIDETICLIB_SPEC.md) | [INTERFACE](EIDETICLIB_INTERFACE.md) | Text-to-anchor grounding: an FDC code plus a Wikidata Q-ID, offline and deterministic. |
| LatticeLib | — | [INTERFACE](LATTICELIB_INTERFACE.md) | The FDC encoder (FDCMatcher / FDCRuntime) plus the FDC frame and signatures. |

## Storage, sync, and queue

| Package | Spec | Interface | What it is |
|---|---|---|---|
| PersistenceKit | [SPEC](PERSISTENCEKIT_SPEC.md) | [INTERFACE](PERSISTENCEKIT_INTERFACE.md) | Storage backends behind one protocol: SQLite, PostgreSQL, InMemory. |
| ConvergenceKit | [SPEC](CONVERGENCEKIT_SPEC.md) | [INTERFACE](CONVERGENCEKIT_INTERFACE.md) | Sync backends behind one protocol: CloudKit, Federation, None. |
| QueueKit | [SPEC](QUEUEKIT_SPEC.md) | [INTERFACE](QUEUEKIT_INTERFACE.md) | A fill-and-drain serial job queue (send / drain / watch / reply) over Filesystem, PersistenceKit, and InMemory backends. |

## Substrate kits

| Package | Spec | Interface | What it is |
|---|---|---|---|
| LocusKit | [SPEC](LOCUSKIT_SPEC.md) | [INTERFACE](LOCUSKIT_INTERFACE.md) | Spatial memory and the knowledge graph for one estate — the four nouns, bitmap state, full audit trail. |
| VectorKit | [SPEC](VECTORKIT_SPEC.md) | [INTERFACE](VECTORKIT_INTERFACE.md) | On-device model-tagged vector storage and nearest-neighbour machinery. |
| CorpusKit | [SPEC](CORPUSKIT_SPEC.md) | [INTERFACE](CORPUSKIT_INTERFACE.md) | Standalone-capable RAG database; in GLK, derived indexing over the canonical LocusKit Drawer source. |

## Composition and brain

| Package | Spec | Interface | What it is |
|---|---|---|---|
| GeniusLocusKit | [SPEC](GENIUSLOCUSKIT_SPEC.md) | [INTERFACE](GENIUSLOCUSKIT_INTERFACE.md) | GLK Super System and write surface: composes LocusKit and CorpusKit over one canonical Drawer dataset, exposes the nine verbs, and runs the Brain layer. |
| NeuronKit | [SPEC](NEURONKIT_SPEC.md) | [INTERFACE](NEURONKIT_INTERFACE.md) | The algorithm BrainKit: hybrid recall, the dreaming daemon, Bradley-Terry, SolverBandit. |
| CognitionKit | [SPEC](COGNITIONKIT_SPEC.md) | [INTERFACE](COGNITIONKIT_INTERFACE.md) | The behaviour BrainKit: named, composable workflows (recipes). Sequences NeuronKit; contains no algorithms of its own. |
| VaultKit | — | [INTERFACE](VAULTKIT_INTERFACE.md) | A bidirectional bridge between a MOOTx01 estate and a human-readable vault. |

## Access surfaces

| Surface | Spec | Interface | What it is |
|---|---|---|---|
| aria-mcp | [SPEC](ARIA_MCP_SPEC.md) | [INTERFACE](ARIA_MCP_INTERFACE.md) | The external access surface — the ARIA language projected onto MCP primitives (tools, resources, prompts, sampling, elicitation). |
| moot-mgr | [SPEC](MOOT_MGR_SPEC.md) | — | The GUI control and monitor surface for the headless mootx01 daemon. |
| mootx01 CLI | — | [INTERFACE](INSTALLER_INTERFACE.md) | The Swift CLI / host that installs and runs a MOOTx01 estate. |

## Cross-cutting specifications

**[`GENIUSLOCUS_ARCHITECTURE_SPEC.md`](GENIUSLOCUS_ARCHITECTURE_SPEC.md)** —
the authoritative substrate architecture: estate model, verb surface,
bitmap layouts, audit trail, standing signals, conformance rules. The
contract every conforming implementation must satisfy. Read this first.

**[`FDC_ENCODER_CANONICAL.md`](FDC_ENCODER_CANONICAL.md)** — the
deterministic linguistic pipeline that maps text to a Free Decimal
Correspondence (FDC) code. No learned model, no network call at runtime;
the classification backbone the substrate adopted as its 1.0 scheme. The
former MOOT Decimal Classification Codes (MDCC) taxonomy was removed in
the MDCC→FDC migration; the superseded MDCC specs are kept in
[`../archive/`](../archive/) for history only.

## Conventions

Spec filenames are bare — no version suffix (VERSIONING.md §3). The
version lives in front matter (`version: MAJOR.MINOR.PATCH`). Material
changes are made in place: bump the front-matter `version` and append a
changelog entry — the filename does not change, so citations from code
and other docs stay stable. A spec moves to [`../archive/`](../archive/)
only when it is superseded outright.

Each document opens with a front-matter block (`title`, `version`,
`status`, `date`, `description`, `spec_type`, `authors`, `relates_to`).
Code comments that implement a contract reference the spec by filename;
renaming a spec means updating those code citations.

Reference documents define what is required; decision records explain
why; engineering documents describe how. When in doubt, add the contract
here and the reasoning to [`../decisions/`](../decisions/).
