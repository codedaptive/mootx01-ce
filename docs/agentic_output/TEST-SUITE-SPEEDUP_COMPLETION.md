---
mission: TEST-SUITE-SPEEDUP
agent: bilby
date: 2026-07-08
worktree: /Users/bob/devlop/mootx01-ce/.claude/worktrees/agent-a504579d321d7eace
branch: worktree-agent-a504579d321d7eace
---

# COMPLETION: TEST-SUITE-SPEEDUP

**Status:** COMPLETE

---

## What Was Done

### Part 1: Mechanism diagnosis
Identified two independent hang mechanisms via `sample <pid>` on the live test runner:

1. **Keychain serialization (dominant)** — All 50 `kit.open(storage:owner:)` call sites in
   `packages/kits/AriaMcpKit/Tests/AriaMCPTests/` defaulted to `KeychainEstateIdentityKeyStore()`,
   hitting the macOS system-wide Security-framework mutex (`SecItemAdd` →
   `Security::KeychainCore::KeychainImpl::exists()` → `__psynch_mutexwait`). Under Swift
   Testing's parallel scheduler, hundreds of concurrent estate-open calls serialized on this
   single process-global lock. The seam for the fix already existed in production:
   `Estate.open(storage:owner:identityKeyStore:)` with a documented `InMemoryEstateIdentityKeyStore`
   for tests.

2. **Pipe write hang (independent, deterministic)** — `StdioFramingTests.swift:136`
   `testOversizedFrameClosesInputCleanly()` had dead setup code that wrote 4 MiB+1 bytes to a
   `Pipe` whose read end was never consumed. OS pipe buffer (~64 KiB) filled and the synchronous
   `NSFileHandle.write(contentsOf:)` / `write(2)` never returned. Confirmed by `sample` showing
   the thread stuck at that exact call site, and by `perl -e 'alarm 20; exec @ARGV' swift test
   --filter testOversizedFrameClosesInputCleanly` timing out at 20s (exit 142).

### Part 2: Keychain seam injection
Injected `identityKeyStore: InMemoryEstateIdentityKeyStore()` at all 50 call sites across 38 test
files. No production code touched — the injection seam predated this mission.

Files modified (38 total, all in `packages/kits/AriaMcpKit/Tests/AriaMCPTests/`):
AutonomicGovernorTests, DreamRunnerTests, DurableSemanticRecallTests, EstateStatusSyncTests (3 sites),
FactProvenanceTests, FdcCaptureTests, FdcReclassifyTests, GateRejectionMessageTests,
GraphCentralityProducerTests, HTTPServerTests, HTTPTransportHardeningTests (2 sites),
HydrationDecodeTests, InMemorySemanticRecallTests (2 sites), LensToolsTests (2 sites),
LexiconGapsTests, MemoryGetTests, MultiEstateRoutingTests, OrderingDispatchTests,
PersistenceTests (2 sites), PreferenceProducerTests, RecallDiscriminationTests,
RecallProvenanceSurfacingTests (2 sites), RecipeToolsTests (1 scripted + 1 manual multi-line),
SchemeDiscriminatorTests, ScoringDispatchTests, SearchRedactionTests,
SensitivityUnlockIntegrationTests, ServerTests (3 sites), SessionProtocolTests,
StdioFramingTests, SurfaceHintAndMoveWingTests, TeachmeTests, TraceRewardTests,
TunnelRecallTests, V1ConformanceTests, VaultToolsTests, WithdrawRecallDropDispatchTests.

### Part 3: Pipe hang fix
Removed dead `inPipe`/`outPipe` setup from `testOversizedFrameClosesInputCleanly()`. Renamed
surviving `inPipe2`/`outPipe2` to `inPipe`/`outPipe`. Added explanatory comment documenting the
hang mechanism. No assertion weakened — the cap-trip behavior is fully proven by the
`smallCap`/`smallPayload` path that remains. Test now completes in 0.001s.

### Part 4: Concurrency safety audit
Audited all HTTP test call sites for fixed port binding. Both sites already bind port 0:
- `HTTPTransportHardeningTests.swift:111`: `port: 0`
- `HTTPServerTests.swift:73`: `HTTPServer(dispatcher: dispatcher, port: 0, ...)`
No change needed. Confirmed compliant.

**Commit:** `5310740739e174b9b8e2402dd181d3a1ab76d48e`
**Commit message:** `test(aria-mcp): suite speedup — inject in-memory Keychain seam, fix pipe-write hang; ports already ephemeral`

---

## Test Verification Log

### Baseline (from mission evidence)
- Pre-mission distribution: <1s: 50, 1-5s: 20, 5-60s: 300, >60s: 136
- Total: 506 tests, 55 suites
- Full suite: never completed in any observed run (>60s class cumulatively unbounded)

### Final (post-commit)
- Command: `/usr/bin/time -p swift test --package-path packages/kits/AriaMcpKit`
- Real elapsed: **47.03s** (wall clock including build ~2s)
- Exit code: 0
- Total tests: 507 (484 AriaMCPTests + 23 AriaResidentTests)
- Post-mission distribution: <1s: 478, 1-5s: 25, 5-60s: 4, >60s: 0
- Max single test: 11.949s ("ADR-016 Wings Surface" 18-test serialized suite)
- Suite target (≤5 minutes): MET (47s)

### Remaining failures (all pre-existing, unrelated to this mission)

| Suite | Count | Status | Evidence |
|---|---|---|---|
| VaultToolsTests | 1 | Named in mission as pre-existing | |
| SensitivityUnlockIntegrationTests | 5 | Reproduced identically via `git stash` A/B on original code; audit-entry-count assertion, fails in 21ms, non-timing | Zero diff to this mission |
| AriaResidentTelemetryTests | 1 | Intellectus global-state race; test suite comment self-documents it | Zero diff to `Tests/AriaResidentTests/` |

---

## Mechanism Findings — Per Class with File:Line

### Class 1: Keychain Mutex (>60s class, >300 tests affected)

**Root cause:** `KeychainEstateIdentityKeyStore.storePrivateKey()` calls `SecItemAdd` /
`SecItemUpdate` which enter `Security::KeychainCore::KeychainImpl::exists()` — a process-global
mutex. Hundreds of concurrent estate opens under Swift Testing's parallel scheduler pile up on
this single lock.

**Evidence:** `sample <pid>` of live hung test runner showed all cooperative-queue threads parked
in `_pthread_mutex_firstfit_lock_wait` with stack bottom at `SecItemAdd` → `Security::KeychainCore`.

**Fix location:** Every file listed in Part 2 above. The injection parameter was:
```swift
// BEFORE
try await kit.open(storage: storage, owner: owner)

// AFTER
try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
```

**Seam file (read-only, not modified):**
`packages/kits/LocusKit/Sources/LocusKit/EstateIdentityKeyStore.swift` — `InMemoryEstateIdentityKeyStore`
`packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/EstateCoordinator.swift:73` — the injection parameter

### Class 2: Pipe Write Hang (1 test, deterministic)

**Root cause:** `StdioFramingTests.swift` line ~129-142 (pre-fix) — dead code path wrote 4 MiB+1
bytes to `inPipe.fileHandleForWriting` using synchronous `NSFileHandle.write(contentsOf:)`. Nothing
ever consumed from `inPipe.fileHandleForReading`. When the macOS kernel pipe buffer (~64 KiB) filled,
`write(2)` blocked forever.

**Evidence:** `sample <pid>` showed thread stuck in `NSFileHandle.write(contentsOf:)`. The
subsequent `inPipe2`/`outPipe2` path in the same test proved the larger pipe was entirely dead
code. `perl -e 'alarm 20; exec @ARGV' swift test --filter testOversizedFrameClosesInputCleanly`
confirmed 20-second timeout (exit 142).

**Fix location:** `packages/kits/AriaMcpKit/Tests/AriaMCPTests/StdioFramingTests.swift` — removed
dead Pipe setup, renamed `inPipe2`/`outPipe2` to `inPipe`/`outPipe`, added pipe-buffer-fill comment.

### Class 3: Fixed Ports (not present — already compliant)

**Audit result:** Zero hardcoded listen ports in any test file. Both HTTP server test instantiations
already used `port: 0`. Two-checkout deadlock must have had a different root cause, or was
incidentally resolved by the Keychain fix (which eliminated the multi-hour blocking that created
the illusion of deadlock).

---

## Before / After Numbers

| Metric | Before | After |
|---|---|---|
| <1s tests | 50 | 478 |
| 1-5s tests | 20 | 25 |
| 5-60s tests | 300 | 4 |
| >60s tests | 136 | 0 |
| Wall clock | unbounded | 47.03s |
| Gate (≤5 min) | FAIL | PASS |

---

## Discoveries

1. The `InMemoryEstateIdentityKeyStore` injection seam was already documented in the
   `EstateIdentityKeyStore.swift` header comment with explicit test-use guidance. Every test
   ignoring it was not a design gap — it was an oversight accumulated over the lifetime of the
   suite. Future tests should default to injecting it.

2. Swift Testing's parallel scheduler is aggressive. Any `SecItem*` call in a test helper will
   bottleneck the entire cooperative pool under parallel scheduling, regardless of how fast the
   actual test logic is. The mitigation is to never call `SecItem*` in tests directly or
   indirectly — always inject an in-memory substitute.

3. `testOversizedFrameClosesInputCleanly()` had dead code that was harmless under XCTest (ran
   serially, got killed by the test framework before the hang was observable) but fatal under
   swift-testing's `.serialized` scheduling (blocks the entire suite).

4. The two-checkout deadlock previously blamed on fixed ports may have been entirely the Keychain
   mutex — two processes running this suite concurrently both pile into the Security framework's
   process-local lock (which is per-process, not system-wide, but both processes' cooperative pools
   grind to a halt independently, and the test runs appear to deadlock from the outside).

---

## Outstanding (out of scope, not pursued)

- `SensitivityUnlockIntegrationTests` — 5 audit-entry-count assertion failures. Real ADR-025
  audit-log bug in a different subsystem. Confirmed pre-existing via git stash A/B. Separate
  blast radius.
- `AriaResidentTelemetryTests` — Intellectus global-state race. Separate mission (test isolation
  or global-state reset). Zero diff in this mission.
