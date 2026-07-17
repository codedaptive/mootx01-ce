---
status: proposed
question: Should ConvergenceKit's CKRecordMapping use CKRecord.encryptedValues for content columns, and if so, which columns, under what migration path, and at what cost?
authors: MOOTx01 maintainers
date: 2026-07-17
version: v0.1
relates_to:
  - docs/reference/CONVERGENCEKIT_SPEC.md
  - docs/reference/CONVERGENCEKIT_INTERFACE.md
  - docs/decisions/DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16.md
  - docs/decisions/ADR-014-apple-sqlcipher-at-rest.md
supersedes: none
context:
  - Perkins flagged CKRecord.encryptedValues as an advisory (not blocking) follow-up during the CVK-ICLOUD program.
  - The current CKRecordMapping writes all TypedValue columns to plain CKRecord fields. Apple's servers (and the CloudKit Dashboard) can read all field values.
  - encryptedValues was introduced in iOS 15 / macOS 12 and provides end-to-end encryption for individual CKRecord fields via iCloud Keychain-held keys.
  - Tracked in TRACKED_FOLLOWUPS item 3 (docs/status/CVK_ICLOUD/TRACKED_FOLLOWUPS.md).
---

# Decision: CKRecord.encryptedValues evaluation for ConvergenceKit content columns

## RECOMMEND: defer

**Adopt when a specific sensitivity requirement arises that TLS alone cannot satisfy for a named content type (e.g. diary body, high-sensitivity drawer content). Do not adopt in the general case now.**

Rationale compressed: the type compatibility is complete, the zone-feed pull path makes the server-side no-query restriction a nil impact, and the implementation sketch is viable — but ADR-014 SQLCipher already covers at-rest, the migration story for existing records is non-trivial, and the dashboard debuggability cost is high during active development.

Bob decides.

---

## Context

`CKRecord.encryptedValues` stores field values as end-to-end encrypted ciphertext on Apple's CloudKit servers. The encryption key is held in the user's iCloud Keychain, not by Apple. Apple's servers, the CloudKit Dashboard, and any process without the key see only opaque ciphertext.

The CVK-ICLOUD program shipped a zone-change-feed pull path (`fetchZoneChanges`) with a manifest-driven `CKRecordMapping` that assigns TypedValue columns to plain `CKRecord` fields. The Perkins advisory (CVK-ICLOUD post-flight) flagged this as a follow-up: evaluate whether sensitive columns (diary content, high-sensitivity drawers) should use `encryptedValues`.

---

## Five questions, five answers

### 1. TypedValue ↔ encryptedValues compatibility

`CKRecord.encryptedValues` accepts the same ObjC-bridgeable types as regular record fields: `NSString`, `NSNumber`, `NSDate`, `Data`, `CKAsset`, `[CKRecord.Reference]`. Every TypedValue case that CKRecordMapping currently encodes maps to one of these:

| TypedValue case | CKRecord representation | encryptedValues compatible? |
|---|---|---|
| `.bool(b)` | `NSNumber` (type "c"/"B") | yes |
| `.int(i)` | `NSNumber` (Int64) | yes |
| `.bitmap(i)` | `NSNumber` (Int64) | yes |
| `.float(f)` | `NSNumber` (Double) | yes |
| `.text(s)` | `NSString` | yes |
| `.blob(d)` | `Data` | yes |
| `.uuid(u)` | `NSString` (uuidString) | yes |
| `.timestamp(d)` | `NSDate` | yes |
| `.json(d)` | `NSString` or `Data` | yes |
| `.hlc(h)` | `NSNumber` (packed Int64) | yes |
| `.fingerprint(fp)` | `Data` (32 bytes) | yes |
| `.null` | nil (field removed) | yes |
| `.array` | throws (already unsupported) | n/a |

**Complete type compatibility. No case requires a new encoding strategy.**

**Metadata fields must stay plaintext.** `_syncHLC`, `_syncSchemaVersion`, `_syncKitID`, `_syncColumnHLCs`, `_syncTypeTags`, and `_syncDeleted` are routing and conflict-resolution metadata — they contain no user PII and encrypting them adds zero security value while any decryption failure would silently corrupt sync routing (wrong table, wrong LWW gate outcome, wrong tombstone detection). All `_sync*` fields must always use `record[key]`, never `record.encryptedValues[key]`.

### 2. Server-side query restriction — impact on our pull path

CloudKit's documented constraint: fields stored in `encryptedValues` cannot be queried or indexed server-side. A `CKQueryOperation` with a predicate on an encrypted field will fail.

**Impact on our pull path: zero.**

`PullCycle.pull()` uses exclusively:

```swift
let result = try await database.fetchZoneChanges(
    inZoneWith: zoneID,
    since: serverChangeToken
)
```

This is `CKFetchRecordZoneChangesOperation` — a zone change feed that delivers the full delta since the last change token. It is not a `CKQueryOperation`. We never issue server-side query predicates on content field values. All conflict resolution, LWW gating, and schema version checking happens client-side after records are decoded by `CKRecordMapping.decode()`.

The zone-feed architecture means the server-side query restriction is completely irrelevant to our design. If the pull path ever adopted `CKQueryOperation` for selective pull, this restriction would become load-bearing — that transition should revisit this decision.

### 3. Tombstone, slot-registry, and side-table records

**Tombstone records** (`CKRecordMapping.tombstoneRecord()`): carry only `_syncDeleted`, `_syncHLC`, `_syncSchemaVersion`, `_syncKitID`. No content fields. Entirely unaffected by encryption choice.

**Slot-registry records** (`SlotRecordMapping`): carry `device_uuid`, `epoch`, `last_active_hlc`, `claimed_at`. These are device coordination metadata, not user content. They are fetched via `fetch(withRecordIDs:)` during sync initialization (before the main pull loop). Encrypting slot records would mean a decryption failure during slot registry bootstrap blocks the entire sync initialization — a disproportionate failure mode for metadata that contains no diary content. Slot records should remain plaintext.

**ConvergenceKit side tables** (`CKSideSchema` — `_ck_sync_meta`, `_ck_outbox`, `_ck_change_token`, `_ck_sync_meta_cols`, `_ck_pending_skew`): these are local SQLite side tables, not CKRecord fields. They are covered by ADR-014 SQLCipher at-rest encryption and are not relevant to the `encryptedValues` question.

### 4. Migration story for already-synced plaintext records

Existing CloudKit records written by the current `CKRecordMapping` have all content columns in plain `record[key]` fields. CloudKit provides no server-side API to re-encrypt fields in place. The migration is entirely client-side.

**Recommended migration sketch (DO NOT BUILD until the feature is needed):**

This sketch uses `CKSideSchema`/`SyncManifest` as the existing machinery to extend:

**Step 1 — Opt-in flag in SyncManifest.** Add `encryptedContentColumns: Set<String>?` to `SyncManifest` (or per `SyncedTable`). Default `nil` = current behavior, no change. This mirrors how `excludedColumns` was added — additive, backward-compatible, nil means empty.

**Step 2 — Dual-write CKRecordMapping.** In `CKRecordMapping.record(from:)`, columns whose names appear in `encryptedContentColumns` go to `record.encryptedValues[key] = value`; all others go to `record[key] = value`. The `_sync*` metadata fields always use `record[key]`.

**Step 3 — Dual-read CKRecordMapping.** In `CKRecordMapping.decode()`, for each key in `record.allKeys()` plus `record.encryptedValues.keys`, prefer the encrypted value when both are present. This handles: (a) old plaintext records from unupgraded peers, (b) own old records written before the flag was set, (c) records from a peer that rolled back the flag.

**Step 4 — Deploy one table at a time.** A `SyncManifest.schemaVersion` bump is NOT needed for this change — the encryption routing is a local client decision, not a wire-format change. Old records are naturally overwritten with encrypted versions on each subsequent write to that row.

**Step 5 — No side-table changes needed.** `CKSideSchema` version stays at current (v8). Outbox entries store the TypedValue JSON payload, not the CKRecord field routing decision — the routing is applied fresh at push time, so old outbox entries are upgraded automatically on next push.

**Migration window:** Until all active devices upgrade to the version with the flag set, some peers will write plaintext and some will write encrypted. The dual-read decode path handles this indefinitely. This is acceptable for a safety-first rollout.

### 5. Dashboard debuggability and Apple key-escrow posture

**Dashboard:** CloudKit Dashboard shows only opaque ciphertext for `encryptedValues` fields. You cannot read field values, inspect content type discriminators, or verify TypedValue encoding correctness. During active development this is a significant cost — the dashboard is a primary tool for diagnosing schema mismatches, sync loop artifacts, and HLC ordering anomalies. After the sync architecture stabilizes this cost decreases, but never reaches zero.

**Apple key-escrow posture (stated honestly):** `encryptedValues` uses CloudKit end-to-end encryption. The encryption key is stored in the user's iCloud Keychain and is not accessible to Apple's servers. Apple cannot read encrypted field values.

The escrow model has nuances worth naming:
- Key recovery is via iCloud Keychain. If the user loses all their devices and has no iCloud Keychain recovery contact or recovery key set, encrypted records are permanently unreadable.
- The iCloud Keychain itself is subject to Apple's Secure Enclave infrastructure. It is stronger than regular iCloud Keychain items (which have server-side recovery options) — CloudKit E2EE keys specifically do not have server-side recovery.
- This is stronger than TLS-only (where Apple's CloudKit servers see plaintext in memory) but not equivalent to a key that has never left the device (the key is synchronized across the user's devices via iCloud Keychain).
- For MOOTx01 CE's threat model (protecting user notes from Apple seeing them in transit), this is materially stronger than the current plaintext CKRecord approach.

---

## Existing protection layer

ADR-014 (SQLCipher whole-file encryption, CommonCrypto backend, Secure Enclave key) protects all estate data at rest on the device. A physical device theft or forensic copy of the SQLite file yields only ciphertext. The gap `encryptedValues` fills is a narrower one: Apple's CloudKit relay servers see plaintext content values in transit between devices. For most threat models (protecting data from Apple's infrastructure), that gap is real. For the current development phase it is outweighed by the practical costs below.

---

## Why defer (not reject, not adopt now)

| Factor | Adopt now | Defer | Reject |
|---|---|---|---|
| Type compatibility | Complete ✓ | — | — |
| Query restriction impact | Nil ✓ | — | — |
| Migration complexity | Non-trivial: old records stay plaintext indefinitely | Manageable with dual-read decode when triggered | — |
| Dashboard debuggability | Significant cost during development | Recoverable: can add plaintext debug variants later | — |
| At-rest already covered | ADR-014 SQLCipher | — | — |
| Named requirement? | No specific content type mandated yet | Trigger on first named requirement | — |
| Implementation viable? | Yes | Yes | Yes |

**Reject** is wrong: the implementation is sound, the threat model is real, and the migration path is understood.

**Adopt now** is premature: no specific content sensitivity requirement names a column that MUST be protected from Apple's servers. The migration complexity and debuggability cost are justified only by a named requirement. Adopting speculatively adds ongoing friction (opaque dashboard, dual-read complexity) with no current payoff.

**Defer**: when the first content sensitivity requirement names a specific column (e.g. diary body, high-sensitivity drawer title), revisit with a mission scoped to that column set. The implementation sketch above is the starting point.

---

## Implementation sketch (for reference, not approved for build)

Changes confined to `CKRecordMapping.swift` and a `SyncManifest` struct extension:

```swift
// SyncManifest extension (additive, backward-compatible):
// encryptedContentColumns: columns to route through record.encryptedValues.
// nil or empty = current behavior (no encryption).
// _sync* keys are always excluded from this set at the call site.
public struct SyncManifest {
    // ... existing fields ...
    public var encryptedContentColumns: Set<String>?
}

// CKRecordMapping.record(from:) — push path change:
// Replace:  try assign(value: value, to: record, forKey: key)
// With:
if let encryptedSet = encryptedContentColumns, encryptedSet.contains(key) {
    try assign(value: value, to: record.encryptedValues, forKey: key)
} else {
    try assign(value: value, to: record, forKey: key)
}

// CKRecordMapping.decode() — pull path change:
// After the existing for key in record.allKeys() loop, add:
for key in record.encryptedValues.keys {
    if key.hasPrefix("_sync") { continue }
    if let any = record.encryptedValues[key] {
        values[key] = try typedValue(from: any)
    }
}
// (encrypted values overwrite plaintext values for the same key, so
//  a peer writing encrypted always wins over the plaintext fallback)
```

No `CKSideSchema` version bump required. No `SyncManifest.schemaVersion` bump required. The change is local to push/pull routing; the outbox and wire format are unchanged.

A round-trip test through `CloudZoneFake` (the injectable `CloudKitDatabaseProtocol` test seam) should validate: plaintext write → encrypted read (backward-compat), encrypted write → encrypted read (new path), mixed batch (some encrypted, some plaintext) → correct decode for all.

---

## Update to TRACKED_FOLLOWUPS

Row 3 in `docs/status/CVK_ICLOUD/TRACKED_FOLLOWUPS.md` should read:

> **CKRecord.encryptedValues eval** — evaluated CVK-WB3. Recommendation: DEFER until a named content sensitivity requirement triggers adoption. Decision record: `docs/decisions/DECISION_CONVERGENCEKIT_ENCRYPTEDVALUES_2026-07-17.md`. Implementation sketch and migration path documented. Type compatibility is complete; zone-feed pull path makes the query restriction moot. Bob decides.
