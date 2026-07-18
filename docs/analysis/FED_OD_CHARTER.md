---
title: On-Demand Federation Program Charter
version: v0.1
status: active
mission: FED-OD-0
reviewer: Kong
date: 2026-07-18
relates_to:
  - docs/decisions/DECISION_FEDERATION_ONDEMAND_LAN_PROXIMITY_2026-07-18.md
  - docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md
  - docs/reference/CONVERGENCEKIT_INTERFACE.md
  - docs/reference/FEDERATION_SYNCSERVER_WIRE_PROTOCOL.md
  - docs/analysis/CVK_WAVEC_FEDERATION_CHARTER.md
  - apps/Mootx01-App/Sources/MootGateway/Sync/SensitivityFilteredStorage.swift
---

# Kong Architecture Review: FED-OD-0
# On-Demand Federation Program Charter

## Assessment

The On-Demand Federation program extends the Wave C transport spine (persistent
Ed25519 identity, signed pairing, durable outbox, Relay abstraction) with three
new capabilities: LAN discovery via mDNS, a direct TLS LANRelay as the third Relay
conformer, and a user-initiated Federation Session that is the on-demand unit of
sharing. The program is explicitly phased: F1 is session plumbing (no cryptographic
grants, ceiling-protected by the P5-M1 SensitivityFilteredStorage pattern extended
to LANRelay); F2 is the cryptographic spine (signed grants, per-scope keys, tell
record, clawback); F3 is the full risk chooser (content-axis levels, inference
budget, In-person preset). The architecture is sound at the F1 level. The F1/F2
boundary is load-bearing and must be maintained with precision.

---

## 7 Verdict Assessments

### V1 — LANRelay and the Relay contract

**Verdict: Fits. No protocol mismatch; implementation pattern already established.**

The shipped Swift `Relay` contract is `send(to:message:) throws` and
`drain(for:) -> [SignedEnvelope]`. LANRelay is a LAN direct-connection (two-way,
both peers server+client, no central inbox). The apparent tension — "drain" implies
polling a remote inbox, but LAN is push-oriented — is not a contract violation. The
conformance fixture tests the abstract contract: send delivers an envelope, drain
returns it, second drain is empty. It does not test HOW the envelope reaches the
drain buffer.

**Smallest reconciliation**: LANRelay maintains a local receive buffer (type
`[Data: [SignedEnvelope]]` guarded by NSLock or equivalent actor), populated by a
background TCP listener task. `send(to:message:)` writes the envelope to the peer's
TCP socket. `drain(for:)` reads from the local buffer. This is structurally identical
to `FederationRelay`'s inbox dict extended across a TLS socket. The in-process
`FederationRelay` is already the template; LANRelay extends it with a network leg.

The Rust `Relay` trait shape (`register` → mpsc Receiver, `broadcast`, `send_to`) is
actually a better natural fit for LAN: `register` spins up a TCP listener per identity
and returns the receiver channel; `send_to` connects to the peer's TCP endpoint and
writes. The mpsc channel IS the local buffer. No mismatch on the Rust leg.

`RelayConformanceTests` runs unchanged for LANRelay as the third suite.

### V2 — Identity-bound TLS on LAN

**Verdict: Sufficient. Concrete mechanism is viable on both platforms.**

Both platforms cannot use Ed25519 directly as a TLS certificate key type. The
binding mechanism:

**Apple (Network.framework):** Each estate generates a self-signed P-256 certificate
(via SecKeyCreateRandomKey + SecCertificateCreateWithData or the CryptoKit P256
path) whose Subject Alternative Name (or a custom OID extension) carries the hex
fingerprint of the estate's Ed25519 public key. Both sides are configured with
`NWParameters.init(tls:tcp:)` using a custom `sec_protocol_options_set_verify_block`
that reads the peer's certificate, extracts the Ed25519 fingerprint, and verifies it
matches the peer in `_fed_peers`. A MITM cannot forge this without the peer's Ed25519
private key. The TLS channel's secrecy derives from P-256 ephemeral DH; the identity
binding derives from the Ed25519 fingerprint in the cert.

**Rust port (rustls):** Same mechanism, different API. rustls exposes
`ServerCertVerifier` and `ClientCertVerifier` traits. A custom verifier reads the
peer's DER certificate, extracts the custom OID extension, and checks the Ed25519
fingerprint against the known peer identity. Implementation uses `x509-cert` crate
for certificate construction and parsing.

**SAS timing**: The short-authentication-string confirmation sits BETWEEN the
ephemeral X25519 key exchange (WC6 PairingProposal/Acceptance transcript) and the
`_fed_peers` write. Sequence: (1) ephemeral X25519 exchange establishes session key;
(2) SAS is derived from the full transcript (both public keys + session key + nonce);
(3) both users confirm matching SAS; (4) only then are both sides written to
`_fed_peers` and the TLS cert generated. On subsequent reconnects the pinned
fingerprint is the MITM defense — no SAS needed. The SAS is the first-contact
guarantee; the pinned cert is the recurring-connection guarantee.

Self-signed cert pinned to estate key is sufficient provided (a) the SAS ceremony
is mandatory on first pairing and (b) the custom certificate verifier refuses
connections from keys not in `_fed_peers`. Both conditions are required.

### V3 — iOS proximity reality-check

**Verdict: QR-first is correct. Two App Store landmines require explicit attention.**

Confirmed prohibitions (verified against Apple developer docs):
- Phone-to-phone NFC for third-party apps: prohibited. Core NFC supports tag reading
  only. No P2P NFC API. Correctly excluded.
- NameDrop: not an API. No third-party access. Correctly excluded.

Confirmed availability (no exotic entitlements):
- MultipeerConnectivity: available, standard app submission. No special entitlement.
  Background operation requires the Bonjour background networking entitlement — F1
  requires active foreground only, so this is not needed.
- NearbyInteraction (UWB): available iOS 14+, U1/U3 chip devices (iPhone 11+).
  Requires `NSNearbyInteractionUsageDescription` in Info.plist only. No entitlement
  beyond the standard submission. Must gate on
  `NISession.deviceCapabilities.supportsDeviceInitiation` — non-UWB devices present
  the framework but sessions fail at runtime.
- Camera (QR scan): standard, expected. Requires `NSCameraUsageDescription`.

**App Store landmine 1 (blocking):** `NSLocalNetworkUsageDescription` is required in
Info.plist for any app that browses or advertises via Bonjour/mDNS (iOS 14+ local
network permission). Absent = App Store rejection. Present but generic = high user
denial rate, silently breaking LAN discovery. The usage description must name the
specific function: "Mootx01 needs local network access to discover other Mootx01
estates on the same Wi-Fi network." This must be in the mission scope for FED-OD-1.

**App Store landmine 2 (runtime only):** NearbyInteraction on non-UWB devices fails
at `NISession()` creation, not at API availability check. The app must guard
explicitly before offering UWB in the ceremony UI.

QR-first is architecturally correct for v1 primary. It requires no entitlements
beyond camera, works on all iOS devices, and provides a clear auditable user action
that is the natural MITM verification step.

### V4 — Session-as-grant: interim soundness

**Verdict: Sound. F2 is additive, not destructive. One UX caveat.**

The session-as-grant maps: session-enable = grant-create with implicit terms
(lifetime = singleSession, scope = manifest, custody mode 1 mediated, no tell
record, no per-scope key). F2 makes those implicit terms explicit and signed.

F2 upgrade path is clean:
- F2 adds a `_grants` table. Session-enable creates a signed grant row. The grant
  row carries the terms the F1 session carried implicitly. No F1 data structures are
  removed; `_grants` is additive.
- F2 extends session-start to present a scope picker (the chooser). The code path
  gains a parameter; existing callers default to manifest scope.
- F2 adds per-scope key generation after grant creation. The key lifecycle is
  orthogonal to the session lifecycle machinery.
- F2 adds tell-record logging as a side effect of grant operations. F1 has no tell
  records; F2 begins logging from the first signed grant.

**Nothing in F2 requires tearing out F1 code.** The session lifecycle (enable/disable)
is the durable abstraction. Grants are metadata layered on top of it.

**Caveat (UX, not code):** If F1 ships "Start Session" as "share everything at
manifest scope with this peer," users form a mental model of sharing as all-or-nothing.
F2 introduces scope narrowing. This may read as a behavior change to users who never
saw a scope picker. Mitigation: F1's posture card must visibly communicate that scope
= manifest (the whole connected estate), and F2's scope picker must be framed as
"choose what to share" not "this feature is different now." The posture card copy is a
Simms concern (user guide) and a Friedlander concern (visual hierarchy of the scope
indicator).

### V5 — Sharing model invariants F1 must honor

**Verdict: Ceiling-only enforcement satisfies F1's invariants. The invariant line is
precise.**

Three hard invariants from the sharing model (§§ 5, 3):

**Secret-never-crosses:** F1 satisfies this structurally. The SensitivityFilteredStorage
pattern (extended to LANRelay) prevents secret rows (sensitivity bit 48) from entering
the outbox. No scope key is minted because sign-then-encrypt-to-scope does not exist
in F1. The structural absence of key-minting is the mechanism: a row cannot cross if
it never enters the outbox, and secret rows never enter the outbox by bitmap check.

**Private-default-closed:** Satisfied with conditions. Discovery is off by default
(three-position: Off / While app open / Always). Session start requires explicit user
action (posture card + Start Session). A private row at or below the ceiling (normal
or elevated sensitivity) DOES cross during an active session — this is authorized by
the session start act, which IS the affirmative disclosure decision. This satisfies
the intent: "a private row is never disclosed until a grant explicitly opens it." The
session IS the implicit grant. What must NOT happen: any automatic session start,
silent session extension past user-specified scope, or session that starts without the
user seeing the posture card.

**No-durable-opener:** Satisfied at F1. The LANRelay TLS channel is the opener; it is
ephemeral (session end closes the channel). No scope key is minted in F1. No key
survives session end. The no-durable-opener posture holds because F1 implements only
custody mode 1 (mediated per-access): the originating estate is live and online; when
the session ends, access ends.

**What must NOT ship until F2 keys exist (the invariant line):**

| Must NOT ship in F1 | Reason |
|---|---|
| Always-on mode with durable key handoff | Would implement custody mode 2 without signing/audit; breaks no-durable-opener |
| Per-scope key generation or distribution | F2's cryptographic spine; F1 has no key lifecycle |
| Tell-record log entries for session events | No grant ID to log against; entries would be unverifiable |
| Re-share permission controls (even UI-only) | No enforcement mechanism; showing the control implies enforcement |
| Cryptographic clawback | Requires scope key revocation; F1 has no scope keys |
| Private-share prompt per §5 | Requires mandatory expiry picker backed by a key lifetime; session end is not a key expiry |
| Posture cards with false capabilities | "Balanced with tell record ON" must not ship if tell record is not implemented; lock it visibly |
| Open/Convenient/Locked/In-person/Sealed postures as functional | Unbuilt. Render locked, never functional stubs |

### V6 — UI surface buildability

**Verdict: Buildable on shipped scaffold. F1 card subset is Balanced-only.**

The sync-toggle/SyncTileView pattern (moot-mgr) is the exact precedent: a user action
calls `engine.enable(manifest:storage:)` with a configured SensitivityFilteredStorage
ceiling. The Federation Session panel is the same pattern with a scope configuration
step (the posture card) interposed before enable.

Implementation pattern:
```
[Start Session tapped] → posture card → [Balanced selected] →
FederationSessionManager.startSession(peer: peer, posture: .balanced) →
SensitivityFilteredStorage(wrapping: base, ceiling: .elevated) →
engine.enable(manifest: sessionManifest, storage: filtered)
```

`SyncController.enable(engine:manifest:ceiling:)` already enforces the
SensitivityFilteredStorage invariant (Perkins Amendment 1). The same invariant applies
to the LANRelay path — the wrapper must be the exact handle passed to engine.enable.

**F1 card subset:**

| Preset | F1 status | Block reason |
|---|---|---|
| Open | Locked | Durable grants + free re-share (F2) |
| Convenient | Locked | Relay link + long-decay key (F2) |
| **Balanced** | **Functional** | Session lifetime ≈ short decay; LAN ≈ peer-to-peer; ceiling = elevated; no re-share |
| Locked | Locked | Cryptographic clawback + NFC touch (F2/F3) |
| In-person | Locked | UWB + physical-decay custody (F3) |
| Sealed | Locked | Secret class; no key ever minted |

Balanced ships with honest limitations stated on the card: no tell record, no
cryptographic clawback (session end only), inference budget off.

The "secret has no UI" rule (decision §5) is enforced by construction: no control
ever offers secret rows. The posture card's scope selector shows manifest tables; the
filtering is by ceiling, not by user selection of sensitivity tier.

**Nert and Friedlander involvement:** The posture card is a novel UI pattern. Nert
reviews the panel's accessibility (VoiceOver labeling of the locked postures,
Dynamic Type scaling, Switch Control navigation order). Friedlander reviews visual
hierarchy: locked postures must read as structurally unavailable, not merely dimmed.

### V7 — Cross-leg parity (Rust port)

**Verdict: Apple-only for F1 is sound. Rust LANRelay is F2 scope explicitly.**

The F1 scope statement ("own machines + explicitly paired peers") in the accepted
decision covers the Apple device ecosystem. Linux/Windows peers via the Rust port are
not part of the F1 user story.

Rust LANRelay parity requires:
1. mDNS browser/advertiser on Linux (`mdns-sd` or similar crate; no `libmdns` in
   `std`). On Windows, `mDnsServiceDiscovery` (Win10+) or crate wrapping `dnsapi.dll`.
2. rustls custom `ServerCertVerifier` and `ClientCertVerifier` for Ed25519-pinned TLS.
3. TCP listener per registered identity feeding mpsc channels (fits the Rust Relay
   trait naturally; `register` returns the receiver).
4. `tokio::net::TcpListener` + `tokio_rustls` for the async listener.

Parity burden is moderate, not high. The Rust Relay trait shape (register/send_to)
maps better to LANRelay than Swift's drain pattern. The main effort is the mDNS
cross-platform library choice.

**Non-obvious risk**: The Rust port's `FederationRelay` does NOT have a `drain`
method — it uses push (mpsc sender). If the F1 Apple `LANRelay` uses a local buffer +
poll/drain, and the F2 Rust `LANRelay` uses push/mpsc, the behavioral difference
(poll cadence vs. immediate push) may affect message delivery latency in cross-leg
tests. This divergence should be documented in the cross-leg concordance table when
Rust LANRelay ships.

---

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `NSLocalNetworkUsageDescription` absent → App Store rejection | High | FED-OD-1 scope explicitly includes Info.plist key + usage string |
| F1 session inadvertently ships always-on (custody mode 2) path | High | Invariant line enforced: no durable key handoff in F1; Perkins reviews FED-OD-4 |
| LANRelay cursor not persisted → at-least-once guarantee weakens | Med | LANRelay has no cursor (local buffer clears on drain); engine LWW gate handles re-delivery; same model as FederationRelay |
| TLS cert pinning implemented incorrectly (wrong extension OID, or verifier accepts unregistered peers) | High | Perkins reviews FED-OD-2; negative test: connection from unknown key must be refused |
| SAS confirmation skipped by accident (race between scan complete and SAS dialog) | High | SAS UI gate must block `_fed_peers` write until both users confirm; FED-OD-3 has explicit negative test |
| UWB auto-fire ceremony fires without both screens open (proximity without pairing intent) | Med | NearbyInteraction session only starts from the QR pairing screen; FED-OD-5 scope |
| Posture card ships with "tell record: ON" labeling when no tell record is implemented | Med | F1 card copy must say "no disclosure log (coming in F2)"; Friedlander reviews labeling |
| F1 UI implies re-share is forbidden (correct) but no enforcement exists | Low | No re-share API; absence by construction. UI labeling is accurate |
| Rust LANRelay scope creep into F1 | Low | F1 scope explicitly Apple-only; any Rust work is a separate mission |

**Non-obvious risk nobody else named**: The session-end determinism requirement (no
outbound entry created after End Session lands in any relay — decision §6 last bullet)
has an edge case: if the durable outbox contains queued envelopes at session-end, the
push cycle may attempt to deliver them to the now-closed LANRelay after the session
ends. The FED-OD-4 session lifecycle must explicitly drain or discard the outbox at
session end. If the outbox drains asynchronously, a race exists between "session ended"
and "push cycle fires the queued entries." The fix: session-end closes the relay
connection first, then marks the engine disabled. Any in-flight push gets a transport
error and the outbox entry stays (no delivery). The I-2/I-10 style test for this is
FED-OD-7's "session-end is deterministic" check.

---

## Dependencies

**Depends on:**
- Wave C shipped: persistent Ed25519 identity (WC1), durable outbox (WC2), signed
  pairing (WC6), HostedRelay HTTPS conformer (WC7), SensitivityFilteredStorage P5-M1
  ceiling pattern
- Apple frameworks: Network.framework (TLS), MultipeerConnectivity, NearbyInteraction,
  AVFoundation (QR scan)
- Sharing model (2026-05-21): grant invariants, custody modes, chooser presets, risk
  table

**Affects:**
- `packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/` — LANRelay.swift
  (new), RelayConformanceTests.swift (third suite added)
- `apps/Mootx01-App/Sources/MootGateway/Sync/` — FederationSessionManager.swift
  (new), SyncController (session lifecycle wiring)
- `apps/Mootx01-App/Sources/GatewayUI/` — FederationPanel.swift (new, entire UI)
- `apps/moot-mgr/` — FederationPanel (Mac equivalent)
- `apps/Mootx01-App/Package.swift` — new LAN target(s), entitlement additions
- Info.plist — `NSLocalNetworkUsageDescription`, `NSCameraUsageDescription`,
  `NSNearbyInteractionUsageDescription`

**Conflicts with:**
- None open. The sharing model (2026-05-21) is the governing doctrine; the F1 scope
  is explicitly endorsed by the accepted decision (2026-07-18). No ADR conflicts.

---

## F1 Mission List

All F1 missions: worker = sonnet-4-6. Medium budget.

### FED-OD-1: LAN Discovery Service
**Parallel with FED-OD-2.**

Scope: NWBrowser + NWListener (Apple Network.framework) wrapping `_mootx01-fed._tcp`
mDNS. Advertise TXT record with short Ed25519 fingerprint, display name, protocol
version, relay port — no content-derived bytes. Three-position discoverability toggle
state (Off / While app open / Always). Off by default. LAN discovery never implies
trust. `NSLocalNetworkUsageDescription` added to Info.plist.

Files (net-new + 2 edits):
- NEW: `packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/LAN/LANDiscovery.swift`
- NEW: `packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/LAN/LANDiscoveryTests.swift`
- EDIT: `apps/Mootx01-App/Package.swift` (new dependency if LANDiscovery is a target)
- EDIT: `apps/Mootx01-App/Mootx01App-Info.plist` or PrivacyInfo.xcprivacy

Tier: Tier 3 (net-new) + atomic for Package.swift/Info.plist edits.
Verify: swift test ConvergenceKitFederationTests exits 0; negative test: TXT record
contains no content-derived bytes.
Needs: Perkins (TXT record negative test — content byte prohibition).

### FED-OD-2: LANRelay Swift Conformer
**Parallel with FED-OD-1.**

Scope: `LANRelay: Relay` in `ConvergenceKitFederation`. TLS channel via
Network.framework; self-signed P-256 cert with Ed25519 fingerprint in SAN extension;
custom TLS verifier checks peer against `_fed_peers`; local receive buffer (actor or
NSLock-guarded dict) populated by incoming connection listener; `send` = TCP write;
`drain` = read from buffer. Passes `RelayConformanceTests` as third suite.

Files (net-new + 1 edit):
- NEW: `packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/Relay/LANRelay.swift`
- NEW: `packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/Relay/LANRelayTLSConfig.swift`
- EDIT: `packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/Relay/RelayConformanceTests.swift`
  (add Suite 3: LANRelay via loopback)

Tier: Tier 3 (net-new) + 1 edit (Tier 1 limit: ≤ 5 edits, this is 1).
Verify: swift test ConvergenceKitFederationTests exits 0, LANRelay suite green;
negative test: connection from key not in `_fed_peers` refused at TLS layer.
Needs: Perkins (TLS pinning + refused-unknown-peer negative test).

### FED-OD-3: QR Pairing Ceremony
**Depends on FED-OD-2.**

Scope: State machine for QR-first pairing ceremony. Device A: QRCodeDisplay
(public key + session nonce encoded as QR). Device B: QRScanner (AVCaptureSession).
Both sides: ephemeral X25519 exchange bound to WC6 PairingProposal/Acceptance;
SAS derivation (HKDF over transcript: both public keys + session key + nonce);
SAS confirmation dialog (color/emoji pattern); `_fed_peers` write only after both
sides confirm matching SAS. Negative tests: SAS mismatch refuses peering, tampered
proposal fails verification.

Files (net-new):
- NEW: `apps/Mootx01-App/Sources/MootGateway/Federation/QRPairingCoordinator.swift`
- NEW: `apps/Mootx01-App/Sources/GatewayUI/Federation/QRPairingView.swift`
- NEW: `apps/Mootx01-App/Sources/GatewayUI/Federation/SASConfirmationView.swift`
- NEW: `apps/Mootx01-App/Tests/MootGatewayTests/Federation/QRPairingCoordinatorTests.swift`

Tier: Tier 3.
Verify: swift test exits 0; negative: SAS mismatch throws pairingRefused; tampered
proposal throws authenticationFailed.
Needs: Perkins (SAS derivation review; `_fed_peers` write-gate review).

### FED-OD-4: Federation Session Lifecycle
**Depends on FED-OD-2, FED-OD-3.**

Scope: `FederationSessionManager` in MootGateway. Session start: constructs
`SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)` and calls
`engine.enable(manifest: sessionManifest, storage: filtered)` via existing
`SyncController.enable` path. Session end: calls `engine.disable()`, closes the
LANRelay TLS channel (channel close must precede engine disable to prevent
post-session push attempts on the closed relay). Durable outbox entries queued at
session-end: push cycle gets transport error, entries remain in outbox (not discarded)
for future sessions. Session state machine: Idle → Connecting → Active → Ended.

Files (net-new + 2 edits):
- NEW: `apps/Mootx01-App/Sources/MootGateway/Federation/FederationSessionManager.swift`
- EDIT: `apps/Mootx01-App/Sources/MootGateway/Sync/SyncController.swift`
  (wire session manager to engine lifecycle)
- EDIT: `apps/Mootx01-App/Sources/MootGateway/GatewayRuntime.swift`
  (expose session manager to UI layer)

Tier: Tier 1 (touches SyncController, a shared primitive). ≤ 5 edits (2 edits + 1 new file).
Verify: swift test exits 0; no outbound entry created after session-end (I-2/I-10
style test for LANRelay path); ceiling holds: above-ceiling rows never reach LANRelay.
Needs: Perkins (ceiling-enforcement review, session-end ordering review).

### FED-OD-5: UWB Enhancement (Proximity Auto-Fire)
**Depends on FED-OD-3. Optional for F1.0, required for F1.1.**

Scope: `UWBProximityCoordinator` wrapping `NearbyInteraction` + `MultipeerConnectivity`.
Only activates from the QR pairing screen (intent signal). Within ~10 cm and both
pairing screens open: auto-fires the QR ceremony (calls QRPairingCoordinator directly
instead of waiting for manual scan). Hardware gate: `NISession.deviceCapabilities
.supportsDeviceInitiation`; non-UWB devices skip UWB path silently. `NSNearbyInteractionUsageDescription` in Info.plist.

Files (net-new):
- NEW: `apps/Mootx01-App/Sources/MootGateway/Federation/UWBProximityCoordinator.swift`
- EDIT: `apps/Mootx01-App/Sources/GatewayUI/Federation/QRPairingView.swift`
  (add proximity indicator when UWB active)

Tier: Tier 3 + 1 UI edit.
Verify: On non-UWB device, UWBProximityCoordinator.isAvailable == false; on UWB
device at simulated 5 cm, ceremony fires without manual scan.
Needs: Nert (accessibility of the proximity indicator; VoiceOver label for "
approaching — ceremony will fire automatically").

### FED-OD-6: Federation UI Panel
**Depends on FED-OD-1, FED-OD-4.**

Scope: `FederationPanel` in moot-mgr (Mac) and `FederationPanelView` in Mootx01-App
(iOS). Sections: Visibility (Off/While open/Always toggle, drives LANDiscovery state);
Nearby (discovered estates not yet paired, Pair button launches QR ceremony); Peers
(`_fed_peers`, per-peer posture summary, last session date, Unpair); Start Session
(peer selection → posture card → scope indicator → Start, live session banner with
countdown and End Session). Posture card: Balanced functional, all others visibly
locked (not dimmed — structurally locked with "coming in F2" annotation). Secret has
no UI. No control ever offers secret rows.

Files (net-new, Tier 3 — UI component bounded by FederationPanel):
- NEW: `apps/Mootx01-App/Sources/GatewayUI/Federation/FederationPanelView.swift`
- NEW: `apps/Mootx01-App/Sources/GatewayUI/Federation/PostureCardView.swift`
- NEW: `apps/Mootx01-App/Sources/GatewayUI/Federation/SessionBannerView.swift`
- NEW: `apps/moot-mgr/Sources/…/FederationPanel.swift` (Mac equivalent)
- NEW: Localization strings for all UI text

Tier: Tier 2 (UI-bounded by FederationPanel component, ≤ 6 files).
Verify: Balanced posture card is functional end-to-end with FED-OD-4 session manager;
all locked postures render locked (not interactive); secret has no UI (grep
"secret\|Secret" in FederationPanel sources must show zero entries in interactive
controls).
Needs: Nert (VoiceOver labeling, Dynamic Type, Switch Control order on session
banner); Friedlander (locked-posture visual design, "coming in F2" annotation
treatment, session banner hierarchy); Simms (user guide for Federation panel).

### FED-OD-7: F1 Conformance Suite
**Depends on FED-OD-2, FED-OD-4. Parallel with FED-OD-5 and FED-OD-6.**

Scope: Extends existing conformance suites with F1-specific negative tests.
(1) Discovery: TXT record contains no content-derived bytes (fingerprint-only
negative test). (2) LANRelay session-end: no outbound entry created after session
end — extends I-2/I-10 style. (3) Ceiling-holds across sessions: above-ceiling rows
never reach LANRelay inbox (extends P5-M1 gate tests to new transport). (4) SAS
mismatch refusal (extends WC6 negative tests to QR ceremony). (5) Tampered proposal
refusal (same). (6) LANRelay unknown-key refused at TLS layer.

Files (net-new + 1 edit):
- NEW: `packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/LAN/LANFederationConformanceTests.swift`
- EDIT: `packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/Relay/RelayConformanceTests.swift`
  (if any shared fixture needs extending — may be zero edits if all new)

Tier: Tier 3 (new test file) or Tier 1 if editing existing conformance file.
Verify: swift test exits 0; all 6 negative tests green.
Needs: Perkins (review all negative test assertions; conformance coverage sign-off).

---

## F2 Mission List (cryptographic spine)

### FED-OD-8: Grants Schema and Lifecycle
Scope: `_grants` SQLite table (grantee, scope, content level, lifetime, channel,
custody mode, clawback class, inference budget, timestamp). Grant create (signed by
grantor Ed25519 key) on session-start. Grant revoke on session-end. Schema migration.

### FED-OD-9: Sign-Then-Encrypt-to-Scope
Scope: Per-scope key generation at grant mint. Sign-then-encrypt for outbound envelopes
scoped to a grant. Inbound decrypt using scope key. Custody mode 1 (mediated) only.

### FED-OD-10: Tell Record and Clawback Request
Scope: `_tell_record` append-only events. Session-start, session-end, row-crossed events.
Clawback request (signed, best-effort for shareable; cryptographic for private-to-secret).

### FED-OD-11: Private-Share Prompt
Scope: §5 dialog (affirmative act, mandatory expiry picker). Wires to scope key
mint-on-confirmation. Private rows above manifest scope require this prompt.

---

## F3 Mission List (full chooser)

### FED-OD-12: Full Risk Chooser
Scope: All presets functional. Open (durable grants + free re-share). Locked (single-session
+ cryptographic clawback). In-person (proximity + ephemeral-only key). Sealed (secret class,
no key ever minted, verified absence).

### FED-OD-13: Inference Budget Enforcement
Scope: Query budget counter per grant. Differential-privacy ledger. Budget exceeded →
session throttled. Content-axis salience/posture level gated by budget.

### FED-OD-14: In-Person Preset Polish
Scope: UWB + physical-proximity gate as the ceremonial trigger for In-person preset.
Custody mode 4 (physical decay) activation gate (IP clearance required, v1.5 per
sharing model Appendix B.4). If IP clearance unavailable, In-person uses custody mode 1
ephemeral only.

### FED-OD-15: Re-Share with Audit
Scope: Mediated re-share path. Substrate derives onward key, logs in tell record.
Re-share permission property on grant. Provenance chain carried forward.

### FED-OD-16: Rust Port LANRelay
Scope: `LANRelay: Relay` in Rust (`src/federation.rs`). mDNS via crate (to be chosen).
rustls custom cert verifier. tokio TCP listener per registered identity. Cross-leg
delivery latency comparison documented in concordance table.

---

## The F1 Invariant Line

**What must not ship in F1:**

1. Always-on mode with durable key handoff (no custody mode 2 without F2 grant spine)
2. Per-scope key generation, distribution, or key lifetime enforcement
3. Tell-record log entries (no grant ID to log against)
4. Re-share permission controls, even UI-only (no enforcement)
5. Cryptographic clawback (requires scope key revocation)
6. Private-share prompt per sharing model §5 (requires key lifetime from expiry)
7. Any posture card preset other than Balanced as functional (all others visibly locked)
8. Secret rows in any UI control or scope selector

**The line in one sentence**: F1 ships a ceiling-protected, session-bounded, single-posture
(Balanced) federation window. Everything that requires a signed grant row, a per-scope key,
or a tell record entry is F2 territory.

---

## Notes for the Audit Trail

**Decision provenance**: The accepted decision (2026-07-18) names QR-first, Balanced
default, LANRelay as third conformer, and the P5-M1 ceiling pattern as the F1 security
mechanism. This charter operationalizes those decisions into missions; it does not
introduce new design positions.

**Custody mode mapping**: F1's session-as-grant is equivalent to custody mode 1 (mediated
per-access) per sharing model Appendix B.1. The session IS the mediation: the originating
estate controls access by controlling the LANRelay TLS channel lifetime. This mapping
should be documented in FED-OD-4 so the F2 migration path is legible.

**Perkins Amendment 1 extension**: The invariant that `SensitivityFilteredStorage` must be
the exact handle passed to `engine.enable()` (documented in SensitivityFilteredStorage.swift
file header, Perkins Amendment 1) extends to the LANRelay path. FED-OD-4 must enforce this
invariant on the new session-enable code path. Perkins must verify this in FED-OD-4 review.

**RelayConformanceTests is the contract registry**: Three conformers, one contract. Any
future Relay conformer (Rust LANRelay, future gRPC relay) must pass
`RelayConformanceTests` unmodified. This is the invariant established by the decision
(§6 first bullet) and must not be relaxed.

**`NSLocalNetworkUsageDescription` is a hard dependency of App Store submission.**
This key was identified in V3 as a blocking landmine. It must appear in FED-OD-1 scope
and must not be deferred to a cleanup mission. App Store rejection from missing usage
string is a days-long round-trip delay.

**ADR-013 note**: The sharing model §3 includes a note "(Signature algorithm superseded
by ADR-013: ECDSA P-256, for FIPS approved-mode compliance. The per-estate-identity
model is unchanged.)" The LANRelay TLS design in V2 uses P-256 for the TLS certificate
key (consistent with ADR-013). The pairing identity (Ed25519 per WC6) is carried in
the cert extension, not as the cert key. This is the correct layering; the TLS cert
key and the estate identity key are distinct and serve different purposes.

**Sequencing gate**: FED-OD-1 and FED-OD-2 are the program's foundation — no other F1
mission can start without both. FED-OD-7 (conformance) should be the last F1 mission
to gate merge, not the first to be authored. Write the conformance tests after the
behavior exists to test against; don't author aspirational tests into a mission that
Bilby will fail against absent code.
