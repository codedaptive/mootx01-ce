---
mission: FAB5-EV
stream: ev
branch: stream/ev-encryptedvalues-adoption
status: complete
date: 2026-07-23
---

# FAB5-EV Completion Report — CKRecord.encryptedValues Adoption

## Summary

Adopted `CKRecord.encryptedValues` as the opt-in encryption channel for
ConvergenceKit CloudKit sync. Implemented as a Tier-1 primitive-touching
mission (3 edit sites + 1 new test file). The feature is inert by default
(empty-map preserves byte-identical wire format for all existing callers).

---

## Commits

| SHA | Message |
|---|---|
| `c4defee0` | `feat(cvk-ck): SyncManifest.encryptedContentColumns opt-in` |
| `0cceb99b` | `feat(cvk-ck): encode declared columns via encryptedValues` |
| `60c4c0b0` | `feat(cvk-ck): dual-read decode for encrypted content columns` |
| `6a3c5e00` | `fix(cvk-ck): correct validateEncryptedColumns doc comment` |

---

## Files Modified

| File | Change |
|---|---|
| `packages/kits/ConvergenceKit/Sources/ConvergenceKit/SyncTypes.swift` | New `encryptedContentColumns: [String: Set<String>]` on `SyncManifest`; new `validateEncryptedColumns()` method |
| `packages/kits/ConvergenceKit/Sources/ConvergenceKitCloudKit/CKRecordMapping.swift` | New `encryptedColumns: Set<String> = []` param on `record(from:)`; encrypted-first dual-read in `decode(_:)` |
| `packages/kits/ConvergenceKit/Tests/ConvergenceKitCloudKitTests/EncryptedValuesTests.swift` | **New** — 15 tests in 5 suites |
| `docs/reference/CONVERGENCEKIT_SPEC.md` | v1.3 → v1.4; B-6 wire note added (FAB5-EV encryptedValues) |
| `docs/reference/CONVERGENCEKIT_INTERFACE.md` | v1.7 → v1.8; SyncManifest block updated; stale `postApplyIntegrityHook` signature corrected |

**Not modified (confirmed out of scope):**
- `SlotRecordMapping.swift` — registry stays plaintext ✅
- `ConvergenceKitFederation` sources ✅
- Any `_ck_sync_meta` schema file ✅

---

## Test Verification Log

### Baseline (mission start)
- Command: `cd packages/kits/ConvergenceKit && swift test`
- Pass count: **254 tests in 52 suites**
- Exit code: 0

### Final
- Command: `cd packages/kits/ConvergenceKit && swift test 2>&1 | tail -5`
- Exit code: **0**
- Pass count: **269 tests in 57 suites** (+15 new tests)
- Tail output (verbatim):
```
Test "stop() is deterministic even when pull throws retryable errors" passed after 0.100 seconds.
Suite "AdaptivePollScheduler — CKError backoff (CVK-WB6)" passed after 0.122 seconds.
Test "local write lands in CloudZoneFake automatically without manual push()" passed after 2.141 seconds.
Suite "AutoPushOnWrite — debouncer integration" passed after 2.143 seconds.
Test run with 269 tests in 57 suites passed after 2.144 seconds.
```

---

## Agent Reports

### Smythe Pre-flight
**Verdict: GREEN**

Key findings:
- `SyncManifest` confirmed clean insertion point (no `encryptedContentColumns` pre-existed)
- `encryptedValues` zero hits in entire package — terrain virgin
- Platform floor macOS 26 / iOS 26 — no `@available` guards required
- ~20 `SyncManifest.init` call sites — all INTENTIONALLY_LEFT (defaulted param, no update needed)
- Pre-existing stale drift in `CONVERGENCEKIT_INTERFACE.md` `postApplyIntegrityHook` signature — fixed during doc update

### Adams Post-flight
**Verdict: CLEAN-WITH-FOLLOWUPS**

Test re-run: **exact match** — exit 0, 269 tests in 57 suites.

Blast radius verified: 5 files in diff, all declared; no EXPLICITLY_OUT file touched.

| # | Severity | Finding | Action |
|---|---|---|---|
| 1 | WARNING | `PushCycle.swift` calls `CKRecordMapping.record(from:)` without `encryptedColumns:` — Phase-2 engine wiring needed before consumers can actually encrypt | Phase-2 follow-up mission (out of Phase-1 scope) |
| 2 | WARNING | `CloudKitSyncEngine.enable()` doesn't call `validateEncryptedColumns()` — doc comment fixed to reflect this (`6a3c5e00`) | Doc comment fixed; engine call deferred to Phase 2 |
| 3 | INFO | `.hlc`/`.fingerprint` TypedValue cases not tested via encrypted channel | Coverage gap, not correctness gap |
| 4 | INFO | `postApplyIntegrityHook` stale signature corrected incidentally | Done ✅ |
| 5 | INFO | BRR in gitignored path | Process note only |

No CRITICAL blocking findings.

---

## Self-Review Against BRR MUST_UPDATE List

| MUST_UPDATE Site | Done | Evidence |
|---|---|---|
| `CKRecordMapping.record(from:...)` encode loop | ✅ | `encryptedColumns.contains(key)` routes to `record.encryptedValues` |
| `CKRecordMapping.decode(_:)` values loop | ✅ | Union of both channels, encrypted-first |
| `CONVERGENCEKIT_SPEC.md` B-6 wire note area | ✅ | FAB5-EV wire note added under B-6 |
| `CONVERGENCEKIT_INTERFACE.md` SyncManifest block | ✅ | New field + method + corrected hook signature |

---

## Success Criteria

| Criterion | Status |
|---|---|
| Opt-in exists (encryptedContentColumns) | ✅ |
| Defaults inert (empty map = byte-identical records) | ✅ |
| Metadata provably plaintext (_sync*, _ck_* rejected) | ✅ |
| Dual-read migration path proven | ✅ |
| Full ConvergenceKit suite green | ✅ |
| SPEC/INTERFACE updated in behavior commits | ✅ |

---

## Phase-2 Follow-up Required

Adams finding #1 is the critical follow-on item: `PushCycle.swift` must pass
`encryptedColumns: manifest.encryptedContentColumns[entry.tableName] ?? []` to
`CKRecordMapping.record(from:)`, and `CloudKitSyncEngine.enable()` must call
`manifest.validateEncryptedColumns()`. Until that wiring mission ships, consumers
should not declare `encryptedContentColumns` in production manifests — the
fields will reach CloudKit in plaintext. Mission `st` (the first consumer)
should depend on that Phase-2 wiring mission.
