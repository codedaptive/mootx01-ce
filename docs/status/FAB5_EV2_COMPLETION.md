---
mission: FAB5-EV2
stream: ev3
branch: stream/ev3-encryptedvalues-phase2-wiring
status: complete
date: 2026-07-24
---

# FAB5-EV2 Completion Report — encryptedValues Phase-2 Wiring

## Summary

Wired the FAB5-EV Phase 1 opt-in to the live engine. Two production edits:
PushCycle now passes `manifest.encryptedContentColumns[tableName] ?? []` into
`CKRecordMapping.record(...)` so declared columns route through
`CKRecord.encryptedValues` on every push; `CloudKitStateActor.enable()` now
calls `manifest.validateEncryptedColumns()` immediately after manifest
assignment so an invalid declaration fails loud before zone setup or any push
occurs. The Phase-1 empty-default is preserved: tables with no declaration are
byte-identical to pre-EV2 behaviour.

---

## Commits

| SHA | Message |
|---|---|
| `4b481542` | `feat(cvk-ck): wire encryptedContentColumns through PushCycle` |
| `10e57353` | `feat(cvk-ck): validate encrypted column declarations at engine enable` |
| `81710d0c` | `docs(cvk-ck): fix test file header comment count (Adams INFO)` |

---

## Files Modified

| File | Change |
|---|---|
| `packages/kits/ConvergenceKit/Sources/ConvergenceKitCloudKit/Engine/PushCycle.swift` | Pass `encryptedColumns: manifest.encryptedContentColumns[entry.tableName] ?? []` to `CKRecordMapping.record(...)` |
| `packages/kits/ConvergenceKit/Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift` | Call `try manifest.validateEncryptedColumns()` after manifest assignment, before zone setup |
| `docs/reference/CONVERGENCEKIT_SPEC.md` | Phase 2 wire-note sentence added to existing FAB5-EV block |

## New Test Files

| File | Coverage |
|---|---|
| `Tests/ConvergenceKitCloudKitTests/EncryptedValuesPushWiringTests.swift` | Full push path: declared column routes to `encryptedValues`; undeclared table stays plaintext |
| `Tests/ConvergenceKitCloudKitTests/EncryptedValuesEnableValidationTests.swift` | `enable()` rejects `_ck_*` table; `enable()` rejects `_sync*` column; valid and empty declarations pass |

## Files NOT Modified

- `SyncTypes.swift` — Phase 1, untouched
- `CKRecordMapping.swift` — Phase 1, untouched
- `CloudKitSyncEngine.swift` — public wrapper, untouched
- `Registry/SlotRecordMapping.swift`, side schemas, Federation sources — untouched

---

## Blast Radius Report

| Symbol | Classification | Status |
|---|---|---|
| `CloudKitStateActor.push()` (`PushCycle.swift`) | MUST_UPDATE | Done |
| `CloudKitStateActor.enable(manifest:storage:)` | MUST_UPDATE | Done |
| `docs/reference/CONVERGENCEKIT_SPEC.md` | MUST_UPDATE | Done |
| Test callers of `CKRecordMapping.record(...)` | INTENTIONALLY_LEFT | Verified — test-only, not production push path |

---

## Pre-flight (Smythe)

**Verdict: GREEN**

- Phase 1 surface fully present: `encryptedContentColumns` at `SyncTypes.swift:143`, `validateEncryptedColumns()` at `SyncTypes.swift:187`, `encryptedColumns:` parameter at `CKRecordMapping.swift:91`.
- Push call site confirmed unwired at `PushCycle.swift:130-139`.
- Enable call site confirmed lacking `validateEncryptedColumns()` call.
- No prior-art conflict with existing `EncryptedValuesTests.swift`.
- One production call site; all test callers INTENTIONALLY_LEFT.
- No blockers.

---

## Test Verification Log

### Baseline (mission start)
- Command: `cd packages/kits/ConvergenceKit && swift test`
- Exit code: 0
- Pass count: **272 tests in 58 suites**

### Final
- Command: `cd packages/kits/ConvergenceKit && swift test 2>&1 | tail -40`
- Exit code: **0**
- Pass count: **278 tests in 60 suites**
- Delta: +6 tests, +2 suites (all new; zero regressions)
- Tail output:
  ```
  Test run with 278 tests in 60 suites passed after 2.065 seconds.
  ```

---

## Self-Review

- Diff matches BRR MUST_UPDATE list exactly (2 production sites + 1 doc, 2 new test files).
- No bridge helpers, shims, orphan `@available(*, deprecated)`, or TODO/FIXME on changed symbols.
- No `SyncTypes.swift`, `CKRecordMapping.swift`, `CloudKitSyncEngine.swift` changes.
- Comments in production files are current and describe current behaviour.
- `encryptedColumns: manifest.encryptedContentColumns[entry.tableName] ?? []` — `?? []` preserves byte-identity for undeclared tables.
- `validateEncryptedColumns()` placed before `self.storage = storage` so a throw leaves the engine fully disabled.

---

## Post-flight (Adams)

**Verdict: PASS**

Findings:
- INFO: Test header comment said "Three scenarios" while file had 2 test functions. Fixed in commit `81710d0c` (comment-fidelity, non-blocking, resolved before signal).
- No CRITICAL or WARNING findings.
- Diff verified exact match to BRR.
- MUST NOT MODIFY files confirmed zero diff.
- `swift test` re-run independently: exit 0, 278 tests.
- Wiring correctness confirmed: `encryptedColumns:` at correct call site; `validateEncryptedColumns()` before zone setup.

---

## Success Criteria

- [x] Phase-1 opt-in is live end to end: declaration validated at enable, enforced on push
- [x] A declared tier column provably never appears in plaintext on the real push path (proven by push-wiring test via CloudZoneFake)
- [x] FAB5-ST gate passes: "Gate: FAB5-EV Phase-2 wiring mission must complete before FAB5-ST can begin" (`RELEASE_CHECKLIST_1_1.md:160`)
- [x] All tests green (278/278, exit 0)
