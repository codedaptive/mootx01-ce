# Blast Radius Report — CVK-ICLOUD-P2-M1

**Baseline:** swift test pass count at mission start: 126
**Rust baseline:** 0 test functions (cargo test: ok, 0 tests)
**Mission:** fieldLevelLWW per-column HLC conflict policy, both legs (R1)
**Stream:** CVK-ICLOUD-P2-M1

## Symbol 1: `ConflictPolicy.fieldLevelLWW` (Swift) — new enum case

**Change class:** additive (new case on existing enum)
**Scope:** public enum in `ConvergenceKit` module; exhaustive switch
required by Swift compiler at every switch site

### Call sites (exhaustive switch enforcement)

| File | Classification | Justification |
|---|---|---|
| `Sources/ConvergenceKit/SyncTypes.swift` | MUST_UPDATE | Add `case fieldLevelLWW` |
| `Sources/ConvergenceKitCloudKit/Engine/ApplyInbound.swift` | MUST_UPDATE | Both tombstone + normal switch arms (compiler enforces) |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | MUST_UPDATE | Both tombstone + normal switch arms (compiler enforces) |

### Summary
- MUST_UPDATE: 3 files
- RESCOPE_REQUIRED: 0

---

## Symbol 2: `SyncRecord.columnHLCs: ColumnHLCMap?` (Swift) — new optional field

**Change class:** additive (new optional field; backward-compatible wire format via encodeIfPresent/decodeIfPresent)
**Scope:** public struct `SyncRecord` in `ConvergenceKit` module

### Call sites

| File | Classification | Justification |
|---|---|---|
| `Sources/ConvergenceKit/SyncRecord.swift` | MUST_UPDATE | Add field, CodingKeys case, encode/decode |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | MUST_UPDATE | push() builds SyncRecord — add `columnHLCs:` param |

### Summary
- MUST_UPDATE: 2 files
- RESCOPE_REQUIRED: 0

---

## Symbol 3: `CKSideSchema` (Swift) — bump v3 → v6

**Change class:** additive migration (new table + new column on existing table)
**Scope:** internal `declaration` lazy var in `SideSchema.swift`

### Call sites

| File | Classification | Justification |
|---|---|---|
| `Sources/ConvergenceKit/SideSchema.swift` | MUST_UPDATE | Bump to v6; add `_ck_sync_meta_cols` table + `column_hlcs` column on `_ck_outbox` |

No external callers maintain version literals — they all call `CKSideSchema.ensure(storage:)`.

### Summary
- MUST_UPDATE: 1 file
- RESCOPE_REQUIRED: 0

---

## Symbol 4: `OutboxEntry` (Swift) — new `columnHLCsData: Data?` field

**Change class:** additive (new optional field with default nil)
**Scope:** public struct in `ConvergenceKit` module

### Call sites

| File | Classification | Justification |
|---|---|---|
| `Sources/ConvergenceKit/Outbox/OutboxEntry.swift` | MUST_UPDATE | Add field + init param |
| `Sources/ConvergenceKit/Outbox/OutboxStore.swift` | MUST_UPDATE | insertEntry writes column, decodeRow reads it, append merges, remintAll preserves |
| `Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift` | MUST_UPDATE | recordOutbound stamps column HLCs and passes to OutboxEntry init |
| `Sources/ConvergenceKitCloudKit/Engine/PushCycle.swift` | MUST_UPDATE | Decode columnHLCsData and pass to CKRecordMapping.record |

### Summary
- MUST_UPDATE: 4 files
- RESCOPE_REQUIRED: 0

---

## Symbol 5: `CKRecordMapping.record(...)` (Swift) — new `columnHLCs:` parameter

**Change class:** additive (default parameter `columnHLCs: ColumnHLCMap? = nil`; backward-compatible)
**Scope:** public static function in `ConvergenceKitCloudKit` module

### Call sites

| File | Classification | Justification |
|---|---|---|
| `Sources/ConvergenceKitCloudKit/CKRecordMapping.swift` | MUST_UPDATE | Add param; encode `_syncColumnHLCs` JSON blob; add to DecodedRecord |
| `Sources/ConvergenceKitCloudKit/Engine/PushCycle.swift` | MUST_UPDATE | Pass `columnHLCs:` |

### Summary
- MUST_UPDATE: 2 files (PushCycle already in Symbol 4 list)
- RESCOPE_REQUIRED: 0

---

## Symbol 6: `FederationStateActor.ensureFedSyncMetaTable` — bump v1 → v2

**Change class:** additive migration (adds `_fed_sync_meta_cols` table)
**Scope:** static func in `ConvergenceKitFederation` module; private schema

### Call sites

| File | Classification | Justification |
|---|---|---|
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | MUST_UPDATE | Already updating for Symbol 1 + 2; also bump schema version |

### Summary
- MUST_UPDATE: already covered

---

## Symbol 7: Rust `ConflictPolicy` enum — new `FieldLevelLWW` variant

**Change class:** additive (new variant; serde camelCase encodes as "fieldLevelLWW")
**Scope:** `pub enum ConflictPolicy` in `rust/src/types.rs`

### Call sites

| File | Classification | Justification |
|---|---|---|
| `rust/src/types.rs` | MUST_UPDATE | Add variant |
| `rust/src/federation.rs` | MUST_UPDATE (codegraph) | apply_record switch; compiler enforces in Rust if exhaustive match used |

### Summary
- MUST_UPDATE: 2 Rust files
- RESCOPE_REQUIRED: 0

---

## Symbol 8: Rust `SyncRecord` — new `column_hlcs: Option<ColumnHLCMap>` field

**Change class:** additive (new optional field; skip_serializing_if)
**Scope:** `pub struct SyncRecord` in `rust/src/record.rs`

### Call sites

| File | Classification | Justification |
|---|---|---|
| `rust/src/record.rs` | MUST_UPDATE | Add `ColumnHLCMap` struct + field |
| `rust/src/federation.rs` | MUST_UPDATE | `SyncRecord::new()` call sites; may need to pass `column_hlcs: None` |

### Summary
- MUST_UPDATE: 2 Rust files (already captured above)
- RESCOPE_REQUIRED: 0

---

## New files (additive, no callers to update)

| File | Purpose |
|---|---|
| `Sources/ConvergenceKit/FieldLWW/ColumnHLCMap.swift` | Column→HLC map type; Codable, merge, stampAll |
| `Sources/ConvergenceKit/FieldLWW/FieldLWWMerge.swift` | Pure commutative merge logic |
| `Sources/ConvergenceKit/FieldLWW/ColumnHLCStore.swift` | Side-table CRUD for `_*_sync_meta_cols` |
| `Tests/ConvergenceKitTests/FieldLWWMergeTests.swift` | Unit tests for merge + commutativity |
| `Tests/ConvergenceKitConformance/ColumnHLCMapConformanceTests.swift` | Wire round-trip Swift+Rust |
| `Tests/ConvergenceKitCloudKitTests/ColumnHLCCoalescingTests.swift` | Outbox coalescing merge |
| `Tests/ConvergenceKitCloudKitTests/FieldLWWCloudKitApplyTests.swift` | End-to-end CK apply |
| `Tests/ConvergenceKitFederationTests/FieldLWWFederationApplyTests.swift` | End-to-end Federation apply |
| `docs/status/CVK_ICLOUD/P2-M1.md` | Completion report |

---

## MUST_UPDATE list (deduplicated)

**Swift (9 existing files):**
1. `Sources/ConvergenceKit/SyncTypes.swift`
2. `Sources/ConvergenceKit/SyncRecord.swift`
3. `Sources/ConvergenceKit/SideSchema.swift`
4. `Sources/ConvergenceKit/Outbox/OutboxEntry.swift`
5. `Sources/ConvergenceKit/Outbox/OutboxStore.swift`
6. `Sources/ConvergenceKitCloudKit/CKRecordMapping.swift`
7. `Sources/ConvergenceKitCloudKit/Engine/ApplyInbound.swift`
8. `Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift`
9. `Sources/ConvergenceKitCloudKit/Engine/PushCycle.swift`
10. `Sources/ConvergenceKitFederation/FederationSyncEngine.swift`

**Rust (2 existing files):**
1. `rust/src/types.rs`
2. `rust/src/record.rs`
(federation.rs: verify if `match conflict_policy` is exhaustive — update if needed)

## RESCOPE_REQUIRED
None. All call sites are within mission scope.

## Siblings note

P2-M2 (excludedColumns) and P2-M3 (postApplyIntegrityHook) also touch
`SyncTypes.swift` and `ApplyInbound.swift`. This stream touches ONLY
`fieldLevelLWW` and its enforcement points. Root reconciles the three
parallel diffs at merge time.
