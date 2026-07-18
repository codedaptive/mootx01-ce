---
version: v0.1
---

# COMPLETION: FED-OD-6b

Status: COMPLETE

## What Was Done

- Part 1 (Identity): Replaced `Data(count: 32)` zero-byte advertising key with real estate
  Ed25519 public key. `FederationController.bootstrapFromEstate()` probes via `FederationSyncEngine`
  (empty manifest, enable/read/disable) to load or mint `LocalIdentity`. `startDiscovery()` uses
  `localIdentity?.publicKey ?? Data(count: 32)` so tests without an estate get a harmless fallback.
  — commit 76ae1963

- Part 2 (Pair path): Removed "Add as Test Peer" placeholder. `FederationPanelView.pairingSheet`
  now presents real `QRPairingView(role: .proposer)`. `QRPairingView` gained a `@State private var
  remotePeerPublicKey: Data?` that captures `identityPublicKey` from `QRAcceptorPayload`. The
  `onComplete` closure type changed to `(SASConfirmation, Data) async throws -> Void` so the peer
  public key is available at confirmation time. `FederationController.completePairing` calls
  `lanFingerprintFromPublicKey` for the peer id and persists via `registerPairedPeer`.
  — commit 76ae1963

- Part 3 (Peers list): `FederationSessionManager` gained four new public methods:
  `estateIdentity()`, `registerPairedPeer(publicKey:family:)`, `loadPairedPeers()`,
  `removePairedPeer(publicKey:)`. All probe via the identity-engine pattern and operate on
  `_fed_peers` rows. `KnownPeer` struct gained `publicKeyData: Data?`. `FederationController.init()`
  runs `bootstrapFromEstate()` async task that merges `_fed_peers` rows into the in-memory list
  (display names from UserDefaults cache, membership authority from estate). `unpair(_:)` deletes
  the real row when `peer.publicKeyData != nil`. UserDefaults key bumped from
  `federation.knownPeers.f1` to `federation.knownPeers.f1b` (new KnownPeer format with
  `publicKeyData`).
  — commit 76ae1963

- Part 4 (Session lifecycle): `startSession(peer:posture:)` delegates to real
  `FederationSessionManager` when `peer.publicKeyData != nil`, using `MootGateway.FederationPosture.balanced`
  and `MootEstateSyncManifest.standard()`. `endSession()` calls `manager.endSession()` then
  `try? await manager.reset()` so the manager is ready for the next session. Both still update
  in-memory `activeSession` / `lastSession` for UI binding.
  — commit 76ae1963

- Part 5 (Preservation): All 25 GatewayUITests pass (exit 0). Localization, a11y, Balanced-only-
  functional, secret-no-UI, and locked-card invariants retained. Session lifecycle tests updated to
  use `FederationController(sessionManager:)` (new `#if DEBUG` init), `MootBridge.attachInMemory()`,
  and `FakeLANRelayLoopbackTransport` instead of the old stub paths. Swift 6 catch clause ambiguity
  (`GatewayUI.FederationSessionError` vs `MootGateway.FederationSessionError`) resolved via explicit
  module qualification.
  — commit 76ae1963

- Part 6 (Camera seam): QR code scanning (camera + CoreImage decode) stays behind
  `QRPairingView`/`QRPairingCoordinator`. The seam is clean — tests bypass it via
  `FakeLANRelayLoopbackTransport`. No additional device-hardware gap exists in this commit.
  — commit 76ae1963

## Test Verification Log

- swift build (GatewayUI + MootGateway): exit 0 (verified 2026-07-18)
- swift test --filter GatewayUITests: exit 0, 25 tests in 5 suites, all passing (verified 2026-07-18)
- Baseline: 25 tests before mission; 25 after — delta unchanged (tests updated to assert real wiring)

## Placeholders Removed → What They Now Call

| Placeholder | Now calls |
|---|---|
| `Data(count: 32)` zero-byte advertising key | `localIdentity?.publicKey` via `FederationSyncEngine` probe |
| "Add as Test Peer" button / placeholder sheet | `QRPairingView(role: .proposer)` with real `onComplete(SASConfirmation, Data)` |
| `knownPeers` loaded from UserDefaults only | Hybrid: `_fed_peers` for membership, UserDefaults for display names / lastSession |
| `unpair` no-ops on estate | `manager.removePairedPeer(publicKey:)` deletes real row |
| `startSession` local stub | `manager.startSession(peer:posture:scope:)` with balanced posture + standard manifest |
| `endSession` local stub | `manager.endSession()` + `manager.reset()` |

## Genuinely Unwireable Gaps (P6 note)

None. Camera/CoreImage QR scanning is behind the `QRPairingView` seam and does not require new
code in this mission. Unit tests drive the state machine via `FakeLANRelayLoopbackTransport`.

## Discoveries

- `FederationSessionError` name collision: both `GatewayUI` and `MootGateway` export this name.
  Swift 6 catch clauses require explicit module qualification (`GatewayUI.FederationSessionError`)
  when both are imported. `MootGateway.FederationSessionError` is `Equatable`; `GatewayUI`'s is not
  (has associated value `postureNotFunctionalInF1(FederationPosture)`). If the `GatewayUI` variant
  gains an `Equatable` conformance in future, the test qualification can be simplified.

- Swift 6 beta catch-pattern restriction: `catch EnumType.caseWithAssociatedValue(let x)` now
  requires `_ErrorCodeProtocol` conformance. Non-Foundation error enums must use
  `catch let e as EnumType { if case .theCase(let x) = e { ... } }` pattern instead. This is a
  permanent Swift 6 syntax constraint, not a beta artifact.

- `FederationSyncEngine` probe is the correct access path for identity outside an active session.
  `FederationStateActor.loadOrMintIdentity()` is `internal`, so the probe pattern (init with
  `tables:[]`, call `enable()`, read `engine.identity`, call `disable()`) is the public contract.
  Both `estateIdentity()` and `registerPairedPeer()` on `FederationSessionManager` use this pattern.

## Outstanding

- Display name input: `completePairing` currently uses the LAN fingerprint as display name
  (matching prior stub behavior). A future mission could add a naming step to the QR ceremony UI.
- `_fed_peers` display names: estate has no display_name column by design (names are local-only
  context). The hybrid UserDefaults cache approach is load-bearing for display continuity.
