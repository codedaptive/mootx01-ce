# Blast Radius Report — FED-OD-4

**Baseline:** 235 tests (ConvergenceKit) + 126 MootGatewayTests + 13 GatewayUITests = 374 total — all exit 0 at mission start.
**Mission:** Federation Session Lifecycle — on-demand window (FED-OD-4)
**Tier:** Tier 1 (touches SyncController, a shared primitive) — ≤5 edits

## Symbols being changed

Three categories:
1. `LANRelayTransport` — protocol extension, additive `close()` method
2. `LANRelay` — additive `closeChannel()` method
3. `SyncController.disable()` — additive cascade to `federationSessionManager?.endSession()`

---

## Symbol 1: `LANRelayTransport.close()` (additive — protocol extension)

**Change class:** Additive protocol method (default no-op via extension)
**Scope:** public (protocol is public in ConvergenceKitFederation)

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/Relay/FakeLANRelayTransport.swift` | whole file | grep | INTENTIONALLY_LEFT | Existing conformer receives default no-op `close()` via extension; no code change required. Conformance tests do not test session-end close behavior. |
| `packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/Relay/LANRelayTLSConfig.swift` | comments | grep | INTENTIONALLY_LEFT | References FakeLANRelayTransport only in comments; no code change needed. |

### Summary
- MUST_UPDATE: 0 sites (additive method; default handles all existing conformers)
- INTENTIONALLY_LEFT: 2 (all justified above)
- RESCOPE_REQUIRED: 0

---

## Symbol 2: `LANRelay.closeChannel()` (additive)

**Change class:** Additive public method on `LANRelay`
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `apps/Mootx01-App/Sources/MootGateway/Federation/FederationSessionManager.swift` | new file | — | MUST_UPDATE | New file: calls `lanRelay.closeChannel()` in `endSession()`. This is new code, not existing caller. |

### Summary
- MUST_UPDATE: 1 (the new FederationSessionManager.swift — new code)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 3: `SyncController.disable()` (semantic extension — federation cascade)

**Change class:** Additive behavior — on `disable()`, cascade to `federationSessionManager?.endSession()` if set
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `apps/Mootx01-App/Sources/MootGateway/Sync/MootSyncDriver.swift` | 84 | rg | INTENTIONALLY_LEFT | Calls `controller?.disable()` — behavior unchanged from caller's perspective. Cascade is additive (ends federation session if active; no-op if none set). Caller contract preserved. |
| `apps/Mootx01-App/Tests/MootGatewayTests/SyncControllerTests.swift` | various | rg | INTENTIONALLY_LEFT | Tests call `disable()` without a federation session manager set — cascade is guarded by optional (`federationSessionManager?.endSession()`), so existing tests are unaffected. |

### Summary
- MUST_UPDATE: 0 (cascade is additive, existing callers unaffected)
- INTENTIONALLY_LEFT: 2 (both justified)
- RESCOPE_REQUIRED: 0

---

## Purely additive new files (no blast radius)

| File | Notes |
|---|---|
| `apps/Mootx01-App/Sources/MootGateway/Federation/FederationSessionManager.swift` | New type — no existing callers |
| `apps/Mootx01-App/Tests/MootGatewayTests/Federation/FederationSessionManagerTests.swift` | New test file |

---

## Mission-level summary

- Total MUST_UPDATE sites: 1 (new FederationSessionManager.swift calling closeChannel)
- Total INTENTIONALLY_LEFT: 4 (all justified)
- RESCOPE_REQUIRED: 0
- Total edits to existing files: 3 (LANRelay.swift, SyncController.swift, GatewayRuntime.swift) — within Tier 1 limit (≤5)

## F1 Invariant Line (what was NOT built)

Per FED-OD charter §V5 and the mission brief, the following are explicitly out of scope:
- No per-scope key minting
- No tell-record entries
- No durable key handoff
- No always-on mode
- No re-share
- No private-share prompt
- No posture other than Balanced (the only functional F1 posture)

Session == conceptually grant{lifetime:singleSession, channel:lanDirect, custody:mediated} per charter V4 — but the `_grants` table does not exist until F2 (FED-OD-8). This mapping is documented in FederationSessionManager.swift as the interim the charter blessed.
