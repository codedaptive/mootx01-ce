---
title: ConvergenceKit Playground Rules
version: v0.1
status: active
date: 2026-07-16
description: "Consumer contract for kit authors composing PersistenceKit and ConvergenceKit for sync: ten rules, examples, policy decision table, and capability matrix."
spec_type: consumer-contract
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/CONVERGENCEKIT_SPEC.md
  - docs/reference/CONVERGENCEKIT_INTERFACE.md
  - docs/decisions/DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16.md
  - docs/decisions/DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md
  - docs/analysis/CVK_ICLOUD_KONG_REVIEW.md
---

# ConvergenceKit Playground Rules

This is the single document a consumer kit author needs before composing
PersistenceKit and ConvergenceKit for sync. Read it before declaring a
`SyncManifest`.

## How to read this document

Each rule states:

- **RULE** — the constraint in one sentence.
- **WHY** — the specific failure mode the rule prevents.
- **INSTEAD** — the correct pattern.
- **EXAMPLE** — a concrete `SyncManifest` or `SyncedTable` declaration.

Examples are labeled **[SHIPPED]** when they use only the public API that
is in the released `SyncTypes.swift` (four `ConflictPolicy` cases, base
`SyncedTable` and `SyncManifest` fields). They are labeled
**[DRAFT: v1.2]** when they depend on v1.2-draft surfaces
(`fieldLevelLWW`, `excludedColumns`, `postApplyIntegrityHook`).
See the SPEC invariants cross-referenced as I-N and behavioral contracts
as B-N throughout.

---

## The Ten Rules

### Rule 1 — Every synced table has a single-column UUID primary key

**WHY:** ConvergenceKit encodes the primary key as a CloudKit
`recordName` (a UUID string). A composite key, a non-UUID string key, or
any multi-column primary key cannot be decoded at the receive boundary.
The pull loop throws `corruptRemoteIdentity`, quarantines the record,
counts it as a conflict, and moves on. That record never applies — silently
and permanently.

**INSTEAD:** Ensure every table in the manifest has exactly one UUID
column serving as its primary key. Declare that column name in
`primaryKeyColumn`.

**EXAMPLE [SHIPPED]:**
```swift
// CORRECT — single UUID column as primary key
SyncedTable(
    name: "observations",
    primaryKeyColumn: "id",         // UUID column; maps cleanly to CKRecord.ID
    conflictPolicy: .appendOnly
)

// WRONG — "key" is a TEXT identifier, not a UUID.
// Every received record throws corruptRemoteIdentity and is quarantined.
SyncedTable(
    name: "config",
    primaryKeyColumn: "key",        // TEXT primary key — not a UUID
    conflictPolicy: .lastWriterWinsByHLC
)
```

Cross-reference: SPEC I-4 (kit and schema gate); SPEC B-6 (CloudKit
record naming — `kitID_tableName`, UUID-based record IDs).

---

### Rule 2 — Policy follows data shape; no transaction spans a sync boundary

**WHY:** The wrong policy corrupts data silently. A mutable-entity table
declared `appendOnly` rejects every remote update — the device sees only
its own writes, forever. A counter column on a `lastWriterWinsByHLC` table
loses concurrent increments from other devices (see Rule 5). Transactions
that span two tables are not atomic across sync: ConvergenceKit applies
rows one at a time, and a partial batch is the normal inbound case.

**INSTEAD:** Choose policy from data shape, not intuition. The decision
table in the "Policy Decision Table" section below maps shapes to policies.
For multi-table consistency, supply a post-apply hook (Rule 3).

**EXAMPLE [SHIPPED]:**
```swift
let manifest = SyncManifest(
    kitID: "CorpusKit",
    schemaVersion: 3,
    zoneIdentifier: "GeniusLocus-\(estateID)",
    tables: [
        // Append-only: events accumulate; remote deletes are silently rejected.
        SyncedTable(name: "chunks",
                    primaryKeyColumn: "id",
                    conflictPolicy: .appendOnly),
        // Mutable entities: most-recent write wins at the row grain.
        SyncedTable(name: "corpus_meta",
                    primaryKeyColumn: "id",
                    conflictPolicy: .lastWriterWinsByHLC),
    ]
)
```

Cross-reference: SPEC B-4 (conflict policy at the apply boundary).

---

### Rule 3 — No cross-row or cross-table invariants are maintained by sync; supply a post-apply hook to restore them

**WHY:** ConvergenceKit applies each inbound row independently. A batch
of N rows may arrive in any order and may be partially applied — transport
failure, version skew hold, or per-record conflict can leave a batch
partially written. Any local state that assumes "all rows in a batch
arrived together" reads inconsistent data during the apply window. For
example: a `chapters` table and a `chapter_order` table are both synced.
After a partial pull, chapter rows may exist with no matching order entry.

**INSTEAD:** Design local invariants to tolerate temporary inconsistency.
Restore cross-row or cross-table state in a hook that runs after each full
pull batch completes.

**EXAMPLE [DRAFT: v1.2] — `postApplyIntegrityHook` requires
`SyncManifest` v1.2 and is not in the shipped `SyncManifest.init`:**
```swift
// v1.2-draft: postApplyIntegrityHook parameter is not in the shipped init.
// When v1.2 ships, pass the hook at construction.
var manifest = SyncManifest(
    kitID: "CorpusKit",
    schemaVersion: 3,
    zoneIdentifier: "GeniusLocus-\(estateID)",
    tables: tables,
    postApplyIntegrityHook: { storage in
        // Recompute derived cross-table state after each pull batch.
        await recomputeChapterOrdering(storage: storage)
    }
)
```

**Shipped workaround [SHIPPED]:** run the integrity pass manually after
every `pull()` call:
```swift
let receipt = try await engine.pull()
if receipt.pulled > 0 {
    await recomputeChapterOrdering(storage: storage)
}
```

Cross-reference: SPEC I-3 (apply-through-storage); SPEC B-10 (schema-skew
posture, v1.2-draft); decision doc N3 (convergence loop), R3 requirement.

---

### Rule 4 — Derived columns never sync

**WHY:** A derived column (a value recomputed from other data) should
produce the same result on every device. Syncing it sends the sender's
computed value, which then overwrites the receiver's locally-computed
value via LWW. If the computation depends on local state — indexes, folded
scores, position-relative rankings — the receiver silently receives a value
computed from different inputs. The receiver's computation is now wrong,
and neither device knows it.

**INSTEAD:** Exclude derived columns from sync records by listing them in
`excludedColumns` on the `SyncedTable` declaration. They are never
serialized into the outbound `SyncRecord`. As a shipped workaround,
avoid storing derived values in PersistenceKit at all — compute them at
read time or in a separate non-synced table.

**EXAMPLE [DRAFT: v1.2] — `excludedColumns` requires `SyncedTable` v1.2
and is not in the shipped `SyncedTable.init`:**
```swift
// v1.2-draft: excludedColumns parameter is not in the shipped init.
SyncedTable(
    name: "drawers",
    primaryKeyColumn: "id",
    conflictPolicy: .lastWriterWinsByHLC,
    excludedColumns: ["computed_score", "rank_position"]   // recomputed locally
)
```

**Shipped workaround [SHIPPED]:** do not store derived values in
PersistenceKit. Compute them at read time.

Cross-reference: SPEC I-5 (direction honoured); SPEC B-8 (`fieldLevelLWW`
`excludedColumns`, v1.2-draft); decision doc R2 requirement.

---

### Rule 5 — No increment semantics

**WHY:** Two devices both read a counter (value: 5) and increment it to 6.
Both push. One wins LWW. The other's increment is silently discarded. The
counter reads 6, but both increments were real. There is no recovery: the
discarded increment is gone and left no trace in storage.

**INSTEAD:** Model the counter as an `appendOnly` event table. Each device
appends a row carrying the delta. The current count is folded locally by
summing the `value` column.

**EXAMPLE [SHIPPED]:**
```swift
// CORRECT — counter modeled as append-only events
SyncedTable(
    name: "entity_events",
    primaryKeyColumn: "event_id",
    conflictPolicy: .appendOnly
)
// Schema: entity_events(event_id UUID, entity_id UUID, kind TEXT, value INT64)
// Read:   SELECT SUM(value) FROM entity_events
//         WHERE entity_id = ? AND kind = 'viewCount'

// WRONG — view_count column in this table loses concurrent increments.
// Do not place counter columns on lastWriterWinsByHLC tables.
SyncedTable(
    name: "entities",
    primaryKeyColumn: "id",
    conflictPolicy: .lastWriterWinsByHLC
)
// entity.view_count: each device's increment races with other devices;
// one increment wins LWW, the rest are silently lost.
```

Cross-reference: SPEC B-4 (`appendOnly` idempotent upsert on primary key).

---

### Rule 6 — Deletes are tombstoned LWW; `pushOnly` tables silently swallow remote tombstones

**WHY:** `lastWriterWinsByHLC` applies HLC ordering to both upserts and
deletes (SPEC B-4, v1.2-draft B-9). A device that edits a row at HLC T=5
beats a concurrent delete at T=4: the row survives. This is correct LWW
behavior — edit-beats-delete is the contract, not delete-always-wins.

A `pushOnly` table (SPEC I-5) never accepts inbound changes of any kind,
including tombstones. A hard delete on device A ships outbound but is
silently discarded inbound on every peer. The row persists on all other
devices.

**INSTEAD:** Accept edit-beats-delete as the LWW contract for
`bidirectional` tables. For `pushOnly` tables where delete visibility
across devices is needed: use a soft-delete bitmap column rather than
hard-deleting rows. Set a bit to mark the row deleted; filter by that bit
at read time.

**EXAMPLE [SHIPPED]:**
```swift
// CORRECT — soft-delete via bitmap bit on a pushOnly table
SyncedTable(
    name: "config_entries",
    direction: .pushOnly,
    primaryKeyColumn: "id",
    conflictPolicy: .lastWriterWinsByHLC
)
// Schema: config_entries(id UUID, payload TEXT, operational_bitmap INT64)
// Bit 0 of operational_bitmap = soft-deleted.
// To delete:  UPDATE config_entries
//             SET operational_bitmap = operational_bitmap | 1
//             WHERE id = ?
// To read:    SELECT * FROM config_entries
//             WHERE (operational_bitmap & 1) = 0

// WRONG — hard-deleting from a pushOnly table; remote devices never see it.
// The DELETE ships outbound but is silently swallowed inbound on all peers.
// try await storage.rowStore.delete(from: "config_entries", rowKey: entryID)
```

Cross-reference: SPEC I-5 (direction honoured); SPEC B-4 (LWW delete
gate); SPEC B-9 (tombstoned deletes, v1.2-draft); Kong review Q3 finding
(pushOnly + tombstone asymmetric delete semantics, A8).

---

### Rule 7 — Ordering is by substrate HLC only; no other ordering guarantee crosses a sync boundary

**PREREQUISITE (N2 slot registry, v1.2-draft):** This ordering guarantee
holds only when each device holds a unique HLC node ID. The slot registry
(N2) enforces this by assigning a `(slot, epoch)` pair per device at
`enable()` time. Before N2 ships, two devices may draw the same random
node ID per SPEC B-6; HLC comparisons for the same physical-time window
then become undefined, and LWW resolves differently on different replicas.

**WHY:** Insertion order and wall-clock order are local concepts. A batch
of inbound rows may arrive in a different order than they were written.
SQL `rowid` order at the sender is not preserved at the receiver. The HLC
on each `SyncRecord` is the only total order that propagates across the
sync boundary.

**INSTEAD:** Sort, filter, and display records using the HLC value. Store
the HLC in a dedicated column (for example, `created_hlc INT64`) when the
application needs cross-device ordering. Do not assume that `rowid`,
auto-increment IDs, or wall-clock sequence is consistent across devices.

No manifest example is needed for this rule — it is a constraint on data
access, not on manifest declaration. The HLC is available in the substrate
via `HLCGenerator`; ConvergenceKit's `SyncRecord` carries a `PackedHLC`
that unpacks to `HLC`.

Cross-reference: SPEC I-6 (HLC determinism); SPEC B-6 (48/12/4-bit
HLC layout); decision doc N2 (device slot identity, v1.2-draft); Kong
review Q5 finding (Rule 7 N2 prerequisite note, A10).

---

### Rule 8 — Version skew pauses sync, never breaks it

**WHY:** When one device has migrated to `schemaVersion` 4 and another is
still on 3, the version-3 device cannot interpret a version-4 record
without risking corrupt storage or silent data loss. ConvergenceKit's
schema gate (SPEC I-4) prevents this: records whose `schemaVersion`
does not match the receiver's manifest are rejected before any storage
mutation.

**INSTEAD:** Increment `schemaVersion` whenever you add, remove, or rename
a column. Keep the version number identical in the manifest and the
PersistenceKit schema migration. Old devices discard newer records as
conflicts (shipped, per I-4) until they update. With B-10 (v1.2-draft),
newer records are held in a durable pending queue and replayed after the
local schema migrates to match.

**EXAMPLE [SHIPPED]:**
```swift
// schemaVersion must increment when schema changes.
// Both devices must share the same schemaVersion for records to apply.
SyncManifest(
    kitID: "CorpusKit",
    schemaVersion: 4,          // bumped from 3 when "summary" column was added
    zoneIdentifier: "GeniusLocus-\(estateID)",
    tables: [...]
)
// A device still on schemaVersion 3 receives these records:
//   Shipped (I-4):        schemaMismatch → counted as conflict, record dropped.
//   v1.2-draft (B-10):   schemaMismatch → held in pending queue,
//                         replayed after local schema migrates to 4.
```

Cross-reference: SPEC I-4 (kit and schema gate); SPEC B-10 (schema-skew
posture, v1.2-draft); decision doc R9 requirement.

---

### Rule 9 — The iCloud arm is Apple-platform and Swift-vertical only

**WHY:** CloudKit has no Rust API. The no-FFI constraint between Swift and
Rust legs is immutable (N4). The Rust vertical's multi-machine story is
Federation. Wire-format additions — new `SyncRecord` fields, new
`TypedValue` cases, the v1.2-draft `columnHLCs` field for
`fieldLevelLWW` — still carry byte-identical Rust twins per C-8, because
the shared wire format is not CloudKit-specific.

**INSTEAD:** Use `CloudKitSyncEngine` only in Swift-vertical code. Use
`FederationSyncEngine` for the Rust multi-machine path. When
`fieldLevelLWW` ships with per-column HLC wire fields, include the Rust
`SyncRecord` twin in the implementation scope — the transport is Swift-only
but the format is shared.

**EXAMPLE [SHIPPED]:**
```swift
// Swift-vertical: iCloud multi-device sync
let engine: any SyncEngine = CloudKitSyncEngine()
try await engine.enable(manifest: manifest, storage: storage)

// There is no CloudKit path in the Rust vertical.
// For Rust multi-machine sync, use FederationSyncEngine in src/federation.rs.
```

Cross-reference: SPEC B-6 (CloudKit metadata); SPEC B-7 (Federation
pairing); SPEC C-8 (wire round-trip parity); decision doc N4 (Swift-leg
exclusivity).

---

### Rule 10 — Under `fieldLevelLWW`, array and blob columns are atomic whole values; concurrent appends lose the lower-HLC write

*Added by the Kong architecture review (CVK-ICLOUD P0-M2, Q5 finding
A9). Applies when `fieldLevelLWW` ships as part of v1.2.*

**WHY:** `fieldLevelLWW` applies last-writer-wins at the column grain —
not at the element grain within an array. Two devices both append to a
`tags` column: device A appends "swift" at HLC T=5; device B appends
"macOS" at T=4. At the column grain, device A's write wins. Device B's
write — the entire column value including "macOS" — is discarded. The
result is only `["swift"]`, not `["existing", "swift", "macOS"]`. This
is the most likely footgun when adopting `fieldLevelLWW` for entities
with list-valued fields.

**INSTEAD:** Model growing collections as `appendOnly` rows in a separate
table, not as array columns on a `fieldLevelLWW` table. Each element is a
row with a UUID primary key. Both appends survive as distinct rows.

**EXAMPLE [DRAFT: v1.2] — `fieldLevelLWW` requires `ConflictPolicy` v1.2
and is not in the shipped `ConflictPolicy`:**
```swift
// WRONG — array column under fieldLevelLWW loses concurrent appends.
// (v1.2-draft — fieldLevelLWW is not in the shipped ConflictPolicy)
SyncedTable(
    name: "entities",
    primaryKeyColumn: "id",
    conflictPolicy: .fieldLevelLWW   // v1.2-draft
)
// Schema: entities(id UUID, name TEXT, tags ARRAY)
// Device A appends "swift" to tags at HLC T=5.
// Device B appends "macOS" to tags at HLC T=4.
// LWW at column grain: Device A wins the whole column.
// Device B's "macOS" is silently discarded.

// CORRECT — append-only rows: both appends survive as distinct rows.
SyncedTable(
    name: "entity_tags",
    primaryKeyColumn: "tag_id",
    conflictPolicy: .appendOnly       // SHIPPED
)
// Schema: entity_tags(tag_id UUID, entity_id UUID, value TEXT)
// Device A row: (tag_id: uuid-a, entity_id: X, value: "swift")
// Device B row: (tag_id: uuid-b, entity_id: X, value: "macOS")
// Both rows converge on all devices. Neither is discarded.
// Read: SELECT value FROM entity_tags WHERE entity_id = ?
```

Cross-reference: SPEC B-8 (`fieldLevelLWW`, v1.2-draft); Kong review Q5
finding (array/blob LWW semantics under fieldLevelLWW, A9).

---

## Policy Decision Table

Choose a conflict policy and direction by answering: "what is the shape
of my data?"

| Data shape | Policy | Direction | Notes |
|---|---|---|---|
| Append-only observations (events, audit log, messages, activity) | `appendOnly` | `bidirectional` | Remote deletes silently rejected. A row that exists on any device is never removed by sync. |
| Mutable entities (any field may be overwritten) | `lastWriterWinsByHLC` | `bidirectional` | The entire row is the LWW unit. Most-recent write wins at the row grain. |
| Mutable entities with independent per-field edits *(v1.2-draft)* | `fieldLevelLWW` | `bidirectional` | Each column is the LWW unit. Do not use for array or blob columns — see Rule 10. |
| Counters | `appendOnly` on a separate event table | `bidirectional` | Fold locally via aggregate query. Never sync the counter column directly — see Rule 5. |
| Soft-deletable rows | `lastWriterWinsByHLC` + soft-delete bitmap column | `bidirectional` | Set a bitmap bit on delete. Never hard-delete synced rows if delete propagation is needed — see Rule 6. |
| Mutable entities with derived columns *(v1.2-draft)* | `lastWriterWinsByHLC` + `excludedColumns` | `bidirectional` | Exclude recomputed columns from sync. Recompute locally on every device — see Rule 4. |
| Configuration pushed from one authoritative device | `lastWriterWinsByHLC` | `pushOnly` | Inbound changes are silently skipped. Remote deletes are swallowed inbound — see Rule 6 pushOnly caveat. Use soft-delete if delete propagation is needed. |
| Read-only reference data pulled from a server | `remoteWins` | `pullOnly` | Local writes are never shipped. Remote overwrites unconditionally. |

---

## Capability Matrix

### MAY assume

A consumer composing PersistenceKit and ConvergenceKit may rely on:

**Per-row eventual convergence.** Given identical `schemaVersion`, no
version skew, and the slot registry active (N2, v1.2-draft), any two
devices sharing the same `SyncManifest` will eventually converge to the
same row values for all `bidirectional` tables after enough push/pull
cycles.

**Observer wake on inbound.** Writes from `applyInbound` go through the
receiver's PersistenceKit `rowStore` (SPEC I-3). Any `StorageObserver`
registered on that storage fires naturally. Downstream watchers wake
without knowing sync exists.

**Substrate HLC ordering.** Within a single device, HLC is strictly
monotonically increasing (SPEC I-6). Across devices, HLC ordering is
sound when node IDs are unique (N2 slot registry, v1.2-draft). HLC
provides the only total order that survives a sync round-trip.

**Version-skew protection.** A `schemaVersion` mismatch does not corrupt
local storage. Shipped behavior (SPEC I-4): mismatched records are
rejected as conflicts. With B-10 (v1.2-draft): mismatched records are
held in a durable queue and replayed after local schema migration.

**Schema gate before apply.** `kitID` and `schemaVersion` mismatches are
rejected before any storage mutation (SPEC I-4). A record from a different
kit never touches your tables.

**Idempotent pull.** Pulling the same record twice (network retry, token
reset) does not double-apply. `appendOnly` idempotency is via primary key.
`lastWriterWinsByHLC` idempotency is via HLC gate.

### MUST NOT assume

**Cross-table snapshots.** Rows in two tables are applied independently.
There is no atomic apply across tables. Any code that reads table A and
table B together and expects them to be mutually consistent at every
instant during a pull is fragile (Rule 3).

**Transactions.** ConvergenceKit replicates rows, not SQL transactions. A
batch of N rows may be partially applied.

**Increment semantics.** Concurrent increments to any stored column from
two devices produce a lost-increment. Model counts as append-only events
(Rule 5).

**Synchronous convergence.** `pull()` returns whatever the transport
delivered at that call. Convergence is eventual.

**Delete finality on `pushOnly` tables.** A hard delete on a `pushOnly`
table is silently swallowed inbound on all peers (Rule 6 pushOnly caveat).
Use soft-delete bitmap columns if remote delete visibility is required.

**Array-append merges under `fieldLevelLWW` (v1.2-draft).** Concurrent
writes to an array or blob column from two devices are atomic at the column
grain. The lower-HLC write is discarded in its entirety (Rule 10).

**Cross-device insertion order.** Rows may arrive at the receiver in a
different order than they were written. Do not assume SQL `rowid` or
wall-clock sequence is preserved across devices (Rule 7).

**Stale-insert resurrection prevention (v1.2-draft).** Before SPEC B-9
ships, a stale insert for a previously hard-deleted `(table, rowKey)` may
resurrect the row. After B-9, the tombstone HLC persists in the side table
and gates stale inserts.

---

## SPEC Cross-References

| Rule | SPEC invariants and contracts |
|---|---|
| Rule 1 (UUID primary key) | I-4 (kit and schema gate); B-6 (CloudKit record naming) |
| Rule 2 (policy follows shape) | B-4 (conflict policy at the apply boundary) |
| Rule 3 (no cross-row invariants; post-apply hook) | I-3 (apply-through-storage); B-10 (schema-skew posture, v1.2-draft) |
| Rule 4 (derived columns never sync) | I-5 (direction honoured); B-8 (`fieldLevelLWW` `excludedColumns`, v1.2-draft) |
| Rule 5 (no increment semantics) | B-4 (`appendOnly` idempotent upsert on primary key) |
| Rule 6 (deletes tombstoned LWW; pushOnly caveat) | I-5 (direction honoured); B-4 (LWW delete gate); B-9 (tombstoned deletes, v1.2-draft) |
| Rule 7 (HLC ordering only; N2 prerequisite) | I-6 (HLC determinism); B-6 (48/12/4-bit HLC layout); N2 (slot registry, v1.2-draft) |
| Rule 8 (version skew pauses sync) | I-4 (kit and schema gate); B-10 (schema-skew posture, v1.2-draft) |
| Rule 9 (iCloud Swift-vertical only) | B-6 (CloudKit); B-7 (Federation); C-8 (wire round-trip parity) |
| Rule 10 (array/blob atomic under fieldLevelLWW) | B-8 (`fieldLevelLWW`, v1.2-draft) |

---

## Changelog

### v0.1 -- 2026-07-16
Initial document. Establishes ten playground rules for consumers composing
PersistenceKit and ConvergenceKit for sync. Rules 1–9 are derived from the
concurrent multi-device architecture decision (2026-07-16). Rule 10 and the
Rule 6 pushOnly caveat and Rule 7 N2 prerequisite note incorporate Kong
architecture review (CVK-ICLOUD P0-M2) adjudications Q3 A8, Q5 A9, and
Q5 A10 respectively.
