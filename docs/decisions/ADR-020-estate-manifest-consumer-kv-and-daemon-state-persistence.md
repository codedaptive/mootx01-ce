---
status: decided
question: Where do the dreaming/maintenance daemons' policy, bandit, and idempotency/cycle state persist so they survive a restart, given NeuronKit reaches the substrate only through estate verbs (B-1) and the substrate exposes no manifest write surface?
authors: MOOTx01 maintainers
date: 2026-06-25
version: v1.0
relates_to:
  - docs/reference/LOCUSKIT_SPEC.md
  - docs/reference/LOCUSKIT_INTERFACE.md
  - docs/reference/NEURONKIT_SPEC.md
  - docs/reference/NEURONKIT_INTERFACE.md
  - docs/decisions/ADR-018-brain-layer-governor-placement.md
supersedes: none
context:
  - The dreaming/maintenance daemons hold policy, the Thompson-Sampling bandit, and idempotency/cycle state (proposedKeys, consolidated EWC++ confidence, cycleCount, lastTickAt, lastReindexVocab; maintenance baselines + lastAuditCheckAt) in actor memory.
  - Production wired the in-memory policy stores (InMemoryDreamingPolicyStore / InMemoryMaintenancePolicyStore), so every restart lost policy + bandit and re-proposed already-proposed tunnels, re-ran consolidations, and repeated suppressed maintenance proposals.
  - The dreaming/maintenance daemon-internal state had NO persistence seam at all.
---

# ADR-020 — Estate-manifest consumer key-value surface + daemon-state persistence

## Context

The NEURONKIT_SPEC says the dreaming policy is "substrate-resident in
manifest" (§ 3.1). But the code carried a recorded blocker (B-1): NeuronKit
reaches the substrate only through estate verbs, and the verb surface exposed
**no manifest accessor a NeuronKit caller could write through**. So in
production the daemons were constructed with `InMemoryDreamingPolicyStore` /
`InMemoryMaintenancePolicyStore`, and their actor-local idempotency/cycle state
had no persistence seam whatsoever. Every process restart therefore:

- lost the learned trigger-mode bandit and any operator policy edits;
- forgot `proposedKeys`, so the dreaming daemon re-proposed associations it had
  already proposed;
- reset `consolidated` (EWC++) confidence and `cycleCount`;
- lost maintenance fingerprint baselines + `lastAuditCheckAt`, repeating
  suppressed maintenance proposals.

This is the "state-in-RAM-rebuilt-on-restart" class the persistence-on-disk
pass (matrix tier, BM25/InvertedIndexStore, VectorStore sidecar, ingest queue,
topology fingerprint) exists to close — here for the Brain layer.

## Decision

**Persist at the lowest level that owns the data: the substrate.** Two parts.

### 1. Complete the estate manifest write surface (LocusKit)

The LocusKit store layer already had arbitrary key-value persistence
(`DrawerStore.setMeta`/`getMeta`, Swift; `set_meta`/`get_meta`, Rust), backed
by the durable `manifest` table on every backend (SQLite, InMemory, Postgres) —
`Estate.create` already writes through it. Only the public `Estate` surface was
missing; the code even flagged it as the "future verb surface." We surface it:

- **Swift:** `Estate.meta(key:) async throws -> String?` and
  `Estate.setMeta(key:value:) async throws`.
- **Rust:** `Estate::meta(&str) -> Result<Option<String>, EstateError>` and
  `Estate::set_meta(&str, &str) -> Result<(), EstateError>`.

This is the public, durable, lowest-level key-value primitive over the manifest
table. Consumers MUST namespace keys (e.g. `"neuronkit.dreaming.policy"`) to
avoid collision with the typed v1 `ManifestKey` set. The substrate owns the
STORAGE; the consumer owns the typed SERIALIZATION of what goes in it.

### 2. Back the daemon stores + state with the manifest (NeuronKit)

- NeuronKit gains manifest-backed implementations of the existing
  `DreamingPolicyStore` / `MaintenancePolicyStore` seams (policy + bandit),
  reached through `GeniusLocusKit.estate(for:)` → `LocusKit.Estate` meta surface
  — the public interface, no layering inversion (CognitionKit → NeuronKit → GLK
  → LocusKit; ADR-018).
- The daemon-internal state gains explicit persistence seams (load on init /
  first cycle, save after each cycle), serialized as namespaced manifest JSON:
  `DreamingDaemonState { lastTickAt, proposedKeys, lastReindexVocab,
  consolidated, cycleCount }` and `MaintenanceDaemonState { lastTickAt,
  lastAuditCheckAt, proposedKeys, cycleCount, fingerprintBaselines }`. The seam
  methods carry default no-op implementations so existing in-memory conformers
  (tests) compile unchanged — the same additive pattern the bandit seam used.
- The production `AutonomicGovernor` wiring constructs the manifest-backed
  stores instead of the in-memory ones.

## Alternatives considered

- **(A) Host-side estate-backed store in AriaMcpKit/AriaResident**, owning a
  SQLite table beside the estate db (the pattern ObserverSink/StatsStore uses
  for topology snapshots). **Rejected:** AriaMcpKit is the interface surface —
  the TOP of the topology tree. Having it persist substrate-owned daemon state
  inverts ownership (the Interface Rules: features owned at the lowest level;
  data flows up/down through public interfaces; a kit must not reach around the
  middle-level kit). Topology snapshots are genuinely host *telemetry* (moot-mgr's
  view); daemon policy/state is the Brain's own estate state and belongs in the
  substrate. This is the premise that selected B over A.
- **(C) Hybrid** (policy/bandit via manifest, high-churn state host-side):
  unnecessary once the substrate owns one durable KV surface for both.

## Consequences

- Restart continues from durable state: no re-proposing, no re-consolidating, no
  repeated suppressed maintenance proposals; operator policy + learned bandit
  survive.
- One new public substrate capability (`Estate.meta`/`setMeta`), additive and
  parity-gated across both ports. The manifest table absorbs a small number of
  namespaced consumer keys; `proposedKeys` growth is bounded by the daemon's own
  idempotency horizon.
- Known parity note: the Rust SQLite backend creates tables at the latest schema
  and does not replay column-add migrations (see the F5 persistence note); the
  manifest table is a fixed key-value shape, so this does not affect ADR-020.

## Status

Decided 2026-06-25. Implemented across LocusKit (Estate meta surface),
NeuronKit (manifest-backed stores + daemon-state seams + governor wiring), both
ports, with conformance tests. Part of the persistence-on-disk pass (F6).
