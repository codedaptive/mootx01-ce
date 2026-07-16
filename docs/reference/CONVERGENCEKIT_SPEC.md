---
title: ConvergenceKit Specification
version: 1.2-draft
status: active
date: 2026-06-14
description: "Behavioral specification for ConvergenceKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/CONVERGENCEKIT_INTERFACE.md
  - docs/reference/PERSISTENCEKIT_SPEC.md
  - docs/reference/SUBSTRATELIB_SPEC.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/decisions/DECISION_SYNCKIT_DESIGN_2026-05-19.md
  - docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md
purpose: |
  ConvergenceKit is the optional sync layer for the substrate. It
  replicates PersistenceKit row mutations across device or perimeter
  boundaries behind a single `SyncEngine` protocol, with three
  backends — None (the local-first default), CloudKit (Apple-ecosystem
  device-to-device), and Federation (Ed25519-authenticated
  estate-to-estate). Its only consumer protocol is PersistenceKit's:
  a kit declares which tables sync via a `SyncManifest`, and sync
  flows as table-level replication. The companion INTERFACE document
  carries the signatures that satisfy this contract.
---

# ConvergenceKit Specification

## § 1 — What this package is

ConvergenceKit replicates PersistenceKit operations across device or
perimeter boundaries. A consumer declares which of its tables sync,
which zone they belong to, and how conflicts resolve, all through a
declarative `SyncManifest`. ConvergenceKit observes the local
PersistenceKit through its `StorageObserver`, ships outbound changes
over a backend transport, and applies inbound changes back through the
receiver's PersistenceKit `rowStore` — which fires `StorageObserver`
naturally on the receive side, so downstream watchers wake without
knowing sync exists. The Federation backend's transport is pluggable
behind a `Relay` abstraction (INTERFACE § 4), so a hosted SyncServer can
replace the in-process relay without engine changes.

The wire unit is a single PersistenceKit row mutation tagged with a
hybrid logical clock (HLC), schema version, and kit ID. The receiver
decodes it, checks kit and schema agreement, and applies it under the
table's declared conflict policy. PersistenceKit's own constraints
(primary keys, the audit log's idempotent `(eventID, hlc)` compound
key) produce convergence; ConvergenceKit adds no independent CRDT
mathematics of its own.

This package is a **Kit**: it manages lifecycle and state. A
`SyncEngine` instance holds enable/disable state, an observation task
set, a pending-outbound queue, subscriber continuations, and (for
CloudKit) a server change token. Sync is optional and never assumed —
the default backend, `None`, makes every operation a successful no-op
so the substrate runs local-first with no sync code paths active.

## § 2 — Scope

This specification defines:

- The `SyncEngine` lifecycle: `enable` / `disable` / `push` / `pull` /
  `subscribe` / `state`, and their ordering and idempotency rules.
- The `SyncManifest` declaration model: synced tables, replication
  direction, conflict policy, kit ID, schema version, zone identifier.
- The `SyncRecord` wire format and the discriminated `SyncValueMap` /
  `SyncValueBox` encoding of PersistenceKit `TypedValue`.
- The four conflict policies and their apply-boundary semantics.
- The three backends — None, CloudKit, Federation — and what each
  promises.
- Federation peer identity (Ed25519) and the hyperplane-family pairing
  handshake.
- The conceptual error model (`SyncError`).

This specification does NOT define:

- API signatures — those live in `CONVERGENCEKIT_INTERFACE.md`.
- Storage, row stores, the audit log, `TypedValue`, `TableChange`, or
  `StorageObserver` — those are PersistenceKit's
  (`PERSISTENCEKIT_SPEC.md`).
- The HLC and `Fingerprint256` primitives carried on the wire — those
  are SubstrateLib's (`SUBSTRATELIB_SPEC.md`).
- Cross-estate access policy, grants, and multi-estate routing — those
  are an access-surface concern (aria-mcp), per invariant I-13.

## § 3 — Position in the kit family

```
SubstrateLib        PersistenceKit
   ▲      ▲              ▲
   │      └──────┬───────┘
   │             │
   └──────  ConvergenceKit  (core: protocols + types + wire format)
                 ▲
     ┌───────────┼────────────┐
   None       CloudKit     Federation   (backend targets)
                 ▲
            consumers compose
            ConvergenceKit + PersistenceKit
            (e.g. CorpusKit declares a manifest)
```

**Depends on:** SubstrateLib (HLC, `Fingerprint256`, `HLCGenerator`),
PersistenceKit (`Storage`, `TableChange`, `TypedValue`,
`StorageObserver`, `StorageEvent`). The Federation backend additionally
depends on swift-crypto (Ed25519 via `Curve25519.Signing`).

**Consumed by:** any kit that composes PersistenceKit and wants
replication. A consumer declares a `SyncManifest` and selects a backend;
it does not call the substrate-internal sync paths procedurally.
CorpusKit is the present consumer (it builds a chunk-table manifest).
ConvergenceKit is a foundation peer of PersistenceKit, not a layer above
the substrate kits.

## § 4 — Invariants

**I-1 (enable-before-use):** `push`, `pull`, and `subscribe` require a
prior successful `enable`. Calling them while disabled raises
`notEnabled`. A second `enable` without an intervening `disable` raises
`alreadyEnabled`.

**I-2 (disable idempotency):** `disable` always succeeds, may be called
when already disabled, and tears down all observation tasks, subscriber
continuations, and pending-outbound state. Teardown of the observation
tasks is awaited (Swift) / joined (Rust) before `disable` returns, so no
write observed after `disable` can land in the outbox — the disable
boundary is deterministic on both ports. After `disable`, `state` is
`disabled`.

**I-3 (apply-through-storage):** inbound changes are applied only
through the receiver's PersistenceKit `rowStore`. ConvergenceKit never
mutates storage by a side channel; the receive-side `StorageObserver`
fires as a consequence of the apply, waking downstream watchers.

**I-4 (kit and schema gate):** an inbound record is accepted only if its
`kitID` and `schemaVersion` equal the receiver manifest's. A `kitID`
mismatch is `kitMismatch`; a `schemaVersion` mismatch is
`schemaMismatch`. Either rejects the record (the record does not apply;
it is counted as a conflict and may be retried after an app update).

**I-5 (direction honoured):** for a table declared `pullOnly`, local
changes are not shipped on `push`. For a table declared `pushOnly`,
inbound changes for that table are skipped on `pull`. `bidirectional`
ships and accepts both ways.

**I-6 (HLC determinism):** when an outbound change carries no HLC of its
own, the engine mints one through `HLCGenerator.send(now:)`, taking the
clock as an explicit parameter. The engine never fabricates an HLC from
an inline `Date()` with a colliding node ID; the single wall-clock read
is isolated to one auditable `nowMillis()` method per backend.

**I-7 (Federation authentication):** every Federation message is signed
with the sender's Ed25519 key at `push` and verified at `pull`. A
message that fails signature verification is rejected and counted as a
conflict; its records do not apply.

**I-8 (per-estate identity):** a Federation identity is per-estate, not
per-device or per-user. Two estates on the same device hold distinct
keypairs and do not implicitly trust each other across the federation
channel.

**I-9 (federation is not substrate):** ConvergenceKit replicates rows;
it does not itself decide cross-estate access. Multi-estate access
policy is mediated by the access surface (aria-mcp), per architecture
invariant I-13.

**I-10 (no-echo) (v1.2-draft):** An inbound sync apply never re-enters
the outbox. The mechanism is a PersistenceKit-stamped change origin:
`TableChange` carries an `origin` field (`local | syncApply`), stamped
at write time. ConvergenceKit's outbound observer discards events where
`origin == syncApply`. Consumer-visible guarantee: hook-observed writes
and local writes always carry `origin == local` and are never discarded.

**I-11 (device slot identity) (v1.2-draft):** HLC node IDs are
registry-assigned `(slot, epoch)` pairs. Slots 1–15 are assignable;
node 0 is permanently reserved (shipped code fabricated HLCs with node 0,
so no registry-assigned identity may be ambiguous against those historical
writes). A superseded epoch must not push: a device returning after eviction
holds a stale `(slot, epoch)` and receives `reenrollRequired` before any
of its records are applied. On re-enrollment, pending outbound entries are
re-minted with fresh HLCs under the new `(slot, epoch)` identity.

**I-12 (durable pipeline) (v1.2-draft):** The outbound queue and the
server change token survive process death. Outbox entries clear only on
per-record confirmation from the transport; the token is persisted per
zone and reloaded at next `enable`.

## § 5 — Behavioral contracts

**B-1 (None passthrough):** with the None backend, `enable` and
`disable` succeed trivially, `push` and `pull` return `SyncReceipt.empty`
(when enabled), and `subscribe` returns a stream that never emits and
finishes when the caller cancels. None is the local-first default.

**B-2 (receipt accounting):** a `SyncReceipt` reports `pushed`,
`pulled`, and `conflicts` counts for one cycle plus a completion
timestamp. `push` reports `pulled == 0`; `pull` reports `pushed == 0`.
A rejected or unverifiable inbound record increments `conflicts`, not
`pulled`.

**B-3 (event stream):** `subscribe` yields `SyncEvent` values as
activity happens: `remoteChangesApplied(count:)` after a pull applies
≥1 record, `pushCompleted(receipt:)` after a push, and
`peerConnected` / `peerDisconnected` for Federation pairing. Closing the
stream stops the subscription. The CloudKit and Federation backends
buffer the newest 256 events.

**B-4 (conflict policy at the apply boundary):** the receiver applies
each inbound record under the table's `ConflictPolicy`:

- `lastWriterWinsByHLC` — on insert/update: reads the local row's stored
  `_syncHLC` (reserved column written by every winning apply); if the
  incoming HLC is strictly less than `_syncHLC` the record is silently
  dropped; otherwise the row is upserted and `_syncHLC` is written with
  the incoming HLC so the next inbound comparison has durable state. On
  delete: the same HLC gate applies — a stale delete (incoming HLC <
  local `_syncHLC`) is silently rejected; a newer or equal delete
  hard-deletes the row. Both CloudKit and Federation backends implement
  this identical comparison semantics.
- `appendOnly` — upserts idempotently on the primary key (audit-log
  style); remote deletes are silently rejected.
- `remoteWins` — upserts unconditionally; remote deletes execute without
  an HLC check.
- `localWins` — inserts only when no row currently exists for the key;
  remote deletes are silently rejected.

**B-5 (wire fidelity):** `SyncValueMap` round-trips every PersistenceKit
`TypedValue` case across an encoder via a discriminated `SyncValueBox`,
so `null`, `bool`, `int`, `bitmap`, `float`, `text`, `blob`, `uuid`,
`timestamp`, `json`, `hlc`, `fingerprint`, and `array` survive
serialization. The `bitmap`-vs-`int` and `json`-vs-`blob` distinctions
are preserved by the discriminator tag.

**B-6 (CloudKit metadata):** the CloudKit mapper drives record mapping
from the manifest, not from per-entity hardcoding. Each table maps to
record type `kitID_tableName`; sync metadata travels in reserved fields
(`_syncHLC`, `_syncSchemaVersion`, `_syncKitID`). The HLC packs into one
sortable `Int64` (48 bits physical, 12 bits logical, 4 bits node).

**B-7 (Federation pairing):** two estates pair by exchanging public keys
and a shared `HyperplaneFamilySpec` (seed + dimension) so their 256-bit
fingerprints are directly comparable. Pairing is symmetric — each side
registers the other. Pairing rides a `Relay` transport abstraction
(INTERFACE § 4): the in-process `FederationRelay` is the local-and-test
implementation, and a hosted HTTPS/gRPC SyncServer relay is a drop-in
`Relay` conformer requiring no change to the engine.

**B-8 (fieldLevelLWW) (v1.2-draft):** `ConflictPolicy.fieldLevelLWW`
applies last-writer-wins at the column grain. Per-column HLCs are
wire-carried in the `SyncRecord` (a new optional `columnHLCs:
[String: PackedHLC]?` field, requiring a byte-identical Rust twin per
C-8). Array and blob columns have no merge semantics: concurrent writes
to the same column from different devices lose the lower-HLC side.
Consumers who need append-safe semantics on array columns should use
`appendOnly` tables instead.

**B-9 (tombstoned deletes) (v1.2-draft):** Deletes are typed tombstone
records applied through the LWW gate. The tombstone HLC persists in the
side table after a hard-delete on both backends — `_ck_sync_meta` on
CloudKit, an equivalent side-table entry on Federation — so a stale
insert for the same `(table, rowKey)` cannot resurrect a deleted row.
The `_syncHLC` storage location for both backends is the side table after
R7 lands, not the row itself. Note on `pushOnly` and tombstones: a
`pushOnly` table (I-5) silently swallows remote tombstones; it never
accepts inbound deletes. Consumers who need delete propagation on
`pushOnly`-declared tables must use soft-delete bitmap columns instead.

**B-10 (schema-skew posture) (v1.2-draft):** A record whose
`schemaVersion` is newer than the local receiver's is not rejected as a
conflict; it is held in a persisted pending queue and replayed after the
local schema migrates to the matching version. Records whose
`schemaVersion` is strictly older than the local receiver's are rejected
as conflicts per I-4.

**B-11 (convergence loop) (v1.2-draft):** The outbox drains on a
debounced cadence after local writes to prevent per-keystroke push storms.
Inbound: adaptive tiered polling is the correctness path — fast cadence
immediately after observed remote activity, backing off to idle cadence
when the zone has been quiet. Zone-subscription push
(`CKRecordZoneSubscription`) is an optional latency accelerator for host
apps holding APNs entitlements; a silent-push wakeup nudges the engine
to drain a pull cycle sooner than idle cadence would. All multi-device
behavior is sound under polling alone.

**B-12 (side-table governance) (v1.2-draft):** All `_ck_*` side tables —
`_ck_sync_meta`, `_ck_outbox`, `_ck_change_token`, `_ck_device_identity`,
and `_ck_pending_skew` — live under a single `SchemaDeclaration` with
`kitID "ConvergenceKit"` and a single version counter. Each additional
side table increments the version; migrations are additive. No two
`SchemaDeclaration` entries share the same version number with different
table sets.

**Note N4 (CloudKit exclusivity) (v1.2-draft):** The CloudKit backend is
Swift-vertical only, following the same precedent as Metal compute kernels.
CloudKit has no Rust API, and the no-FFI constraint between Swift and Rust
legs is immutable. Vocabulary and wire-format changes (including additions
from B-8) still carry byte-identical Rust twins per C-8. The Rust
vertical's multi-machine story is Federation
(`DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md`).

## § 6 — Error model (conceptual)

Errors are the `SyncError` enum (shape in INTERFACE § 4). Categories:

| Category | Trigger | Recovery posture |
|---|---|---|
| `notEnabled` | `push`/`pull`/`subscribe` before `enable` | abort; caller must enable first |
| `alreadyEnabled` | second `enable` without `disable` | abort; caller must disable first |
| `schemaMismatch(expected,received)` | inbound record's schema version ≠ receiver's | reject record; retry post-app-update |
| `kitMismatch(expected,received)` | inbound record's kit ID ≠ receiver's | reject record; cross-kit safety guard |
| `transportFailure(detail)` | CloudKit `modifyRecords` / `recordZoneChanges` failure | surface; retry the cycle |
| `decodingFailure(detail)` | malformed wire bytes / missing metadata field | reject record; counted as conflict |
| `encodingFailure(detail)` | record encode or signature failure on push | abort the push cycle |
| `peerUnreachable(identity)` | Federation peer not reachable | surface; retry |
| `authenticationFailed(detail)` | Federation identity/auth failure | surface; do not apply |
| `unsupportedTable(name)` | inbound record names a table absent from the manifest | reject record |
| `corruptRemoteIdentity(recordName)` | CloudKit-only: CKRecord's `recordName` cannot be parsed as a UUID | quarantine record; counted as conflict; pull continues |
| `reenrollRequired(slot:staleEpoch:currentEpoch:)` | CloudKit-only (v1.2-draft): device's `(slot, epoch)` has been superseded by eviction and re-epoch; raised before any records are applied | engine re-claims a fresh slot, re-mints pending outbox entries with the new identity, then resumes; does not abort the pull cycle |
| `slotExhausted(activeCount:)` | CloudKit-only (v1.2-draft): all 15 assignable slots are occupied by recently-active devices | surfaced to caller; loud; no records applied until a slot is freed |

Per-cycle inbound rejections (`schemaMismatch`, `kitMismatch`,
`decodingFailure`, `unsupportedTable`, `corruptRemoteIdentity`, signature
failure) are caught, logged, and counted in the receipt's `conflicts`;
they do not abort the whole cycle. `notEnabled`, `alreadyEnabled`,
`transportFailure`, and `encodingFailure` are thrown to the caller.
`corruptRemoteIdentity`, `reenrollRequired`, and `slotExhausted` are
CloudKit-only; they are never thrown by the Federation or None backends.

## § 7 — Conformance requirements

**C-1 (lifecycle gate):** `push`/`pull` before `enable` raise
`notEnabled`; a second `enable` raises `alreadyEnabled`; `disable` is
idempotent and returns `state == disabled` (I-1, I-2).

**C-2 (round-trip convergence):** with two estates over the same
manifest, a one-shot push from A followed by a pull on B leaves B's
storage matching A's writes for every `bidirectional` table.

**C-3 (direction respected):** a `pushOnly` table never accepts inbound
changes; a `pullOnly` table never ships local changes (I-5).

**C-4 (conflict policies):** `lastWriterWinsByHLC`, `appendOnly`,
`localWins`, and `remoteWins` each behave per B-4 on the conformance
fixtures.

**C-5 (kit/schema rejection):** an inbound record with a mismatched
`kitID` or `schemaVersion` is rejected and counted as a conflict, and
does not mutate storage (I-4, B-2).

**C-6 (None semantics):** the None backend's `push`/`pull` return
`SyncReceipt.empty` when enabled and `subscribe` never emits (B-1).

**C-7 (Federation authentication):** a message with an invalid signature
is rejected at pull and its records do not apply (I-7).

**C-8 (wire round-trip):** every `TypedValue` case round-trips through
`SyncValueMap` / `SyncValueBox` and the Rust version agrees with the Swift version on the discriminated encoding (B-5). The CloudKit HLC pack/unpack
is lossless within the 48/12/4-bit layout (B-6).

The conformance fixtures run with InMemory PersistenceKit underneath.
None and Federation run them unconditionally; CloudKit is gated on a
configured test container.

## Changelog

### 1.2-draft -- 2026-07-16
- Added I-10 (no-echo), I-11 (device slot identity), I-12 (durable
  pipeline) to § 4.
- Added B-8 (fieldLevelLWW), B-9 (tombstoned deletes), B-10 (schema-skew
  posture), B-11 (convergence loop), B-12 (side-table governance), and
  Note N4 (CloudKit exclusivity) to § 5.
- Added `reenrollRequired(slot:staleEpoch:currentEpoch:)` and
  `slotExhausted(activeCount:)` CloudKit-only error cases to § 6;
  updated per-cycle vs. cycle-aborting classification note.

### 1.1 -- 2026-07-16
- Added `corruptRemoteIdentity(recordName)` to § 6 error model (CloudKit-only; per-record quarantine, does not abort the pull cycle).
- Clarified which error categories are per-cycle vs. cycle-aborting.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
