---
title: ARIA
status: canon
authors: MOOTx01 maintainers
date: 2026-06-14
version: 1.0.0
description: Overview of ARIA — the interface specification (Augmented Recall and Inference Architecture) every consumer uses to reach a MOOTx01 estate.
---

# ARIA

*The interface specification for MOOTx01.*

---

ARIA is the language every consumer uses to talk to a MOOTx01 estate. It is the vocabulary, the verbs, the semantics that any AI tool, any application, any port of MOOTx01 honors. ARIA is what makes MOOTx01 portable. Every implementation speaks the same ARIA.

ARIA expands as Augmented Recall and Inference Architecture.

This document is the overview. The formal specification lives in `docs/reference/`.

---

## What ARIA is

ARIA is an interface specification. Not a server, not a library, not a wire format. ARIA is the contract: the set of operations a MOOTx01 estate must support and the semantics those operations must honor, regardless of how the estate is implemented or how it is reached.

The Swift implementation of MOOTx01 speaks ARIA. The Rust implementation speaks ARIA. Future ports will speak ARIA. Every consumer reaches MOOTx01 through ARIA, and every implementation behaves the same way at the ARIA boundary.

This is the architectural commitment that makes everything else work. If ARIA were a library, MOOTx01 would be locked to whatever language that library was written in. If ARIA were a wire format, MOOTx01 would be locked to wire-protocol semantics. ARIA is the contract above both. Libraries and wire formats are how the contract is reached, not what the contract is.

---

## Consumption surfaces

ARIA is reached three ways.

**aria-mcp** — an MCP server that wraps a MOOTx01 estate and exposes the ARIA surface over the Model Context Protocol. Any AI client that speaks MCP — Claude, ChatGPT, Claude Code, a local model with an MCP runtime — can reach the estate through this server. The MCP wrapper does not add or change semantics; it carries ARIA over the wire.

**Native API** — a callable library API that exposes the ARIA surface for compiled applications. A Swift application calls the Swift implementation directly. A Rust application calls the Rust implementation directly. Same ARIA, same operations, same semantics. No protocol overhead, no server, no wire.

**Embedded library** — an application can compile MOOTx01 directly into itself and call ARIA in-process. The application gets its own MOOT in its own domain. The user authorizes what crosses between the application's MOOT and the user's personal MOOT.

These are three ways to reach the same contract, not three different contracts. An AI agent calling ARIA through MCP and a compiled application calling ARIA through the native API are calling the same operations. They get the same answers. They honor the same semantics.

---

## Consistency across implementations

ARIA is consistent across implementations or MOOTx01 does not hold together. This is the discipline that makes the project portable.

The Swift implementation and the Rust implementation are conformance-gated against shared test vectors. Any operation that ARIA defines must produce identical results in both implementations against the same input. The test harness in `docs/validation/substrate_math_performance/test-harness/` is the enforcement mechanism.

Future ports — to other languages, to other platforms — will be conformance-gated the same way. A port that does not pass the ARIA conformance suite is not a port. It is a different system that happens to share some vocabulary.

This is what lets a user move from a Mac to a Linux server to an iOS device and have their MOOT behave the same way everywhere. It is what lets an application developer write against ARIA and know their application will work against any conforming MOOTx01 implementation. It is what lets the ecosystem grow without fragmenting.

---

## What ARIA covers

ARIA defines:

- **Capture** — how content enters a MOOT and what is preserved (verbatim, with provenance, with lineage).
- **State** — how a memory's status is queried and changed (active, retired, contested, superseded).
- **Recall** — how the estate is queried, ranked, filtered, and returned to the consumer.
- **Convening** — how two MOOTs gather, exchange what each was authorized to share, and separate without merging.
- **Provenance** — how the origin of each memory is recorded and how consumers filter on it.
- **Audit** — how structural changes are recorded and how historical state is reconstructed.
- **Verbs** — the nine substrate verbs (capture, reanchor, mutate, withdraw, expunge, recall, propose, associate, learn) and their semantics.

ARIA does not define:

- The storage backend. ARIA does not care whether the estate is on SQLite, PostgreSQL, or anything else.
- The embedding model. ARIA does not care which model generated a vector, only that the model identity is recorded with the vector.
- The application's domain. ARIA does not care what the application is for. The application is x01 in its own domain; ARIA carries that domain's MOOT.
- The user interface. ARIA does not specify how a MOOT is presented to a user. ARIA is the contract; the interface is whatever the consumer builds.

---

## Where the formal specification lives

The full ARIA specification is in `docs/reference/`. The architecture spec (`GENIUSLOCUS_ARCHITECTURE_SPEC.md`) is the authoritative source for the substrate's behavior, and ARIA is the surface of that substrate.

The engineering cookbook (`docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md`) is the reference for how the algorithms behind ARIA actually work.

The conformance test vectors are in `docs/validation/substrate_math_performance/test-harness/`.

---

## Why ARIA exists

Every other AI memory system on the market is a library or a service. The library locks you to a language. The service locks you to a vendor. Both lock the user's memory to whoever owns the implementation.

ARIA is the architectural commitment that the user's memory is not locked to anyone. The implementations can change. The consumption surfaces can change. The vendors can come and go. The user's MOOT is theirs, and ARIA is the language that guarantees it stays reachable.

This is the open commitment. ARIA is what is open. MOOTx01 estates are private to the user. The language is free for everyone. The gatherings belong to whoever called them.
