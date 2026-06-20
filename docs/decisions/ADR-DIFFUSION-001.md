---
status: proposed
question: How does MOOTx01 monitor change-over-time across the reduction hierarchy — the "motion" of memory — and turn it into anticipation, as the temporal peer of distillation?
authors: MOOTx01 maintainers
date: 2026-06-19
relates_to:
  - mootx01_distillation_math.md  (Sub-Quadratic Sparse-Selection — the space-axis reducer)
  - mootx01_diffusion_math.md     (the diffusion analogy — SNR, noise schedule, flow matching, delta features)
supersedes: none
context:
  - Distillation (intra-item reduction) is built and shipped per-item, Swift+Rust.
  - Diffusion is the unbuilt temporal peer. Its primitives (TypedDecayWeighting,
    DeltaFeatureExtractor, the SNR gate) already exist but were misplaced as
    distillation-pipeline stages; they belong here, across the layer hierarchy.
  - Verified: the audit log lacks the granularity to rebuild reduced positions
    (it records bitmap-flag deltas + lifecycle timing only — no content/room/anchor
    values). Option 3 below (log the reduced *position* fingerprint + zone) is the
    chosen substrate extension.
---

# ADR-DIFFUSION-001 — The Diffusion Layer: Memory in Motion

## Thesis

Distillation answers **"what is this?"** by reducing an item across its features —
the *space* axis. Diffusion answers **"where is this going?"** by tracking how the
reduced items move over time — the *time* axis. They are **peers**, not parent and
child. Diffusion runs *over* the distillation mirror (it watches the factoid
**positions** move rather than re-reading raw payloads — which is what makes it
cheap), so it is a peer in role and downstream in dependency.

Diffusion's product is **anticipation**: given how the data has moved, extrapolate
what comes next, at every zoom level, and serve that prediction both cold (to the
dreaming layer) and hot (to recall and the temporal lenses).

---

## 1. Position in the architecture

Three layers, each with a distinct job over the same memory:

| Layer | Axis | Question | Built? |
|---|---|---|---|
| **FDC zone** | address | *where does this live?* (coarse lattice region) | yes |
| **Distillation** | space | *what is this, in 10 words?* (intra-item reduction) | yes (per-item) |
| **Diffusion** | time | *where is this going?* (motion + anticipation) | **this ADR** |

Diffusion consumes the distillation mirror and the FDC zone assignment; it produces
the motion model and anticipation signals. It owns no reduction of its own — it
reduces the *temporal* dimension (a time-series of reduced positions → a trajectory).

---

## 2. Per-layer motion models — the temporal mirror of the distillation tree

Distillation builds a **spatial** hierarchy: item-factoid → zone-factoid →
estate-factoid (factoids-of-factoids, O(log N)). Diffusion is that **same hierarchy
tracked over time**: **a motion model exists at each layer, computed one layer at a
time** from that layer's own reduced representation.

- **Node** = an item's factoid fingerprint. Its motion = how its value changes
  (`apache → agpl_draft → agpl_final` traces a path).
- **Zone** = the aggregate (centroid / zone-factoid) of a zone's items. Its motion =
  the zone drifting, heating, cooling as items arrive.
- **Estate** = the distribution over zones. Its motion = attention pivoting.

Layers **roll up like factoids-of-factoids**: a zone's motion summarizes its items'
motions, the estate's summarizes its zones' — but each layer is a **first-class,
queryable object** at its own scale. They **compose** into anticipation: *estate
"pivoting to project B" + zone "B's testing is accelerating" + node "the deadline
date is still volatile."*

---

## 3. The zoom hierarchy **is** the noise schedule

The single most important structural insight: the diffusion noise schedule (high-
frequency detail decays first, low-frequency structure persists) is realized **across
the zoom levels**, not within one item's features. Each layer carries its own decay
constant λ and timescale:

| Layer | Frequency | λ (decay) | Behaviour |
|---|---|---|---|
| **Node** | high | large | fast decay, volatile, short memory (a fact flips in one capture) |
| **Zone** | mid | medium | drifts over days |
| **Estate** | low | small | slow, stable, long memory (attention pivots over weeks) |

**Node fast, estate slow.** This is where `TypedDecayWeighting` finally belongs:
not inside one item (where it is inert — an item is captured at a single time) but
as the **per-layer λ schedule** that governs how far back each layer's fold reaches.

---

## 4. What a motion model contains

Each layer's motion model is small and local — its reduced position over time, fitted to:

- **Trajectory** — the sampled positions (a short path in the reduced space).
- **Velocity** — the last displacement, `v = x_t − x_{t−1}` (flow-matching's
  straight-line field; the simplest honest extrapolator).
- **Volatility / spread** — the variance of recent moves (SNR-over-time): is this
  converging, stable, or thrashing?

Anticipation = extrapolate the trajectory forward at that layer; volatility sets the
confidence of the extrapolation.

---

## 5. Data substrate — the position-fingerprint audit extension (Option 3)

Diffusion needs a **time-series at each layer**. The distillation mirror is current-
state only. **Verified finding (refined 2026-06-19):** the substrate already carries
more than first thought.
- The `UnifiedAuditLog` records `{hlc, verb, rowID}` per change, so **mutation timing
  / lifecycle is already present** (node volatility is foldable today).
- The underlying `SubstrateTypes.AuditEvent` **already carries the lattice anchor**
  (`beforeLatticeAnchor`/`afterLatticeAnchor`, a `UInt64` UDC code) — so the **zone**
  is in the substrate, with before/after on `reanchor`. It is simply **not bridged**
  to the `UnifiedAuditLog` yet: `AuditBridge.bridge` emits only the three bitmap
  columns (`adjective`/`operational`/`provenance`).
- The only thing genuinely absent is the fine **content fingerprint** (the semantic
  position that moves on a value change *within* a zone, e.g. apache→agpl).

So Option 3 splits into a cheap, no-substrate-change foundation and a later
fingerprint enhancement.

**Decision — Option 3 (a): bridge the zone (no substrate change).** Extend
`AuditBridge.bridge` to also emit a `fieldPath:"latticeAnchor"` entry from the
event's before/after anchor (`.integer` of the UDC code). This unlocks **zone /
topic-trajectory motion + mutation-timing volatility** from the existing audit, both
ports, touching only the GLK bridge (the substrate `AuditEvent`/`AuditGate` are
untouched — the anchor is already there).

**Decision — Option 3 (b): add the content fingerprint (later).** For fine node
*value* trajectories, add a `fieldPath:"fingerprint"` (256-bit reduced position,
computed at capture). This is the only part that extends the substrate audit fields.

Rationale: same cost class as the existing bitmap entries (tiny, fixed-width), no
hot-path cost (positions are computed at capture anyway), **single source of truth**,
and **retroactive** — re-folding the existing log under new λ constants instantly
yields the full history under the new model (snapshots cannot do this; every retune
would discard the past). It deliberately **avoids content-history bloat** — we log
the *position*, never the content.

**Factoids over time (same hook).** Factoids are drawers, so the same fingerprint-in-
audit extension records *factoid* trajectories for free — and at the zone/estate
layers the position **is** the factoid, so this is the primary upper-layer signal,
not an add-on. It carries one coupling: factoids must be **versioned** — re-distilled
**in place** (mutate the factoid drawer; the audit logs fingerprint before→after) as
their inputs move. Today's per-item sweep is *skip-if-already-distilled* (write-once);
factoids-over-time requires it to become **update-on-re-distill**, and the
zone/estate factoids require the **multi-level distillation tree** (see §11).

---

## 6. The fold — per-layer decay-weighted reconstruction

The motion model is a **derived accelerator**, the same pattern as the matrix tier
(`MatrixTier.rebuild(from: log)`): not stored state, a fold over the audit log.

1. Replay the audit log in HLC order. Each layer's position evolves as events apply
   (a `capture` adds an item's fingerprint to its zone's centroid; a `mutate`/
   `reanchor` moves a node; a factoid re-distill stamps a new factoid position).
2. **Decay falls out of the timestamped fold.** Weight each event by its age:
   `w = exp(−λ_layer · Δt)`. **One log, N folds — one per layer/λ — N motion
   models.** The noise schedule is not a separate structure; it is the λ chosen per
   fold. The layers are not different *data*; they are the same data viewed through
   different decay constants.
3. **Cost is bounded.** Fast layers (large λ) fold only a recent window (old events
   weight ~0); only the slow estate layer touches the long tail, downsampled.
   **Incremental:** keep the computed motion model in memory (it *is* the cached
   fold, like the matrix tier) and each dreaming cycle fold only the *new* events
   since last cycle — steady-state O(new events), not O(all). Full re-fold is the
   cold-start / retune fallback.

---

## 7. The math — classical and deterministic

"Diffusion" is an **analogy**, exactly as SSA was for distillation. The
implementation is **classical trajectory analysis over the mirror — not a trained
diffusion network.** No LLM, deterministic, conformance-friendly (Swift and Rust
fold the same log to the same trajectory). The diffusion-paper primitives are
**relocated here**, where they are meaningful:

- `TypedDecayWeighting` → the **per-layer λ schedule** (§3).
- `DeltaFeatureExtractor` → **node-level supersession / convergence** detection
  (CONVERGENT / MONOTONE / OSCILLATING / DIVERGENT over a node's value path).
- **Consistency score** (`mutual_information` over positions) → **positioning**: how
  a new arrival sits relative to a layer's existing constellation; the write-time
  anomaly/supersession signal.
- **Velocity / extrapolation** → flow-matching's straight-line field, the anticipator.

They were inert/misapplied as per-item distillation stages (a single item is
contemporaneous — nothing decays *within* it). They come alive across items over
time. **Follow-up cleanup:** retire the now-dead temporal stages from the per-item
distillation path.

---

## 8. Anticipation

The deliverable. At each layer:

- **Extrapolate** the trajectory forward along its velocity, bounded by its
  volatility (a volatile node yields a low-confidence prediction; a smoothly drifting
  zone a high-confidence one).
- **Compose** across layers — estate-level direction × zone-level acceleration ×
  node-level stability — into a single anticipatory read.

Outputs: *"this value is converging to X"* (node), *"this zone is accelerating toward
Y"* (zone), *"attention is pivoting from A to B"* (estate), and *"this new fact breaks
the trend / supersedes belief Z"* (write-time).

---

## 9. Read surfaces & temperatures

Diffusion is **not** only a late/dreaming signal. The *integration* is cold; the
*anticipation it produces is read hot.*

- **Cold (dreaming).** The dreaming daemon folds the audit-position series per layer
  and maintains the in-memory motion model (a new dreaming duty alongside the matrix-
  tier rebuild). Late-arriving, expensive, the source of the model.
- **Hot (read the model).**
  - **The temporal lenses** — diffusion is the missing **engine** under already-
    shipped tools: `moot_lens_anticipate`, `drift`, `successors`, `constellation`,
    `theme_weather`, `rhythm`, `precedence`. They read the layer they care about
    (`drift` on a zone → zone-motion; `anticipate` on the estate → estate-motion).
  - **Anticipatory recall** — bias/pre-fetch toward where the trajectory points (a
    branch-predictor for memory). Diffusion becomes a **selectable signal family**
    the recall optimizer can fuse (RecallShape), not only a dream output.
  - **Write-time supersession / anomaly** — the consistency score at ingest:
    "this supersedes X / breaks the trend," flagged immediately, not next cycle.
  - **Freshness** — type-λ decay says a NUM fact is probably stale; proactively
    down-weight or re-verify.

---

## 10. Relationship to distillation

Peers over a shared substrate (the mirror). Distillation provides the **positions**;
diffusion tracks their **motion**. Distillation is intra-item and fires per item;
diffusion is intra-zone/-layer and fires in dreaming, read everywhere. Neither is a
stage of the other — the entanglement that put SNR/decay/delta inside the
distillation pipeline was the original modelling error this ADR corrects.

---

## 11. Build sequencing & dependencies

1. **Bridge the zone — Option 3(a)** — `AuditBridge` emits a `latticeAnchor` entry
   from the event's before/after anchor, both ports. **No substrate change** (the
   anchor is already in `AuditEvent`); touches only the GLK bridge + its tests.
   *Prerequisite for the fold.* Cheap, isolated. ← **building first**
2. **Node-layer motion model** — fold the node's `{verb, hlc, anchor}` history with
   λ_node: mutation-timing volatility + topic-trajectory + reanchor supersession +
   write-time anomaly. Buildable on Option 3(a) alone; does not need the multi-level
   tree. (Fine *value*-trajectory supersession waits on the content fingerprint,
   Option 3(b).)
3. **Content fingerprint — Option 3(b)** — add `fieldPath:"fingerprint"` to the audit
   (the only substrate-audit-field extension) for fine node value trajectories.
3. **Multi-level distillation tree** — zone-factoid / estate-factoid (factoids-of-
   factoids) + **update-on-re-distill** (versioned factoids). *Gates the zone/estate
   motion models* — they have no positions to track until the tree exists.
4. **Zone + estate motion models** — fold zone/estate factoid paths with λ_zone /
   λ_estate; deliver drift / theme_weather / estate anticipation.
5. **Hot wiring** — point the temporal lenses at the motion model; add the diffusion
   signal family to the recall optimizer.
6. **Cleanup** — retire the dead temporal stages from per-item distillation (§7).

---

## 12. Open decisions (to ablate, not guess)

- **The λ constants** (λ_node ≫ λ_zone ≫ λ_estate) and each layer's fold window /
  sampling cadence — informed priors from the diffusion analogy, to be tuned against
  real recall behaviour via the quality optimizer (the diffusion-math doc flags these
  as the open parameters).
- **Velocity model** — start with first-order (`x_t − x_{t−1}`); revisit
  higher-order / decay-weighted regression if first-order under-anticipates.
- **Extrapolation horizon** per layer (how far forward is honest).
- **Consistency-score threshold** for write-time anomaly vs. routine reinforcement.

---

## 13. Non-goals / explicit boundaries

- **Not a trained diffusion model.** Classical trajectory math over the mirror. A
  learned reverse process is out of scope (archived raws are fetched, not regenerated).
- **Not per-event real-time.** Integration is cold (dreaming); only the *read* of the
  cached model is hot.
- **Not inside distillation.** Diffusion is a peer layer; the per-item distillation
  path stays clean (its temporal stages are retired in §7).
- **No content history.** The audit extension logs the reduced *position*, never the
  content — retroactivity without bloat.
