---
status: accepted
question: What architecture governs running one MOOTx01 estate on multiple Apple machines simultaneously via iCloud, and what transport and coordination hardening is required?
authors: MOOTx01 maintainers
date: 2026-07-16
relates_to:
  - docs/reference/CONVERGENCEKIT_SPEC.md
  - docs/reference/CONVERGENCEKIT_INTERFACE.md
  - docs/decisions/DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md
supersedes: none
context:
  - ConvergenceKit v1.0 was designed for single-device use; the CloudKit backend assumed at most one active machine writing to a zone at a time.
  - Multiple Apple devices sharing one iCloud account may run MOOTx01 concurrently against the same private CloudKit zone.
  - The shipped CloudKit backend has six distinct defects that cause data loss, ping-pong replication storms, and duplicate events under any concurrent-device scenario.
  - The HLC node ID is drawn at random per launch; two machines collide with probability ≈1/15 per session pair, producing silent LWW divergence that cannot be detected or repaired after the fact.
  - An inbound apply fires StorageObserver, which re-enqueues the received record for outbound push, creating an unbounded ping-pong loop between two live machines.
---

# Decision: ConvergenceKit concurrent multi-device architecture via iCloud

## Context

The iCloud private database provides a shared relay for one user's
devices. When two or more Apple machines run MOOTx01 against the
same estate simultaneously, the existing CloudKit backend exposes
correctness failures across three surfaces: replication echo, node
identity collision, and transport defects that lose or duplicate data.

A 2026-07-16 audit of `CloudKitSyncEngine.swift` confirmed six shipped
defects. Each is listed in the Shipped-defect audit section below with
its source location.

The R1–R10 requirements in
`DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md` address
transport hardening and vocabulary gaps. They were proposed on
2026-06-09 and are promoted to accepted and blocking scope by this
decision.

---

## Decision

The MOOTx01 estate runs as a **local-first multi-master** across
Apple devices:

- Each machine holds its complete local SQLite estate. The CloudKit
  private database is a relay, never a store of record.
- No SQLite database is placed in iCloud Drive.
- No primary machine exists; all devices are peers.
- Convergence is per-row eventual via Hybrid Logical Clock (HLC)
  last-writer-wins, backed by ConvergenceKit's existing conflict
  policies.

R1–R10 of `DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md`
are promoted from proposed to accepted and constitute blocking scope
for the ConvergenceKit v1.1 implementation program.

### Playground Rules (consumer contract)

These nine rules govern any kit or application composing
PersistenceKit and ConvergenceKit for sync. They will become a
governed reference document; they are recorded here as the
architectural contract established by this decision.

1. Every synced table has a single-column UUID primary key.
2. Policy follows data shape: use `appendOnly` for append-only data
   and `fieldLevelLWW` for mutable entities. No transaction spans a
   sync boundary.
3. No cross-row or cross-table invariants are maintained by sync.
   Supply a post-apply integrity hook (R3) to restore structural
   invariants after a pull batch applies.
4. Derived columns never sync. Columns recomputed locally on every
   device are excluded via column projection (R2).
5. No increment semantics. Counters are append-only events folded
   locally; syncing an increment conflicts silently with a concurrent
   increment from another device.
6. Deletes are tombstoned LWW. Consumers either tolerate
   edit-beats-delete outcomes or use soft-delete bitmap bits.
7. Ordering is by substrate HLC only. No other ordering guarantee
   crosses a sync boundary.
8. Version skew pauses sync, never breaks it. A schema mismatch holds
   newer-version records in a pending queue (R9) until the local
   schema catches up.
9. The iCloud arm is Apple-platform and Swift-vertical only. The Rust
   vertical's multi-machine story is Federation.

---

## Requirements

**N1 — Echo suppression.**
`applyInbound` writes through the receiver's `rowStore` (invariant
I-3), which fires `StorageObserver`. The engine's own observer task,
registered at `enable` time, records the resulting change event into
`pendingOutbound` and schedules a push — sending back to the remote
machine a record it just delivered. With two live machines, every
record ping-pongs indefinitely; neither machine converges.

Requirement: an inbound apply must never re-enter the outbox.

**Accepted mechanism (per Kong Q2 REWORK adjudication):** PersistenceKit
stamps an `origin` field on `TableChange` at write time. The field takes
one of two values: `local` (every caller-initiated write) or `syncApply`
(writes issued by `applyInbound`). Inbound applies are issued through an
origin-tagged write path that sets `origin == syncApply` on the resulting
`TableChange`. ConvergenceKit's outbound observer discards any
`TableChange` whose `origin == syncApply`; only `origin == local` events
enter the outbox. A genuine local write that arrives concurrently with an
inbound apply always carries `origin == local` and is never suppressed.

**Why the keyed suppression window was rejected:** the straightforward
alternative — a `Set<String>` keyed on `"table:rowKey"` held in the
engine actor, set before `upsert` inside `applyInbound` and cleared after
— is unsound on the SQLite production backend for two reasons. First,
SQLite observer delivery is fire-and-forget: `notifyObservers` spawns a
`Task { await r.notify(change) }` per change with no ordering guarantee,
so the echo notification can arrive at `recordOutbound` after `applyInbound`
has completed and the suppression flag is already cleared. Second,
`TableChange.hlc` is always `nil` in practice on both InMemory and SQLite
backends; there is no information in the delivered event that distinguishes
an echo from a genuine concurrent local write to the same `(table, rowKey)`
pair. A keyed window cannot make that distinction and will either silently
suppress genuine local writes or fail to suppress echoes under the right
scheduling order.

**Accepted cost:** this mechanism requires adding an `origin` field to
`TableChange` in PersistenceKit — a type extension with its own blast
radius. The full specification is deferred to `PERSISTENCEKIT_SPEC.md`
and the implementing mission (P1-M1). No PersistenceKit changes are in
scope for P0 missions.

**N2 — Device slot registry with fenced eviction.**
The HLC packs node identity in 4 bits (CKRecordMapping wire layout —
physical 48b | logical 12b | node 4b — spec B-6),
yielding 16 addressable node values, of which node 0 is permanently
reserved: earlier shipped code fabricated HLCs with node 0, so no
registry-assigned identity may ever be ambiguous against those
historical writes. That leaves 15 assignable slots (1–15). The
current implementation draws
`Int32.random(in: 1...0x0F)` per launch with no persistence and no
coordination. Two machines collide with probability ≈1/15 per session
pair, producing colliding HLCs whose LWW ties resolve differently on
different replicas — silent, undetectable divergence.

Requirement: a slot registry of 15 well-known CloudKit records
(slots 1–15) in the manifest's own sync zone — one engine, one zone,
one registry. A device claims a slot via a conditional CloudKit save on
the record change tag (compare-and-swap, the only conflict-free
reservation primitive the private database provides). A slot
assignment is `(slot, epoch)`, not `slot` alone.

On exhaustion — all slots occupied by recently-active devices — the
engine evicts the oldest-inactive slot **and** bumps its epoch. A
device that returns after being evicted holds a superseded
`(slot, epoch)` pair. It must receive a distinct `reenrollRequired`
error **before any of its records are applied**. It re-claims a fresh
slot, then resumes normal operation.

Rationale for fenced eviction: naive eviction without epoch fencing
is worse than exhaustion. An evicted machine does not know it was
evicted; two live devices sharing a node ID produce colliding HLCs
whose LWW ties resolve differently on different replicas — the
definition of silent divergence. Fenced eviction fails loudly at the
enrollment boundary; all records after re-enrollment carry an
unambiguous node identity. Ordering is sound retroactively: eviction
requires that the evicted slot's last-active timestamp be well in the
past, so the new claimant's HLC physical component is strictly above
everything the evicted identity ever wrote. The real limit is 15
simultaneously active machines; hitting it raises `slotExhausted`,
which is loud, not silent.

Rejected alternative — widening the node field: the `CKRecordMapping`
CloudKit wire layout (physical 48b | logical 12b | node 4b, spec B-6)
is a CloudKit-only format that limits nodes to 4 bits. Widening would
break the CloudKit wire format with blast radius across all
`_ck_sync_meta` and `_ck_outbox` side tables. (Note: `SubstrateTypes.HLC.packed`
uses a distinct layout — node 8b | logical 16b | physical 40b — and is
not the gating constraint here; the 4-bit limit is specific to
CKRecordMapping.) The registry provides headroom for up to 15 concurrent
machines via one side table without touching the wire format.

**N3 — Convergence loop.**
Outbound: debounce the outbox drain on local writes to prevent
per-keystroke push storms.

Inbound: adaptive polling is the correctness path for the resident
daemon. A launchd process cannot receive APNs silent push without
host-app process mediation; the daemon must poll to discover remote
changes. Polling uses a tiered cadence: fast cadence immediately
after observed activity, backing off to idle cadence when the zone
has been quiet.

Host apps that hold APNs entitlements (such as `moot-mgr`) may
register a `CKRecordZoneSubscription` as an optional latency
accelerator. A silent-push wakeup nudges the engine to run a pull
cycle sooner than the idle cadence would. Silent push is an
optimization; it is never required for correctness. All multi-device
behaviour must be sound under polling alone.

**N4 — Swift-leg exclusivity.**
CloudKit has no Rust API. The no-FFI rule between Swift and Rust legs
is immutable. Therefore the CloudKit sync backend is Swift-vertical
only — the same precedent as Metal compute kernels, which have no
Rust path and none is planned. Vocabulary and wire-format changes
(SyncRecord encoding, TypedValue discriminators) still carry
byte-identical Rust twins per C-8 and B-4. The Rust vertical's
multi-machine story is Federation
(`DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md`).

---

## Rationale

The local-first multi-master model is the only iCloud architecture
consistent with the substrate's existing guarantees. PersistenceKit
is the store of record; ConvergenceKit is a replication layer above
it. Placing SQLite in iCloud Drive or designating a primary machine
would invert that contract and introduce new failure modes (iCloud
Drive conflict versions, split-brain on the primary designation)
without eliminating the convergence problem.

The fenced slot registry (N2) closes the node-collision failure mode
without touching the wire format or the conformance harness.
Alternative approaches — random re-roll on detected collision,
widening the node field — either require detecting a collision after
divergence has already occurred (too late for LWW correctness) or
break the wire format across both legs (unacceptable blast radius).

Echo suppression (N1) is a correctness fix, not an optimization.
Without it, the CloudKit backend is not convergent in the multi-device
case: every apply generates a new outbound change, producing
unbounded replication traffic and no stable fixed point.

The tiered polling model (N3) is a consequence of the process
architecture. A launchd daemon without APNs entitlements receives no
push wakeups from CloudKit. Polling is the only conformant inbound
path; the optional subscription accelerator ensures the architecture
degrades gracefully to polling-only when push is unavailable, rather
than requiring push as a correctness dependency.

---

## Shipped-defect audit (2026-07-16)

Source: `packages/kits/ConvergenceKit/Sources/ConvergenceKitCloudKit/
CloudKitSyncEngine.swift`. Each finding is keyed to the line(s)
verified in the source file at time of audit.

**D1 — Delete fan-out across all tables (lines 320–329).**
Inbound deletions carry only a `CKRecord.ID`, which encodes row key
and zone but not record type. The engine iterates every non-`pushOnly`
manifest table and attempts deletion against each one. A deletion
intended for one table silently fires against every synced table that
happens to share the same primary-key UUID value. Addressed by R7
(route deletions by record type; carry deletion HLCs).

**D2 — Deletions bypass HLC (line 328).**
The delete loop calls `storage.rowStore.delete(...)` with no HLC
comparison. A stale delete from a slow device beats a newer edit from
a faster device, discarding the edit. Spec B-4 requires the same HLC
gate on deletes as on updates. Addressed by R7.

**D3 — `pendingOutbound` cleared before transport (lines 188–189).**
`push()` captures the pending array and calls `removeAll()` before the
`modifyRecords` call at line 240. A transport failure loses the entire
pending batch permanently; the records are not re-queued. Addressed by
R4 (durable outbox; clear entries only on per-record confirmation).

**D4 — `serverChangeToken` not persisted (line 99).**
`serverChangeToken` is an actor variable. Every process launch
re-pulls the full zone from the beginning rather than from the last
known position. Addressed by R5 (persist the token per zone; handle
`changeTokenExpired` by resetting and re-pulling).

**D5 — `modifyRecords` per-record results discarded (lines 240–248).**
`modifyRecords(atomically: false)` returns per-record results for
partial-success handling. The result is assigned to `_`; records
rejected by CloudKit (quota, size, server conflict) are counted as
successfully pushed. Addressed by R6 (consume per-record results;
return failed records to the outbox).

**D6 — Synthetic `pushCompleted` start signal double-fires
(lines 185 and 253).**
`push()` emits `.pushCompleted(receipt: .empty)` at line 185 before
any work begins, then emits `.pushCompleted(receipt: receipt)` at
line 253 on completion. Every push delivers two `pushCompleted` events
to subscribers. Addressed by R10 (remove the start-signal emission;
add a distinct `SyncEvent` case if a start event is needed).

---

## Status

Accepted (2026-07-16). R1–R10 from
`DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md` are blocking
scope for ConvergenceKit v1.1. N1–N4 above extend that scope for
multi-device correctness. See also
`DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md`, which is
updated to accepted status by this decision.
