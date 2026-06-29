---
status: decided
question: How should the dreaming daemon decide WHAT to dream about and WHEN to fire, so it (a) stops the O(room^2) per-cycle blowup, (b) runs in stdio as well as the resident daemon, and (c) proposes associations from what was actually recalled rather than what merely shares a room?
authors: MOOTx01 maintainers
date: 2026-06-26
relates_to:
  - docs/decisions/ADR-017-node-tree-containment-hierarchy.md
  - docs/decisions/ADR-018-brain-layer-governor-placement.md
  - docs/decisions/ADR-020-estate-manifest-consumer-kv-and-daemon-state-persistence.md
  - docs/reference/NEURONKIT_SPEC.md
  - docs/reference/QUEUEKIT_SPEC.md
supersedes: none
context:
  - Replaces the dreaming candidate-generation model (the "v1 node-grouping algorithm" in EstateDreamingReader.build*Observations) and the dreaming trigger model (blind 30s timer in the resident governor).
  - Changes which tunnels get proposed (co-recall instead of co-location), so it changes DreamingDecision conformance vectors. This is a v2 dreaming model.
  - No SQLite schema change to existing tables; adds a durable dreaming queue (QueueKit maildir beside the estate) and a co-recall counts store.
---

# ADR-021 — Recall-driven dreaming queue (dreaming v2)

> **Status: decided.** All seven phases shipped (T1–T14, 2026-06-26):
> co-recall queue replaces co-location (D1), four-cadence REM dispatch table
> (D5a/ALPHA/THETA/BETA/OMEGA), pending-gated ALPHA, persisted daemon state via
> estate manifest (F6/ADR-020), stdio dream runner, and T14 naming cleanup
> (BetaSeam → Beta). NEURONKIT_SPEC §9 C-1 updated to v2 model. Build is
> SQLite-first; Postgres queue-backend deferred to the Postgres pass.

## Context

### What dreaming does

The dreaming daemon (NeuronKit) proposes **tunnels** — associative links
between drawers — and files them as `Proposal` nouns for the downstream loop.
A pair `(a, b)` is proposed when its **contrastive confidence** clears
`minConfidence` (0.7) and it has been observed at least `minAttempts` (3)
times, and it is not already a tunnel or a prior proposal.

### How it works today (v1), and why it is broken

1. **Candidate generation — `EstateDreamingReader`** loads *all* live drawers
   (`all_drawers`), groups them by `parent_node_id` (room), and emits **one
   observation per pair of drawers sharing a room**. For a room of K drawers
   that is K·(K−1)/2 pairs.

2. **Trigger — blind 30s timer.** The resident `AutonomicGovernor` calls
   `DreamingDaemon.pump` every `tick_interval_ms` (30 000 ms) regardless of
   whether anything was recalled. The interval doubles as the reward lookback
   window (`since = now − interval`).

3. **Scoring — `DreamingDecision.decide`** computes, per observation, an
   InfoNCE contrastive confidence at `temperature = 0.2` against
   `baseline = minSuccessRate` (0.6), blends it with the EWC++ consolidated
   memory (`max(raw, consolidated · 0.9)`), then gates and emits.

**Measured on the real 49.5k-drawer estate:** the drawers concentrate into a
few large rooms (largest = 20 011 drawers); the all-pairs generator emits
**~275 million observations every 30 seconds**, allocates and sorts them, and
scores every one — building String-keyed maps sized to that count.

**The math that makes almost all of it waste.** With `temperature = 0.2`,
`baseline = 0.6`, `minConfidence = 0.7`, the contrastive confidence of a pair
is fixed by how many of its two endpoints carry recall reward in the window:

| endpoints rewarded | confidence | emits? |
|---|---|---|
| neither | `1/(1+e^(0.6/0.2))` = **0.047** | no |
| one | **0.377** | no |
| both | **0.881** | **yes** |

A pair can only clear the 0.7 gate via a fresh score if **both** endpoints
were recently recalled (the EWC retained term only *decays* a prior score, so
it never lifts a never-emittable pair over the bar). Therefore of the 275M
pairs, the only ones that can ever produce a proposal are the handful where
**both endpoints were co-recalled**. The other ~275M are generated, sorted,
and scored solely to be discarded — every 30 seconds, forever, even during a
bulk import or an idle estate where there is zero recall activity.

### Two further defects exposed while profiling

- **Dreaming never runs in stdio.** The governor — hence the timer, hence
  dreaming — exists **only in the resident `--http` daemon**. The default
  `serve` (stdio) starts no governor; it only forks a detached *encode*
  drainer when there is encode work. So a stdio deployment never forms
  associations at all.
- **`.event` / `.hybrid` are dormant.** `DreamingTriggerMode` and
  `pumpOnEvent` exist and are unit-tested, but nothing in production sets the
  mode off `.timer` or calls `pumpOnEvent`. And as designed, `.event` fires on
  `observationCount >= threshold` — a count that is itself the *output of the
  expensive O(room^2) build*, so it gates *after* paying the cost on a signal
  that is effectively always true. The event path, as wired, cannot save the
  work.

## Decision

Adopt a **recall-driven dreaming queue**: dreaming becomes an incremental,
event-sourced pipeline built on QueueKit (the same machinery the encode
pipeline uses), plus a bounded periodic consolidation sweep. There is **no
all-pairs co-location scan anywhere**.

### Decision 1 — Co-recall replaces co-location as the association signal ✅ RATIFIED (2026-06-25)

A candidate pair `(a, b)` is generated when `a` and `b` are **recalled
together** (returned/used in the same recall), not when they merely share a
room. Rationale:

- It is what the gate already enforces — only co-recalled (both-rewarded)
  pairs ever emit, so co-location was never the operative signal; it was an
  expensive pre-filter that the confidence math made redundant.
- It is the correct semantic for an associative memory: *link the things you
  pulled up together*, not *link room-mates that happened to be recalled*.
- It removes the room-size dependency entirely, so the candidate set is
  bounded by recall activity, never by estate shape.

**Consequence:** dreaming may now propose **cross-room** tunnels (two drawers
recalled together from different rooms), which v1 never could. This is the
intended upgrade, and it is the part that changes proposals — hence the
explicit ruling.

### Decision 2 — Enqueue on recall, drain on fire (a STREAM in the one per-estate queue)

> **Revised (2026-06-25)** from "a dedicated dreaming queue (maildir)" to "a
> `stream_id="dreaming"` stream in the ONE per-estate queue." See Decision 7
> for the queue topology + backend/encryption rule that motivated the change.

- The **recall verbs** (`EstateVerbs` recall path), after writing
  `recall_trace`, **enqueue a dreaming item** onto the per-estate queue under
  `stream_id="dreaming"`: the set of drawer ids surfaced/used in that recall
  (the reward targets), HLC-stamped. Batched enqueue (one commit per batch via
  `send_batch`).
- **"Dreaming fires" = drain the `"dreaming"` stream.** A **stream-scoped**
  drain (Decision 7) claims the available recall items *of that stream only*,
  unions their drawer sets, generates the co-recall pairs **within the drained
  window**, updates the co-recall counts, runs `DreamingDecision.decide`, and
  files proposals through the existing sink.
- **`pending_count(stream:"dreaming")` is the trigger.** Empty ⇒ nothing to
  dream ⇒ no work. No estate scan, no probe.
- The push model (enqueue the explicit co-recall set) carries the per-event
  grouping in the job payload, so it does not depend on a `recall_trace`
  recall-event id. `recall_trace` remains the **durable record** consumed by
  the longer-window REM cycles (§ Decision 5 THETA) and crash recovery; it is
  **not** the live ALPHA feed.

### Decision 3 — One mechanism for resident AND stdio

- **Resident daemon:** the governor tick drains the `"dreaming"` stream on its
  cadence; empty ⇒ no-op (idle/import cycles cost nothing). The 30s timer
  becomes "drain the stream if non-empty," not "scan the estate."
- **Stdio:** reuse the existing detached-drainer pattern. On `serve` teardown /
  next query, if the `"dreaming"` stream has pending items, fork a detached
  dreamer (as stdio already forks the encode drainer). **This is how stdio gets
  dreaming for the first time.**

### Decision 4 — `attempts` = co-recall count

`minAttempts` (3) now means "this pair has been co-recalled ≥ 3 times,"
maintained in a small persistent **co-recall counts** store keyed by pair,
updated per drained recall window. This is a stronger, cheaper gate than v1's
"the room has ≥ 3 drawers."

### Decision 5 — The REM schedule: four consolidation cycles at deepening cadence

Dreaming is **one engine** parameterized by `(window, decay, breadth, prune,
retire)`, instantiated at four cadences — the substrate's "REM cycles." They
are a consolidation *hierarchy*: each does work the faster ones cannot, and
none enumerates room pairs.

| Cycle | Cadence | Job | Window / scope | Decay | Tunnel writes |
|---|---|---|---|---|---|
| **REM-ALPHA** | 30 s | drain the dreaming queue → form fresh co-recall tunnels (Decision 2) | the just-recalled set | none — *form* only | propose |
| **REM-THETA** | hourly→daily | consolidation: emergent links across the day's events; bump `attempts` for repeats | last day of `recall_trace` | apply EWC decay | propose + adjust confidences |
| **REM-BETA** | weekly | **prune** — compact/GC the consolidated + co-recall-counts stores (memory-only) | internal stores | aggressive; drop decayed-to-floor entries | none |
| **REM-OMEGA** | biweekly | **retire** — forget tunnels no longer reinforced by recall | shipped tunnels + reinforcement history | — | **retire** |

Why each cycle earns its place:

- **ALPHA** buys latency — associations exist right after co-recall. Bounded by
  the queue; the only cycle that must be fast. This is the queue drain
  (Decisions 2–3); it is the only cycle that runs in **stdio** (via the
  detached dreamer).
- **THETA** buys what one recall can't see: links that only emerge from
  *repeated* co-recall over a day (so `attempts ≥ 3` finally has teeth), and it
  applies EWC decay so confidence ages. Bounded by the day's recalled set²
  (≪ room²).
- **BETA** buys **bounded memory growth** — it garbage-collects the internal
  consolidated/co-recall-counts stores (drops entries decayed below a floor).
  Memory-only: it changes no tunnels.
- **OMEGA** buys **forgetting of real associations** — it retires tunnels that
  recall no longer reinforces (the forgetting curve for shipped links). The
  rarest and most consequential cycle, deliberately isolated at the longest
  cadence so the one product-visible destructive op is the least frequent.

**The v1 O(room^2) co-location sweep is removed outright** — it can only
produce pairs the gate rejects.

Defaults proposed (open for ruling) — REM schedule:
- **D5a — periods:** ALPHA 30 s, THETA daily, BETA weekly, OMEGA biweekly.
- **D5b — OMEGA retirement is reversible, not destructive:** a retired tunnel
  is flipped via an `operational` bitmap bit (no Bool field; per schema
  invariant) and audited, so a later co-recall can re-form it. No hard delete.
- **D5c — stdio runs the periodic cycles opportunistically:** THETA/BETA/OMEGA
  need a persistent scheduler, so in the resident they are governor duties; a
  **stdio-only** deployment runs them lazily on invocation, gated by persisted
  last-run timestamps (the same "check-on-next-query" pattern stdio uses for
  the encode drain), so stdio-only estates still consolidate, prune, and retire
  — just on use, not on a clock.
- **D5d — OMEGA scopes to DREAMED provenance only (never retires declared
  links):** there are two association channels — **declared** (palace
  `tunnels.json`, vault wikilinks; imported directly via VaultKit PalaceBridge)
  and **emergent** (recall-driven dreaming). OMEGA's retire predicate is
  `provenance = dreamed AND not reinforced by recall`; it must never retire a
  declared tunnel (the user/source drew it deliberately — it persists until
  removed at its source). The `tunnels.provenanceBitmap` carries the
  dreamed-vs-declared bit; dreaming stamps emergent tunnels dreamed, and
  imports keep declared.

### Decision 6 — Trigger-mode semantics + stdio fork triggers ✅ RATIFIED (2026-06-25)

The trigger mode describes **who drives dreaming**, decoupled from *what runs*
(the REM cycles). The mode follows the serve shape (overridable):

- **`.timer`** — the process owns a long-lived scheduler (the resident
  governor). It ticks and runs whichever REM cycles are **due**, in-process, no
  forking. Default for `serve --http`.
- **`.event`** — the process owns **no loop**. Dreaming runs in a short-lived,
  **detached forked process** spawned by structural lifecycle hooks; the
  "event" is a moment in another process's life. Default for `serve` (stdio).
- **`.hybrid`** — a resident loop **and** event pokes can both fire (e.g. a
  resident fires REM-ALPHA immediately on a large recall instead of waiting for
  the next tick). Optional; for residents wanting low-latency response.

**The forked dreamer — `mootx01 dream`** (new subcommand, sibling of
`mootx01 drain`):

- Detached (`setsid` / `DETACHED_PROCESS`), fire-and-forget, stdio redirected —
  so the dream outlives the short stdio session.
- Acquires the dreaming **drain-lease** (heartbeat-TTL, reusing the T3 lease) —
  **at most one dreamer per estate**; a second fork no-ops if the lease is held
  (prevents stampede across concurrent stdio sessions).
- **Computes due-ness itself:** runs REM-ALPHA if the dreaming queue is
  non-empty; runs THETA/BETA/OMEGA if their persisted last-run timestamp is
  overdue. The trigger only decides *when to spawn*; the dreamer decides *what
  to run*.
- Exits when done, releasing the lease. Queue + lease make re-runs
  idempotent/crash-safe.

**Stdio structural triggers** (each: cheap due-check → fork `mootx01 dream`
only if the lease is free and there is work):

1. **post-recall** — after a recall verb enqueues co-recall work → fork (gives
   REM-ALPHA its latency).
2. **on-exit** — stdio `serve` shutdown → fork a final detached dreamer to
   drain residual queue + run any due periodic cycles (catches the session's
   last recalls; survives the exiting process).
3. **on-startup / first-query** — check last-run timestamps; if any periodic
   cycle is overdue, fork (lazy consolidation for stdio-only estates — D5c).

This is the existing encode `spawn_detached_drain` pattern, generalized to
dreaming and extended with periodic due-ness + the lease. The resident
(`.timer` / `.hybrid`) needs no fork — the governor runs the cycles in-process.

### Decision 7 — One per-estate queue; encrypted-DB backend; stream-scoped drain ✅ RATIFIED (2026-06-25)

**Topology (canon).** The estate topology mandates **one queue per estate** —
one queue holding many job *types*, discriminated by `stream_id`
(`Job.payload` is opaque `Data`; the table carries a `stream_id` column and a
`(stream_id, status)` index; the claim is `.serializable`). It is an
anti-sprawl rule: do not stand up a separate queue instance per consumer.

**The drift this corrects.** Today mootx01 runs *multiple* per-estate queue
instances — CorpusKit's encode queue and GLK's standing-signal queue — because
`drainAvailable` claims `WHERE status='new'` with **no `stream_id` filter**, so
two consumers on one queue would steal each other's jobs. The one-table
capability is present in the schema but unused.

**Two changes, cleanly split:**

- **QueueKit (the general SDK) — additive only.** Add **stream-scoped drain**:
  `drainAvailable(stream:)` / complete / `pendingCount(stream:)` filtered by
  `stream_id` (PK backend uses the existing `(stream_id, status)` index; the
  Filesystem backend filters by the stream prefix already in the maildir
  filename). The backend roster (RAM, maildir, SQL, Postgres) is **untouched**
  — maildir stays a valid backend other SDK consumers may choose.

- **mootx01 kit wiring — backend selection + convergence.** mootx01's
  consumers stop standing up separate instances and stop using the maildir.
  They open **one per-estate queue** and use streams (`encode`, `dreaming`,
  `signals`). The backend is chosen by the **estate's storage class**:

  | Estate storage | Queue backend | Why |
  |---|---|---|
  | Encrypted SQLite | PersistenceKitBackend over a **separate encrypted SQLite queue DB** (`<estate>/queue.sqlite`, same `EstateEncryptionConfig`/key) | Separate file ⇒ separate writer ⇒ no contention with the estate's content writer; **encrypted** (confidential) and **a DB** (integrity, access-controlled). |
  | PostgreSQL | PersistenceKitBackend over Postgres (queue table) | MVCC (no single-writer bottleneck), access-controlled, encrypted-at-rest, remote-safe. |
  | Ephemeral / InMemory | PersistenceKitBackend over InMemory | RAM; nothing on disk. |

  A **per-(estate, stream) lease** lets the encode and dreaming drainers run
  concurrently without blocking each other.

**Why not the maildir (security).** mootx01 estates carry private,
cipher-encrypted user data. A maildir would put the queue's payloads — which
include verbatim drawer text and ids — in **plaintext files on disk beside the
encrypted estate** (confidentiality breach), and its drain trusts any file in
`new/` with no authenticity check (**control-plane injection / poisoning**). A
separate encrypted SQLite queue DB gives the same off-the-content-writer
isolation a maildir gave, **plus** encryption + integrity. This is the queue's
security model, and the convergence also closes the pre-existing plaintext
exposure in the encode queue. (QueueKit keeps the maildir for general SDK use;
mootx01 simply does not select it.)

**SQLite-first sequencing.** The rule above covers SQLite *and* Postgres so the
"same on SQLite and Postgres" first principle holds in the design. The build
implements the **encrypted-SQLite** branch (+ InMemory for tests) now; the
**Postgres-estate** branch is specified but its wiring lands in the later
Postgres pass. QueueKit's stream-scoped drain is storage-agnostic, so it covers
Postgres at the SDK level with no extra work — only mootx01's Postgres
backend-selection wiring is deferred.

## Intersection with bulk import (palace / vault)

A massive import (the 40k corpus, or a vault) has **≈ zero intersection with
recall-driven dreaming** — and that is the point of v2.

- Import writes drawers → feeds the **encode** pipeline (encode queue →
  vectors/BM25). Encode is REM-orthogonal.
- Import is **not recall** → writes no `recall_trace` → enqueues no dreaming
  items → **all four REM cycles stay idle.** (Under v1 a 40k import triggered
  ~275M-pair dreaming scans every 30 s for zero proposals; under v2 it triggers
  none.) Imported content becomes dream-*eligible* only when it is later
  co-recalled.
- The associations that arrive **at import time are declared, not dreamed**:
  palace `tunnels.json` and vault wikilinks are imported directly as tunnels
  via VaultKit PalaceBridge, carrying declared provenance. Dreaming only sees
  them as `existingTunnelKeys` (suppress re-proposing) and — per **D5d** —
  OMEGA never retires them.

So the two import paths feed the **explicit/declared** association channel plus
the encode pipeline; they never feed the **emergent/dreamed** channel. The two
channels meet only in the tunnel store (shared destination, distinguished by
`provenanceBitmap`), never in the dreaming compute.

## Consequences

**Positive**
- Per-cycle cost drops from O(room^2) (275M pairs) to O(recalled_window²)
  (typically tens–hundreds of pairs). The 30s burst disappears.
- Dreaming works in stdio (today it does not).
- Proposals reflect actual usage (co-recall), the truer associative signal.
- Reuses the hardened, batched, crash-safe QueueKit drain pipeline; one
  mental model for encode and dreaming.
- Durable: recalls that happened before a crash are still dreamed after
  restart (the queue persists).

**Negative / cost**
- v2 changes which tunnels are proposed → **`DreamingDecision` and dreaming
  end-to-end conformance vectors must be re-baselined** (both ports, four-way).
- New durable surface: a dreaming QueueKit maildir + a co-recall-counts store
  (filesystem + one small table). No change to existing tables.
- `EstateDreamingReader.build*Observations` (the all-pairs builder) is
  deleted; `pumpOnEvent`'s `observationCount` contract is replaced by the
  queue-drain trigger.
- Cross-room proposals are new behavior; if any consumer assumed tunnels are
  intra-room, that assumption breaks (none known).

**Migration**
- No data migration (schema unfrozen, no production data — per project
  invariants). On first resident start / first sweep, the consolidation sweep
  backfills from existing `recall_trace`.
- Bit-identity: Swift and Rust must agree on the new decide inputs
  (co-recall pair set ordering, counts), gated against shared vectors.

## Alternatives considered

- **Keep the timer, add a cheap recall-since-last-dream gate** (skip empty
  cycles). Removes the *waste* but keeps the co-location candidate model and
  does nothing for stdio. Strictly weaker than the queue; subsumed by it.
- **Light up `.event` as-is** (fire on `observationCount`). Rejected: the
  count is the expensive build's output, so it gates after paying the cost.
- **Cap room size for pairing.** Rejected: silently drops real candidates and
  still uses co-location.
- **Keep a daily O(room^2) full sweep "the old way."** Rejected: it can only
  emit co-recalled pairs anyway, so the room enumeration buys nothing the
  bounded recall-history sweep (Decision 5) does not already provide.

## Implementation plan

Phased; each phase lands Swift + Rust at parity with conformance gates. Newton
owns the four-way conformance for the decide/counts math (substrate kit work);
Bilby owns the queue/wiring/stdio plumbing.

**Phase 0 — Spec + vectors (no code). ✅ LANDED 2026-06-25.**
`NEURONKIT_SPEC` § 12 (v1.4.0) is the normative form of this ADR: dreaming
queue, co-recall pairing, `attempts` = co-recall count, decide math (unchanged),
the REM schedule, trigger modes + `mootx01 dream`, the OMEGA provenance rule,
and the bulk-import intersection. Canonical conformance vectors CV-D1..D5 fixed
in § 12.10. `QUEUEKIT_SPEC` § 3 (v1.4.0) documents the GLK-owned dreaming queue
consumer. Both front matters + changelogs bumped. (Implementing `*_INTERFACE`
updates accompany the code phases that introduce each API.)

**Phase 1 — QueueKit stream-scoped drain + per-stream lease (SDK, additive).**
Add `drainAvailable(stream:)` / complete / `pendingCount(stream:)` scoped to
`stream_id` on the `QueueBackend` contract (default = current all-streams
behavior for compatibility; PK override uses the `(stream_id, status)` index;
Filesystem override filters by the maildir filename's stream prefix). Add a
per-`(estate, stream)` lease helper. Backend roster untouched. Both ports +
queue conformance (stream isolation: a `"a"` drainer never claims `"b"` jobs).

**Phase 2 — mootx01 convergence onto one per-estate queue (Decision 7).**
mootx01 stops standing up separate queue instances and stops selecting the
maildir. Introduce one per-estate queue with backend by storage class —
**encrypted SQLite queue DB** (`<estate>/queue.sqlite`, estate
`EstateEncryptionConfig`/key) for SQLite estates, **InMemory** for ephemeral;
the **Postgres branch is specified (Decision 7) but deferred to the Postgres
pass**. Migrate the **encode** queue (CorpusKit) and the **standing-signal**
queue (GLK) onto it as streams `encode` / `signals` with stream-scoped drain +
per-stream leases. No data migration (schema unfrozen, no users). Removes the
encode queue's plaintext-maildir exposure. Both ports.

**Phase 2b — Enqueue on recall (dreaming stream).**
In the recall verbs (`EstateVerbs` / `estate_verbs.rs`), after the existing
`recall_trace` insert, enqueue the dreaming item (the surfaced/used drawer
set) under `stream="dreaming"`. Guard: only when ≥ 2 used drawers (a single
drawer makes no pair). Both ports.

**Phase 3 — Recall-driven decide.**
Replace `EstateDreamingReader`'s all-pairs builder with a drain-fed candidate
builder: drain the dreaming queue, union the windows, emit co-recall pairs,
update the co-recall-counts store, call `DreamingDecision.decide`. Delete the
co-location/all-pairs path. Re-baseline decide conformance vectors. Both ports
(Newton).

**Phase 4 — REM-ALPHA, resident (`.timer`).**
Governor tick drains the dreaming queue (gated on `pending_count()`), replacing
the timer scan. Idle/import cycles become no-ops. The gated-tick interval is
now just the ALPHA drain cadence (30 s). Mode auto-selected `.timer` for
`serve --http`.

**Phase 5 — REM-ALPHA, stdio (`.event`) + `mootx01 dream`.**
Add the `mootx01 dream` subcommand (sibling of `mootx01 drain`): detached,
takes the dreaming drain-lease, computes due-ness, runs the due REM cycles,
exits. Wire the three stdio structural triggers (post-recall, on-exit,
on-startup/first-query) to fork it when the lease is free and work exists
(Decision 6). Mode auto-selected `.event` for `serve` (stdio). First time
stdio forms associations.

**Phase 6 — REM-THETA (consolidation).**
Bounded daily sweep over `recall_trace` (resident: a long-interval governor
duty alongside maintenance). Builds reward over the day window, scores co-recall
pairs among the day's recalled set, applies EWC decay, bumps `attempts`,
backfills emergent cross-window associations. Bounded by the recalled set².

**Phase 7 — REM-BETA (prune) + REM-OMEGA (retire).**
BETA: weekly GC of the consolidated + co-recall-counts stores (drop
decayed-to-floor entries); memory-only. OMEGA: biweekly retirement of tunnels
no longer reinforced by recall, via an `operational` bitmap bit (reversible,
audited — D5b), driven by a per-tunnel reinforcement signal derived from
`recall_trace`. Both are resident governor duties; stdio runs all three
periodic cycles opportunistically on invocation, gated by persisted last-run
timestamps (D5c).

**Phase 8 — Remove dead paths + docs (T14, complete).**
v1 observation builder and dormant `observationCount` event contract deleted
(T8); teachme/guidance reconciled (T8); `BetaSeam` renamed `Beta` (T14);
stale v1 dreaming comments updated; ADR status → decided; NEURONKIT_SPEC §9 C-1
updated to v2 model.

## Verification

- Conformance: new decide/counts vectors green four-way (Swift scalar/Metal,
  Rust scalar/BLAS) — Newton.
- Live: re-drive the 49.5k import — dreaming cost during import ≈ 0 (no
  recall); after a burst of real recalls, a bounded dream fires and proposes
  cross-recall tunnels within ~one cadence; stdio forms associations via the
  detached dreamer.
- Regression: existing recall, encode, and proposal-loop tests stay green.
