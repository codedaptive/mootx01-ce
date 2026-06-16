---
status: superseded
authors: MOOTx01 maintainers
date: 2026-06-14
version: 1.0.0
description: "Behavioral specification for NeuronKit: invariants, conformance requirements, and the contract it guarantees."
package: NeuronKit
kind: Kit
relates_to:
  - NEURONKIT_INTERFACE.md  (the API surface this spec contracts)
  - GENIUSLOCUSKIT_SPEC.md  (the estate verb surface every substrate touch flows through)
  - GENIUSLOCUS_ARCHITECTURE_SPEC.md  (the Brain layer, recall fusion, branch COW, autonomic daemons)
  - EIDETICLIB_SPEC.md  (the deterministic text-to-anchor lookup NeuronKit composes)
  - ENGRAMLIB_SPEC.md  (the Hamming distance primitive MMR ranking uses)
  - LOCUSKIT_SPEC.md  (the read-only Drawer value type and adjective-state the reasoning surface shapes)
  - COGNITIONKIT_SPEC.md  (the not-yet-built consumer that composes NeuronKit into named recipes)
purpose: |
  NeuronKit is the subconscious mind of the MOOTx01 substrate: the
  algorithms layer that hosts the autonomic daemons (dreaming,
  maintenance, the audit-chain monitor) and the reasoning functions
  (lattice-anchor inference, hybrid recall, MMR diversification,
  context synthesis, branch operations, the migration benchmark,
  tournament ranking, Bradley-Terry strength estimation). It owns no
  substrate state. Every substrate touch flows through the
  GeniusLocusKit estate verb surface; the one acknowledged exception is
  read-only LocusKit value-type access used to shape reasoning value
  types. The companion INTERFACE document carries the signatures.
superseded_by: ../reference/NEURONKIT_SPEC.md
---

# NeuronKit Specification

> **Superseded** by [docs/reference/NEURONKIT_SPEC.md](../reference/NEURONKIT_SPEC.md)
> on 2026-06-14. Preserved for historical reference; the present-tense
> normative language below describes a past snapshot, not current behavior.

## § 1 — What this package is

NeuronKit is the algorithms layer of the MOOTx01 substrate — the
"subconscious mind." It sits above GeniusLocusKit and offers two
families of function:

- **Autonomic functions.** Background daemons that mine substrate state
  and *propose* changes for human confirmation: the dreaming daemon
  (latent-association discovery, § 3.1), the maintenance daemon
  (five health scans + the audit-chain integrity monitor, § 3.2 / § 3.5).
  Each is a Swift `actor` that ticks on a schedule and on demand, and
  whose only writes are proposals plus one cycle diary entry. They
  never mutate the substrate directly.
- **Reasoning functions.** Pure, on-demand computations: lattice-anchor
  inference (§ 4.0), hybrid recall (RRF + MMR, § 4.1), standalone MMR
  diversification (§ 4.1 step 4), context synthesis (§ 4.2), copy-on-write
  branch operations (§ 4.3), the migration recall-fidelity benchmark
  (§ 4.7), tournament ranking (§ 4.4), and the Bradley-Terry batch MLE
  ranker (§ 4.4).

NeuronKit is consumed by CognitionKit (the named-recipe layer), which is
not yet built; see `COGNITIONKIT_SPEC.md`. NeuronKit itself ships no
user-facing recipes.

This package is a **Kit**: it manages lifecycle (the daemon actors carry
actor-isolated mutable state across cycles) and composes upstream kits.
Its reasoning engines are pure and stateless; the autonomic daemons are
the stateful surface.

## § 2 — Scope

This specification defines:

- The substrate-access discipline (B-1) and the one acknowledged
  read-only LocusKit value-type exception.
- The dreaming daemon: its seam architecture, the seven-step tick, the
  contrastive-confidence and EWC++ consolidation math, and the
  never-create-Tunnels structural guarantee.
- The maintenance daemon: the five health scans, the audit-chain monitor,
  and the never-remediate structural guarantee.
- The reasoning functions: lattice-anchor inference, hybrid recall
  (RRF + MMR), standalone MMR, context synthesis, branch operations,
  the migration benchmark, tournament ranking, and Bradley-Terry.
- Determinism obligations (`now` passed in, never `Date()` in engines).
- The conceptual error model.
- Cross-port (Swift / Rust) conformance obligations and the documented
  Rust-narrower gaps.

This specification does NOT define:

- API signatures — those live in `NEURONKIT_INTERFACE.md`.
- The estate verb surface, branch COW mechanics, or the Brain-layer
  adapter that binds the daemon seams to live verbs — those are
  GeniusLocusKit's (`GENIUSLOCUSKIT_SPEC.md`).
- The linguistic pipeline (tokenize, normalize, stem, gazetteer-match,
  classify, resolve) — that is EideticLib's (`EIDETICLIB_SPEC.md`).
- The Hamming distance primitive — that is EngramLib's
  (`ENGRAMLIB_SPEC.md`).
- Storage, SQL, and the `Drawer` schema — those are LocusKit's
  (`LOCUSKIT_SPEC.md`).
- User-facing recipes — those are CognitionKit's
  (`COGNITIONKIT_SPEC.md`).

## § 3 — Position in the kit family

```
EideticLib      EngramLib      LocusKit (read-only value types)
     ▲              ▲                 ▲
     │              │                 │
   GeniusLocusKit (estate verb surface; branch COW; Brain layer)
     ▲
   NeuronKit   ← composes all of the above
     ▲
   CognitionKit   (named recipes — NOT BUILT)
```

**Depends on:** EideticLib (text-to-anchor `lookup`), EngramLib
(Hamming `distance` for MMR), GeniusLocusKit (the `EstateHandle`, the
nine estate verbs, branch COW verbs, `ExternalCorpus`,
`AuditChainVerifier`), and LocusKit (the read-only `Drawer` value type
and its read-only adjective-state accessors — the B-1 exception, I-2).

**Consumed by:** CognitionKit (not yet built). There are **zero
external in-tree consumers** of NeuronKit; the recipe layer that would
compose it has not shipped.

## § 4 — Invariants

**I-1 (no autonomic substrate writes outside `propose` + diary):** an
autonomic daemon's only writes are proposals (via the estate `propose`
verb, in production) and exactly one cycle diary entry. It has no other
write path, structurally: the daemon's write seam exposes only
`propose(_:)` and `recordCycleDiary(_:)`.

**I-2 (read-only LocusKit value-type exception):** NeuronKit may import
LocusKit solely to reference the `Drawer` value type and its read-only
adjective-state accessors (`isCurrentlyBelieved`, `adjectiveSensitivity`,
`exportability`) when shaping reasoning value types and synthesis math.
This is the single acknowledged exception to B-1. No LocusKit verb call,
no SQL, no storage handle is reachable from NeuronKit. (See B-1.)

**I-3 (forbidden-combination discipline):** a drawer may not be both
`secret` AND publicly exportable. The maintenance daemon scans for this
and proposes a discipline-violation remediation; the substrate, not
NeuronKit, owns the constraint. (LocusKit § 6.1.)

**I-15 (parent never modified by branch derivation):** deriving a COW
branch never mutates the parent estate. The guarantee lives in the
GeniusLocusKit substrate; NeuronKit's branch wrappers are thin forwards
and add no second place the guarantee could drift. (GeniusLocusKit
C-10.)

**I-16 (tournaments never auto-promote):** `runTournament` performs zero
substrate writes and never calls a branch-promotion verb. Its `winner`
is advisory only. Promotion is a separate, human-initiated GeniusLocusKit
verb (`glkPromoteBranch`).

## § 5 — Behavioral contracts

**B-1 (substrate access discipline):** NeuronKit never executes SQL and
never calls LocusKit, VectorKit, CorpusKit, PersistenceKit, or QueueKit
write APIs directly. The GeniusLocusKit estate verb surface is the only
substrate boundary. EngramLib (`distance`) and EideticLib (`lookup`) are
typed-math / lookup dependencies with no substrate, SQL, or estate
access, consistent with B-1. The one acknowledged exception is the
read-only LocusKit value-type access in I-2. Because the Brain-layer
verb surface is not yet live (the GeniusLocusKit `propose` verb raises
`notSupportedByEstate`, and no verb yet reads recall traces, existing
tunnels, drawers, or the audit log, or writes a diary entry), the
daemons depend on NeuronKit-owned **seam protocols** that the production
Brain-layer adapter will bind to live verbs. The daemons reference
substrate *value* types but call no substrate *method*, so B-1 holds
structurally today.

**B-2 (proposals are not actions):** every autonomic function that
detects something needing human attention emits a `ProposeFrame`; it
never applies the change. The dreaming daemon proposes Tunnels but never
creates one (its sink has no Tunnel-creation method); the maintenance
daemon proposes remediations but never remediates (its sink has no
expunge / withdraw / mutate method).

**B-3 (reasoning functions have no autonomic side effects):** the
reasoning functions read their inputs, compute, and return. The sole
documented substrate touch among them is the migration benchmark
(§ 4.7) and tournament ranking (§ 4.4), which issue ONLY the read-only
`BranchHandle.recall(_:)` and no write verb. Context synthesis (§ 4.2)
reserves its `estate` parameter and touches it not at all (C-9).

**B-4 (autonomic idempotency):** re-running a daemon over unchanged
state emits no duplicate proposals. Each daemon keeps an actor-isolated
set of already-proposed candidate keys; a key already proposed in a
prior cycle is suppressed and counted, never re-emitted.

**B-5 (deterministic engines):** every NeuronKit computation is a
deterministic function of its inputs. No engine reads the wall clock —
`now` is always a caller-supplied parameter (the daemon `pump`/`trigger`
methods, the benchmark, the tournament, the dreaming/maintenance cycles).
There is no unseeded randomness and no hash-order iteration that reaches
the output: ties break on stable keys (input index, ascending ID
string, geometric-mean-normalised strength), so the Swift and Rust ports
agree bit-for-bit on shared vectors.

**B-6 (hybrid recall is bounded by the verb surface):** the `recall`
verb returns a single ordered `[Drawer]` (its internal RRF over the BM25
and vector lists is drained inside the GeniusLocusKit boundary). The
hybrid-recall wrapper therefore runs the RRF math over a degenerate
(L₁ == L₂) input and applies MMR using a deterministic, vector-free
shingle-Jaccard proxy — actual embedding similarity is not reachable
under B-1. The tuning knobs (`bm25Weight`, `vectorWeight`, `rrfK`,
`mmrLambda`) are preserved so the day the verb surface exposes separate
lexical and semantic lists, only the fan-in changes.

**B-7 (the migration benchmark is zero-tolerance for silent loss):**
`benchmark`'s `notFoundInBranch` set lists concepts present in the
origin corpus but absent from branch recall. A conforming migration
yields an empty set; any non-empty value disqualifies the branch from
tournament ranking downstream (the C-13 gate, applied before scoring).

## § 6 — Error model (conceptual)

NeuronKit's reasoning surface is mostly total — edge inputs (empty
candidate lists, `k <= 0`, empty corpora) return empty / neutral results
rather than throwing. The one module that raises typed errors is the
Bradley-Terry fitter, which owns NeuronKit's `MOOTx01Error` enum per the
project convention (one typed error enum per owning module, never optionals
plus logging). Daemon and branch operations surface upstream
GeniusLocusKit verb errors unchanged.

Standalone MMR (`mmrRank`, § 4.1 step 4) enforces one domain
precondition: `lambda` must be in `[0, 1]`. The MMR score
`λ·relevance − (1−λ)·maxSim` is a convex blend only on that interval;
an out-of-range λ produces out-of-spec scores. The check is a
process-terminating precondition (programmer error, the substrate
convention), enforced identically in the Swift and Rust ports.

| Category | Trigger | Recovery posture |
|---|---|---|
| Self-pairing (`selfPairing`) | A `PairwiseOutcome` has `winner == loser` — a malformed tally, not a quantity-zero record. | Abort the fit; surface so the caller corrects tally construction. Never silently dropped. |
| Disconnected comparison graph (`disconnectedComparisonGraph`) | The directed win graph is not strongly connected, so the BT MLE is not finite (a competitor never wins, or never loses, or a group is uncompared). | Abort the fit; finite confidence intervals cannot be represented for a non-finite estimate. |
| MMR lambda out of range (precondition) | `mmrRank` / `MMREngine.select` called with `lambda < 0` or `lambda > 1`. | Process-terminating precondition; the caller must pass `lambda ∈ [0, 1]`. |
| Verb error (forwarded) | A branch op, benchmark, or daemon proposal hits a stale handle or a not-yet-live verb (`estateNotOpen`, `notSupportedByEstate`). | Forwarded unchanged from GeniusLocusKit; the caller retries or aborts per the verb's contract. |

Rust version note: the Rust version models the two fitter errors as a
crate-local `TournamentError` enum (`SelfPairing`,
`DisconnectedComparisonGraph`) rather than a shared `MOOTx01Error` name.
The *cases* and their triggers match; the *type name* differs across
ports (documented drift — see § 7 C-6 and INTERFACE § 4).

## § 7 — Conformance requirements

**C-1 (dreaming cadence):** the dreaming daemon fires a cycle once its
configured `tickIntervalMs` has elapsed since the last tick (the spec's
±10% jitter tolerance is satisfied exactly: the scheduler fires as soon
as the full interval elapses). The first `pump` always fires.

**C-8 (MMR on every page):** hybrid recall applies MMR reranking to the
full result before paging, so every emitted `RecallStream.Page` is drawn
from the reranked sequence. Even an empty result emits one terminal page
(`rows.isEmpty`, `isLast == true`).

**C-9 (synthesis is read-only):** `ContextSynthesizer.synthesize`
performs no estate write, invokes no estate verb, and consults no
substrate state beyond the materialised `page.rows`. Its `estate`
parameter is reserved and untouched.

**C-13 (zero silent migration loss):** the migration benchmark's
`notFoundInBranch` is empty for a conforming migration; a non-empty set
disqualifies the branch from tournament ranking (the gate is applied
BEFORE scoring, and disqualified branches are retained with a typed
reason rather than dropped). The benchmark's only substrate call is the
read-only `BranchHandle.recall(_:)`.

**C-15 (reward source):** the dreaming daemon derives reward from
`RecallTraceItem.used` via the default `RecallTraceRewardSource`
(used → 1.0, unused → 0.0). Ignoring this source is non-conformant. The
two-source taxonomy (implicit recall-trace + explicit `DiaryEntry.reward`)
is preserved at the type level; the explicit source is a documented seam
the substrate does not yet populate.

**C-Det (cross-port determinism):** for every shared test vector, the
Swift and Rust ports agree bit-for-bit on the reasoning engines they
both implement — lattice-anchor inference, hybrid-recall rerank /
shingle similarity / paging, context synthesis, and the Bradley-Terry
fit (strengths AND confidence-interval bounds). Tie-breaks resolve on
stable keys so the agreement is exact.

## Changelog

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
