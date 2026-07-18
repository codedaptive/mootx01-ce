---
version: v0.1
reviewer: Adams
task: FED-OD Phase F1
scope: c208d889..c9525caa
date: 2026-07-18
---

# POST-FLIGHT: FED-OD Phase F1 (7 missions, on-demand federation)

Final Status: **BLOCKED**

One CRITICAL open. Remaining findings are WARNING or INFO and do not block
individually, but the CRITICAL blocks merge.

---

## First Pass Findings

| # | Severity | Finding | File:Line | Resolution | Status |
|---|---|---|---|---|---|
| 1 | CRITICAL | Stale reconciliation comments: file header says "FED-OD-4 is NOT present in this worktree" and lists reconciliation TODOs that FED-OD-6b already completed. Additional stale "FED-OD-4 will..." clusters at lines 163-164, 182-183, 190-198 describe actions that either didn't happen as described or have already shipped. Comment-fidelity CLAUDE.md: stale comments are CRITICAL blocking findings. | `apps/Mootx01-App/Sources/GatewayUI/Federation/FederationSessionManagerProtocol.swift` lines 1-17, 163-164, 182-183, 190-198 | Rewrite four comment clusters to describe shipped state: (a) replace header with "FED-OD-6b completed reconciliation; FederationController holds a real FederationSessionManager via composition"; (b) update FederationSession.init comment to note 30-minute window is the F1 production value, not a placeholder; (c) update FederationSessionManaging doc to remove "stub implementation" language (FederationController is now the real conformer); (d) update KnownPeer.publicKeyData to remove reference to the removed "F1 test-peer path" | open |
| 2 | WARNING | FSM-1 inbox-delta assertion trivially true. No `push()` is called between `startSession` and `endSession`, so `transport.inboxCount(for: peerKey)` is 0 before and 0 after — the delta==0 assertion proves nothing about a racing push. The channel-close-first CODE is correct and `transport.isClosed` assertion is real. The race scenario is unverified by test. | `apps/Mootx01-App/Tests/MootGatewayTests/Federation/FederationSessionManagerTests.swift` lines 81-94 | Add FSM-1b: populate an outbox entry (write a below-ceiling row, trigger a push that queues an envelope) before calling `endSession()`, then assert the envelope is NOT in `transport.inboxCount`. This proves the channel-close-first ordering actually blocks a real competing push, not just that the flag is set. | open |
| 3 | WARNING | Missing BRRs: FED-OD-3 edited `Package.swift` (existing, pre-stream) and `apps/Mootx01-App/Package.swift`; FED-OD-5 edited `project.yml` (existing, pre-stream) and `QRPairingView.swift` (intra-stream); FED-OD-6 edited `ContentView.swift` (existing, pre-stream). All edits were purely additive with zero call-site blast radius. The blast-radius protocol was not followed: no BRR filed for any of these three missions. | `apps/Mootx01-App/Package.swift`, `apps/Mootx01-App/project.yml`, `apps/Mootx01-App/Sources/GatewayUI/ContentView.swift` | File retroactive BRRs for FED-OD-3, FED-OD-5, and FED-OD-6 documenting the additive-only nature of each pre-existing file edit and confirming blast radius is zero. | open |
| 4 | INFO | `LANRelayIdentityFactory.makeEphemeralIdentity` throws `notImplemented`. Production NW transport cannot complete TLS handshakes until keychain-backed SecIdentity generation ships. Tracked in TRACKED_FOLLOWUPS as "FED | LANRelay production TLS identity". Documented F1 planned gap — the verify/fingerprint path is done and unit-tested. | `packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/Relay/LANRelayTLSConfig.swift:makeEphemeralIdentity` | No action before merge — tracked. Assign a platform mission for PKCS12/temporary-keychain SecIdentity generation. | tracked |
| 5 | INFO | `FederationSessionError` name collision: both `GatewayUI` and `MootGateway` export this name. Swift 6 requires explicit module qualification in catch clauses where both are imported. Tracked in TRACKED_FOLLOWUPS as a small cleanup item. | `GatewayUI/FederationSessionManagerProtocol.swift` + `MootGateway/FederationSessionManager.swift` | No action before merge — tracked. Future cleanup: rename one (e.g. `FederationUIError` in `GatewayUI`). | tracked |
| 6 | INFO | Kit test count discrepancy: FED-OD-7 completion report claims 236 tests in ConvergenceKitFederationTests after adding `conformanceSurfaceCompiles`; Adams re-run shows 235 consistently. The `conformanceSurfaceCompiles` test compiles and passes when filtered directly (exit 0, 1 test in 1 suite). Likely cause: the "before FED-OD-7" baseline count in the completion report was 234 (not 235), making the +1 addition yield 235, not 236. Non-blocking — test exists and passes. | `packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/LAN/LANFederationConformanceTests.swift` | No action required. The test runs. The completion report's before-count was off by 1. | closed |

---

## Blast Radius Verification

- Files claimed in diff: 38 (via git diff --name-only c208d889..c9525caa)
- Files actually in diff: 38
- BRRs filed: FED-OD-1 (FED_OD_1_BLAST_RADIUS.md), FED-OD-4 (FED_OD_4_BLAST_RADIUS.md)
- BRRs missing: FED-OD-3, FED-OD-5, FED-OD-6 (see Finding #3 — additive edits, zero call-site blast radius)
- MUST_UPDATE files from filed BRRs:
  - FED-OD-1: `project.yml` NSLocalNetworkUsageDescription + NSBonjourServices — PRESENT in diff (b5769f6f)
  - FED-OD-4: `LANRelay.swift` closeChannel(), `SyncController.swift` federationSessionManager cascade, `GatewayRuntime.swift` federationSession() — ALL PRESENT in diff (4b1768fb)
- MUST_UPDATE files missing from diff: none (all filed MUST_UPDATEs addressed)
- Prohibited patterns: none found. No bridges, shims, orphan @available(*, deprecated), or TODO/FIXME on changed symbols in production code.
- INTENTIONALLY_LEFT justifications: none claimed in filed BRRs.

---

## Test Execution Verification

Method: **B (re-run)** — mission changes engine code (SyncController.disable cascade, LANRelay.closeChannel, SensitivityFilteredStorage wiring) plus data-model fields (KnownPeer.publicKeyData, FederationStateActor identity path).

| Suite | Bilby's claim | Adams re-run | Status |
|---|---|---|---|
| ConvergenceKitFederationTests | exit 0, 235 tests (FED-OD-4 BRR baseline) | exit 0, 235 in 45 suites | PASS |
| MootGatewayTests | exit 0, 134 (FED-OD-7 report) + 5 (FED-OD-5 UWB, merged after FED-OD-7) | exit 0, 139 in 26 suites | PASS |
| GatewayUITests | exit 0, 25 tests (FED-OD-6b report) | exit 0, 25 in 5 suites | PASS |

Note on MootGatewayTests count: FED-OD-7's completion report stated 134 tests. The delta from FED-OD-7 baseline to 139 is the 5 UWBProximityPairing tests added by FED-OD-5, which merged into develop/1.1.x AFTER FED-OD-7 completed in its parallel worktree. The completion report was accurate at the time it was written; the higher count reflects the merged state on develop/1.1.x.

---

## Session-End Determinism Verdict

**Code: CORRECT. Tests: under-powered on the race scenario.**

`FederationSessionManager.endSession()` executes:
1. `lanRelay?.closeChannel()` — closes transport, subsequent sends throw `peerUnreachable`
2. `try await engine?.disable()` — cancels observer tasks, stops outbox writes

Channel-close-first ordering is present in shipped code. A racing `push()` after step 1 but before step 2 would hit the closed transport and retain the outbox entry rather than delivering it.

FSM-1 verifies `transport.isClosed == true` after `endSession()` — this assertion is real and meaningful.

FSM-1 also asserts `inboxCount(for: peerKey) == depthBefore`. This assertion is trivially true because no push is called between `startSession` and `endSession` in the test. The depth is 0 before and 0 after. This does NOT prove that a push racing at session end would be blocked. See Warning #2.

Row 2 of the conformance map is satisfied by the code mechanism. The test gap is advisory, not a production correctness problem.

---

## Eight Verification Tasks — Summary

| Task | Result |
|---|---|
| 1. Test counts + exits | ConvergenceKit 235/exit-0, MootGatewayTests 139/exit-0, GatewayUITests 25/exit-0. All re-verified by Adams. |
| 2. Session-end determinism | Code correct (channel-close-first). FSM-1 proves isClosed. Inbox-delta assertion trivially zero (Warning #2). |
| 3. Row 3 non-vacuous | FSM-8 positive control asserts `receipt.pushed > 0` AND `inboxCount > 0`. FSM-7's zero-count is not vacuous. |
| 4. UWB no-crypto-fork | Zero key material in `UWBProximityPairing.swift`. All crypto unchanged in `QRPairingCoordinator`. Hardware gate: `NISession.deviceCapabilities.supportsDeviceInitiation` checked before and inside `exchangeNIToken()`. |
| 5. Secret-no-UI + placeholder removal | `FederationPosture.sealed` absent by construction. No secret reference in interactive UI controls. `Data(count: 32)` replaced with `localIdentity?.publicKey` + fallback (intentional graceful degradation, documented in FED-OD-6b). "Add as Test Peer" placeholder fully removed. |
| 6. TXT no-content invariant | `txtRecordHasExactlyFourKeys` asserts `Set(record.encode().keys) == Set(["fp","n","v","p"])`. `fingerprintDerivedFromKeyNotContent` asserts `fp == lanFingerprintFromPublicKey(publicKey)`, not content bytes. Non-vacuous. |
| 7. F1 invariant line | No per-scope key minting, no `_grants` table, no tell-record writes, no always-on key, no clawback, no private-share prompt, no non-Balanced functional posture. Grep confirms zero hits for each. |
| 8. Hygiene | Zero conflict markers. No machine paths in new docs. Two tracked gaps (TLS identity, name collision) documented in TRACKED_FOLLOWUPS with clear next-mission assignments. Conformance map rows name real, passing tests. |

---

## What Blocks PASS

Finding #1 (CRITICAL). The stale comment cluster in
`FederationSessionManagerProtocol.swift` tells any future agent reading
the file that FED-OD-4 has not shipped and that reconciliation remains
ahead. It has shipped. Reconciliation is complete. The file contradicts
the codebase it describes.

Bilby fixes Finding #1. Adams re-checks on the follow-up commit.
Warnings #2 and #3 are addressed at Bilby's discretion (both are
resolvable post-merge if deferred with documentation).
