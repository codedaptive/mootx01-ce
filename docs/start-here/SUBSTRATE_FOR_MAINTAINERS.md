---
title: "The MOOTx01 Substrate: A Guide for Maintainers"
subtitle: "What the math does, why we chose it, and where it lives in the code"
author: "MOOTx01 maintainers"
date: "2026-05-21"
---

> **Audience.** Port maintainers, contributors, and engineers reading the kit code. This document explains the substrate in plain language. It names the techniques and points at the kits that use them. It does not derive the mathematics. The full mathematical treatment is held internally.
>
> **What you get here.** Thirteen short sections, one per primitive or layer. Each section answers three questions. What is it. Why did we choose it. Where does it live in the code. That is enough to read the kits with confidence and trust that the foundation is sound.

# How to read this guide

The substrate is the math layer that every kit in MOOTx01 sits on. The kits do the visible work: storage, sync, recall, vector search, RAG, orchestration. The substrate is what makes those kits fast, correct, and consistent across implementations.

Each section follows the same shape.

- **What it is.** One or two sentences in plain language.
- **Why we chose it.** The problem it solves and what we gain.
- **Where it lives.** The kit, the class or module, and the operation that uses it.

You do not need to know the equations to read the code. You do need to know what the code is trying to do. That is what this guide is for.

# 1. The substrate as one object

**What it is.** The substrate is a single mathematical object that wears seven hats at once. The same set of rows is, at different moments, a log of events, a packed grid of bits, a graph, a coordinate space, a counting tier, a hash space, and a vocabulary of legal verbs. Each layer of the kit stack uses a different view of the same rows.

**Why we chose it.** Most systems pick one shape and pay for everything else with translation layers. We picked one object and pay for the views by reading them differently. The result is that a row written once can be filtered as bits, ranked as a hash, projected from a log, walked as a graph, and counted as a vector, with no copies and no schema drift.

**Where it lives.** Every kit agrees on the shape. LocusKit holds one estate. GeniusLocusKit composes many estates into one Brain layer. The vocabulary of legal verbs lives in AriaLexiconLib.

# 2. The lattice: where every row sits in concept space

**What it is.** Every row carries a coordinate pair that says where it sits in human knowledge. The first half uses a long-standing library classification system. The second half uses Wikidata identifiers. Together they give the row a global address that does not depend on any seed or model we control.

**Why we chose it.** A query for "tax documents" should return rows about taxes, not rows that happen to share a hash. The lattice makes that possible. Because the addresses are public and standardized, a row about ducks lands near a row about birds whether the row was captured today or last year, by this user or by their spouse. The addresses also feed one block of the fingerprint, so distance in concept space shows up as distance in the hash.

**Where it lives.** LocusKit puts a lattice anchor on every row and uses the distance to rank recall. GeniusLocusKit uses lattice overlap to decide whether two estates have anything to compare.

**Failure mode to know.** A row without a lattice anchor is incomplete. Every noun type, including ones that have no obvious concept of their own, derives an anchor from context. A tunnel borrows its source's anchor. An association takes the midpoint of its endpoints. The validator catches missing anchors before write.

# 3. The bitmap tier and the operators that read it

**What it is.** Each row carries three sixty-four-bit columns of facts about itself. One column for adjectives (the row's state and trust). One for operational facts (how it was captured). One for provenance (where it came from). Queries against the substrate are bitwise operations against these columns.

**Why we chose it.** Bitwise operations run at the speed of the machine. A filter that asks "is this row in the historical cluster and below restricted sensitivity" compiles to a small chain of shifts, masks, and compares. The processor does this in nanoseconds. A traditional database would read columns, parse values, and run a query planner for the same answer.

**Where it lives.** LocusKit holds the operators (`BitmapOps`), the filter compiler (`Filter`), and the evaluator (`BitmapEvaluator`). A conformance test gates the encodings against the Swift source so the field layouts cannot drift.

**Performance intent.** A single-field predicate finishes in under ten microseconds on Apple Silicon. A full row scan of a working set finishes in roughly one millisecond. The bitmap tier is the reason recall feels instant.

# 4. The fingerprint: a 256-bit handle for every row

**What it is.** Every row has a 256-bit signature in four equal blocks. Rows that are close in meaning end up close in this signature. Distance is measured by counting bits that disagree.

**Why we chose it.** Comparing two rows by their full content is expensive. Comparing them by hash is cheap. We needed a hash where similar rows produced similar hashes, not random ones. The technique is called locality-sensitive hashing, specifically SimHash. Each block captures a different facet of the row: bitmap state, taxonomic neighborhood, lineage and time, and provenance and channel. Distance across the four blocks adds up to one number between zero and 256, and that number is the substrate's structural coordinate.

**Why four blocks instead of one.** Different recall modes care about different facets. A query about "documents from last week from my work account" cares about block 2 and block 3 more than block 0. Splitting the hash into facets lets recall weight the blocks instead of treating the row as one undifferentiated point.

**Where it lives.** SubstrateLib holds the hash itself (`SimHash`) and the batched kernel that produces fingerprints in volume. LocusKit holds the per-block input construction (`DrawerFingerprint`). VectorKit consumes fingerprints next to embeddings during recall.

**Performance intent.** A single fingerprint takes about 166 nanoseconds on Apple Silicon. Batched at 256 rows, that drops to about 59 nanoseconds per input. The bottleneck is memory bandwidth, not arithmetic, which is why the kernel layer matters (section twelve).

# 5. OR-reduction: how we skip work without missing rows

**What it is.** Every room, every wing, and every estate keeps a summary made by ORing all of its rows' bitmaps together. When a query asks "are there any rows in this room with bit K set," we check the summary first. If the summary does not have bit K, no row in the room does, and we can skip the entire room.

**Why we chose it.** Most queries reject most of the working set. OR-reduction lets us reject whole containers without reading a single row inside them. The math is sound because OR is monotonic: if any row had the bit, the summary would too. The technique is called container pruning, and it cuts query work by orders of magnitude on large estates.

**Where it lives.** LocusKit's `ContainerFingerprintStore` maintains the aggregates. The recall pruner consumes them as the first step in evaluating any filter.

**Failure mode to know.** The summaries are only safe if they include every active row. Capture writes into the summary at the moment a row is added. Backfill catches up after a session is opened. Stale set bits left over after a withdrawal are an over-approximation, which means we may scan a container that turns out to be empty of matches, but we will never miss a match. Wrong direction is impossible.

# 6. Count vectors and bundle algebra: how we count across rows

**What it is.** Where OR-reduction asks "does any row in this container have this bit," the count vector asks "how many rows do." For each of the 256 fingerprint positions, we store a count. Folding more rows into the bundle is just vector addition. Removing a cohort is subtraction.

**Why we chose it.** Two questions need a count rather than a yes-or-no. The first is federation: when two estates compare bundles, we need to know which themes are strong, not just present. The second is erasure: when a user withdraws a set of rows, we need to subtract their contribution from every container they touched, without recomputing the bundle from scratch. Vector addition gives us both behaviors for free.

**Where it lives.** SubstrateLib holds the fold itself (`countFold256`) in both a scalar and a SIMD version. LocusKit persists and composes the bundles (`NodeBundleStore`, `BundleMaterializer`). CognitionKit recall and the federation aggregates consume them.

**Implementation note.** The fold uses a bit-sliced carry-save counter. The technique is called Harley-Seal popcount. The point is that a single fold step costs a handful of vector operations instead of looping through bits.

# 7. The audit log: every change, kept forever

**What it is.** Every mutation to the substrate appends an immutable event to a log. The log is the substrate. Current state is what you get by replaying the events in order. Historical state is what you get by replaying up to a given moment in time.

**Why we chose it.** This design choice does three things at once. First, it makes the substrate auditable: every change has a record, with a timestamp and an author, and nothing is silently rewritten. Second, it makes the substrate replicate cleanly: two replicas that have seen the same events project the same state, with no conflict resolution code anywhere. Third, it gives us "as-of" queries for free: rebuilding the state at any past moment is just truncating the replay.

The technique is called a grow-only set CRDT, with hybrid logical clocks for ordering. The CRDT property is what guarantees that two replicas, after exchanging events, end up identical.

**Where it lives.** SubstrateLib provides the set union, the clock, and the projection functions. LocusKit writes every mutation through the log (`EstateAudit`). GeniusLocusKit unifies the logs of LocusKit and CorpusKit when both are present.

**Performance intent.** Reconstruction is linear in the number of audit rows and dominated by the SQLite scan, not by computation. Day-to-day operation does not reconstruct; it works against the current projection, which is maintained incrementally.

# 8. The matrix tier: where the substrate learns

**What it is.** A small family of matrices that accumulate population statistics and learned preferences over time. They live in the substrate, not inside any model's weights, which means we can inspect them, export them, and audit them. There are four core matrices: field presence, correlation, co-occurrence, and temporal causality.

**Why we chose it.** Recall has to know what is common, what tends to appear together, and what tends to follow what. A black-box model could learn this, but we would not be able to explain its answers, and we could not export the learning to a different model. By holding the statistics ourselves, we keep the explanation visible and the data portable.

**Why the four matrices.** Field presence answers "how often is this bit set." Correlation answers "what fraction of rows have this bit." Co-occurrence answers "how often do these two values appear together." Temporal causality answers "how often does this value precede that one." Each matrix updates on the same kind of signed event, so all four stay current with one write path. Older counts fade through a lazy multiplicative decay, applied at the next touch rather than on a schedule.

**Where it lives.** SubstrateLib holds the matrix kernels and the decay pass. GeniusLocusKit drives the matrices from the Brain layer.

**Learned structure.** Alongside the counts, we keep a calibration curve that maps a model's claimed confidence to its actual track record, and a latent-structure factorization (non-negative matrix factorization) that surfaces themes from the co-occurrence matrix. The dreaming daemon recomputes these on a slow cadence and caches the result.

# 9. The estate as a graph

**What it is.** The rows in an estate are nodes. The connections between them (tunnels you created, lineage from one row to the next, co-activation from the matrix tier, temporal precedence, lattice anchoring) are typed weighted edges. The graph is not stored as a graph; it is reconstructed on demand from the tables and matrices the substrate already keeps.

**Why we chose it.** Two questions only the graph view answers cleanly. The first is "which rows are central to this user's thinking," which scores rows by their position in the graph and surfaces keystone drawers. The second is "what is connected to this row at two or three hops," which drives exploratory recall and community detection. We use eigenvalue centrality for the first and a random walk for the second. Community detection (Louvain) suggests rooms when the user has not declared them.

**Where it lives.** LocusKit owns the tunnel topology. GeniusLocusKit runs the graph queries and cross-estate mediation. The keystone score is cached on the row and surfaced through a recall mode.

# 10. Recall scoring: how we rank what comes back

**What it is.** When a query runs, the substrate returns candidate rows ranked by a composite score. The score blends lattice distance (concept proximity) and fingerprint Hamming distance (structural proximity), and when vector embeddings are present, it adds semantic similarity. The weights in the blend are not fixed; they are learned per user and per query type.

**Why we chose it.** No single distance captures what a user means by relevance. Concept distance is right for "find me documents about tax." Fingerprint distance is right for "find me documents that look like this one." Vector distance is right for "find me documents about this idea even if they do not use these words." The composite gives us all three. The learning gives us the weights without having to tune them.

The learning is by pairwise preference (Bradley-Terry), updated from observed user choices. The user picks one of two suggestions; the substrate nudges the weights toward what the user picked.

**Where it lives.** VectorKit holds the composite (`HybridRecall`). NeuronKit holds the preference update and the exploration bandit. CognitionKit recipes choose the ranking mode and emit the trace that feeds the update.

# 11. Federation: two estates that speak

**What it is.** Two MOOTx01 estates can compare notes without merging. The process is deliberate: the two estates exchange identity, agree to a pairing, derive a shared family of hash hyperplanes, and from that point can compare fingerprints. They do not become one estate. They become a pair that can ask each other questions.

**Why we chose it.** Memory is personal. Two people in the same household should be able to ask "what does June look like" and get an answer that draws from both of their MOOTs, without either of them giving up control of their own memory. The handshake makes the comparison possible. The bounded pairing ensures it stays narrow: pairing is reflexive and symmetric, but not transitive, so your pairing with your spouse does not implicitly pair you with their employer.

When two estates aggregate to a tier above them (a household, a team), we add bounded noise to the contribution. The technique is called randomized response. It gives us a formal privacy budget that we can show to a user or to a regulator.

**Where it lives.** ConvergenceKit holds the identity layer, the handshake, the hyperplane exchange, and the sync engine. GeniusLocusKit drives cross-estate operation.

**Failure mode to know.** A fingerprint comparison across two estates that have not exchanged seeds is meaningless. The substrate refuses the comparison rather than producing a number that looks valid but is not.

# 12. Kernel dispatch: the same math, the right backend

**What it is.** The substrate's hot operations (bitmap reduction, Hamming distance, popcount, fingerprint generation, OR-reduce) have multiple implementations. A scalar reference. A SIMD version. A GPU version. The dispatcher picks one at runtime based on the hardware. Every implementation produces bit-identical output to the reference, verified by a conformance test against shared vectors.

**Why we chose it.** Bandwidth, not arithmetic, is the bottleneck for these operations. The right backend on a given chip is an empirical question, not a theoretical one. By measuring rather than assuming, we settled on SIMD as the production default for Apple Silicon, with the matrix coprocessor retained for the genuine matrix work in the matrix tier. The GPU path was tested and rejected at the sizes we operate on; it remains compiled and benchmarked so we can re-evaluate as hardware changes.

**Where it lives.** SubstrateLib holds the kernel trait and the backends. The
conformance harness lives in
`docs/validation/substrate_math_performance/test-harness/`. The current
selection and measurements live in
`docs/engineering/SUBSTRATE_PERFORMANCE_GATE.md`.

**Conformance gate.** Non-negotiable. A faster kernel that produces different output is broken, not faster. Every backend, on every platform, is gated against the byte-identical output of the scalar reference before it can ship.

# 13. The row state automaton and the safety results

**What it is.** Every row in the substrate is in one of ten states. The transitions between states are not arbitrary; they are driven by the substrate's verbs, and the legal transitions are enumerated. One state, "tombstoned," is terminal. Certain combinations are forbidden outright (for example, "secret" and "public" cannot both be true on the same row).

**Why we chose it.** A row that can take any value at any time is a row that cannot be trusted. By constraining transitions, we get three useful guarantees, each of which we hold ourselves to.

- **Reachability.** Every state can be reached from a fresh row by some legal sequence of verbs. No state is a dead letter.
- **Liveness.** Every non-terminal state has at least one way out. No row gets stuck.
- **Safety.** Forbidden combinations are unreachable. Not unlikely. Unreachable. The validator intercepts every write before it commits.

**Where it lives.** LocusKit's `DrawerStateValidator` enforces transitions and forbidden combinations on every write path.

**Why this matters for trust.** When a maintainer reads code that assumes "an active row cannot also be tombstoned," they can rely on that assumption because the validator has already rejected anything that would violate it. The invariants are not documentation. They are gates.

# Closing notes for maintainers

A handful of operating principles, distilled from the math and the engineering record.

**The substrate is measured, not asserted.** Every kernel selection in the production default came from a measurement on real hardware. Decision records cite the hardware tag, the commit, and the benchmark JSON. When something gets faster, we measure it. When something is supposed to be faster but is not, we keep the old one. There is no learned dispatch and no per-batch tuning; those add complexity we have not earned.

**The audit log is the substrate.** It is not a sidecar. Code paths that bypass the log produce state that cannot be replayed, replicated, or audited. There is no exception worth that cost.

**The conformance gate is the kernel's correctness contract.** Bit-identical output to the scalar reference, across every vector, on every backend, on every platform. A kernel that is not bit-identical is broken. The CRC mismatch is the diagnosis.

**The four-block fingerprint is the structural coordinate of the substrate.** When in doubt about how two rows relate, measure their Hamming distance. The blocks are designed so that distance has meaning across noun types, which is what lets one moment summary aggregate drawers and ambient samples together.

**Where to go next.** Start with `docs/engineering/README.md`, use the GeniusLocus
cookbook for the algorithm contract, the performance gate for current backend
selection, and the conformance harness in
`docs/validation/substrate_math_performance/test-harness/` to prove a change
before it ships.

The mathematics behind this guide is held internally. If you find yourself needing it to make a change, that is a sign the change belongs upstream with the substrate team, not in a kit-level mission. Ask before you reach for it.

---

*Maintainers' guide. Derived from the substrate engineering cookbook and the substrate mathematics treatment. The full mathematical derivations are not included by design.*
