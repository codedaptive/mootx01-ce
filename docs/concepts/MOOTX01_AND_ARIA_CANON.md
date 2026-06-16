---
title: MOOTx01 and ARIA — Canonical Definitions
status: canon
authors: MOOTx01 maintainers
date: 2026-06-14
version: 1.0.0
description: The durable definitions of MOOTx01 (GeniusLocusKit in union with the BrainKits) and ARIA (the portable interface language within it).
---

# MOOTx01 and ARIA: Canonical Definitions

These are the durable definitions. The engineering detail and the release plan live in docs/reference/ARIA_MCP_SPEC.md, which projects from these.

## What MOOTx01 is

MOOTx01 is GeniusLocusKit in union with the two BrainKits, NeuronKit and CognitionKit.

- GeniusLocusKit (GLK) is the composition layer and the write surface. It composes LocusKit (spatial memory and the knowledge graph) and CorpusKit (content-plus-vector RAG bundles, built over VectorKit) into one estate, and it coordinates persistence through QueueKit, which uses PersistenceKit directly.
- NeuronKit is the algorithm BrainKit: reasoning functions and autonomic daemons (hybrid recall, the dreaming daemon, branch scoring, and similar).
- CognitionKit is the behaviour BrainKit: named, composable workflows, the recipes.

A MOOTx01 instance is GLK together with both BrainKits. GLK alone, LocusKit alone, and CorpusKit alone are each usable, but MOOTx01 is the union.

## ARIA and its grammar

ARIA is the interface specification for MOOTx01, the contract every consumer honors, and it expands as Augmented Recall and Inference Architecture. ARIA is not a server, a library, or a wire format; it is the set of operations a MOOTx01 estate must support and the semantics they must honor, regardless of implementation or how it is reached. ARIA is not a product in its own right; it is the language inside the product. The product is MOOTx01; ARIA is the open, portable language within it, free for everyone, while the estates stay private to the user (ARIA.md). You do not sell ARIA; you sell MOOTx01, and ARIA is the property that makes it portable and ownable. The authoritative statements are [ARIA.md](ARIA.md) (the interface overview) and [ARIA_LEXICON.md](ARIA_LEXICON.md) (the grammar).

The grammar of the ARIA language is the AriaLexiconLib: every call is one verb applied to a noun, optionally constrained by adjectives. One noun, the drawer; nine verbs fixed by invariant I-7; four adjective categories fixed by invariant I-8; and the acceptance matrix that fixes which verbs each noun accepts, which is the design-time semantics. AriaLexiconLib is the single source of truth for the grammar, and every consumption surface is a projection of it.

## Consumption surfaces and the SDK

ARIA is reached three ways (ARIA.md): the aria-mcp server, which carries ARIA over MCP; the Native API, a callable library that exposes ARIA to compiled applications with no server and no wire; and the Embedded library, where an application compiles MOOTx01 in-process. These are three ways to reach one contract, not three contracts.

The Native API is the SDK surface. Today it is the emergent union of the kit public APIs, GeniusLocusKit and the two BrainKits, which compiled applications link. Whether it becomes a single named SDK module that surfaces link and version against, or remains the union of kit modules, is an open product decision; the working lean is to keep it emergent through pre-1.0 development and formalize a named module once several surfaces depend on it.

aria-mcp is the first consumption surface built. It wraps a MOOTx01 estate and projects the ARIA surface onto MCP primitives; it does not add or change semantics, it carries ARIA over the wire. It is thin over the SDK by definition, so what it can expose is bounded by what the SDK exposes, which is why the dependency on the BrainKits is a property of the SDK surface and not a coupling peculiar to the MCP server. The native targets reach the same contract through the Native API and the Embedded library, but their purpose is demonstration, covered next. All are named ARIA because they speak the ARIA language, not because any one of them defines it.

## The sidecar pattern

The primary way an organization adopts MOOTx01 is by sidecar. An existing app, one already on the market, attaches a MOOT alongside itself and opens that knowledge to the organization through the aria-mcp server, so any MCP client can reach it. The app is not rebuilt on the SDK; it gains a MOOT beside it and exposes that memory over MCP. Ease of this integration is the product feature: an agent should be able to read the source and wire it up with little guidance, and a developer should find it just as easy. This is the broad adoption path, distinct from building a new app on the SDK or shipping the regulation-layer libs, and it is what the demonstration apps exist to show.

## Demonstration apps

ARIA_MacOS, ARIA_iOS, and ARIA_Rust are demonstration apps, not end-user products. Their purpose is to show a developer how to use the kits, in two registers at once. They are compile targets that link the libs or their equivalents, so they demonstrate the SDK in use, and they are themselves source kits, worked examples a developer reads and reuses. The commercial product ships as libs for the regulation layer, so the demos teach exactly that path: take a kit, make a lib, then build a small monitoring app that compiles, updates, installs, and does something interesting with it. The demos do not need to be polished or cool software. Their value is showing that the SDK makes building such apps easy, so they stay small and useful rather than products to perfect. Most importantly they show the sidecar pattern above: how an existing app attaches a MOOT and opens it to an organization over the aria-mcp server, the path most adopters will take.

Each demonstration module also carries detailed instructions written for agentic agents, so an agent can read the entire source and program against the kits autonomously. The demo is documentation that compiles, for both a human developer and an agent.

ARIA_MacOS and ARIA_iOS are the Swift-side demonstrations. ARIA_Rust is the Rust-side demonstration, and it is required, not optional: the Swift and Rust implementations are conformance-gated against shared test vectors (ARIA.md), and the kits ship a Rust version in parallel, so a demonstration set with only Swift apps teaches only one of the two gated ports. ARIA_Rust shows a developer how to take the Rust kits, make a lib, and build a small monitoring binary, with the same agentic source instructions.

## Instance mode and the write surface

A single MOOTx01 instance runs in GLK mode. The write surface is always GLK. Every write goes through GLK, which keeps the underlying databases in sync by way of QueueKit over PersistenceKit. Reads may be taken in narrower lenses on the same instance, a CorpusKit-only query or a LocusKit-only query, but those are read projections of the union, not separate writable stores. Narrowing applies to reads; writing is uniformly GLK.

## API mode and the instance fleet

At the API layer an operator may configure many separate instances of different kinds, for example three CorpusKit, two LocusKit, and three GeniusLocus instances, and route each call to the database it belongs to. QueueKit over PersistenceKit is the mechanism for both the per-database operations and the cross-database coherence. The route-to-the-right-database behaviour is an API-layer concern, not something inside a single instance.

## The substrate owns the atomics

Every low-level operation on the substrate's bit shape and event identity — bitfield extract and write, masks and shifts, AND/OR/XOR, popcount and Hamming distance, fold and reduce, the SHA-256 content hash, and the Hybrid Logical Clock — lives in one library, SubstrateLib, and every kit consumes it by name. No kit reimplements the math. This is not only hygiene; it is the property that makes MOOTx01 portable. SubstrateLib is the single hard port. The Swift and Rust implementations are conformance-gated against shared test vectors (ARIA.md), and those vectors live with the centralized math, so once SubstrateLib's conformance corpus passes on a new platform every kit built on it works there without per-kit re-verification. The conformance corpus is the portability contract; centralizing the atomics is what collapses "port the whole product" into "port one library." The engineering statement of this rule is cookbook invariant I-25.

## The version boundary

v1.0 wraps a full MOOTx01 instance: GLK and both BrainKits. v1.1 lets the MCP provision a narrow instance, just LocusKit or just CorpusKit, and route across a fleet in API mode. Because the BrainKits are NeuronKit and CognitionKit, v1.0 of the aria-mcp server depends on both being in place.
