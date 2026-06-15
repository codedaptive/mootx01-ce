---
title: "The MOOTx01 Substrate: A Guide for Developers"
subtitle: "What MOOTx01 is built on, in the time it takes to drink a coffee"
author: "MOOTx01 maintainers"
date: "2026-05-21"
---

> **Audience.** Developers evaluating MOOTx01, embedding it in an application, or integrating with ARIA. You do not need to maintain the substrate. You need to know what is under the floor so you can build on it with confidence.
>
> **What you get here.** A short tour of the thirteen layers that make MOOTx01 work, with the technique named and the kit pointed at. Roughly two minutes per section. The maintainers' guide goes deeper if you ever need it.

# Why this guide exists

MOOTx01 is a long-term memory substrate. Eleven kits sit on top of a math layer that does the unglamorous work: filtering, hashing, ranking, replicating, and bounding. You can use the kits without understanding the math, the same way you can use a database without writing a query planner. But integrating against a substrate you do not understand is a leap of faith, and we would rather you take a short walk instead.

This guide is the walk. Thirteen short sections, one per layer. By the end, you should know what each kit is doing under the hood, why we made the choices we made, and where to look in the code if you ever want to confirm.

# 1. One object, seven views

The substrate is one mathematical object that supports seven different views of the same rows. The kits each use the view that suits their job. Storage reads the rows as bits. Recall reads them as hashes and graphs. Sync reads them as an event log.

We chose this shape because the alternative is shuffling data between formats every time a kit needs a different question answered. One object, many views, no translation layer.

You will see this shape reflected in the kits: every kit knows about rows; what differs is which view of the row it cares about.

# 2. The lattice: a global address for every row

Every row carries a coordinate pair that says where it sits in human knowledge. The first half uses a library classification system that predates computers. The second half uses Wikidata identifiers. Together they give the row an address that does not depend on any private seed.

We chose this approach because a query for "things about taxes" should return tax-related rows even if those rows were captured by a different person on a different day. Public, standardized addresses make that work. The lattice also feeds into the fingerprint (section four), so concept distance is built into the row's structural identity.

LocusKit puts a lattice anchor on every row.

# 3. The bitmap tier: facts as bits, queries as math

Each row carries three sixty-four-bit columns of facts about itself. Adjectives (state, trust, sensitivity). Operational facts (capture mechanics). Provenance (source). Queries against the substrate compile to bitwise operations on these columns.

We chose this representation because it runs at the speed of the processor. A filter on three or four conditions finishes in microseconds instead of milliseconds. There is no query planner because there is nothing to plan.

LocusKit holds the operators and the compiler.

# 4. The fingerprint: a 256-bit handle that means something

Every row has a 256-bit signature in four equal blocks. Rows that are similar end up with similar signatures. Distance is measured by counting the bits that disagree. The technique is locality-sensitive hashing (SimHash, specifically).

The four blocks each capture a different aspect of the row: the bitmap state, the lattice neighborhood, the lineage and time, and the provenance. Recall can weight the blocks differently depending on what the user is asking for, which is how a single signature serves "find similar," "find recent," and "find from the same source."

SubstrateLib produces the fingerprint. LocusKit builds the per-block inputs. VectorKit uses the fingerprint alongside vector embeddings.

# 5. OR-reduction: skip rooms you do not need to read

Every container (room, wing, estate) keeps a summary made by ORing its rows' bitmaps together. When a query asks "does anything in this room have property X," the substrate checks the summary. If the answer is no, the room is skipped entirely.

We chose this technique because most queries reject most of the working set, and the substrate would rather not look at rows it can prove cannot match. It is the technique that lets recall feel instant on large estates.

LocusKit maintains the summaries.

# 6. Count vectors: when "any" is not enough

Where OR-reduction asks "does any row have this bit," the count vector asks "how many." Adding rows to a bundle is vector addition. Removing rows (when a user withdraws content) is subtraction.

We chose this approach because two things only counts can do: aggregate themes across many estates for federation, and let a user erase a set of rows without rebuilding every container from scratch. The math gives us both behaviors as a side effect.

SubstrateLib holds the fold. LocusKit composes the bundles.

# 7. The audit log: the substrate is the history

Every change to the substrate appends an immutable event to a log. Current state is the replay of those events. Historical state is the replay truncated to a moment in time. There is no separate "history table" because the substrate is the history.

We chose this because it gives us three valuable properties for the price of one design choice. The substrate is auditable: every change is recorded with a timestamp and author. The substrate replicates without conflict resolution: two replicas that see the same events end up in the same state. And the substrate supports "as-of" queries: rebuilding state at any past moment is just truncating the replay.

The underlying technique is a grow-only set CRDT with hybrid logical clocks. SubstrateLib holds it. LocusKit writes through it. GeniusLocusKit unifies it across kits.

# 8. The matrix tier: learning we can read

A small family of matrices accumulates statistics over time: how often a value appears, what tends to co-occur, what tends to follow what. These live in the substrate, not in a model's weights, which means we can inspect, export, and audit them.

We chose this because a black-box model could do the learning, but its answers would not be explainable and its data would not be portable. By holding the statistics ourselves, we keep the user's data with the user and the explanation visible to anyone who looks.

SubstrateLib holds the matrices. The Brain layer in GeniusLocusKit drives them.

# 9. The estate as a graph

Rows are nodes. Connections between them (tunnels you created, lineage chains, co-occurrence from the matrix tier) are typed weighted edges. The graph is reconstructed on demand from data the substrate already keeps; it is not stored separately.

The graph view answers two questions cleanly. Which rows are central to a user's thinking, surfaced as keystone drawers. And what is connected to a row at two or three hops, used for exploratory recall and room suggestions.

LocusKit owns the topology. GeniusLocusKit runs the graph queries.

# 10. Recall scoring: ranking that learns

When a query runs, candidates come back ranked by a composite score. The score blends concept distance (from the lattice), structural distance (from the fingerprint), and, when available, semantic distance (from vector embeddings). The weights in the blend are learned per user from pairwise preferences.

We chose this because no single distance captures relevance on its own. The composite gets us all three signals. The learning gets us the weights without having to tune them by hand.

VectorKit holds the composite. NeuronKit holds the preference update.

# 11. Federation: estates that compare without merging

Two estates can compare notes without merging. Identity is exchanged. A pairing is agreed to. A shared family of hash seeds is derived from the handshake. After that, the two estates can compare fingerprints across the boundary.

We chose this because memory is personal. Two people in the same household should be able to ask "what does June look like" and get an answer that draws on both of their MOOTs, without either of them surrendering their memory to a shared pool. Pairing is reflexive and symmetric, but not transitive. Your pairing with your spouse does not implicitly pair you with their employer.

When estates aggregate to a tier (a household, a team), we add bounded noise to the contribution to provide a formal privacy budget. The technique is called randomized response.

ConvergenceKit holds the handshake and the sync engine.

# 12. Kernel dispatch: the right backend, picked by measurement

The substrate's hot operations have multiple implementations. A scalar reference. A SIMD version. A GPU version. The dispatcher picks one at runtime based on the hardware. Every backend produces bit-identical output to the reference, verified against shared test vectors.

We chose this because bandwidth, not arithmetic, is the bottleneck. The right backend on any given chip is an empirical question, not a theoretical one. SIMD is the production default on Apple Silicon because measurement said so. The GPU path is retained but currently rejected at the sizes we operate on.

The conformance gate is non-negotiable: a faster backend that produces different output is broken, not faster.

SubstrateLib holds the kernel layer.

# 13. Row state and safety guarantees

Every row in the substrate is in one of ten states. Transitions are driven by the substrate's verbs and the legal transitions are enumerated. Some combinations are forbidden outright; a row marked secret cannot also be marked public. The validator intercepts every write before it commits.

We chose this because guarantees that the substrate enforces are guarantees you can build on. When your code assumes a property of a row, the validator has already rejected anything that would violate that property. The invariants are gates, not documentation.

LocusKit's state validator enforces transitions and forbidden combinations.

# What this means when you build on MOOTx01

A few things to keep in mind as you integrate.

**You can trust the substrate to filter fast.** Bitmap operations and OR-reduction are doing the heavy lifting underneath every recall. You do not need to add caching on top of typical queries; the substrate is already cache-aware in the way that matters.

**You can trust the substrate to remember.** The audit log is not a feature you opt into. It is the substrate. Any operation that mutates state goes through it, which means you can rebuild any past moment if you ever need to.

**You can trust the substrate to keep secrets.** Forbidden combinations are unreachable, not unlikely. A row that should not be exportable cannot become exportable by accident.

**You can trust the substrate to learn from use without lock-in.** The matrices and the recall weights are data, not model weights. They are inspectable, exportable, and yours.

**Where to look when you need more.** The maintainers' guide goes a layer deeper, with failure modes, performance numbers, and the technique names mapped to specific kit modules. The engineering cookbook, the decision records, and the conformance harness sit below the maintainers' guide as the working reference for anyone making kernel or algorithm changes. Those live with the maintainer tier; the maintainers' guide is the doorway to them.

You do not need to read any of those to use MOOTx01. They are there for the moments when you want to look under the hood and see how the engine is put together.

---

*Developers' guide. Derived from the maintainers' guide. The full mathematical treatment is held internally.*
