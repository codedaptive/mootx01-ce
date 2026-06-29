---
status: decided
question: An estate has two organizational levels above the drawer — wing and room — but the ARIA `file_memory` path assigns a single fixed default wing ("memories"/`wing_default`) and folds the caller's location string into the room, so the wing level is unused and an entire axis of organization is wasted (test-drive FINDING-5). Wings were originally going to carry the FDC/UDC classification number, but that role moved to the per-drawer lattice anchor (DECISION_LATTICE_CITATION_UDC_WIKIDATA_2026-05-07). What, then, are wings *for*, and how should the system seed, document, and use them?
authors: MOOTx01 maintainers
date: 2026-06-23
version: 1.1.0
relates_to:
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/decisions/DECISION_LATTICE_CITATION_UDC_WIKIDATA_2026-05-07.md
  - docs/concepts/ARIA.md
description: Wings are the estate's provenance/role axis — orthogonal to the FDC lattice anchor, which owns subject. An estate seeds seven suggested default wings (Agentic Memory, User Canon, Source Corpus, Personal, Professional, Projects, Temp), each self-documented by a normal seeded hint memory (NOT special-cased — see the 2026-06-23 §2 amendment); the set is a suggestion, not a constraint — the AI may create any wing. Recall spans all wings by default with opt-in wing scoping. The default wing is renamed "Agentic Memory".
---

# ADR-016 — Wings as the provenance/role organizational axis

## Context

MOOTx01 is a shared storage system for **both the user and the AI**. An estate
nests `wing → room → drawer`, plus an orthogonal per-drawer **lattice anchor**
(an FDC code + optional Wikidata Q-ID) that answers *"what subject is this
about?"* (invariant I-5; every drawer carries one).

Two facts set up the problem:

1. **Wings no longer carry classification.** They were originally going to follow
   FDC/UDC numbering. That was abandoned once the FDC moved to the per-drawer
   lattice anchor (`udc_code`), produced by the deterministic public-domain FDC
   encoder. Subject classification is therefore already handled — by the lattice,
   not by wings.

2. **The wing level is currently wasted.** `file_memory`
   (`ToolDispatch.swift`) sets the wing to a single fixed default and folds the
   caller's `location` into the **room**, so every memory lands in one wing with
   a composite room name (test-drive FINDING-5). An entire organizational axis is
   unused.

The question is what wings should *be*, given that subject is taken.

## Decision

**Wings are the provenance / role axis — orthogonal to the FDC lattice (subject).**
Wing answers *"what role does this memory play / where did it come from / who
owns it?"*; the lattice answers *"what is it about?"*. The two are independent
coordinates a consumer slices separately (e.g. "everything in Professional
classified under ML"). This is the capability a flat vector store cannot offer.

### 1. Seven seeded default wings (suggested, not enforced)

A fresh estate initializes with seven default wings:

| Wing | Role |
|---|---|
| **Agentic Memory** (default) | The AI's own observations, inferences, decisions, session learnings. |
| **User Canon** | Explicit user directives, preferences, corrections, standing orders — authoritative; the AI weights these above its own inferences and does not silently overwrite them. |
| **Source Corpus** | Imported / ingested documents, books, reference material — external grounding, not the AI's beliefs. |
| **Personal** | The user's personal-life domain. |
| **Professional** | The user's work domain. |
| **Projects** | Active project / workspace context. |
| **Temp** | Scratch / ephemeral. Aggressively dream-aged (1.1 — a decay knob scoped to this wing). |

These are **defaults the MCP surface suggests, not a fixed schema.** The AI is
free to create any wing it wants; nothing is enforced. The set spans two natural
sub-axes — provenance (Agentic Memory, User Canon, Source Corpus, Temp) and
life-domain (Personal, Professional, Projects) — both useful. When a memory fits
more than one, provenance lanes take soft precedence over life-domain lanes; this
is *guidance* carried in the charters, not a hard rule.

The prior default wing name (`wing_default` / "memories") is renamed
**"Agentic Memory"**.

### 2. Wings are self-documenting (a seeded hint memory)

> **Amendment 2026-06-23 — the "charter" special-casing is removed.** The
> original design (below) gave each wing a *charter* in a **reserved `_charter`
> room** that the code treated specially: a sentinel `added_by`
> ("estate-provision"), `embeddingModelID = "none"`, and explicit exclusion from
> recall and from `estate_map` room counts. That distinction was agentic
> over-think — and incoherent (a user creating their own wing with a "charter"
> would have no way to be detected). It is gone. Each wing is still seeded with a
> role-description **hint memory**, but it is now a **completely normal drawer**:
> filed into a plainly-named room (`AI_Charter_Hint`), embedded with the normal
> model, recallable, counted, and user-deletable like any other memory. The code
> branches on it nowhere; it is simply part of mootx01 creating the automatic
> default estate. The wing axis (§1) and the seven defaults are unchanged.

Each wing is seeded with a **hint memory** describing in plain language what the
lane is for and when to file there. The hint is:

- **Seeded at estate init** for the seven defaults (a normal drawer in the
  wing's `AI_Charter_Hint` room — no special room, provenance, or embedding).
- **Surfaced by `estate_map`** so a fresh agent learns the filing scheme *from
  the store itself*, and recallable like any memory (the AI's first recall can
  surface the hints — self-onboarding).
- **Editable** — the AI or user refines a lane's purpose by updating (or
  deleting) the hint memory; the scheme self-corrects with use.
- **Portable** — the hint is an ordinary memory, so it travels with its wing
  through vault export/import (wing = top-level vault folder).

When the AI creates a new wing, it can write that wing's hint, so the next agent
inherits the extended scheme.

### 3. Filing

`file_memory` auto-infers the wing where it can — `mcpAgent` channel →
Agentic Memory, `imported`/file channel → Source Corpus — and otherwise accepts
an explicit `wing` argument, with the charters + skill as guidance. The caller's
path continues to map to the **room** hierarchy; the wing is a separate role
input, so the two axes stay clean (path is never split into a wing).

### 4. Recall spans all wings by default

Recall reads **all wings by default.** Wing scoping is **opt-in** via a recall
argument — the agentic lever ("answer from User Canon only", "exclude Source
Corpus from synthesis", "search Projects"). No implicit scoping; the AI aims
recall explicitly when it wants to.

### 5. Wings are soft partitions

Tunnels (the relationship graph) and the lattice footprint cross wings freely.
Wings organize; they do not silo.

## Consequences

- **Recovers a wasted organizational level** and gives it a job the FDC lattice
  cannot do (role/provenance vs subject).
- **Self-onboarding:** a new agent orients from the seeded hints — the
  organization scheme travels with the data.
- **Recall scoping** by wing becomes the high-leverage agentic capability;
  the trust gradient (confirmed/authoritative vs inferred vs corpus) largely
  follows from the wing a memory lives in (relates to test-drive FINDING-4).
- **Vault gains a natural unit** — export/import is wing-scopable and preserves
  the wing tree; drops directly onto the OKF/Obsidian adapter (wing = top folder).
- **Erasure/withdrawal handling can be wing-aware** (relates to FINDING-1):
  Temp self-prunes; User Canon resists resurrection.

## Implementation surface (build scoped separately, both ports)

- Estate init: seed the seven default wings, each with a normal hint memory in
  the wing's `AI_Charter_Hint` room (no special room/provenance/embedding — see
  the §2 amendment).
- `file_memory`: `wing` argument + auto-inference from channel; default
  "Agentic Memory".
- `estate_map`: surface each wing; the hint is a normal counted drawer.
- Recall: optional `wing` scoping argument (default = all wings).
- Vault: preserve/scope by wing (wing = top-level folder).
- `mootx01-memory` skill: "read the wing hints via `estate_map`/recall, file by role".
- 1.1: aggressive dream-aging scoped to the Temp wing.

## Changelog

- 1.0.0 (2026-06-19) — Initial decision. Wings = provenance/role axis; seven
  seeded self-documenting defaults; open-ended; recall spans all wings with
  opt-in scoping; default wing renamed "Agentic Memory".
