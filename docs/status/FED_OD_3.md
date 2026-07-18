---
version: v0.1
---

# COMPLETION: FED-OD-3

**Status:** COMPLETE

**Commit:** `c429137e`

---

## What Was Done

**Part 1 — QRPairingCoordinator (actor):** State machine for the
proposer/acceptor ceremony. `startAsProposer(identity:family:)` generates
the `QRPairingPayload` (identity pubkey + 16-byte session nonce + ephemeral
X25519 pubkey + Ed25519 proposal signature). `startAsAcceptor(payload:identity:)`
verifies the proposer's signature and runs the ephemeral X25519 key agreement.
Both private halves are discarded immediately after `combineSharedSecret` is
called — the discard is commented in-line as the no-durable-opener boundary.
`processAcceptorPayload(_:)` handles the proposer side's key agreement after
receiving B's `QRAcceptorPayload`.

**Part 2 — SAS derivation:** `SASDeriver.derive(sessionNonce:sharedEphemeralSecret:proposalSigningBytes:acceptorIdentityPublicKey:)`
is a pure, stateless function. Input: 8 bytes from HKDF-SHA256 keyed on the
shared ephemeral secret (salt=sessionNonce, info=proposalSigningBytes ‖
acceptorIdentityPublicKey). Output: 4 `SASEntry` values, each carrying an
`emojiIndex` (0..<16) and a `colorIndex` (0..<8). Tested deterministic via
QR-6 with fixed inputs.

**Part 3 — confirmSAS() gate:** `confirmSAS()` transitions the actor to
`.done` and returns a `SASConfirmation` holding `family`, optional `proposal`,
and optional `proposerSignature`. The coordinator never calls
`engine.acceptPairingProposal()` or `engine.pair()` internally — it returns
the material and the CALLER performs the `_fed_peers` write after the user
taps Confirm. Gate verified in QR-1: `fedPeersCount == 0` asserted before
`confirmSAS()` + `pair()`, then `== 1` on each side after.

**Part 4 — QRPairingCodec:** JSON encode/decode for `QRPairingPayload` and
`QRAcceptorPayload`. `decode(_:)` enforces a 512-byte ceiling (reusing the
SyncValueBox depth-cap discipline), checks `version == currentVersion`, and
wraps any `DecodingError` as `PairingError.malformedPayload`. Acceptor codec
symmetrically tested via QR-5.

**Part 5 — Tampered-proposal path:** `startAsAcceptor` verifies the proposer's
Ed25519 signature over `proposalSigningBytes()` before any key material is
derived. Invalid signature → `PairingError.authenticationFailed`, state remains
`idle`, no `_fed_peers` write. Tested QR-3.

**Part 6 — Views:** `QRPairingView` (proposer QR display + acceptor scan
scaffolding; real `AVCaptureSession` integration deferred to app target per
comment). `SASConfirmationView` with 4-tile `SASPatternView`/`SASSymbolTile`,
full VoiceOver accessibility labels, and Confirm/Reject callbacks. iOS-only
`.navigationBarTitleDisplayMode` guarded with `#if os(iOS)`.

**Part 7 — Package.swift:** Added `ConvergenceKitFederation` product dep to
`MootGateway`, `GatewayUI`, and `MootGatewayTests` targets.

---

## Test Verification Log

```
swift build: exit 0
swift test:  exit 0, 139 tests (126 MootGatewayTests + 13 GatewayUITests),
             all passing (verified 2026-07-18)
Baseline:    132 before mission (per prior run trace); 139 after — delta +7
```

New tests (all in `QR Pairing Ceremony (FED-OD-3)` suite):
- QR-1: happy ceremony — matching SAS on both sides — peer persisted after confirmSAS
- QR-2: SAS mismatch (MITM simulation) — no _fed_peers write
- QR-3: tampered QR proposal signature — authenticationFailed + no _fed_peers write
- QR-4: ephemeral keys not retained after ceremony completion
- QR-5: QR codec round-trip and malformed payload rejection
- QR-6: SAS derivation is deterministic (pure function test)
- QR-7: coordinator state machine — confirmSAS requires SAS to be computed

---

## Ephemeral Binding Shape

```
QRPairingPayload {
    version: Int                    // currentVersion = 1
    identityPublicKey: Data         // 32-byte Ed25519 pubkey (proposer estate identity)
    sessionNonce: Data              // 16-byte random (ties the exchange to this session)
    ephemeralPublicKey: Data        // 32-byte X25519 pubkey (fresh per ceremony)
    proposedFamilySeed: UInt64
    proposedFamilyDimension: Int
    proposalSignature: Data         // Ed25519 sig over proposalSigningBytes()
                                    // = identityPubKey(32) + seed(8LE) + dim(4LE) + nonce
}
```

The ephemeral private key exists only inside the actor state during
`proposerWaiting`; discarded at the end of `processAcceptorPayload(_:)`.
Acceptor's private key is local to `startAsAcceptor` scope — never stored.

---

## SAS Derivation

```
ikm  = sharedEphemeralSecret (32 bytes, X25519 shared secret)
salt = sessionNonce (16 bytes)
info = proposalSigningBytes || acceptorIdentityPublicKey

derivedBytes = HKDF<SHA256>(ikm, salt, info, outputByteCount: 8)

entry[i].emojiIndex = derivedBytes[2i]   & 0x0F      // low 4 bits
entry[i].colorIndex = derivedBytes[2i+1] & 0x07      // low 3 bits
```

Output: 4 `SASEntry` values. Both devices compute identically iff no
ephemeral-key substitution occurred (MITM path → different shared secrets →
different SAS → user rejects).

---

## Rust Status

`federation.rs` has `pair()`. The QR ceremony coordinator is Apple-only for
F1 (Charter V7 verdict: "Apple-only for F1 is sound. Rust LANRelay is F2
scope explicitly."). Rust QR ceremony twin is **FED-OD-16**.

---

## Discoveries

- `FederationSyncEngine.identity` is an actor-isolated property — `await` is
  required from async test context even though Swift 6 warning may suppress
  "no async operations" for some call sites. No change needed; `await` is
  correct.

- `proposalSigningBytes()` covers `identityPublicKey + seed + dimension +
  nonce` — NOT the ephemeral key. This is intentional per the WC6 design:
  the signature authenticates the proposer's identity and family spec, while
  the ephemeral key is bound via the SAS (MITM cannot update the signature,
  but can be detected through SAS mismatch).

- The QR ceremony's `acceptorResponse` back-channel (B→A in a real device
  scenario) is a second QR code or a relay envelope (FED-OD-7 pairingAcceptance
  PayloadKind 0x11). In-process testing uses direct coordinator calls.

---

## Outstanding

- Real `AVCaptureSession` integration for `AcceptorQRScanView` deferred to
  app target (requires `UIKit`/`AVFoundation`; out of SwiftPM library scope).
- CoreImage QR code generation for `ProposerQRDisplayView` similarly deferred
  to app target.
- Relay-based proposer finalization (proposer receives B's envelope via relay
  and calls corresponding `engine` API) is WC7 territory — no public API
  exists yet for relay-mediated proposer completion.
- Rust twin (FED-OD-16) not yet dispatched.
