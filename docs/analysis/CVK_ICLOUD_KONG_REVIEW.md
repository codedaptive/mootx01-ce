---
title: Kong Architecture Review — CVK-ICLOUD P0-M2
status: delivered
reviewer: Kong
date: 2026-07-16
mission: CVK-ICLOUD P0-M2
decisions_reviewed:
  - docs/decisions/DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16.md
  - docs/decisions/DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md
spec_reviewed:
  - docs/reference/CONVERGENCEKIT_SPEC.md (v1.1)
  - docs/reference/CONVERGENCEKIT_INTERFACE.md (v1.2)
code_reviewed:
  - packages/kits/ConvergenceKit/Sources/ConvergenceKitCloudKit/CloudKitSyncEngine.swift
  - packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/FederationSyncEngine.swift
  - packages/kits/ConvergenceKit/Sources/ConvergenceKit/SyncTypes.swift
  - packages/kits/PersistenceKit/Sources/PersistenceKit/StorageObserver.swift
  - packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/InMemoryObserver.swift
  - packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/InMemoryStorage.swift
  - packages/kits/PersistenceKit/Sources/PersistenceKitSQLite/SQLiteObserver.swift
  - packages/kits/PersistenceKit/Sources/PersistenceKitSQLite/SQLiteStorage.swift
adjudications_given:
  slot_registry: 15 slots (1–15); node 0 permanently reserved
  registry_zone: manifest's own sync zone
  cloudkit_arm: Swift-only
---

# Kong Architecture Review: CVK-ICLOUD P0-M2

## Assessment

The two decisions together establish a local-first multi-master architecture for one MOOTx01 estate shared across Apple devices via iCloud private database. The architecture is correct in its core claims: the echo loop is real and confirmed in shipped code; the node-collision probability calculation (≈1/15 per session pair) is accurate; the six shipped defects (D1–D6) are verified at the line level. The design choices — epoch-fenced slot registry, engine-internal echo suppression, tiered polling as the sole correctness path — are sound at the pattern level. However, four of the six focus questions expose implementation gaps that must be resolved before N1–N2 can be coded to completion. Two are CRITICAL. None require architecture rework at the strategic level; all require specification work before the implementation program opens.

Binding adjudications (slot registry = 15 slots, node 0 reserved, registry in manifest zone, CloudKit arm Swift-only) are taken as given. They appear internally consistent with the spec.

---

## Q1 — Epoch-fenced slot eviction

**Verdict: ACCEPT-WITH-CHANGES**

### Findings

| Finding | Severity | Description |
|---|---|---|
| `reenrollRequired` and `slotExhausted` error cases absent from SyncError | CRITICAL | The shipped SyncError enum (verified in SyncTypes.swift) has no cases for `reenrollRequired` or `slotExhausted`. N2 requires raising a "distinct `reenrollRequired` error before any of its records are applied" — but no such case exists in the type system. The precedent for CloudKit-only error cases is established by `corruptRemoteIdentity`. These cases must be added before N2 is implementable. They require updates to SyncTypes.swift, the INTERFACE.md concordance table, and (for completeness) the Rust types.rs — though they will never fire in Rust, the parity table must document them as Swift-only. |
| Outbox disposition on re-enrollment unspecified | CRITICAL | When a device returns after being evicted and must re-enroll, it may have queued outbox records minted under the old `(slot, epoch)` with the old nodeID. N2 says the device "re-claims a fresh slot, then resumes normal operation" — but does not specify what happens to the existing outbox. If old records are drained as-is, their node identity no longer matches any live registry entry (the old slot was re-epoched). If they are purged, local changes are silently lost. If they are re-minted with the new nodeID, the HLC reorder could violate downstream HLC monotonicity expectations. This is not a corner case: any device that suffered a long offline period or crash-during-claim arrives in this state. The decision must specify the outbox disposition policy at the re-enrollment boundary. |
| Ghost slot registrations from crash-during-claim | WARNING | If the CAS claim succeeds in CloudKit but the device crashes before persisting the claimed `(slot, epoch)` locally, the slot is occupied in the registry by a ghost identity. On the next launch, the device claims a new slot. The ghost slot occupies a registry slot until the inactivity eviction fires. Under worst-case crash patterns (15 rapid crash-and-restart sequences), all 15 slots could be filled with ghost entries, triggering `slotExhausted`. The decision should specify the minimum inactivity window and recommend that the claimed slot be durably persisted (e.g., in `_ck_device_identity` local table) before considering the claim complete. |
| CAS contention retry strategy unspecified | WARNING | Two devices simultaneously trying to claim the same free slot will both fire conditional CKRecord saves; one gets a `serverRecordChanged` error. The retry behavior — pick a different slot, retry the same slot, or back off — is unspecified. With up to 15 devices and 15 slots, pathological contention is unlikely but possible. One sentence of retry guidance is sufficient. |

### Non-obvious risk

The ordering-soundness argument in N2 states: "eviction requires that the evicted slot's last-active timestamp be well in the past, so the new claimant's HLC physical component is strictly above everything the evicted identity ever wrote." This holds only if the wall clock on the new claimant is at least as advanced as the wall clock on the original slot holder. A device with a malfunctioning system clock (or a device whose clock is set backwards) can claim an evicted slot and mint HLCs whose physical component is BELOW HLCs the old holder produced. The slot registry provides collision avoidance only if HLC physical ordering is sound. Extreme clock skew breaks the guarantee silently. The pending-skew queue (R9) addresses schema version skew but not HLC-ordering skew. This is inherent to HLC-based systems and is probably acceptable given Apple devices' typical NTP discipline, but it should be named in the decision's risk register.

### Conditions for ACCEPT

1. Add `reenrollRequired` and `slotExhausted` to SyncError (Swift-only, like `corruptRemoteIdentity`). Update INTERFACE.md concordance table.
2. Specify outbox disposition at re-enrollment boundary. Recommended: purge outbox entries carrying the old nodeID, accept potential loss, and document as a known behavior.
3. Specify the minimum inactivity-eviction window and require durable local persistence of `(slot, epoch)` before claim is considered complete.
4. Add one sentence of CAS-retry guidance (e.g., "on `serverRecordChanged`, pick the next numerically available free slot").

---

## Q2 — Engine-internal echo suppression

**Verdict: REWORK**

This question required reading the actual observer delivery semantics in shipped code, not the spec. The spec doc claims ("no PersistenceKit type change is required") are technically achievable but the decision as written does not specify a mechanism sound enough to implement correctly. The problem is more constrained than the decision acknowledges.

### Observer delivery semantics — verified facts

From source (not memory):

1. **Neither InMemory nor SQLite backends stamp HLC on TableChange events.** The `hlc` field on `TableChange` is always `nil` in practice. Confirmed: InMemoryStorage calls `notify(TableChange(table:, event:, rowKey:, values:))` (no `hlc:` argument); SQLiteStorage calls `notifyObservers(TableChange(table:, event:, rowKey:, values:))` (no `hlc:` argument). The CloudKitSyncEngine.swift comment confirms this: "the InMemory and SQLite observers do not stamp an HLC on the change notification today."

2. **SQLite observer delivery ordering is UNDEFINED.** SQLiteStorage.notifyObservers is `private func notifyObservers(_ change: TableChange) { if let r = observerRegistry { Task { await r.notify(change) } } }` — a fire-and-forget unordered Task spawn per change. The StorageObserver.swift header says "Ordering is preserved within an observer" but this does NOT hold for the SQLite backend. SQLite notifications can arrive at `recordOutbound` in any order.

3. **InMemory observer delivery is ordered.** InMemoryStorage uses `await registry.notify(change)` (awaited, not fire-and-forget). The comment in InMemoryStorage.swift documents this explicitly: prior fire-and-forget was fixed because "concurrent/sequential mutations could be observed out of order."

### Why the keyed-window approach is unsound as stated

N1 proposes "an apply-side suppression flag" as the fix. The most natural implementation is a `Set<String>` keyed on `"table:rowKey.uuidString"` held in the actor state. Set the flag before `upsert` inside `applyInbound`; clear it after.

This works for InMemory because delivery is ordered — the echo notification will arrive in the stream in order, and will be processed by `recordOutbound` while the suppression flag is still set (since the actor is busy in `applyInbound` at every suspension point). A genuine concurrent local write to the same `(table, rowKey)` that fires the observer during `applyInbound`'s execution would arrive in the stream AFTER the echo but BEFORE the flag is cleared. It would be suppressed.

For SQLite, delivery is unordered. The echo and the genuine local write could arrive in any order. The flag might be cleared before the echo is processed (if it races behind a prior unordered Task). Or the echo might arrive long after the flag is cleared and slip into the outbox. Neither is safe.

There is also a deeper issue: `TableChange` carries no origin tag. There is no information in the delivered event that distinguishes "this was written by applyInbound" from "this was written by a local user action." Without an origin tag, the ONLY suppression strategy is key-based (suppress by `table:rowKey`), which cannot correctly handle the genuine-concurrent-write case the decision acknowledges.

### Findings

| Finding | Severity | Description |
|---|---|---|
| Keyed suppression window cannot distinguish echo from genuine concurrent local write | CRITICAL | A `(table, rowKey)` suppression key suppresses ALL observer events for that row during the window, including genuine concurrent local writes. The decision acknowledges this ("A genuine local write that arrives while the suppression window is active must still be recorded and shipped") but provides no mechanism to accomplish it. Without either an origin tag on TableChange or a counter-based approach that limits suppression to exactly one event per inbound apply, the suppression window will silently swallow genuine local writes under the right timing. |
| SQLite delivery ordering breaks actor-serial suppression assumption | CRITICAL | Any suppression strategy that relies on the actor being busy in `applyInbound` when the echo notification arrives (so the flag is still set) is unsound for SQLite. SQLite's fire-and-forget Task dispatch means the echo notification can arrive at `recordOutbound` long after `applyInbound` has completed and the flag is cleared — meaning no suppression occurs — or arrive before the flag is set — same result. For the SQLite production backend, the keyed-flag approach as described does not close the echo loop. |
| "No PersistenceKit type change required" constraint may be over-strict | WARNING | The cleanest solution is an origin tag on TableChange: a `source: ObservationSource` field distinguishing `.localWrite` from `.inboundSync`. This requires a PersistenceKit type change (adding a field to `TableChange`). The decision prohibits this, but the prohibition is worth revisiting. The alternative — actor-serial counter per `(table, rowKey)`, suppressing exactly N events per inbound apply — is implementable without PK changes, but is subtly complex and must be documented as acceptable. A third alternative (alternative write path that does NOT fire the observer for inbound applies) would require the `rowStore` to support a `writeInbound` variant — also a PK type change. |

### Non-obvious risk

Echo suppression is framed as preventing unbounded ping-pong. But partial suppression is also a problem. If the suppression mechanism is racy and catches the echo 95% of the time, the remaining 5% creates one additional outbound push. That push, on arrival at the remote machine, fires another echo there. Under high-frequency sync activity, a leaky suppression mechanism creates a bounded but non-zero amplification factor that grows with the number of devices. The decision must specify the suppression correctness guarantee ("no echo ever escapes" vs "echo rate is bounded") because the implementation choice changes depending on which guarantee is targeted.

### Required before proceeding

The decision must specify ONE of:
1. Add an origin tag to `TableChange` (PersistenceKit type change) — cleanest
2. Counter-based actor-serial suppression with explicit documentation of the genuine-concurrent-write suppression risk window
3. An alternate write path for inbound applies that bypasses the observer entirely

Until the mechanism is specified, the implementor cannot write code that reliably closes the echo loop on the SQLite backend (which is the production backend).

---

## Q3 — Policy × direction convergence

**Verdict: ACCEPT-WITH-CHANGES**

### Verified against shipped code

Both CloudKitSyncEngine.applyInbound and FederationSyncEngine.applyInbound were read in full. The four existing policies × insert/update/delete directions match spec B-4 exactly:

- `appendOnly`: remote deletes silently rejected ✓
- `lastWriterWinsByHLC`: HLC gate on both upsert and delete paths; "older" means strictly less than ✓; "newer or equal proceeds" ✓
- `remoteWins`: unconditional upsert; unconditional delete ✓
- `localWins`: insert-if-absent only; remote deletes silently rejected ✓

Direction gate (I-5): both engines check `syncedTable.direction != .pushOnly` before applying inbound records ✓; delete loop in CloudKit also gates on direction ✓.

### Findings

| Finding | Severity | Description |
|---|---|---|
| Tombstone HLC footprint lost after hard-delete in Federation backend | WARNING | FederationSyncEngine.applyInbound stores `_syncHLC` directly in the row via the values map. After a successful `lastWriterWinsByHLC` delete, the row is gone and `_syncHLC` is gone with it. A subsequent stale insert for the same (table, rowKey) will find no row (existing = nil, localHLC = nil), skip the comparison, and resurrect the row. CloudKit's `_ck_sync_meta` side table has the same gap in reverse: it currently doesn't mark entries as deleted, but entries persist after row deletion, so it would gate stale inserts correctly — but this behavior is accidental, not designed. When R7 is implemented, both backends need an explicit tombstone-persistence strategy: either retain side-table entries after deletion (with a `deleted_at_hlc` column) or add a dedicated tombstone table. |
| `fieldLevelLWW` wire encoding undefined | WARNING | R1 requires "a per-column HLC map in the sync metadata." If this map is carried IN the SyncRecord wire format (as a new `columnHLCs: [String: PackedHLC]?` field), it is a C-8 wire format change requiring byte-identical Rust twin. If it is derived only from the receiver's side table using the record's single row-level HLC, concurrent edits to the SAME column from two devices reduce to standard LWW — which is not what fieldLevelLWW promises. The distinction determines the wire format commitment and must be settled before R1 can be implemented. The current spec does not resolve this. |
| `pushOnly` + tombstone produces asymmetric delete semantics | WARNING | A `pushOnly` table ships local deletes outbound but never accepts inbound deletes (I-5). If all syncing devices declare the same table as `pushOnly`, hard deletes from device A ship to CloudKit but are never applied at device B. This is correct per spec but creates an invisible trap: consumers who want shared deletion of pushOnly-table rows cannot achieve it with ConvergenceKit's current direction model. The playground rules say nothing about this. Consumers who need delete propagation on pushOnly tables must use soft-delete bitmap columns instead. Rule 6 addresses this implicitly but should call out the pushOnly constraint explicitly. |
| `localWins` + well-known-UUID row creates permanent divergence | INFO | If two devices both initialize a row with a pre-determined UUID under `localWins`, neither device will ever apply the other's version of that row. Both local versions persist forever; no convergence occurs. The `localWins` policy is correct for this case by design, but the pattern of using well-known UUIDs with `localWins` is a footgun for configuration-table patterns. Not addressed in the playground rules. |

### Conditions for ACCEPT

1. Specify tombstone persistence strategy in R7 scope: after a `lastWriterWinsByHLC` delete, persist the deletion HLC in the side table (or tombstone table) so stale inserts are gated. Applies to BOTH backends.
2. Resolve `fieldLevelLWW` wire encoding before R1 implementation: commit to either per-column wire HLCs (with C-8 Rust twin) or receiver-only side-table approach (with documented limitation).
3. Add one sentence to Playground Rule 6 noting that `pushOnly` tables do not propagate remote deletes inbound.

---

## Q4 — Adaptive polling and host-app accelerator

**Verdict: ACCEPT**

The reasoning is sound. A launchd agent without APNs entitlements cannot receive CloudKit silent push. Polling is the only conformant inbound path for the daemon. The decision correctly establishes that all multi-device behavior must be sound under polling alone, with the subscription accelerator as an optional latency optimization.

The decoupling is correct: the resident daemon is never required to receive APNs; it polls. The host app (with APNs entitlement) optionally registers a `CKRecordZoneSubscription` and nudges the engine. A daemon that never receives a nudge still converges via polling.

### Findings

| Finding | Severity | Description |
|---|---|---|
| Cross-process nudge mechanism unspecified | WARNING | The decision describes a "silent-push wakeup nudges the engine to run a pull cycle sooner" but does not specify how the host app (which receives APNs) signals the daemon to pull. Candidates: shared app-group UserDefaults flag, Darwin notifications, XPC. Without a mechanism, the latency-reduction benefit of the accelerator is undeliverable. This is not a correctness gap (correctness is covered by polling), but the decision should either name the nudge mechanism or explicitly defer it to the R8 implementation spec. |
| Tiered polling cadence values unspecified | INFO | N3 references "fast cadence" and "idle cadence" but gives no numbers. Implementors need concrete values to avoid simultaneous battery drain (too fast) and unacceptable latency (too slow). A reasonable baseline: fast = 15 seconds after observed remote activity, idle = 3 minutes. These can be implementation decisions rather than architectural decisions, but the implementation spec for N3 should document them. |

---

## Q5 — Playground Rules sufficiency

**Verdict: ACCEPT-WITH-CHANGES**

The nine rules are structurally sound. They establish the necessary consumer contracts: single-column UUID PKs, policy-follows-shape, no cross-row invariants in sync, no derived-column sync, no increment semantics, tombstoned deletes, HLC-only ordering, version-skew handling, and iCloud arm scope. For current policy vocabulary (the four existing policies), the rules are sufficient.

### Findings

| Finding | Severity | Description |
|---|---|---|
| Array and blob column behavior under `fieldLevelLWW` not addressed | WARNING | Rule 5 ("No increment semantics") covers counter columns but not array/blob columns under `fieldLevelLWW`. Concurrent array appends from two devices will LWW at the column grain, silently discarding one append. This is the most likely consumer footgun when adopting `fieldLevelLWW` for mutable entities: consumers who think "field-level LWW means each append survives" will be wrong. The rule should state: "fieldLevelLWW applies LWW per column. Concurrent writes to the same column from different devices lose the lower-HLC write. Array columns have no merge semantics; for append-safe columns, use appendOnly tables instead." |
| Rule 7's HLC-ordering guarantee depends on N2 correctness | WARNING | Rule 7 ("Ordering is by substrate HLC only. No other ordering guarantee crosses a sync boundary.") is load-bearing on the slot registry working correctly. If two devices share a node ID (pre-N2 state), HLC comparisons for the same physical-time window become meaningless across nodes. The rule should include a note: "This guarantee holds only when device node IDs are unique, which is enforced by the slot registry (N2)." |
| Rule 9 does not address wire format parity burden | INFO | Rule 9 correctly scopes the CloudKit BACKEND to the Swift vertical. But `fieldLevelLWW`, when it adds per-column HLCs to the wire format, changes the shared SyncRecord structure — which has a Rust twin under C-8. Rule 9 should distinguish "the CloudKit transport is Swift-only" from "wire format changes always carry Rust parity." This prevents the mistaken inference that R1 has no Rust impact. |

### Conditions for ACCEPT

1. Add to Rule 5 (or add Rule 10): "fieldLevelLWW applies LWW per column; concurrent writes to the same column lose the lower-HLC side. Array columns have no merge semantics."
2. Add to Rule 7: "This ordering guarantee holds only when device node IDs are unique (N2 prerequisite)."

---

## Q6 — Second-order effects

**Verdict: ACCEPT-WITH-CHANGES**

### Findings

| Finding | Severity | Description |
|---|---|---|
| `_ck_sync_meta` schema version hardcoded at v1 with no migration plan | WARNING | `ensureSyncMetaTable` creates the `_ck_sync_meta` table with `SchemaDeclaration(kitID: "ConvergenceKitCloudKit", version: 1, ...)`. As R1 adds `_ck_sync_meta_cols`, R4 adds `_ck_outbox`, R5 adds `_ck_change_token`, and R9 adds `_ck_pending_skew`, each addition requires a version bump or a separate `ensureXxxTable` call with its own schema declaration. If two independently-developed releases both increment to v2 with different table sets, a merge conflict occurs in the migration log at runtime. The current ad-hoc approach does not scale to 4+ additional side tables. A migration strategy should be defined: either a single `ConvergenceKitCloudKit` schema declaration that version-bumps at each table addition, or a per-table kitID namespace (e.g., `ConvergenceKitCloudKit.outbox` v1). |
| CloudKit and Federation backends diverge on `_syncHLC` storage location | WARNING | B-4 claims "Both CloudKit and Federation backends implement identical comparison semantics." This is true for the COMPARISON logic but not for the storage location: Federation stores `_syncHLC` in the row values themselves; CloudKit stores it in the `_ck_sync_meta` side table. After hard-deletion, Federation loses the HLC footprint (row gone); CloudKit retains the side table entry (row gone, side table entry stays). When R7 ships, this divergence will matter for stale-insert behavior post-deletion. The spec should acknowledge this structural difference and specify that after R7, both backends must produce identical post-deletion behavior (reject stale inserts to a deleted row). |
| `reenrollRequired` / `slotExhausted` require SyncError extension and INTERFACE update | WARNING | As noted in Q1, these cases are missing from the shipped type system. The CloudKit-only precedent is established by `corruptRemoteIdentity`. The INTERFACE.md concordance table must add both cases (Swift-only, no Rust counterpart, same as `corruptRemoteIdentity`). This is a prerequisite for N2 implementation, not a separate concern. |
| Rust twin wire-parity burden for R1 not yet scheduled | WARNING | C-8 requires byte-identical SyncRecord encoding across Swift and Rust. If R1 adds `columnHLCs: [String: PackedHLC]?` to SyncRecord, that field must be added to the Rust `SyncRecord` struct in record.rs, with a matching serde representation. This is non-trivial (the concordance table must be extended; the Rust federation tests must cover the new field). Scheduling note: R1 wire-format work must include Rust parity as in-scope, not as a follow-up. |
| Device slot registry records are CloudKit records, not local SQLite tables | INFO | The Q6 framing includes "device_identity" in a list of `_ck_*` side tables. For clarity: the 15 slot records live in the CloudKit private zone, not in local SQLite. No local SQLite migration is needed for the registry itself. The `_ck_device_identity` local table (if created) would store the device's OWN `(slot, epoch)` for durable persistence — distinct from the registry records in CloudKit. The Q6 list conflates these two concerns. A clarifying comment in the implementation spec would prevent confusion. |

### Conditions for ACCEPT

1. Define a migration strategy for side table additions before R1/R4/R5/R9 are implemented.
2. Specify post-deletion HLC-footprint policy for both backends in R7 scope.
3. Include Rust twin work explicitly in R1 scope when the wire encoding decision is made.

---

## Dependencies

**Depends on:**
- SubstrateLib HLC 48/12/4 layout (B-6) — adjudicated invariant; wire format not widened
- PersistenceKit StorageObserver delivery semantics (verified in source; at-least-once; InMemory ordered; SQLite unordered fire-and-forget)
- CloudKit conditional record saves (compare-and-swap via record change tag) — standard CK feature; no framework change required
- Existing `_ck_sync_meta` table (single side table; `ensureSyncMetaTable` pattern)

**Affects:**
- SyncError enum (additions required for N2)
- CONVERGENCEKIT_INTERFACE.md concordance table (additions required)
- CONVERGENCEKIT_SPEC.md (error model section, B-4 backend parity note, planned fieldLevelLWW wire encoding)
- Rust `SyncError` in types.rs (documentation of CloudKit-only cases; no code change needed for non-Firebase entries but concordance table requires update)
- Rust `SyncRecord` in record.rs (when R1 wire format is committed)
- Federation backend tombstone behavior (after R7)
- `_ck_sync_meta` migration versioning (side table proliferation)

**Conflicts with:**
- None at architecture level. The prior decision (DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md) is properly promoted to accepted and extended. No competing open ADRs identified.

---

## Recommendation

**ACCEPT WITH CONDITIONS**

Conditions (listed by Q, ordered by severity):

**Must resolve before any N1/N2 implementation code is written:**

1. (Q2-C1) Specify the echo suppression mechanism explicitly — one of: origin tag on TableChange, actor-serial counter, or alternate write path. The current "suppression flag" statement is not implementable safely on the SQLite backend without further precision.
2. (Q2-C2) Acknowledge that SQLiteObserver delivery is unordered (fire-and-forget Tasks). Any suppression strategy must account for this; the INTERFACE.md and StorageObserver.swift comments must align.
3. (Q1-C1) Add `reenrollRequired` and `slotExhausted` to SyncError. Update INTERFACE.md concordance.
4. (Q1-C2) Specify outbox disposition policy at the re-enrollment boundary.

**Must resolve before R7 (tombstoned deletes) implementation:**

5. (Q3-C1) Specify tombstone persistence after hard-delete for both backends.
6. (Q3-C2) Add `pushOnly` + tombstone caveat to Playground Rule 6.

**Must resolve before R1 (fieldLevelLWW) implementation:**

7. (Q3-W2) Commit to wire encoding for per-column HLCs and include Rust twin work in R1 scope.
8. (Q5-C1) Add array/blob LWW caveat to Playground Rules (Rule 5 or new Rule 10).
9. (Q6-C1) Define migration strategy for side table additions.

**Recommended (not blocking):**

10. (Q4-W1) Name the cross-process nudge mechanism for the host-app accelerator, or explicitly defer to the R8 implementation spec.
11. (Q5-C2) Add N2 prerequisite note to Playground Rule 7.
12. (Q1-C3) Specify minimum inactivity-eviction window and require durable local persistence of `(slot, epoch)`.

---

## Notes for the audit trail

**Verified facts, for future reference:**

- `CloudKitSyncEngine.swift` line 108: `HLCGenerator(nodeID: Int32.random(in: 1...0x0F))` — confirmed random per-launch, no persistence, no coordination. This is the shipped defect N2 addresses.
- `CloudKitSyncEngine.swift` line 185 AND 253: double `pushCompleted` emission — confirmed D6.
- `CloudKitSyncEngine.swift` lines 188–189: `pendingOutbound.removeAll()` before transport call — confirmed D3.
- `CloudKitSyncEngine.swift` line 99: `var serverChangeToken: CKServerChangeToken?` in actor, not persisted — confirmed D4.
- `CloudKitSyncEngine.swift` line 240–248: `_ = try await container.privateCloudDatabase.modifyRecords(...)` — confirmed D5 (result discarded).
- `CloudKitSyncEngine.swift` lines 320–329 (approximate): delete loop iterates every non-pushOnly table — confirmed D1 and D2 (no HLC gate on delete path).
- `SyncTypes.swift`: SyncError enum has 11 cases; `reenrollRequired` and `slotExhausted` are NOT among them.
- `StorageObserver.swift`: `TableChange.hlc: HLC?` field exists but is never set by InMemory or SQLite backends in practice.
- `SQLiteStorage.swift` `notifyObservers`: fire-and-forget `Task { await r.notify(change) }` — unordered delivery on SQLite.
- `InMemoryStorage.swift` `notify`: awaited `await registry.notify(change)` — ordered delivery on InMemory.
- Federation `applyInbound`: stores `_syncHLC` in row values directly; CloudKit `applyInbound`: stores it in `_ck_sync_meta` side table. Both correctly implement the comparison logic; the storage location differs.
- `_ck_sync_meta` side table: created at `enable()` via `migrate(to:)` with `version: 1`; no versioning plan for future additions.
- CloudKit test coverage: two test files, one test that checks initial state only (`CloudKitStubTests`), plus CKRecordMapping and LWW-HLC persistence tests. No echo-suppression tests, no slot-registry tests, no multi-device round-trip tests.

**Patterns to remember:**

- PersistenceKit's observer is NOT delivery-source-agnostic: the observer cannot tell a local write from an inbound sync apply. This is the structural reason echo suppression requires explicit mechanism, not just policy.
- The `_ck_sync_meta` side-table pattern (one row per synced row, keyed by table_name + primary_key) is clean for LWW tracking but must be extended to support tombstone footprints. Plan for this in R7 scope.
- CloudKit-only SyncError cases (like `corruptRemoteIdentity`) are the established precedent for N2's new error cases. Use the same pattern.
