---
title: FED-OD-7 Completion Report
mission: FED-OD-7
status: COMPLETE
date: 2026-07-18
stream: worktree-agent-adb1c185114986f47
---

# COMPLETION: FED-OD-7

Status: COMPLETE

## What Was Done

**Part 1 — Terrain verification (Step Zero)**
- `git merge e8d93e38` — fast-forward to FED-OD-4 base. Verified `LANRelay`
  hits in `ConvergenceKit/Sources` and `FED_OD_CHARTER.md` exists.

**Part 2 — Row audit (cited vs. gap)**
- Audited all six §6 conformance rows against existing tests.
- Rows 1, 2, 4, 5, 6 are fully covered by prior missions (FED-OD-1/2/3/4).
- Row 3 (ceiling holds on LANRelay) has a gap: FSM-2 uses an empty manifest
  and explicitly defers the restricted-row assertion to FED-OD-7.

**Part 3 — Kit aggregator (NEW file)**
- Wrote `ConvergenceKitFederationTests/LAN/LANFederationConformanceTests.swift`
- Contains `LANFederationConformanceSuite.conformanceSurfaceCompiles()` — API
  smoke-check for Rows 1 and 6 at the kit layer, with Row 2-5 documented by
  reference.
- All six rows are documented with exact test function names and file paths.

**Part 4 — Ceiling proof tests (NEW in MootGatewayTests)**
- Edited `MootGatewayTests/Federation/FederationSessionManagerTests.swift`
- Added `LANCeilingConformanceTests` suite (FSM-7 and FSM-8).
- FSM-7: restricted row (`adjective_bitmap = 2048`, raw=32 > ceiling=16) —
  asserts `receipt.pushed == 0` and `transport.inboxCount(for: bKey) == 0`.
- FSM-8: positive control — normal row (bitmap=0) — asserts pushed > 0 and
  inboxCount > 0 (confirms the suppression in FSM-7 is real, not infrastructure failure).
- Added missing `PersistenceKit` and `PersistenceKitInMemory` imports.

**Part 5 — Documentation**
- `docs/status/FED_OD_CONFORMANCE.md` — six-row → test-name mapping table.
- `docs/decisions/DECISION_FEDERATION_ONDEMAND_LAN_PROXIMITY_2026-07-18.md`
  §6 firmed to name the exact test functions for each row.
- This completion report.

## Test Verification Log

```
ConvergenceKitFederationTests:
  swift test --package-path packages/kits/ConvergenceKit: exit 0
  Before FED-OD-7: 235 tests in 45 suites
  After FED-OD-7:  236 tests in 46 suites (+1 test, +1 suite)
  Delta: +1 conformanceSurfaceCompiles

MootGatewayTests (Mootx01-App):
  swift test --package-path apps/Mootx01-App: exit 0
  Before FED-OD-7: 132 tests in 23 suites (MootGatewayTests target)
  After FED-OD-7:  134 tests in 25 suites (+2 tests, +2 suites)
  Delta: +FSM-7 restrictedRowNeverReachesLANRelayInbox
         +FSM-8 normalRowReachesLANRelayInbox

All tests pass. Exit 0 on both targets. Baseline not degraded.
```

## Conformance Row Summary

| Row | Description | Status | Test(s) |
|---|---|---|---|
| 1 | TXT no-content-bytes | CITED | `txtRecordHasExactlyFourKeys`, `fingerprintDerivedFromKeyNotContent` |
| 2 | Session-end determinism | CITED | `sessionEndDeterminism` (FSM-1) |
| 3 | Ceiling holds on LANRelay | NEW | `restrictedRowNeverReachesLANRelayInbox` (FSM-7) + `normalRowReachesLANRelayInbox` (FSM-8) |
| 4 | SAS mismatch refusal | CITED | `sasMismatchNoPersistedPeer` (QR-2) |
| 5 | Tampered proposal refusal | CITED | `tamperedProposalSignatureRejected` (QR-3) |
| 6 | TLS refused on unknown key | CITED | `tlsRefusedOnUnknownKey` (Suite 3) |

## Discoveries

- The `ConvergenceKitFederationTests` target cannot depend on MootGateway
  (package boundary); Row 3's ceiling test lives in `MootGatewayTests` where
  both kit and gateway are available. The kit aggregator documents this by
  reference.
- FSM-2's empty-manifest design was intentional (FED-OD-4 scope boundary);
  FSM-7/FSM-8 provide the promised deeper ceiling proof with actual restricted
  rows and LANRelay transport inbox verification.
- Positive control (FSM-8) is structurally important: without it, a broken
  transport or incorrect push logic could make FSM-7's zero-inbox assertion
  vacuously true.

## Outstanding

None outside mission scope.
