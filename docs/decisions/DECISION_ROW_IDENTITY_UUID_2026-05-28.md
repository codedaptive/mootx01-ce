---
status: decided
question: What is the identity of a synced or audited row?
authors: MOOTx01 maintainers
date: 2026-05-28
relates_to:
  - "docs/decisions/DECISION_SYNCKIT_DESIGN_2026-05-19.md (§4 SyncRecord.rowKey: UUID, §7 CloudKit zones)"
  - docs/decisions/DECISION_CLOCK_TRIANGLE_TIME_MODEL_2026-05-28.md (audit event identity; the migration that surfaced this)
  - docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md (Appendix C.3 content-addressed identity, stable across configurations)
  - ConvergenceKit CKRecordMapping.swift (rowKey ↔ CKRecord.ID.recordName), LocusKit Drawer.swift (id), LocusKitSchema.swift (drawers.id)
supersedes: none
context:
  - Syncing to Apple's CloudKit already required row identities to be UUIDs.
  - The clock/triangle decision introduced an audit event identity that needed a stable row id to seal.
  - A documented deterministic-id path produced free strings that silently became unsyncable.
---

# Decision: Row Identity Is a UUID

## 1. Summary

Every synced row's identity is a UUID. This was already an implicit requirement of syncing to Apple's cloud; this document makes it explicit, extends it to the audit event identity introduced by the clock/triangle decision, and closes a latent path that silently produced unsyncable rows.

The drawer identifier `Drawer.id` already defaults to a UUID string and is safe. The documented alternative — supplying a "deterministic id derived from sourceFile + chunkIndex" as a free string — is not safe: such a row cannot round-trip through Apple's CloudKit identity and loses its identity on receive. The rule decided here is one line: row identity is a UUID, and deterministic identity is a deterministic UUID, never a free string.

## 2. Why the row key must be a UUID — Apple cloud compatibility

We want our records to live in Apple's trusted cloud. That choice carries Apple's identity constraint, and the constraint is not negotiable from our side.

A row synced through CloudKit is addressed by a `CKRecord.ID`, whose durable external identity is its `recordName`. ConvergenceKit maps a row's key onto that `recordName` directly: the key's UUID string becomes the `recordName`, and on receive the `recordName` is parsed back to a UUID. CloudKit treats `recordName` as the stable, addressable, deduplicating identity of the record in Apple's store. A UUID string is the canonical safe `recordName`: valid by construction, collision-free, and stable across the full push/pull round-trip.

A non-UUID identity breaks this in a way that is silent and corrupting rather than loud. On receive, a `recordName` that does not parse as a UUID is replaced with a freshly generated UUID, so the record arrives with a different identity than it left with. Convergence is then impossible for that row: the sender and receiver disagree on what the row *is*. Nothing throws; the row simply forks. This is the worst class of failure — undetected identity loss — and it is inherent to using Apple's cloud, not a detail of any one implementation.

ConvergenceKit is already built on this constraint. Its sync record types the row key as `UUID`, and its storage queries address the primary-key column as a UUID value. The assumption is load-bearing throughout the sync path. The decision here aligns the rest of the system to a constraint the sync layer already enforces, rather than weakening the sync layer to tolerate identities Apple's cloud cannot carry.

## 3. The latent path being closed

`Drawer.id` defaults to a fresh UUID string, so the default creation path is already correct and CloudKit-safe. The hazard is the documented guidance that a caller ingesting previously-known content "should supply a deterministic id, for example derived from sourceFile + chunkIndex." Taken literally, that produces a free string such as a file path with a chunk index — a value that is not a UUID and therefore cannot survive the CloudKit round-trip. A drawer created that way is silently unsyncable: it works locally, and loses its identity the moment it touches Apple's cloud.

This is a latent defect independent of any current work; the audit migration merely walked into it by needing a row identity to seal. It is closed here rather than left for a later surprise.

## 4. Decision

Row identity is a UUID, everywhere a row can be synced or audited.

Deterministic identity remains fully supported, but as a deterministic UUID rather than a free string. A caller that wants the same logical content to receive the same id every time derives a UUID deterministically from its natural key (for example, a UUIDv5-style hash over `sourceFile` + `chunkIndex`) instead of using the natural key string directly. This preserves the deterministic-ingest capability the guidance intended, while guaranteeing the result is a valid, stable, CloudKit-safe, convergence-correct identity.

The audit event identity introduced by the clock/triangle decision uses this same UUID — the row's primary-key UUID — directly. There is exactly one identity for a row: the UUID in its primary-key column, the UUID CloudKit addresses it by, and the UUID the audit event seals. This satisfies the federation requirement that identity be stable across configurations (Appendix C.3): a LocusKit-only estate and a full synced stack agree on a row's identity because there is only one, and it is content-stable when derived deterministically.

The audit write path therefore requires the row id to parse as a UUID and fails loudly if it does not, rather than fabricating or deriving a second identity. A non-UUID id reaching a gated write is a programming error against this contract, surfaced at once, not silently bridged — silent bridging is exactly the CloudKit failure mode this decision exists to prevent.

## 5. Consequences

The `drawers` primary-key column continues to store the id as text at the storage layer (the storage type is permissive), but the operative contract is that the text is a UUID string. Callers using the default id are unaffected. Callers using deterministic ids change from a free-string natural key to a deterministic UUID derived from that natural key. Test fixtures that used short non-UUID ids (for example `"d1"`) are updated to UUIDs, aligning the fixtures with the identity contract that any synced estate already requires.

ConvergenceKit is unchanged: it already assumes and enforces a UUID row key. LocusKit's `Drawer.id` documentation is updated to direct deterministic-ingest callers to derive a deterministic UUID rather than supply a free string. The audit migration consumes the row's UUID directly.

## 6. What this does not change

Local, never-synced use is not technically forced to use UUIDs by the storage engine, but the contract is uniform to avoid a class of row that works locally and fails on first sync. The default creation path is unchanged. No schema column-type migration is mandated by this decision; the change is to the identity *contract* and to the deterministic-id guidance, plus the loud-failure enforcement at the audit write boundary.
