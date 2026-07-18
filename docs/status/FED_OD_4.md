---
task: FED-OD-4
title: Federation Session Lifecycle — on-demand window
status: COMPLETE
agent: Bilby
stream: worktree-agent-a258a9d55a228cc7d
date: 2026-07-18
---

# COMPLETION: FED-OD-4

## Status: COMPLETE

## What Was Done

**Base merge (commit 5936390f)**
Merged FED-OD-3 base (5dbe509b) into the stream. Terrain verified:
- `rg 'LANRelay' packages/kits/ConvergenceKit/Sources` — hits confirmed
- `apps/Mootx01-App/Sources/MootGateway/Sync/SensitivityFilteredStorage.swift` — exists

**Blast Radius Report (commit 1396114a)**
Documented full blast radius at `docs/analysis/blast_radius/FED_OD_4_BLAST_RADIUS.md`.
Tier 1 (primitive-touching ≤5 edits): 3 existing files edited, 2 new files.
RESCOPE_REQUIRED: 0. F1 invariant line documented.

**Implementation commits** (final commit — see commit hash below):
1. `LANRelay.swift` — Added `close()` to `LANRelayTransport` protocol with default no-op
   extension. Added `closeChannel()` to `LANRelay` with full session-end ordering rationale.
2. `FederationSessionManager.swift` (NEW) — The app federation layer. Contains:
   - `FederationPosture` enum (balanced + F2/F3 stubs, all non-balanced throw in F1)
   - `FederationSessionError: Error, Sendable, Equatable` — session lifecycle errors
   - `FederationSessionState` — idle / active / ended state machine
   - `FederationSessionManager` actor — startSession / endSession / push / pull / reset
   - `FakeLANRelayLoopbackTransport` — F1 in-process placeholder (until NW transport ships)
3. `SyncController.swift` — Added `federationSessionManager` field and cascade to
   `disable()` via `try? await federationSessionManager?.endSession()`
4. `GatewayRuntime.swift` — Added `federationSession()` accessor (lazy, backed by estate bridge)
5. `FederationSessionManagerTests.swift` (NEW) — 6 tests covering the full FSM matrix

## Session-End Ordering as Shipped

```swift
// FederationSessionManager.endSession() — the load-bearing invariant:
lanRelay?.closeChannel()    // Step 1: close channel — subsequent sends throw
try await engine?.disable() // Step 2: disable engine — cancel observers, stop writes
```

`LANRelay.closeChannel()` calls `transport.close()`, which sets the closed flag on the
transport. Any subsequent `relay.send()` call (e.g. from a racing push()) hits the closed
transport and throws `SyncError.peerUnreachable`. The engine's push cycle retains the
outbox entry rather than delivering it. `engine.disable()` then cancels observer tasks.

This ordering eliminates the race: if we disabled first, a racing push() could drain
the outbox into the still-open channel between disable and close.

## F1 Invariant Line — What Was NOT Built

Per Kong's must-not-ship list and the FED-OD charter §V5:
- NO per-scope key minting or distribution
- NO tell-record log entries (no grant ID to log against — F2 ships `_grants`)
- NO always-on mode or durable key handoff
- NO re-share controls (even UI-only)
- NO cryptographic clawback
- NO private-share prompt
- NO postures other than Balanced functional (all 5 other postures throw `.postureUnavailable`)
- Ceiling-only enforcement: `SensitivityFilteredStorage` at `.elevated` ceiling

## Determinism Test Shape (FSM-1 — the gate test)

```
// FSM-1: Session-end determinism
let transport = ClosableInMemoryTransport()
let manager = FederationSessionManager(bridge: bridge, transport: transport)
try await manager.startSession(peer: peerKey, posture: .balanced, scope: manifest)
let depthBefore = transport.inboxCount(for: peerKey)
try await manager.endSession()
#expect(transport.isClosed)
#expect(transport.inboxCount(for: peerKey) == depthBefore)
#expect(await manager.sessionState == .ended)
```

The `ClosableInMemoryTransport.close()` sets `_isClosed = true`; subsequent `send()` throws
`SyncError.peerUnreachable`. The depth assertion proves no envelopes were delivered after
the channel was closed (channel-close-first ordering confirmed).

## Test Names

| Test ID | Name | Shape |
|---|---|---|
| FSM-1 | session-end determinism — channel closed before engine disabled, no post-session delivery | Gate test for channel-close-first ordering |
| FSM-2 | ceiling holds across session — SensitivityFilteredStorage wired at .elevated | Structural wiring verification |
| FSM-3 | start → sync → end round-trip — two in-process fixtures over shared transport | Full session plumbing round-trip |
| FSM-4 | disable teardown deterministic — no push after end, double-end throws | Idempotency and error path |
| FSM-5 | F1 invariant line — non-Balanced postures throw postureUnavailable | F1 scope gate |
| FSM-6 | session state machine — idle → active → ended → reset → idle | State machine completeness |

## Test Verification Log

- `swift build --target MootGateway`: exit 0 (incremental, no errors)
- `swift test --filter FederationSessionManagerTests`: exit 0, 6 tests, all passing
- App `swift test` (full): exit 0, 132 MootGatewayTests + 13 GatewayUITests = 145 total
  (baseline 139, delta +6 new FSM tests)
- Kit `swift test` (full): exit 0, 235 tests (baseline 235, unchanged)
- Total: 380 tests passing (baseline 374, delta +6)

## Discoveries

- `FederationSessionError: Equatable` must be declared in the same file as the enum for
  Swift to synthesize `==`. An extension-based conformance outside the file fails compilation
  ("prevents automatic synthesis"). Fixed by adding `Equatable` to the declaration in
  `FederationSessionManager.swift` — appropriate for a public error type.
- `FederationSessionManager.reset()` is a synchronous actor method; Swift 6 requires
  `await` from outside the actor isolation domain. Fixed in tests: `try await manager.reset()`.
- `SyncError.peerUnreachable(identity: String)` — the `identity` label is required in
  `ClosableInMemoryTransport.send()` throw. Confirmed from `SyncTypes.swift`.

## Outstanding

- `LANRelayNWTransport` (real NW.framework TLS transport) ships in a later mission;
  `FakeLANRelayLoopbackTransport` serves as the F1 in-process placeholder.
- No per-scope key minting or grant table — that is F2 (FED-OD-8).
- The `docs/reference/CONVERGENCEKIT_INTERFACE.md` may need a note about `closeChannel()`
  on `LANRelay` — Nagatha should audit at next sweep.
