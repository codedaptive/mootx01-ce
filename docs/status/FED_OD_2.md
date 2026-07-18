---
title: FED-OD-2 Completion Report
mission: FED-OD-2
status: COMPLETE
stream: worktree-agent-aa3674ea67c742301
commit: ffbbf78a
date: 2026-07-18
---

# COMPLETION: FED-OD-2

**Status: COMPLETE**

## What Was Done

**Part 1: Merge and base verification** — Merged c208d889 (FED-OD-0 Kong charter,
fast-forward). Verified RelayConformanceTests.swift exists. Established baseline:
104 tests / 25 suites green in ConvergenceKitFederationTests.

**Part 2: LANRelay.swift** (new) — `LANRelayTransport` seam protocol + `LANRelay`
conformer. `send(to:message:)` delegates to the injected transport (throws SyncError
on transport failure). `drain(for:)` delegates to transport (non-throwing, returns
current buffer). Transport seam keeps all socket I/O out of the Relay contract so
unit tests run with zero real network. Commit ffbbf78a.

**Part 3: LANRelayTLSConfig.swift** (new) — Production TLS configuration for
identity-pinned connections. Key deliverables:
- `verifyPeerCertificate(_:against:)` — pure function, verifies peer's SAN extension
  fingerprint against `_fed_peers` set. Testable without Network.framework.
- `extractEd25519Fingerprint(fromCertDER:)` — parses OtherName UTF8String (OID
  1.3.6.1.4.1.99999.1) from DER certificate. Returns 32-byte Ed25519 key or nil.
- `LANRelayTLSConfig.makeNWParameters()` — attaches local P-256 identity + custom
  `sec_protocol_options_set_verify_block`. Unknown peer → TLS handshake refused.
- `LANRelayIdentityFactory.makeEphemeralIdentity` — shape defined, throws
  `notImplemented`; production cert assembly deferred (platform-specific, FED-OD wiring
  note in file header; unit tests are unaffected).

**Part 4: FakeLANRelayTransport.swift** (new, in test target) — In-memory loopback
implementation of `LANRelayTransport`. Open mode (all keys accepted, for conformance
tests) and peer-restricted mode (throws `SyncError.peerUnreachable` for unknown keys,
simulating TLS verifier refusal). NSLock-guarded, `@unchecked Sendable`.

**Part 5: RelayConformanceTests.swift** (edit) — Suite 3 added:
`LANRelayConformanceTests` (spec §6.3). THREE conformers, one contract:
- core conformance checklist (spec §6.3 — LANRelay loopback)
- multiple recipients: envelopes route to correct inbox
- unknown recipient returns empty array
- at-least-once: re-send same envelope does not lose delivery
- **TLS refused: send to unknown peer key throws peerUnreachable** (charter V2)
- envelope byte-fidelity: all fields byte-identical after LAN transport round-trip
- connection teardown: drain returns empty after transport reset (clean teardown)

## Test Verification Log

### Baseline (captured at mission start, post-merge)
- Command: `cd packages/kits/ConvergenceKit && swift test --filter ConvergenceKitFederationTests`
- Exit code: 0
- Pass count: 104 tests / 25 suites

### Final (post-commit ffbbf78a)
- Command: `cd packages/kits/ConvergenceKit && swift test --filter ConvergenceKitFederationTests`
- Exit code: 0
- Pass count: **111 tests / 26 suites** (+7 tests: Suite 3)
- All 7 LANRelay conformance rows: GREEN

- Command: `cd packages/kits/ConvergenceKit && swift test` (full suite)
- Exit code: 0
- Pass count: **235 tests / 45 suites** (all passing)

## Conformance Fixture Pass Evidence — THREE Relays

| Suite | Implementation | Core conformance | Suite-specific rows |
|---|---|---|---|
| Suite 1 | FederationRelay (in-process reference) | GREEN | multipleRecipients, unknownRecipientEmpty, atLeastOnceResend |
| Suite 2 | HostedRelay (HTTPS via FakeRelayHTTPTransport) | GREEN | register, bearerToken, 401→authFailed, 404→peerUnreachable, 409→success, cursorAdvances, networkError |
| Suite 3 | **LANRelay (via FakeLANRelayTransport, loopback)** | **GREEN** | multipleRecipients, unknownRecipientEmpty, atLeastOnceResend, **tlsRefusedOnUnknownKey**, envelopeByteFidelity, teardownIsClean |

## TLS Verifier Shape

Production verification path (Network.framework):
```
NWProtocolTLS.Options
  → sec_protocol_options_set_local_identity (P-256 self-signed cert, SAN = Ed25519 hex)
  → sec_protocol_options_set_verify_block:
      secTrust → SecTrustCopyCertificateChain → leaf cert DER
      → extractEd25519Fingerprint(fromCertDER:)
          → findExtensionOctetContent(OID 2.5.29.17 = subjectAltName)
          → findOtherNameUTF8(OID 1.3.6.1.4.1.99999.1 = mootx01 FED-OD-2)
          → hex decode → 32-byte Data
      → knownPeers.contains(fingerprint)? → TRUE (accept) / FALSE (refuse)
```

Test seam path (FakeLANRelayTransport):
```
send(to: peerKey)
  → if knownPeers != nil && !knownPeers.contains(peerKey) → throw peerUnreachable
  → else → inboxes[peerKey].append(message)
drain(for: key) → inboxes[key]; clear
```

## Seam for Socket-Free Tests

`LANRelayTransport` protocol (two methods: `send(to:message:) throws` and
`drain(for:) -> [SignedEnvelope]`) is the entire seam. LANRelay knows nothing about
sockets, TLS, or Network.framework — it only calls through this protocol. Tests inject
`FakeLANRelayTransport`; production wires `LANRelayNWTransport` (FED-OD wiring task).
This is the same injection pattern as `RelayHTTPTransport` / `FakeRelayHTTPTransport`
for HostedRelay.

## Test Names (Suite 3)

```
Relay conformance — LANRelay (via FakeLANRelayTransport, loopback, spec §6.3)
  ├── core conformance checklist (spec §6.3 — LANRelay loopback)
  ├── multiple recipients: envelopes route to correct inbox
  ├── unknown recipient returns empty array
  ├── at-least-once: re-send same envelope does not lose delivery
  ├── TLS refused: send to unknown peer key throws peerUnreachable (charter V2)
  ├── envelope byte-fidelity: all fields byte-identical after LAN transport round-trip
  └── connection teardown: drain returns empty after transport reset (clean teardown)
```

## Commit Hash

`ffbbf78a`

## Discoveries

1. **Pre-existing warning in RelayConformanceTests.swift** (line ~274, pre-existing):
   `authFailureMaps401` creates `let relay = HostedRelay(...)` that is never used
   (the actual relay under test is `relay401`). This warning predates FED-OD-2 and
   is in the shipped code. Queued as a cleanup item, not in this mission's scope.

2. **LANRelayIdentityFactory.makeEphemeralIdentity deferred**: The production path for
   generating a self-signed P-256 certificate with Ed25519 fingerprint in SAN and
   forming a `SecIdentity` from it (without adding to the user's persistent keychain)
   requires platform-specific implementation (macOS: temporary keychain or PKCS12
   import; iOS: PKCS12 import). This is production wiring, not tested in unit tests.
   Detailed description is in `LANRelayTLSConfig.swift` file header and
   `LANRelayIdentityFactory` doc comment. FED-OD-2 wiring note filed for NW transport
   author to complete.

3. **verifyPeerCertificate uses SecTrustCopyCertificateChain**: Our platform floor is
   macOS 26 / iOS 26 so the deprecated `SecTrustGetCertificateAtIndex` was NOT used.
   The replacement API (`SecTrustCopyCertificateChain`, macOS 12+) is used throughout.

## Outstanding (out of scope for FED-OD-2)

- LAN discovery (FED-OD-1 — parallel stream)
- QR pairing ceremony and SAS confirmation (FED-OD-3 — depends on FED-OD-2 ✓)
- Federation session lifecycle (FED-OD-4 — depends on FED-OD-2 ✓)
- `LANRelayNWTransport` production NW implementation (production wiring, separate task)
- `LANRelayIdentityFactory.makeEphemeralIdentity` production cert generation (same)
