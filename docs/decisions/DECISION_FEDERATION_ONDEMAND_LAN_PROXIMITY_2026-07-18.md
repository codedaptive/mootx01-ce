---
status: accepted
question: How do estates discover each other on a LAN, pair by proximity on iOS, and federate on demand — and what interface does the end user drive?
authors: MOOTx01 maintainers
date: 2026-07-18
relates_to:
  - docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md
  - docs/decisions/DECISION_SYNCKIT_DESIGN_2026-05-19.md
  - docs/reference/FEDERATION_SYNCSERVER_WIRE_PROTOCOL.md
  - docs/reference/CONVERGENCEKIT_SPEC.md
  - docs/analysis/CVK_WAVEC_FEDERATION_CHARTER.md
supersedes: none
context:
  - Wave C shipped the Federation transport spine (persistent Ed25519 identity, signed pairing handshake, persistent peers, durable outbox, Relay abstraction with an HTTPS conformer) but no local discovery, no proximity ceremony, and no user surface.
  - The sharing model (2026-05-21) defines the disclosure doctrine this must serve — grants, key lifetimes, custody modes, the risk chooser — decided on paper, not yet code.
  - Third-party iOS apps cannot use phone-to-phone NFC or NameDrop; the proximity ceremony must be built from MultipeerConnectivity, NearbyInteraction (UWB), and QR.
---

# Decision: On-Demand Federation — LAN Discovery, Proximity Pairing, User Surface

Accepted by Bob 2026-07-18 ("continue as proposed"). Recommendations
adopted: QR-first ceremony with UWB enhancement; Balanced as default
posture; Phase F1 spans own machines plus explicitly paired peers.

## 1. LAN discovery

Bonjour/mDNS, service type `_mootx01-fed._tcp`. TXT record carries ONLY:
short fingerprint of the estate public key, user-chosen display name,
protocol version, relay port. No estate content in discovery, ever.
Discovery never implies trust — the signed pairing handshake (WC6) still
gates everything.

Discoverability is OFF by default, three positions (AirDrop-style):
**Off / While app is open / Always** (Always meaningful only for the Mac
resident). Default-closed applies to presence itself.

## 2. LANRelay — third Relay conformer

Same `Relay` contract as the in-process and Hosted relays, over a direct
TLS connection whose channel is bound to the Ed25519 estate identities
(certificate pinned to the pairing identity — a LAN MITM cannot splice).
MUST pass the shared `RelayConformanceTests` fixture: three conformers,
one contract. The entire shipped sync stack (durable `_fed_outbox`, skew
queue, tombstones, provenance) runs over it unchanged.

## 3. Proximity pairing ceremony ("touch the tips")

Platform truth: third-party iOS apps get no phone-to-phone NFC and no
NameDrop. The ceremony is therefore:

- **QR ceremony (primary, ships everywhere):** device A displays a QR
  carrying its public key + session nonce; B scans; a reverse
  confirmation code closes the loop.
- **UWB enhancement (capable devices):** MultipeerConnectivity for
  nearby detection + NearbyInteraction ranging; with both pairing
  screens open and devices within ~10 cm, the exchange fires
  automatically.
- Either path runs a **fresh ephemeral X25519 exchange bound to the WC6
  PairingProposal/Acceptance**, both private halves discarded after —
  the sharing model's contact-derived handshake and its out-of-band
  MITM defense.
- Both screens render the **same short-authentication-string pattern**
  (color/emoji derived from the transcript); both users confirm.
  Proximity + code-compare, the two closers §2 of the sharing model
  names.

This ceremony is the future mechanical basis for the In-person preset.

## 4. The Federation Session (federating on demand)

The unit of on-demand federation: a user-initiated, time-boxed window —
discover → pair or recognize → choose posture + scope → live window →
end → keys die. A session is precisely a grant with `lifetime =
singleSession`, `channel = lanDirect | proximity`, `custody mode 1
(mediated)` per the sharing model's resolved v1.0 default. Session end
removes the grant; the peer's next read fails.

### Phasing (honest about what exists)

- **F1 — session plumbing:** mDNS discovery + LANRelay + QR ceremony +
  session lifecycle (enable Federation for the window, disable at end);
  scope at manifest granularity; protected by the shipped sensitivity
  ceiling (secret/restricted structurally never cross — the P5-M1
  wrapper pattern). Own machines + explicitly paired peers.
- **F2 — cryptographic spine:** grants as signed rows, per-scope keys,
  sign-then-encrypt-to-scope, the tell record, the §5 private-share
  prompt with mandatory expiry, clawback. Scope narrows to
  wing/room/row; disclosure becomes key-lifetime-enforced.
- **F3 — full chooser:** content-axis levels (fact/field/posture/
  existence), inference budget, re-share-with-audit, In-person preset
  riding the proximity ceremony, UWB polish.

## 5. User interface

A Federation panel in moot-mgr (Mac) and Mootx01-App (iOS), driving the
resident as the sync toggle precedent does:

- **Visibility** — Off / While open / Always.
- **Nearby** — discovered estates; verified badge when already paired;
  Pair launches the ceremony (QR everywhere, UWB where capable).
- **Peers** — `_fed_peers`: per-peer posture, scope summary, last
  session, Unpair. Tell-record viewer + clawback arrive with F2.
- **Start Session** — peer → posture card → scope → live banner with
  countdown, plain what's-crossing indicator, prominent End Session.
- **Posture cards** are the sharing model's §11 presets in plain
  language; default **Balanced**. F1 ships the honorable subset;
  unbuilt postures render visibly locked, never silently fake.
- **Private-share prompt** (§5 of the sharing model) as a system-style
  dialog — affirmative act, mandatory expiry, never auto-disclose.
- **Secret has no UI.** No control ever offers a secret row — absence
  by construction, mirroring "no key is ever minted."

## 6. Conformance

Six negative conformance rows. Each is satisfied by the named test.
See `docs/status/FED_OD_CONFORMANCE.md` for the full mapping.

- **Row 1 — TXT no-content-bytes.** Discovery TXT record contains no
  content-derived bytes (fingerprint only).
  Tests: `LANDiscoveryTXTNegativeTests.txtRecordHasExactlyFourKeys`,
  `LANDiscoveryTXTNegativeTests.fingerprintDerivedFromKeyNotContent`
  (`ConvergenceKitFederationTests/LAN/LANDiscoveryTests.swift`).

- **Row 2 — Session-end determinism.** No outbound entry created after
  End Session lands in any relay.
  Test: `FederationSessionManagerTests.sessionEndDeterminism` (FSM-1)
  (`MootGatewayTests/Federation/FederationSessionManagerTests.swift`).

- **Row 3 — Ceiling holds on LANRelay.** Above-ceiling rows never reach
  a LANRelay inbox.
  Tests: `LANCeilingConformanceTests.restrictedRowNeverReachesLANRelayInbox`
  (FSM-7, negative) and `LANCeilingConformanceTests.normalRowReachesLANRelayInbox`
  (FSM-8, positive control)
  (`MootGatewayTests/Federation/FederationSessionManagerTests.swift`).
  Added by FED-OD-7.

- **Row 4 — SAS mismatch refusal.** Pairing over LANRelay refuses on SAS mismatch.
  Test: `QRPairingCoordinatorTests.sasMismatchNoPersistedPeer` (QR-2)
  (`MootGatewayTests/Federation/QRPairingCoordinatorTests.swift`).

- **Row 5 — Tampered proposal refusal.** Pairing refuses on tampered proposal.
  Tests: `QRPairingCoordinatorTests.tamperedProposalSignatureRejected` (QR-3)
  (`MootGatewayTests/Federation/QRPairingCoordinatorTests.swift`);
  `FederationPairingTests.tamperedProposalRejected`
  (`ConvergenceKitFederationTests/FederationPairingTests.swift`).

- **Row 6 — TLS refused on unknown key.** LANRelay passes RelayConformanceTests
  unmodified.
  Test: `LANRelayConformanceTests.tlsRefusedOnUnknownKey` (Suite 3)
  (`ConvergenceKitFederationTests/Relay/RelayConformanceTests.swift`).
