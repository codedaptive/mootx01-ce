---
title: F1 Federation On-Demand Conformance Map
version: v0.2
mission: FED-OD-7 + FED-OD-F1FIX
decision_doc: DECISION_FEDERATION_ONDEMAND_LAN_PROXIMITY_2026-07-18
updated: 2026-07-18
---

# F1 Federation On-Demand Conformance Map

Six conformance rows from decision doc §6
(`DECISION_FEDERATION_ONDEMAND_LAN_PROXIMITY_2026-07-18`).
Each row names the exact test function(s) that satisfy it, the file, and
whether the test pre-existed or was added by FED-OD-7.

---

## Row 1 — TXT no-content-bytes

**Row text:** "Discovery TXT record contains no content-derived bytes
(negative test: fingerprint only)."

**Status:** COVERED — existing tests from FED-OD-1.

| Test function | File | Suite |
|---|---|---|
| `txtRecordHasExactlyFourKeys` | `LAN/LANDiscoveryTests.swift` | `LANDiscoveryTXTNegativeTests` |
| `fingerprintDerivedFromKeyNotContent` | `LAN/LANDiscoveryTests.swift` | `LANDiscoveryTXTNegativeTests` |
| `startDiscoveryAdvertisesCorrectTXTRecord` | `LAN/LANDiscoveryTests.swift` | `LANDiscoveryLifecycleTests` |

Target: `ConvergenceKitFederationTests`

---

## Row 2 — Session-end determinism

**Row text:** "Session end is deterministic: no outbound entry created after
End Session lands in any relay (extends I-2/I-10 style tests)."

**Status:** COVERED — FSM-1 (channel-close gate) + FSM-1b (non-vacuous delivery proof).
FSM-1b added by FED-OD-F1FIX (Adams review finding #2).

| Test function | File | Suite |
|---|---|---|
| `sessionEndDeterminism` (FSM-1) | `MootGatewayTests/Federation/FederationSessionManagerTests.swift` | `FederationSessionManagerTests` |
| `sessionEndDeterminismNonVacuous` (FSM-1b) | `MootGatewayTests/Federation/FederationSessionManagerTests.swift` | `FederationSessionManagerTests` |

FSM-1 asserts `transport.isClosed` after `endSession()` AND that the inbox
depth delta is zero. The delta assertion in FSM-1 is trivially zero because no
push() is called in that test.

FSM-1b makes the row non-vacuous: it inserts a below-ceiling row (queuing a real
`_fed_outbox` entry), then applies `closeChannel()` before `push()`. The closed
transport causes `push()` to receive `peerUnreachable` → `receipt.pushed == 0` →
`inboxCount(for: bKey) == 0`. This proves the channel-close-first ordering in
`FederationSessionManager.endSession()` actually prevents post-session delivery,
not just that the closed flag is set with an empty outbox.

Target: `MootGatewayTests`

---

## Row 3 — Ceiling holds on LANRelay

**Row text:** "Ceiling holds across sessions: above-ceiling rows never reach
a LANRelay inbox (extends the P5-M1 gate tests to the new transport)."

**Status:** NEW — tests FSM-7 and FSM-8 added by FED-OD-7.

| Test function | File | Suite |
|---|---|---|
| `restrictedRowNeverReachesLANRelayInbox` (FSM-7) | `MootGatewayTests/Federation/FederationSessionManagerTests.swift` | `LANCeilingConformanceTests` |
| `normalRowReachesLANRelayInbox` (FSM-8) | `MootGatewayTests/Federation/FederationSessionManagerTests.swift` | `LANCeilingConformanceTests` |

FSM-7 inserts a row with `adjective_bitmap = Int64(32) << 6` (= 2048,
sensitivity raw=32, above the `.elevated`=16 ceiling), and asserts:
- `receipt.pushed == 0` — outbox is empty after push
- `transport.inboxCount(for: bKey) == 0` — nothing reached the LANRelay inbox

FSM-8 is the positive control: `adjective_bitmap = 0` (normal sensitivity)
asserts `receipt.pushed > 0` and `inboxCount > 0` — proves the
infrastructure is live and the suppression in FSM-7 is real.

Note on placement: `SensitivityFilteredStorage` is a MootGateway-layer type;
`ConvergenceKitFederationTests` cannot depend on it. The ceiling tests
live in `MootGatewayTests` which depends on both `ConvergenceKitFederation`
and `MootGateway`.

Target: `MootGatewayTests`

---

## Row 4 — SAS mismatch refusal

**Row text:** "Pairing over LANRelay refuses on SAS mismatch..."

**Status:** COVERED — existing test QR-2 from FED-OD-3.

| Test function | File | Suite |
|---|---|---|
| `sasMismatchNoPersistedPeer` (QR-2) | `MootGatewayTests/Federation/QRPairingCoordinatorTests.swift` | `QRPairingCoordinatorTests` |

QR-2 simulates a MITM by tampering the ephemeral key so that SAS values
diverge (`sasA ≠ sasB`). It asserts `_fed_peers` remains empty on both
sides — `confirmSAS()` is never called, so no peer is persisted.

Target: `MootGatewayTests`

---

## Row 5 — Tampered proposal refusal

**Row text:** "...and on tampered proposal (extends the WC6 negative tests
to the new channel)."

**Status:** COVERED — existing tests QR-3 (FED-OD-3) and WC6 engine-level gate.

| Test function | File | Suite |
|---|---|---|
| `tamperedProposalSignatureRejected` (QR-3) | `MootGatewayTests/Federation/QRPairingCoordinatorTests.swift` | `QRPairingCoordinatorTests` |
| `tamperedProposalRejected` | `ConvergenceKitFederationTests/FederationPairingTests.swift` | `FederationPairingTests` |

QR-3 asserts `PairingError.authenticationFailed` when `proposalSignature`
is tampered, and that `_fed_peers` remains empty.
`tamperedProposalRejected` covers the engine-level gate
(`SyncError.authenticationFailed`).

Targets: `MootGatewayTests`, `ConvergenceKitFederationTests`

---

## Row 6 — TLS refused on unknown key

**Row text:** "LANRelay passes RelayConformanceTests unmodified."
(Row 6 is the LANRelay-specific TLS identity-pinning negative test.)

**Status:** COVERED — existing test from FED-OD-2 Suite 3.

| Test function | File | Suite |
|---|---|---|
| `tlsRefusedOnUnknownKey` | `Relay/RelayConformanceTests.swift` | `LANRelayConformanceTests` (Suite 3) |

`FakeLANRelayTransport(knownPeers: [knownKey])` simulates the production
NWParameters custom TLS verifier. A `send()` targeting a key not in
`knownPeers` throws `SyncError.peerUnreachable` — proving that LANRelay
does not deliver to unknown keys.

Target: `ConvergenceKitFederationTests`

---

## Aggregator

`LANFederationConformanceTests.conformanceSurfaceCompiles`
(`ConvergenceKitFederationTests/LAN/LANFederationConformanceTests.swift`)

Single smoke-check test that:
- Exercises `LANFederationTXTRecord.encode()` type surface (Row 1)
- Calls `lanFingerprintFromPublicKey` and asserts 16-char output (Row 1)
- Constructs `FakeLANRelayTransport(knownPeers:)` + `LANRelay` (Row 6)
- Documents Rows 2-5 by reference (those types live in MootGateway, not ConvergenceKitFederation)

If this test fails to compile, an API the conformance suite depends on has
drifted — update the references in this table and amend the §6 decision doc.
