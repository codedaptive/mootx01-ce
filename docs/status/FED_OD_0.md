---
title: FED-OD-0 Program Charter — Completion Report
mission: FED-OD-0
status: complete
reviewer: Kong
date: 2026-07-18
output: docs/analysis/FED_OD_CHARTER.md
---

# FED-OD-0 — Program Charter: Complete

## What was done

Kong read and assessed:
- `DECISION_FEDERATION_ONDEMAND_LAN_PROXIMITY_2026-07-18.md` (accepted 2026-07-18)
- `docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#72-disclosure-model` (disclosure doctrine)
- `CONVERGENCEKIT_INTERFACE.md` (Relay abstraction, HostedRelay/RelayHTTPTransport rows,
  concordance table)
- `Sources/ConvergenceKitFederation/FederationSyncEngine.swift`, `HyperplaneFamilyExchange.swift`,
  `Relay/HostedRelay.swift`, `Relay/RelayHTTPTransport.swift`
- `Tests/ConvergenceKitFederationTests/Relay/RelayConformanceTests.swift`
- `apps/Mootx01-App/Sources/MootGateway/Sync/SensitivityFilteredStorage.swift`
- `docs/reference/FEDERATION_SYNCSERVER_WIRE_PROTOCOL.md`
- `docs/analysis/CVK_WAVEC_FEDERATION_CHARTER.md` (Wave C charter for context)

Produced: `docs/analysis/FED_OD_CHARTER.md`

## Verdicts (one-line each)

1. LANRelay fits Relay contract — local receive buffer + TCP listener is FederationRelay
   extended over a network leg; conformance fixture passes unchanged.
2. Identity-bound TLS — self-signed P-256 cert with Ed25519 fingerprint in SAN; custom
   verifier checks `_fed_peers`; SAS confirmation precedes trust-store write; sufficient.
3. iOS proximity — NFC/NameDrop prohibition confirmed; MultipeerConnectivity and
   NearbyInteraction available no exotic entitlements; QR-first correct; two App Store
   landmines: `NSLocalNetworkUsageDescription` (blocking), UWB hardware gate (runtime).
4. Session-as-grant — sound interim; F2 is additive (_grants table added, session path
   extended); nothing torn out; UX mental-model softer risk, not code risk.
5. Sharing model invariants — ceiling-only enforcement satisfies all three F1 invariants
   (secret-never-crosses, private-default-closed, no-durable-opener); invariant line is
   precise: no per-scope keys, no tell records, no durable key handoff in F1.
6. UI surface — buildable on sync-toggle scaffold; F1 card subset is Balanced only;
   all other presets visibly locked, never functional stubs.
7. Cross-leg parity — Apple-only for F1 is architecturally sound; Rust LANRelay is F2/F3;
   Rust Relay trait shape (register/send_to) fits LAN better than Swift's drain.

## Mission list summary (F1)

| ID | One-liner | Parallel? | Reviewer(s) |
|---|---|---|---|
| FED-OD-1 | LAN Discovery — mDNS browser/advertiser, off-by-default, TXT fingerprint-only | Parallel with FED-OD-2 | Perkins |
| FED-OD-2 | LANRelay Swift — Relay conformer, TLS/pinned, RelayConformanceTests third suite | Parallel with FED-OD-1 | Perkins |
| FED-OD-3 | QR Pairing Ceremony — X25519 exchange, SAS confirmation, _fed_peers write | After FED-OD-2 | Perkins |
| FED-OD-4 | Session Lifecycle — start/end, SensitivityFilteredStorage to LANRelay, ceiling holds | After FED-OD-2+3 | Perkins |
| FED-OD-5 | UWB Enhancement — NearbyInteraction ranging, auto-fire at proximity | After FED-OD-3 | Nert |
| FED-OD-6 | Federation UI Panel — Nearby/Peers/Session/PostureCard, Balanced functional, rest locked | After FED-OD-1+4 | Nert, Friedlander, Simms |
| FED-OD-7 | F1 Conformance Suite — 6 negative tests (TXT, session-end, ceiling, SAS, proposal, TLS) | After FED-OD-2+4 | Perkins |

## Most important sequencing risk

**Session-end post-outbox race.** The durable outbox may contain queued envelopes at
session-end. If the engine is disabled before the LANRelay TLS channel is closed, the
push cycle may attempt to deliver queued envelopes to a closed relay after session end.
The fix (close channel first, then disable engine) must be in FED-OD-4 scope and
verified by the determinism test in FED-OD-7. If this race ships, the decision's
conformance requirement ("no outbound entry created after End Session lands") is violated.

## Commit

See git log — committed as Kong.
