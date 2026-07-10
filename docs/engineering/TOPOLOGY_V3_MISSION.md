---
title: Topology V3 — Persistent Multilevel Semantic Zoom
version: v0.5
status: implemented-p0-through-p3
date: 2026-07-09
supersedes_title: "Topology V2 Phase 4 — Folds (governor-side subcommunities)"
description: "Design direction: replace the decorative random-scatter brain with a persistent, multilevel topology the user can zoom — graph relationships supply position, FDC supplies meaning, centrality supplies emphasis, time supplies activity. Folds become one level of this, not the whole feature."
relates_to:
  - docs/reference/MOOT_MGR_SPEC.md
  - docs/reference/NEURONKIT_SPEC.md
---

# Topology V3 — Persistent Multilevel Semantic Zoom

> **Supersedes** the v0.1 "Folds" draft. Folds survive as the Community
> level of this design, but the v0.1 framing ("subclusters from local graph
> structure PLUS drawer-level FDC distribution") is corrected below — FDC
> must not manufacture the structure it then labels.

## Delivery status

This worktree implements P0.1 through P3 in both Swift and Rust: truthful
explicit-edge lifespans, shader-side idle breathing, persisted overlap-matched
community/fold identities with strict-majority continuity, bridge-weighted
fold placement, neighbour-relaxed new-node positions, stable normalized
coordinates, aggregate bridges, Q16 compact positions, hard level budgets,
Estate → Community → Local drill, and activity projected onto exact current
aggregates. V2 snapshots remain compatible and the default no-`level` API
remains the legacy full view.

P4 remains a separately gated storage feature. Genuine historical topology is
not represented as complete until a versioned snapshot/delta store, ranged
event cursor, retention window, split/merge lineage, and FDC-version intervals
exist in both persistence legs. The replay label therefore remains "activity
over current map."

## The problem this fixes (measured + read from the code)

Two independent findings, both confirmed:

1. **Performance (Scorandum, live 52,717-node estate):** the renderer ran
   physics + full node/edge rebuild + ~4.47 MB GPU upload every frame,
   forever, on a graph that stops moving in seconds. Fixed immediately by
   settle-detection + dirty-flag uploads (shipped, commit `8f9604ef`). A
   further lever remains: node "breathing" still runs a CPU alpha/colour
   loop while settled (~0.84 MB/frame) — moving breathing into the shader
   (time uniform + per-node phase attribute) makes the settled state a true
   zero-upload idle.

2. **The layout is not a topology.** XY is `Math.random()` scatter around
   ring-placed community centres (app.js `brainCenters`, member scatter
   ~1789); only the ~14 largest communities get a centre; Z is centrality
   rank (app.js `brainAssignDepth`). So position encodes *which community*
   and nothing about intra-community structure, the scatter **re-randomises
   every layout** (no stable mental map), and Z gives visual depth, not a
   third structural axis. At 52k nodes with 92% of edges touching a hub,
   this necessarily renders as an ovoid haze regardless of frame rate. A
   *fast* blob is still a blob.

## Two principles that constrain the whole design

**P1 — Position is earned from graph relationships, not assigned at random
or by classification.** A knowledge map must preserve the user's mental
map: the same estate lays out the same way across refreshes. Layout is
therefore computed once (governor-side) and **persisted**, not re-scattered
client-side per render.

**P2 — FDC describes structure; it does not manufacture it.** Discover
communities and folds primarily from graph relationships (tunnels, kgFact
bonds, co-activity). Apply FDC afterward as **labels, colour, purity, and
disagreement**. **Start with ZERO FDC influence on clustering** (Bob's
ruling): the first implementation is topology-only. Add a *weak, measurable
regulariser* later ONLY if topology-only results prove insufficient, and
even then keep a **topology-only baseline preserved alongside** so we can
always see where graph structure and classification disagree. Without this, the display fabricates circular confidence — "these
memories form an FDC topic cluster" *because FDC was used to force the
cluster*. The disagreement between structure and label is itself a
first-class signal (it surfaces mis-classification, bridge topics, and
import artefacts).

## The design: semantic zoom, four persistent levels

Every memory is always accounted for — at coarse levels through aggregate
size, density, and counts, never by disappearing. Roles are cleanly
separated: **graph → position, FDC → colour/meaning, centrality → emphasis,
time → activity at the current level.**

| Level | Primary objects | Individual memories | Position source |
|---|---|---|---|
| **Estate** | Communities/folds as aggregate blobs; weighted bridge bundles between them; activity pulses | Represented by size/density/count only | Persisted community layout |
| **Community** | Subfolds + a **balanced representative skeleton** | Skeleton nodes shown; rest as density | Persisted intra-community layout |
| **Local** | Individual memories + their actual tunnels/bonds | All shown | Persisted local embedding |
| **Selection** | The selected memory's immediate neighbourhood | All in-neighbourhood | Focus layout around selection |

### The representative skeleton is balanced, not centrality-only

Selection for the Community-level skeleton includes, deliberately:

- per-community representatives (so every subject community is present);
- **bridge nodes by betweenness** (structurally critical, low eigenvector
  centrality — invisible to a centrality-only cut);
- recent-activity nodes;
- anomalies;
- the currently explored neighbourhood.

Eigenvector centrality supplies *emphasis* (size/glow) within this set —
never the membership of it. The earlier "top-200 by centrality" idea is
rejected: that metric is hub-dominated and would hide exactly the small
coherent communities the estate should make the user feel are present.

## The temporal contract (time is the fourth dimension, and it must be truthful)

Time is not a decorative pulse layer. A single playhead `t` drives every
zoom level, and the design distinguishes temporal *presentation* from
temporal *truth*.

**Presentation (all levels share one clock):**

- One playhead `t`. In activity-projected replay, the **current persisted
  scaffold stays fixed**. In historical-topology replay, time-versioned
  communities may split, merge, appear, and disappear, but every version is
  aligned into one stable estate coordinate frame so unchanged structure does
  not jump as `t` moves.
- Estate level replays community size, density, bridge-traffic, and
  activity; Community level replays fold growth and representative-node
  activity; Local level shows actual node **and edge** births, changes, and
  tombstones.
- Only aggregates/objects that changed at a replay step become dirty (reuses
  the settle/dirty-flag model — replay is just a driven sequence of dirty
  frames).
- An event whose drawer isn't in the current view is shown as honest
  **"unmapped activity"**, never projected onto a substitute community
  member. (Today the radar substitutes an arbitrary member — app.js ~3790 —
  which is a truth violation, not a rendering detail.)

**Truth (what the data must support):**

- **Edge time is type-specific.** Explicit tunnel edges already have an honest
  lifespan: `Tunnel.filedAt` becomes `createdTs`, and tombstoned tunnels retain
  `tombstonedTs`. Derived `kgFact` and `nmf_bond` edges deliberately have no
  single birth instant; they are present-day inferences until provenance can
  establish effective intervals. Replay must never imply a historical lifespan
  for those edges.
- The explicit-tunnel timestamps were lost at two projection boundaries, not
  in estate storage: commit `ce5562da` removed `createdTs` from moot-mgr's
  decoded edge, then `f449f2a1` introduced compact `[s,t,w,type]` edges and
  omitted the still-decoded `tombstonedTs`. **Prerequisite fix (bounded, no
  migration):** restore both values through a dictionary/index or integer-delta
  compact representation in Swift and Rust; filter explicit tunnels by
  `[createdTs, tombstonedTs)` at the playhead; retain the existing 5 MB fixture
  ceiling. Derived edges carry an explicit `presentInference` temporal status.
- **The honest-labeling fork.** Today's replay projects the last N events
  (default 100, MootManager.swift ~690) onto the CURRENT community layout —
  it is *recent activity on today's topology*, NOT the historical graph
  evolving. V3 must pick, explicitly and per level:
  1. **Activity-projected replay (cheap, truthful-if-labeled):** keep
     projecting activity onto the current persisted scaffold, but LABEL it
     as exactly that — "activity over the current map," not "the graph
     through time." Node alive(t) still honors createdTs/tombstonedTs; edge
     lifespan honors the restored timestamps; community/fold structure is
     shown as *present-day* structure with historical activity flowing over
     it.
  2. **Genuine historical topology (expensive, world-class):** the governor
     persists **timestamped topology snapshots or deltas** — node membership
     changes, edge births/deaths, fold/community splits/merges, and FDC
     classifier/version changes — so the scaffold itself can be reconstructed
     at `t`. Only this supports "watch the estate's structure actually form."
- The mission must not ship replay that *looks like* (2) while only having
  the data for (1). Default to (1) with honest labeling; earn (2) when the
  governor delta-persistence exists.

**Historical query and retention contract:**

- `GET /api/events` must support an explicit `[from,to]` range, stable cursor,
  deterministic ascending order, and a documented maximum page size. "All"
  means all pages inside the selected retained range, never merely the default
  100-event response.
- Estate and Community replay consume governor-produced temporal aggregate
  deltas (member counts, activity counts, bridge weights, splits/merges), not a
  browser rescan of every memory on every tick.
- Retention is explicit in the response (`availableFrom`, `availableTo`,
  `truncated`); the UI cannot scrub outside the truthful window.

**FDC time semantics:**

- Activity-projected replay uses the current corrected FDC interpretation and
  labels it **current classification**.
- Historical-topology replay may show the classification recorded at `t` only
  when the anchor code and classifier/data version were persisted for that
  interval. The UI exposes the version and never silently substitutes current
  FDC for historical FDC.

## What the governor computes and persists (both legs, Swift leads)

1. **Community + fold assignment** from graph structure (Louvain, then a
   deterministic farthest-seed, multi-source geodesic partition within large
   communities), with zero FDC influence in V3. Store `communityId`, stable
   `communityKey`, and stable `foldKey` (nullable for historical-only nodes).
2. **A persisted, INCREMENTAL layout** — a stable seed alone does NOT
   preserve positions as the graph grows (V3 decision): a re-seeded layout
   still churns when membership shifts. Use **persistent community IDs keyed
   by membership overlap** across cycles (a community that mostly retains its
   members keeps its id, hence its position), plus an **anchored/incremental
   layout** that perturbs from the prior positions rather than recomputing
   from scratch. New nodes attach near their neighbours; existing nodes
   barely move. This is what actually preserves the mental map.
3. **Level-of-detail aggregates with explicit budgets** — per-community/fold:
   member count, FDC purity, representative ids, and bridge edges + weights,
   so the Estate/Community levels render from aggregates, not 52k points.
   Estate is capped at 96 aggregates with an accounting-preserving "Other
   structure" node; folds are capped at 64 per community; Local is capped at
   2,000 nodes and 12,000 edges and reports truncation. Its edge budget keeps a
   structural spanning forest before ranked detail. Level changes are explicit
   object drill actions rather than camera-distance thresholds, eliminating
   threshold flicker and making navigation keyboard-accessible.
4. **Temporal aggregate deltas** keyed by stable community/fold identity, with
   split/merge lineage and an aligned coordinate-frame version. These are the
   Estate/Community replay source; individual event pages remain the Local and
   Selection replay source.
5. **FDC as an overlay column** on the existing per-node `code`/`codeIndex`
   wire (V2-P1b), with aggregate classification purity as the visible
   structure-vs-classification disagreement signal.

## Blast radius (verify at dispatch — SPEC-BEFORE-REALITY)

TopologyAnalysis + AutonomicGovernor snapshot writer (both legs), moot-mgr
GraphPayload (both legs, new persisted-layout + aggregate fields against the
5 MB ceiling), DashboardAssets (a real renderer rework: level-of-detail,
zoom transitions, aggregate objects — not a tweak). Re-run codegraph impact
at dispatch.

## Sequencing (proposed — Kong review before dispatch)

- **P0 (shipped):** settle + dirty-flag uploads.
- **P0.1 (implemented):** shader-side breathing → zero-upload idle.
- **P0.2 (implemented):** restore compact explicit-edge lifespans in both ports; remove
  substitute-node replay; label the current mode "activity over current map";
  add payload-size and alive-at-`t` parity gates.
- **P1 (implemented):** governor persisted community layout + LOD aggregates + wire; the
  Estate level renders aggregates with stable positions (kills the blob and
  the mental-map churn without any client clustering).
- **P2 (implemented):** Community level — folds + balanced representative skeleton +
  topology-only-vs-FDC disagreement surfaced.
- **P3 (implemented):** Local + Selection levels with explicit drill navigation.
- **P4 (separate storage mission):** paginated time-range API, retained temporal aggregate deltas,
  split/merge lineage, FDC-version history, and genuine historical-topology
  replay in the stable estate coordinate frame.

## Acceptance gates

- **Truth:** every visible object at `t` has a documented temporal basis;
  present-day inferences are visually and programmatically distinguishable
  from historical facts.
- **Accounting:** aggregate counts reconcile exactly with visible descendants
  at the next level and with the live estate at the end of the playhead.
- **Stability:** unchanged nodes and communities move no more than a defined
  epsilon between consecutive snapshots; split/merge lineage is deterministic.
- **Scale:** the 52k-node fixture opens at Estate level without allocating GPU
  geometry for all individual nodes or edges; each level obeys its node, edge,
  and label budget.
- **Performance:** settled live view performs no per-node/per-edge CPU upload;
  replay work is proportional to objects changed at the step, not estate size.
- **Parity:** Swift and Rust emit byte-equivalent stable IDs, fold assignments,
  aggregate counts, bridge weights, temporal indexes, and replay visibility for
  shared golden fixtures.
- **Compatibility:** V2 snapshots decode without migration; missing V3 fields
  degrade to honestly labeled activity-projected replay.

## Validation evidence

- Swift/Rust shared numeric golden coordinates are byte-identical for the
  relationship-weighted layout fixture.
- A non-committed debug scale probe projected 50,000 nodes and 70,000 edges
  into the capped 64 folds in 9.62 seconds on the development host, inside the
  five-minute governor cadence. The fast unit lane remains free of this probe.

## Follow-on decisions

- Whether a post-V3 FDC regulariser is justified by measured topology-only
  failures; its weight remains exactly zero until that evidence exists.
- Whether P4 temporal deltas remain in `StatsStore` or receive a dedicated
  retained topology history store after the lineage and cursor contracts are
  specified.
