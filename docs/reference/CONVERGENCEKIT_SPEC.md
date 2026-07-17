---
title: ConvergenceKit Specification
version: 1.2-draft
status: active
date: 2026-07-16
description: "Behavioral specification for ConvergenceKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/CONVERGENCEKIT_INTERFACE.md
  - docs/reference/CONVERGENCEKIT_PLAYGROUND_RULES.md
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
`kitID` matches and its `schemaVersion` is compatible with the receiver's
manifest. A `kitID` mismatch is `kitMismatch` and rejects the record as a
conflict. A `schemaVersion` mismatch is directional: a record whose version
is **strictly newer** than the receiver's is held in the persistent pending-skew
queue (`_ck_pending_skew` / `_fed_pending_skew`) rather than rejected — it is
not counted as a conflict, and it is replayed from the queue during the next
`enable()` call after the receiver's schema migrates to the matching version
(see B-10). A record whose version is **strictly older** than the receiver's is
rejected as a `schemaMismatch` and counted as a conflict; applying it would
overwrite newer-schema columns with missing-field defaults. Equal `schemaVersion`
is the normal accept path.

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

*Implementation note (CVK-ICLOUD P1-M1, 2026-07-16):* The mechanism is now
implemented and passing tests. `PersistenceKit.RowStore` exposes `insertSync` /
`upsertSync` / `deleteSync`; ConvergenceKit's `applyInbound` calls these paths
(both CloudKit and Federation backends). The CloudKitStateActor and
FederationStateActor `recordOutbound` methods guard on `change.origin != .syncApply`.
The `(v1.2-draft)` status marker will be flipped to active in P5-M4 once full
iCloud end-to-end integration testing confirms convergence on live devices.

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
≥1 record, `pushCompleted(receipt:)` after a push,
`peerConnected` / `peerDisconnected` for Federation pairing, and
`recordsHeldForMigration(count:)` when ≥1 future-schema record was held in
the pending-skew queue during a pull cycle, or when the skew queue is
non-empty after enable-time replay (B-10). Closing the stream stops the
subscription. The CloudKit and Federation backends buffer the newest 256 events.
Rust twin: `SyncEvent::RecordsHeldForMigration { count: usize }` (CVK-ICLOUD P3-M4).

**B-4 (conflict policy at the apply boundary):** the receiver applies
each inbound record under the table's `ConflictPolicy`:

- `lastWriterWinsByHLC` — on insert/update: reads the row's persisted
  sync HLC from the backend's sync-meta side table (`_ck_sync_meta` /
  `_fed_sync_meta`, written by every winning apply; the HLC does not
  live in the application row — see B-9); if the incoming HLC is
  strictly less than the stored HLC the record is silently dropped;
  otherwise the row is upserted and the side-table HLC is written with
  the incoming HLC so the next inbound comparison has durable state. On
  delete: the same HLC gate applies — a stale delete (incoming HLC <
  stored HLC) is silently rejected; a newer or equal delete hard-deletes
  the row and the delete HLC persists in the side table as a tombstone
  entry (B-9), so stale inserts cannot resurrect the row. Both CloudKit
  and Federation backends implement this identical comparison semantics.
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

**B-8 (fieldLevelLWW):** `ConflictPolicy.fieldLevelLWW` applies
last-writer-wins at the column grain using per-column HLCs. Shipped in
`ConvergenceKit` v1.2 (CVK-ICLOUD P2-M1).

- **Wire format:** `SyncRecord` carries an optional `columnHLCs:
  ColumnHLCMap?` field. `ColumnHLCMap` is a `{entries: {colName:
  PackedHLC}}` JSON wrapper. The field is omitted when nil (backward
  compat: row-grain LWW applied instead, using `SyncRecord.hlc`).
- **Capture:** the sender (outbox observer) stamps ALL present value
  columns with the capture HLC. Per-column identity is a future
  refinement once `TableChange` gains `changedColumns` support.
- **Apply:** the receiver applies a column iff incoming column HLC >=
  local column HLC (stored in `_ck_sync_meta_cols` on CloudKit,
  `_fed_sync_meta_cols` on Federation). Missing local HLC = first write,
  always applied. Commutativity is guaranteed: the winner per column is
  always the record with the higher HLC, regardless of apply order.
- **Tombstone interplay:** an incoming delete beats local field edits
  only when the tombstone HLC is >= ALL local column HLCs. If any local
  column HLC is strictly higher, the row was edited after the delete —
  the edit wins (`FieldLWWMerge.tombstoneWins`).
- **Outbox coalescing:** when a newer outbox entry for the same (table,
  row) coalesces with a stale one, column HLC maps are merged (highest
  per column) so no column update is silently discarded.
- **Array and blob columns** are atomic whole values — no sub-field
  addressing. Concurrent writes to the same column lose the lower-HLC
  side. Use `appendOnly` tables for append-safe array semantics.
- **Rust parity:** `ColumnHLCMap { entries: BTreeMap<String, PackedHLC>
  }` in `rust/src/record.rs`; field `column_hlcs: Option<ColumnHLCMap>`
  on `SyncRecord`; wire contract byte-identical per C-8.
- **Side-schema version:** `CKSideSchema` bumped v3 → v6 (v4/v5
  earmarked for device-identity and pending-skew tables). Migration adds
  `_ck_sync_meta_cols` table and `column_hlcs BLOB` column to
  `_ck_outbox`. `FederationSyncEngine` side-schema bumped v1 → v2 to
  add `_fed_sync_meta_cols`.

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

**B-10 (schema-skew pending queue) (v1.2-draft):** A record whose
`schemaVersion` is strictly newer than the local receiver's is not rejected
as a conflict. Instead it is enqueued in the durable pending-skew side table
(`_ck_pending_skew` on CloudKit, `_fed_pending_skew` on Federation) for
deferred replay. Enqueue uses `upsertSync` (echo-suppressed origin) so the
held record is never re-entered into the outbox. The queue is capped at 512
entries; when the cap is exceeded, the oldest entries by `received_at` are
evicted. During `enable()`, after the side schema is ensured and the manifest
is loaded, the engine drains all queue entries whose `schema_version` matches
the current manifest version and replays them through `applyInbound` under the
normal conflict policy. Successfully replayed entries are deleted from the queue.
Entries held for schema versions not yet reached by the local estate remain in
the queue for the next `enable()` cycle. After replay, if the queue is still
non-empty, `SyncEvent.recordsHeldForMigration(count:)` is emitted so subscribers
can surface a "waiting for app update" indicator. Records whose
`schemaVersion` is strictly older than the local receiver's are rejected as
`schemaMismatch` and counted as a conflict (I-4).
Implementation: `PendingSkewQueue.swift`, `SkewReplay.swift` (CVK-ICLOUD P3-M4).

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
table sets. Consolidation state: `_ck_sync_meta`, `_ck_outbox`, and
`_ck_change_token` are consolidated as of v3; `_ck_device_identity`
still carries its own declaration (planned v4 consolidation);
`_ck_pending_skew` was added at v7 via a v6→v7 migration (v4/v5 earmarks
were superseded by the v3→v6 jump for `_ck_sync_meta_cols` and
`_ck_device_identity`). (CVK-ICLOUD P3-M4)

**B-13 (slot registry claim/heartbeat/fence contract) (v1.2-draft):**
The CloudKit device slot registry (N2) enforces the following behavioral
contract for every device that participates in a multi-device estate:

1. **Claim.** On `enable()`, the engine claims one of the 15 assignable
   CloudKit HLC node-ID slots via `SlotClaimOperation` using CloudKit CAS
   (`ifServerRecordUnchanged`). The claim is atomic: exactly one device wins
   each slot per epoch. On CAS race loss the engine retries with jittered
   exponential backoff (A5). After `maxAttempts` all fail, `slotExhausted`
   is thrown.

2. **Preferred-slot stability.** The previously claimed slot is passed as
   `preferredSlot` on subsequent enrollments to reduce unnecessary re-mints
   and HLC namespace changes.

3. **Heartbeat.** At the start of every push cycle — BEFORE reading the
   outbox batch — `EpochFence.heartbeat` fetches this device's own slot
   record from CloudKit and writes the current HLC into `last_active_hlc`
   via a conditional CAS save. The heartbeat doubles as an epoch fence (see
   below). Slots that have never heartbeated (ghost slots, `lastActiveHLC ==
   HLC.zero`) that are older than `SlotGhostWindow` (1 hour) are eligible
   for fast-path eviction.

4. **Epoch fence.** The `EpochFence.heartbeat` CAS compares the registry
   record's epoch to the locally-stored identity epoch. A mismatch means the
   slot was evicted and re-epoch'd while this device was inactive. The engine
   throws `reenrollRequired` BEFORE reading or applying any outbox entries.
   Applying records under a superseded node-ID would produce HLC ties whose
   LWW resolution differs across replicas (silent divergence).

5. **Re-enrollment (A2).** On `reenrollRequired` — whether from the fence
   or from enable-time epoch mismatch — the engine: (a) claims a fresh slot
   via `SlotClaimOperation`; (b) re-mints ALL pending outbox HLCs under the
   new node-ID via `OutboxStore.remintAll`; (c) persists the new identity.
   Re-mint is safe because outbox entries are unpushed local state — no
   remote replica has seen those HLCs, so LWW has no prior decisions to
   invalidate.

6. **Eviction.** When all 15 slots are occupied, `SlotClaimOperation` runs
   `SlotTable.claimSlot` to pick an eviction candidate. Ghost slots (never
   heartbeated, claimedAt older than `SlotGhostWindow`) are preferred (A4
   fast path). Otherwise the slot with the oldest `lastActiveHLC.physicalTime`
   beyond `SlotLongInactivityWindow` (30 days) is chosen. Eviction bumps the
   epoch atomically via a CAS save; a race loss retries. When no candidate
   qualifies, `slotExhausted(activeCount:)` is thrown.

**B-14 (column projection) (v1.2-draft):** `SyncedTable` carries an
`excludedColumns: Set<String>` field (Swift) / `excluded_columns: HashSet<String>`
(Rust). Exclusion semantics only (not inclusion). JSON key `"excludedColumns"`;
omitted when empty for backward compatibility. Two enforcement points per backend:

1. **Outbound (before outbox enqueue):** the outbox entry strips all excluded
   columns from the record's values before append. If, after stripping, the only
   remaining value is the primary key (storm-kill condition), the update is not
   enqueued at all — a derived-column recompute generates zero outbound traffic.
   Delete events (tombstones) are never suppressed regardless of `excludedColumns`.

2. **Inbound (before conflict-policy switch in `applyInbound`):** excluded columns
   are dropped from the inbound record before the policy switch. A peer on a
   different manifest version may send columns this manifest marks excluded;
   dropping them prevents overwriting locally-computed derived values with stale
   remote copies. The drop is logged at warning level with the column list.

`Projection.outboundStrip`, `Projection.isAllExcluded`, and `Projection.isStormKill`
(Swift) / `outbound_strip_change` (Rust) are the canonical implementations.
The `with_excluded_columns` builder on `SyncedTable` (both legs) is the ergonomic
construction path (see CONVERGENCEKIT_INTERFACE.md §SyncedTable).

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
| `schemaMismatch(expected,received)` | inbound record's schema version is strictly OLDER than receiver's (downgrade apply) | reject record; counted as conflict (B-10; future-schema records are held, not rejected) |
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

### Per-record push error taxonomy (CloudKit-only, v1.2-draft)

When `modifyRecords(atomically: false)` returns, each record carries its
own `Result<CKRecord, Error>`. The engine classifies each per-record error
into one of four postures and acts immediately:

| Posture | Trigger | Outbox action |
|---|---|---|
| `retryableBackoff` | Transient: network, rate-limit, service unavailable, authentication | Increment `retry_count`; leave in outbox. If `CKError.retryAfterSeconds` is set, the caller honours it as a minimum delay floor before the next push cycle. |
| `reclaim` | Zone or change token invalid (`zoneNotFound`, `userDeletedZone`, `changeTokenExpired`) | Increment `retry_count`; surface `reclaimNeeded` to caller. Caller must re-create the zone or clear the server change token before the next push attempt. |
| `conflict` | `serverRecordChanged` — server holds a newer version | Increment `retry_count`; leave in outbox. The pull cycle resolves the conflict via LWW before the next push attempt re-pushes the same entry. |
| `permanent` | Quota exceeded, record size exceeded, programming / configuration error | Set `is_parked = 1`; exclude from future `readBatch` calls. Entry is visible via `OutboxStore.parkedEntries()` for diagnostics. No further push attempts. |

The receipt's `pushed` count equals the number of records that received a
`.success` result — not the total sent. Entries that fail with any posture
are NOT counted as pushed (B-2).

Whole-batch transport failures (network outage or authentication error
before CloudKit processes any records) still throw `SyncError.transportFailure`
to the caller; no per-record classification runs. All outbox entries survive
intact for the next push cycle.

The `retryAfter` value from `CKError.retryAfterSeconds` on `requestRateLimited`
errors is surfaced in the `CKErrorClass.retryableBackoff(retryAfter:)` case.
`RetryPolicy.delay(forAttempt:suggestedRetryAfter:)` uses it as a hard floor:
the computed exponential backoff is never shorter than the server's instruction.

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

**C-5 (kit/schema gate):** an inbound record with a mismatched `kitID` is
rejected and counted as a conflict (I-4). An inbound record whose
`schemaVersion` is strictly older than the receiver's is rejected and counted
as a conflict. An inbound record whose `schemaVersion` is strictly newer than
the receiver's is enqueued in the pending-skew queue, not counted as a conflict,
and not applied to storage. In no case does a rejected or held record mutate the
user table (I-4, B-2, B-10).

**C-15 (skew-queue hold and replay):** given a record in the cloud with
`schemaVersion` = N+1 and a receiver with manifest `schemaVersion` = N: the
record is held in `_ck_pending_skew` (or `_fed_pending_skew`) during pull and
does not appear in the user table; on disable/re-enable with manifest
`schemaVersion` = N+1, the record is replayed through `applyInbound` and
appears in the user table; the queue entry is deleted after successful replay;
the outbox stays empty after replay (echo suppression, I-10). (CVK-ICLOUD P3-M4)

**C-6 (None semantics):** the None backend's `push`/`pull` return
`SyncReceipt.empty` when enabled and `subscribe` never emits (B-1).

**C-7 (Federation authentication):** a message with an invalid signature
is rejected at pull and its records do not apply (I-7).

**C-8 (wire round-trip):** every `TypedValue` case round-trips through
`SyncValueMap` / `SyncValueBox` and the Rust version agrees with the Swift version on the discriminated encoding (B-5). The CloudKit HLC pack/unpack
is lossless within the 48/12/4-bit layout (B-6).

**C-9 (echo suppression):** an inbound write from `applyInbound` does not
re-enter the outbox. After a push-pull cycle, the receiving side has zero
pending outbound entries attributable to the received records (I-10).

**C-10 (LWW tombstone persistence):** a delete event carries its HLC into
the side table after the hard-delete so that a stale insert arriving later
is still rejected (A6 unification, B-9).

**C-11 (column projection) (v1.2-draft):** given a manifest with
`excludedColumns = ["derived"]` on a table:
- An outbound update that changes ONLY `"derived"` is not enqueued (storm kill).
- A peer that sends `"derived"` in an inbound record: the column is dropped
  before `applyInbound`; the local value of `"derived"` is not overwritten.
- A `SyncedTable` with non-empty `excludedColumns` round-trips losslessly
  through JSON; a legacy JSON payload without `"excludedColumns"` decodes to
  an empty set (backward compat). Empty `excludedColumns` is omitted from JSON.
- Delete events propagate regardless of `excludedColumns`.

The conformance fixtures run with InMemory PersistenceKit underneath.
None and Federation run them unconditionally; CloudKit is gated on a
configured test container.

## Changelog

### 1.2-draft -- 2026-07-16 (updated 2026-07-16 CVK-ICLOUD P3-M4)
- Updated I-4 (kit and schema gate): future-schema records (schemaVersion > manifest)
  are now held in the pending-skew queue rather than rejected as conflicts; only
  downgrade-schema records (schemaVersion < manifest) are rejected as schemaMismatch.
- Updated B-3 (event stream): added `recordsHeldForMigration(count:)` event (emitted
  on pull when future-schema records are held, and on enable() when the queue is
  non-empty after replay); added Rust twin reference.
- Rewrote B-10 (schema-skew posture → schema-skew pending queue): added queue cap
  (512 entries, oldest-eviction), enable-time replay semantics, echo-suppressed enqueue,
  deleteApplied cleanup, and still-held notification.
- Updated B-12 (side-table governance): corrected `_ck_pending_skew` arrival version
  to v7 (via v6→v7 migration); removed stale "planned v5" forward reference.
- Updated C-5 (kit/schema gate): split into kitID rejection vs. schema-version routing
  (future-schema = hold, downgrade = conflict).
- Added C-15 (skew-queue hold and replay): hold-then-replay conformance requirement.
- Updated § 6 error table: `schemaMismatch` now describes the downgrade-only trigger.
- Implementation: `PendingSkewQueue.swift`, `SkewReplay.swift`, `SideSchema.swift`
  (v7 + pendingSkewTable), `PullCycle.swift` (split schema check), `CloudKitStateActor.swift`
  (enable-time replay), `FederationSyncEngine.swift` (`_fed_pending_skew`, v3 schema,
  pull+enable updates), `SyncTypes.swift` (`recordsHeldForMigration`), `rust/src/types.rs`
  (`RecordsHeldForMigration`). Tests: `SkewQueueTests.swift` (8 unit tests),
  `SkewIntegrationTests.swift` (5 CK integration tests).

### 1.2-draft -- 2026-07-16 (updated 2026-07-16 CVK-ICLOUD P2-M2)
- Added B-14 (column projection) to § 5: `excludedColumns` field on
  `SyncedTable`, two-point enforcement (outbound strip + storm kill; inbound
  drop with warning), delete unaffected, backward-compatible JSON encoding.
- Added C-9 (echo suppression), C-10 (LWW tombstone persistence), C-11
  (column projection) conformance requirements to § 7.
- Implementation: `Projection.swift` (pure helpers), `SyncTypes.swift`
  (`excludedColumns` field + Codable), CloudKit `recordOutbound` +
  `applyInbound`, Federation `recordOutbound` + `applyInbound`, Rust
  `SyncedTable.excluded_columns` + `with_excluded_columns` + `outbound_strip_change`
  + inbound projection in `apply_record`. Tests: `ProjectionTests.swift`
  (21 tests covering strip, isAllExcluded, isStormKill, engine outbound/inbound,
  manifest round-trip). (CVK-ICLOUD P2-M2 R2)

### 1.2-draft -- 2026-07-16 (updated 2026-07-16 CVK-ICLOUD P2-M4)
- Added `docs/reference/CONVERGENCEKIT_PLAYGROUND_RULES.md` to
  `relates_to`. Consumer contract document (CVK-ICLOUD P2-M4).

### 1.2-draft -- 2026-07-16 (updated 2026-07-16 CVK-ICLOUD P1-M6)
- Added per-record push error taxonomy subsection to § 6: four postures
  (`retryableBackoff`, `reclaim`, `conflict`, `permanent`), outbox action
  per posture, B-2 `pushed`-count alignment, `retryAfter` floor semantics
  (CVK-ICLOUD P1-M6 R6).

### 1.2-draft -- 2026-07-16 (updated 2026-07-16 CVK-ICLOUD P1-M5)
- Added I-10 (no-echo), I-11 (device slot identity), I-12 (durable
  pipeline) to § 4.
- Added implementation note to I-10: echo suppression is now implemented
  (CVK-ICLOUD P1-M1). PersistenceKit stamped origin tag, ConvergenceKit
  `applyInbound` uses sync-tagged write paths, `recordOutbound` discards
  `.syncApply` changes in both CloudKit and Federation backends. The
  `(v1.2-draft)` marker on I-10 will flip to active in P5-M4 after
  end-to-end live-device validation.
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
