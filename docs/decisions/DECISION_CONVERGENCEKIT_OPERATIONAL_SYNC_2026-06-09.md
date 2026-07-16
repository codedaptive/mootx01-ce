---
status: accepted
question: Should ConvergenceKit extend its policy vocabulary and harden its CloudKit backend to support operational-store sync beyond substrate-native data?
authors: MOOTx01 maintainers
date: 2026-06-09
relates_to:
  - docs/reference/CONVERGENCEKIT_SPEC.md
  - docs/reference/CONVERGENCEKIT_INTERFACE.md
supersedes: none
context:
  - ConvergenceKit v1.0's policy vocabulary was shaped by append-mostly, observation-grain substrate data.
  - Host applications sync mutable, transactional, hierarchical operational stores that expose vocabulary and transport-hardening gaps.
  - These are additive requirements, not a choice between competing options, so no alternatives axis is weighed.
---

# Decision: ConvergenceKit operational-sync requirements — extend the policy vocabulary beyond substrate-native data

## Context

ConvergenceKit v1.0's policy vocabulary (`SyncedTable`: name, direction,
primary key, one of four row-grain conflict policies) was shaped by the
substrate's native data: drawers, observations, and audit-log entries.
That data is append-mostly, observation-grain, and rarely subject to
concurrent field-level edits. For that shape, row-grain
`lastWriterWinsByHLC` and `appendOnly` are correct and sufficient.

Host applications built on the SDK will sync **operational stores**:
mutable, transactional, often hierarchical entity data with derived
columns and structural invariants. The first such integrations expose
three vocabulary gaps and a set of transport-hardening gaps in the
CloudKit backend. This document records both lists as the requirements
for ConvergenceKit v1.1. It is deliberately application-agnostic:
application-specific sync contracts live in the application's own
repository and reference this document, never the reverse.

---

## Decision

Extend ConvergenceKit to support operational-store sync per requirements
R1–R10 below. The pipeline architecture (StorageObserver → outbox →
transport → applyInbound → StorageObserver) is unchanged; all extensions
are additive to the policy vocabulary and the backend implementations.

---

## Requirements

### Vocabulary (shape) extensions

**R1 — Field-grain conflict policy.** Add `ConflictPolicy.fieldLevelLWW`:
per-column HLC comparison at the receive boundary, so concurrent edits to
*different* columns of the same row both survive. Row-grain LWW silently
discards one side of any concurrent same-row edit, which is acceptable
for observation-grain data and lossy for mutable entity data. The
substrate's HLC primitives already exist; the work is a per-column HLC
map in the sync metadata and a column-wise merge in `applyInbound`.

**R2 — Column projection.** Add an exclusion (or inclusion) column list
to `SyncedTable`. Operational rows commonly carry derived columns
recomputed locally on every device (scores, caches, materialized
explanations). Because the outbox is observer-fed and observers fire on
update, derived-column recomputes otherwise become outbound traffic for
data the receiver immediately recomputes — a sync storm proportional to
local compute, not to user edits. Projection also reduces record size
and conflict surface.

**R3 — Post-apply integrity hook.** Add an optional per-manifest callback
invoked after a pull batch applies, so the consumer can restore
structural invariants that row-grain policies cannot express (orphaned
references after a concurrent move/delete, referential repairs,
re-parenting rules). The hook runs inside the consumer's transaction
scope; ConvergenceKit stays ignorant of the invariants themselves.

### Transport hardening (CloudKit backend; audit of 2026-06-09)

**R4 — Durable outbox.** `pendingOutbound` is an in-memory actor array
today: changes are lost if the process dies before push, and
`push()` clears the array *before* the transport call, so a transport
failure also loses the batch. Persist the outbox on PersistenceKit's
`AuditLog` (HLC-ordered, append-only, idempotent compound key — already
the right structure) and clear entries only on per-record confirmation.

**R5 — Persisted server change token.** `serverChangeToken` is an actor
variable; every process launch re-pulls the full zone. Persist the token
per zone; handle `changeTokenExpired` by resetting and re-pulling rather
than failing permanently.

**R6 — Per-record push results and error taxonomy.** The result of
`modifyRecords(atomically: false)` is currently discarded; rejected
records (quota, size, server conflict) are counted as pushed. Consume
per-record results, return failed records to the outbox, and implement a
CKError taxonomy with retry/backoff (rate limits, zone-not-found,
token expiry as distinct paths).

**R7 — Tombstoned deletes under LWW.** Inbound deletions currently
bypass HLC comparison (a stale delete beats a newer edit) and attempt
deletion against every manifest table because the record type is
ignored. Carry deletion HLCs (tombstones), apply LWW to delete/update
conflicts, and route deletions by record type.

**R8 — Server-push subscriptions.** No `CKModifySubscriptionsOperation`
exists; remote changes arrive only on manual pull. Register zone
subscriptions and surface silent-push wakeups through the existing
`subscribe()` stream.

**R9 — Schema-skew policy.** A schema-version mismatch on pull is
currently logged as a conflict and the record dropped, which silently
halts sync between devices on different app versions. Define an explicit
policy: at minimum, hold newer-version records in a pending queue until
local migration catches up.

### Hygiene

**R10 —** Remove the synthetic `pushCompleted(receipt: .empty)` "start
signal" emission at the top of `push()`; subscribers currently observe
every push completing twice. If a start event is useful, add a distinct
`SyncEvent` case.

---

## Rationale

The v1.0 skeleton (consumer model, manifest declaration, observer-fed
pipeline, HLC discipline) is correct and is not revisited. The gaps are
concentrated in (a) a policy vocabulary that has only ever been fed
substrate-native data, and (b) a CloudKit backend that implements the
happy path of a sync engine without the durability and failure handling
that distinguish a sync engine from a demo. Both lists are finite and
additive. Completing them moves ConvergenceKit from memory-sync to
general-sync, which is the difference between an SDK that hosts the
substrate and an SDK that hosts a platform.

Sequencing note for host applications: PersistenceKit can be adopted
independently of ConvergenceKit (`ConvergenceKitNone` is production-ready
passthrough). Applications that are not yet multi-device can land on
PersistenceKit first and enable ConvergenceKit only when R4–R7 (the
data-loss and correctness class) are complete, making this hardening a
gate rather than a regression risk.

---

## Status of this document

Accepted (2026-07-16). R1–R10 constitute ConvergenceKit v1.1 blocking
scope. Promoted to accepted by
`DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16.md`, which
extends these requirements with N1–N4 for concurrent multi-device
correctness and records the 2026-07-16 shipped-defect audit.
