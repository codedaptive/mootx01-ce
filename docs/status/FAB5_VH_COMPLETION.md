---
version: v0.1
mission: FAB5-VH
stream: vh
branch: stream/vh-testflight-validation-harness
status: COMPLETE
date: 2026-07-23
---

# Completion Report — FAB5-VH: TestFlight & Two-Device Validation Harness

## Mission Summary

Net-new Tier 3 mission — all new files, zero edits to existing source or tests.
Produces the validation matrix, release checklist, and scenario fixtures for the
MOOTx01 1.1 TestFlight and App Store submission pipeline.

---

## What Was Done

### Part 1 — Release checklist + matrix docs (commits 2c33323d)

**RELEASE_CHECKLIST_1_1.md:**
- Section 0: cold-install review-safe defaults assertion (sync off, federation off,
  LAN off, miners off) with verification commands.
- Section 1: all 8 FAB5 stream gates (sm/ev/cp/dt COMPLETE; fr/st/fo PENDING per
  Smythe YELLOW finding; vh this stream). Each gate includes signal file path,
  verification command, and stream-specific checklist lines.
- FAB5-EV Phase-2 wiring gap documented as a hard watchpoint under the ev gate.
- Sections 2–5: Xcode/build gates, TestFlight submission steps (7 manual steps),
  RC-week watchpoints (~September 8 target), post-submission protocol.

**TWO_DEVICE_SYNC_MATRIX.md:**
- 6 scenario groups (13 individual scenarios) covering: concurrent writes (1a/1b),
  kill/restore (2a/2b/2c), slot eviction/fencing (3a/3b via automated suites),
  tier enable/revoke (4a/4b — post-FAB5-ST), offline/rejoin (5a/5b/5c), and
  automated conformance gate (6).
- Each scenario: precondition, steps, expected outcome, per-run result table.
- Matrix references automated coverage (CrashRecoveryTests, SlotFencingScenarios,
  TwoDeviceKillRestoreTests) by test name for cross-reference.

### Part 2 — Scenario fixtures + perf record (commit f9c2b068)

**TwoDeviceKillRestoreTests.swift** — 3 new conformance fixtures covering two-device
gaps not present in CrashRecoveryTests (single-device) or SlotFencingScenarios
(slot registry unit tests):

1. `concurrentKillAndRestoreBothEstates` — Both estates accumulate writes then crash
   simultaneously (disable/enable on both). Verifies durable outbox survives on both
   sides and all 6 rows converge after restart + sync.
2. `offlineRejoinCatchUp` — A does not push or pull while B writes and pushes 10 rows.
   Verifies A's pull catches the full backlog on rejoin (convergence proof via
   `assertSyncMetaMatch`).
3. `offlineDivergenceResolves` — Both estates write concurrently while "offline" (no
   push/pull), including 1 contested row. A's clock advanced +10 s to guarantee
   deterministic LWW winner. Verifies identical resolution on both estates after rejoin.

All fixtures: poll-deadline pattern (no Task.sleep), deterministic, fresh InMemoryStorage
per test. No existing test files edited.

### Part 3 — TestFlight round-one log (commit e433524e)

**TESTFLIGHT_SUBMISSION_LOG.md:**
- Upload steps (xcodebuild archive → Organizer → ASC).
- Internal test result table (before external submission).
- Beta App Review findings log: rounds 1/2/3 each with finding table + verdict.
- Blocker triage protocol: policy → owning stream → fix → re-upload.
- External TestFlight status tracker.
- Automated conformance gate record (Round 1 pre-upload baseline: 272 tests, exit 0).

---

## Commits

| SHA | Message |
|---|---|
| `2c33323d` | `docs(release): 1.1 release checklist and two-device matrix` |
| `f9c2b068` | `test(cvk): net-new validation fixtures + perf record` |
| `e433524e` | `docs(release): TestFlight round-one findings` |

---

## Test Verification Log

### Baseline (mission start)
- Command: `cd packages/kits/ConvergenceKit && swift test 2>&1 | tail -5`
- Exit code: 0
- Pass count: **269 tests in 57 suites**

### Final
- Command: `cd packages/kits/ConvergenceKit && swift test 2>&1 | tail -5`
- Exit code: **0**
- Pass count: **272 tests in 58 suites** (+3 new: TwoDeviceKillRestoreTests)
- Tail output (verbatim):
```
Test "stop() is deterministic even when pull throws retryable errors" passed after 0.100 seconds.
Suite "AdaptivePollScheduler — CKError backoff (CVK-WB6)" passed after 0.129 seconds.
Test "local write lands in CloudZoneFake automatically without manual push()" passed after 2.047 seconds.
Suite "AutoPushOnWrite — debouncer integration" passed after 2.049 seconds.
Test run with 272 tests in 58 suites passed after 2.050 seconds.
```

Default `swift test` wall time unchanged (2.05 s). No perf-suite wall-clock increase;
MOOT_PERF_BENCH=1 lanes not triggered by new fixtures.

---

## Pre-flight (Smythe)

**Verdict: YELLOW** — no functional blockers; two warnings:

- **W1:** FAB5-FR unconfirmed (no `.done-fr`, no completion report). Addressed: FR
  checklist lines marked pending in RELEASE_CHECKLIST_1_1.md.
- **W2:** FAB5-ST and FAB5-FO absent (expected; both parallel). Addressed: marked
  pending in checklist.

All collision checks clean. No reserved-file conflicts. Baseline 269/57/exit 0 confirmed.

---

## Self-Review

### Scope (Tier 3 no-edit claim)

- `git diff HEAD~3..HEAD --stat` → 4 files, all new (`+++` only, zero deletions)
- Zero edits to: any Swift source, any existing test, any existing doc
- Adams independently confirmed: no-edit claim PASS

### Standard checks

- **Secrets:** no credentials, tokens, or API keys in any new file ✅
- **Stale comments:** "previously" hits in doc prose are current-behavior descriptions ✅
- **Prohibited patterns:** none (bridge/shim/deprecation not applicable to docs+tests) ✅
- **Localization:** no user-facing strings in new code ✅
- **Determinism:** all 3 fixtures use poll-deadline, no Task.sleep ✅
- **Blast radius:** additive only; zero existing files touched ✅

---

## Post-flight (Adams)

**Verdict: CLEAN**

- No-edit claim: **PASS** — zero deletions in diff; 4 new files only
- Test Execution Verification: re-run by Adams confirmed **272 tests, 58 suites, exit 0**
- Logic check: all 3 fixtures sound; clock-advance unit correct (10,000 ms = 10 s);
  `assertSyncMetaMatch` called correctly after both estates pull; LWW winner deterministic
- Import list matches established test files
- Test names match TWO_DEVICE_SYNC_MATRIX.md scenario references

Two INFO items (non-blocking):
1. `offlineRejoinCatchUp` relies on B's re-pull populating `_ck_sync_meta` for its own
   previously-pushed records — behavior is correct and matches `rePullAfterCrashIsIdempotent`
   pattern in CrashRecoveryTests; comment in code explains the dependency
2. TWO_DEVICE_SYNC_MATRIX scenario 4 (tier enable/revoke) gated on FAB5-ST — correct;
   documented as pending

---

## Discoveries

- `assertSyncMetaMatch` requires BOTH estates to have completed a pull before assertion;
  the push path does not populate `_ck_sync_meta` on the pushing estate. This is the same
  behavior present in `orderingSoundnessAfterEvictReclaim` (Scenario 5, SlotFencingScenarios).
  Test 2 initially failed with `sortedA.count=10, sortedB.count=0`; fixed by adding
  `_ = try await fixture.engineB.pull()` before the assertion.
- FAB5-EV Phase-2 wiring (PushCycle.swift) is a hard gate before FAB5-ST can encrypt
  production fields. Documented in RELEASE_CHECKLIST_1_1.md §ev as a watchpoint.

---

## Success Criteria

| Criterion | Status |
|---|---|
| Release checklist: all FAB5 streams with verification commands | ✅ |
| Checklist cross-references every FAB5 signal (sm, ev, st, cp, fr, dt, fo) | ✅ |
| Two-device matrix executable on real hardware | ✅ |
| Fixtures deterministic; no wall-clock dependence | ✅ |
| Perf suites env-gated (MOOT_PERF_BENCH=1; no wall-time increase) | ✅ |
| No existing file touched (Adams-verified) | ✅ |
| TestFlight log ready for Bob's upload step | ✅ |
| swift test exit 0, baseline + 3 net-new tests | ✅ |
