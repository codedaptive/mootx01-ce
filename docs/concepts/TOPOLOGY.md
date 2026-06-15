---
title: MOOTx01 Topology
status: canon
authors: MOOTx01 maintainers
date: 2026-06-14
version: 1.0.0
description: A readable front door to the repository — the two products, the kit stack, FDC, the license shape, and how a developer reaches the substrate.
---

# MOOTx01 Topology

A readable front door to the repository. Read this once and you should know what the two products are, how the kits stack, what FDC is, what the license shape is, how a developer reaches the substrate, and how an existing app adopts it. Engineering detail lives in `docs/reference/` and `docs/concepts/MOOTX01_AND_ARIA_CANON.md`; this document is the map.

## The two products

**MOOTx01** is the personal knowledge substrate. It is a family of composable kits that store, search, relate, and reason over a person's knowledge, runs locally, and is owned by the user. A single running instance is a MOOT. The product is GeniusLocusKit in union with the two BrainKits (NeuronKit and CognitionKit).

**ARIA** is the language inside the product. ARIA expands as Augmented Recall and Inference Architecture. It is the interface specification and its grammar — one noun, nine verbs, four adjective categories — not a server, a library, or a product. ARIA is what makes a MOOT portable and reachable across implementations. ARIA stays open and free for everyone; the user's estate stays private to the user. You do not sell ARIA. You sell MOOTx01, and ARIA is the property that makes it portable and ownable.

The grammar is reified in `AriaLexiconLib`, the single source of truth: every call is one verb applied to a noun, optionally constrained by adjectives. The authoritative statements are [`ARIA.md`](ARIA.md) (the interface overview) and [`ARIA_LEXICON.md`](ARIA_LEXICON.md) (the grammar).

## The kit stack

The kits compose bottom-up. Each layer assumes only the layers below it.

```
Behaviour
    CognitionKit       Named, composable workflows (recipes)
    NeuronKit          AI algorithms: hybrid recall, dreaming, branch scoring

Composition (the write surface)
    GeniusLocusKit     LocusKit + CorpusKit unified into one estate; nine verbs;
                       Brain layer (standing-signal daemons, matrix tier,
                       training daemon); persistence via QueueKit over PersistenceKit

Standalone substrate
    LocusKit           Spatial memory + knowledge graph (one estate)
    CorpusKit             Content-plus-vector RAG bundles
    VectorKit          On-device embeddings + nearest-neighbour search (HNSW)

Grounding
    EideticLib          Text-to-anchor: delegates to LatticeLib's FDC encoder
                       to classify (FDC code) and resolve (Wikidata Q-ID).
                       Standalone peer of the substrate kits, no substrate dependency.
    LatticeLib            Free Decimal Correspondence (FDC): the encoder
                       (FDCMatcher / FDCRuntime) plus the FDC frame and
                       signatures, the classification surface EideticLib consumes.

Typed math
    EngramLib          Typed 256-bit Engram API over SubstrateLib

Foundation
    SubstrateTypes     Value types: HLC, Fingerprint256, Row, RowState/RowVerb,
                       AuditEvent, NounType, LatticeAnchor, CountVector256,
                       Hyperplane{Family}, MatrixF/C/O/T, TimeRange. Algebra
                       primitives: SimHash, Hamming, ORReduce, BitwiseArithmetic,
                       FNV. Zero-dependency.
    SubstrateKernel    Kernel dispatch (PortableKernel) over hardware backends:
                       scalar, SIMD, NEON, Metal, BNNS. Over SubstrateTypes.
    SubstrateML        Learning + graph algorithms: BradleyTerry, NMF, FFT,
                       FloatSimHash, RandomWalks, EigenvalueCentrality,
                       LatticeDistance, UDCTreeDistance, AnomalyDetection,
                       and the ambient-signal extractors (CoreLocation,
                       EventKit, HealthKit, ScreenTime, SystemTelemetry).
                       Over SubstrateTypes + SubstrateKernel.
    SubstrateLib       Orchestration: AuditGate (write gate), GSetAuditLog,
                       AuditLogFold, RowStateAutomaton, MatrixDecay, BitField,
                       SHA256, HammingNN. Depends on SubstrateTypes, SubstrateKernel,
                       and SubstrateML directly (no umbrella re-export).
    PersistenceKit         Storage backends: SQLite, PostgreSQL, InMemory.
                       Over SubstrateLib + SubstrateTypes.
    ConvergenceKit            Sync backends: CloudKit, Federation, None.
                       Over PersistenceKit + SubstrateLib + Crypto.
    QueueKit           Fill-and-drain job queue: RAM and database backends.
                       Over PersistenceKit + SubstrateLib.
    AriaLexiconLib        Reified ARIA grammar (zero-dependency).
```

### How the layers compose

Foundation has eight kits: the four-package substrate (SubstrateTypes → SubstrateKernel → SubstrateML → SubstrateLib; each consumer depends on the precise sub-package it uses, with no umbrella re-export), PersistenceKit, QueueKit and ConvergenceKit (peers that share SubstrateLib and chain QueueKit and ConvergenceKit on top of PersistenceKit), and the zero-dependency AriaLexiconLib. These are not five independent peers: PersistenceKit takes SubstrateLib and SubstrateTypes; ConvergenceKit and QueueKit take SubstrateLib and PersistenceKit; the substrate split itself defines an internal ordering. The Foundation still bottoms out at SubstrateTypes and AriaLexiconLib, neither of which has any dependency. EngramLib lifts SubstrateLib's bytes into a typed 256-bit Engram. EideticLib sits beside the substrate as a standalone grounding utility: it produces anchors (FDC code + Wikidata Q-ID + confidence) via LatticeLib's FDC encoder and is consumed by the layers above without being part of them — it imports no substrate kit and is licensed independently.

Standalone substrate is three usable estates in their own right: LocusKit for spatial memory and the knowledge graph, VectorKit for on-device semantic search, CorpusKit for content-plus-vector bundles. Each is shippable on its own.

The grounding pair, LatticeLib and EideticLib, sits beside the substrate rather than under it. LatticeLib is the code-and-data side: the FDC encoder (`FDCMatcher` / `FDCRuntime`) plus the FDC frame and signatures it matches against. EideticLib is the lookup side: `EideticLib.lookup` delegates to LatticeLib's `FDC.encodeAnchor`, canonicalizing a term to a concept bag, matching it against the pinned FDC signatures, and emitting an anchor (FDC code + dominant Wikidata Q-ID + confidence). Both ship with frozen FDC reference artifacts so they work out of the box; neither imports a substrate kit.

GeniusLocusKit is the composition layer and the write surface. It unifies LocusKit and CorpusKit (which itself sits over VectorKit) into one estate, exposes the nine verbs of the ARIA grammar against that estate, coordinates persistence through QueueKit over PersistenceKit, and runs the Brain layer: standing-signal daemons (dreaming, maintenance, vector-similarity, decay-sweep, byReference-validity, end-of-day-tournament), the matrix tier (F/C/O/T families with calibration and NMF), and a training daemon gated by manifest-set transition counts.

The BrainKits sit on top. NeuronKit is the algorithm BrainKit: reasoning functions and autonomic daemons (hybrid recall, dreaming, Bradley-Terry, SolverBandit). CognitionKit is the behaviour BrainKit: named, composable workflows. A MOOTx01 instance is GLK plus both BrainKits.

### Instance mode and the write surface

A single MOOTx01 instance runs in GLK mode. The write surface is always GLK; every write goes through it, and GLK keeps the underlying databases in sync via QueueKit over PersistenceKit. Reads may be taken in narrower lenses on the same instance — a CorpusKit-only query, a LocusKit-only query — but those are read projections of the union, not separate writable stores. Narrowing applies to reads; writing is uniformly GLK.

This applies to estate mode. When consuming kits independently via the SDK (LocusKit, CorpusKit, VectorKit standalone), GLK is not required and writes go directly to the kit. See `packages/SDK.md` for the independently-consumable kit model.

At the API layer an operator may configure many separate instances of different kinds (for example three CorpusKit, two LocusKit, three GeniusLocus) and route each call to the database it belongs to. That route-to-the-right-database behaviour is an API-layer concern, not something inside a single instance.

## FDC, the classification spine

**FDC**, Free Decimal Correspondence, is the public-domain decimal classification frame MOOTx01 adopted as its v1.0 classifier. The notation is Dewey-like — a code's structure encodes where a concept sits in the tree — and it carries no license, so it can be opened, adopted, and federated freely. (An earlier MOOT-original taxonomy, MDCC, was removed in the MDCC→FDC migration; FDC is the shipped scheme.)

The engine lives in **LatticeLib**: the FDC encoder (`FDCMatcher` / `FDCRuntime`), the FDC frame (the code tree), and the FDC signatures (the weighted concept-to-code mapping the matcher scores against). The full encoder pipeline is documented in `docs/reference/FDC_ENCODER_CANONICAL.md`.

EideticLib consumes FDC. `EideticLib.lookup` delegates to `FDC.encodeAnchor`: a term is canonicalized to a concept bag, the bag is matched against the pinned FDC signatures, and the result is an anchor — an FDC code plus the bag's dominant Wikidata Q-ID. Resolution is offline and deterministic against the pinned FDC artifacts; the network is never consulted. EideticLib also carries the valid-but-unknown-code state: a well-formed FDC code the instance does not yet recognize is stored and round-tripped intact, queryable as pending, and resolved once it is learned.

## The license shape

Free to build and share, pay to profit. Make something new and free with it, go forward, no permission. Profit from what you built with it, get a license. The blocked act is offering for money what you built with the code, not who you are.

The tiers:

| Tier | Price | Covers |
|------|-------|--------|
| Personal use | Free, forever | Any individual using MOOTx01 for their own life |
| Build and share free | Free | Building and sharing non-paid work |
| Mobile app | $100 lifetime | Compiling into a for-sale mobile app, all of vX.y |
| Corporate internal | $500 lifetime | Internal-facing applications, all of vX.y |
| Service provider | $5,000 / year | Hosting MOOTs as a service for third parties |
| FedRAMP | Negotiated | Commercial, hardening kept out of the open core |

A lifetime tier covers every point release within the major; the next major is a new purchase. The mechanism is a dual license on a source-available core: the public license states the free-to-build, no-selling grant, and the paid tiers are separate agreements alongside it. The launch ships a source-available, free-to-build, pay-to-profit grant; PolyForm-family and the Functional Source License are the proven precedents.

EideticLib is licensed independently: Apache for code plus CC for data, as a separate repository. The substrate kits sit under the core license.

## Consumption surfaces

ARIA is reached three ways. These are three ways to reach one contract, not three contracts.

```
                    ┌───────────────────────────┐
                    │       MOOTx01 estate      │
                    │   (GLK + BrainKits)       │
                    └─────────────┬─────────────┘
                                  │
                       ARIA surface (one contract)
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        ▼                         ▼                         ▼
┌───────────────┐         ┌───────────────┐         ┌───────────────┐
│   aria-mcp    │         │  Native API   │         │   Embedded    │
│  (MCP server) │         │ (linked lib)  │         │  (in-process) │
└───────────────┘         └───────────────┘         └───────────────┘
   MCP clients              compiled apps            apps that compile
   reach via wire           link a library           MOOTx01 in-process
```

**aria-mcp** is the first consumption surface built. It wraps a MOOTx01 estate and projects the ARIA surface onto MCP primitives. It does not add or change semantics; it carries ARIA over the wire. It is thin over the SDK by definition, so what it can expose is bounded by what the SDK exposes.

**The Native API** is the SDK surface. Today it is the emergent union of the kit public APIs — GeniusLocusKit and the two BrainKits — which compiled applications link. Whether it becomes a single named SDK module or remains the union of kit modules is an open product decision; the working lean is to keep it emergent through pre-1.0 development and formalize a named module once several surfaces depend on it.

**The Embedded library** is the in-process path: an application compiles MOOTx01 directly into its own binary.

All three are named ARIA because they speak the ARIA language, not because any one of them defines it.

### v1.0 and v1.1

v1.0 wraps a full MOOTx01 instance: GLK and both BrainKits. v1.1 lets the MCP provision a narrow instance (just LocusKit, just CorpusKit) and route across a fleet in API mode. Because the BrainKits are NeuronKit and CognitionKit, v1.0 of the aria-mcp server depends on both being in place.

## The sidecar pattern

The primary way an organization adopts MOOTx01 is by sidecar. An existing app — one already on the market — attaches a MOOT alongside itself and opens that knowledge to the organization through the aria-mcp server, so any MCP client can reach it. The app is not rebuilt on the SDK. It gains a MOOT beside it and exposes that memory over MCP.

```
   Existing application                 MCP clients
        (unchanged)                  (Claude, Claude Code,
              │                       other tooling)
              │                              │
              │  writes/reads                │ ARIA over MCP
              ▼                              ▼
   ┌─────────────────┐              ┌─────────────────┐
   │  MOOT (sidecar) │◀────────────▶│   aria-mcp      │
   │  GLK estate     │              │   server        │
   └─────────────────┘              └─────────────────┘
```

Ease of this integration is the product feature: an agent should be able to read the source and wire it up with little guidance, and a developer should find it just as easy. This is the broad adoption path, distinct from building a new app on the SDK or shipping the regulation-layer libs, and it is what the demonstration apps exist to show.

### Demonstration apps

ARIA_MacOS, ARIA_iOS, and ARIA_Rust are demonstration apps, not end-user products. Their purpose is to show a developer how to use the kits, in two registers at once: they are compile targets that link the libs (or their Rust equivalents), demonstrating the SDK in use, and they are themselves source kits, worked examples a developer reads and reuses. The demos do not need to be polished. Their value is showing that the SDK makes building such apps easy.

ARIA_Rust is required, not optional: the Swift and Rust implementations are conformance-gated against shared test vectors, and the kits ship Rust ports in parallel. A demonstration set with only Swift apps teaches only one of the two gated ports.

Each demonstration module also carries detailed instructions written for agentic agents, so an agent can read the entire source and program against the kits autonomously. The demo is documentation that compiles, for both a human developer and an agent.

## Where to go next

| If you want to… | Read |
|-----------------|------|
| Understand the durable definitions | `docs/concepts/MOOTX01_AND_ARIA_CANON.md` |
| Read the ARIA interface and grammar | `ARIA.md`, `ARIA_LEXICON.md` |
| Read the substrate spec | `docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md` |
| See the visual topology | `docs/concepts/topology-assets/` (SVG diagrams) |
| Build against the kits | `docs/validation/substrate_math_performance/` (reference + conformance harness) |
