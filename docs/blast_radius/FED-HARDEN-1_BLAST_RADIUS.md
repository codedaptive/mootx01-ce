---
mission: FED-HARDEN-1
title: Federation pull hardening — registry key as sole trust anchor
date: 2026-07-12
status: complete
---

# Blast Radius Report — FED-HARDEN-1

Hardening `FederationSyncEngine.pull()` so that signature verification and canonical
signing-bytes construction use the **registered peer key** from the pairing registry,
not the `senderPublicKey` claim inside the incoming envelope. The F-3-class guard
(envelope `senderPublicKey` must equal the registered key) already existed; this
ensures the verified key derives from the pairing registry even when the two values
are equal by the guard, and tightens the logging path to record both keys on rejection.

New regression tests: two Swift tests (`pullRejectsSignedEnvelopeFromUnpairedSender`,
`pullRejectsEnvelopeWithSpoofedSenderKeyAndAttackerSignature`) + Rust mirror tests
added in this fix bundle (`pull_rejects_envelope_with_spoofed_sender_key_and_attacker_signature`,
`pull_accepts_paired_envelope_and_ingests_record`).

Commit: `822b888a`

---

## Step 0 — Baseline

`FederationPairingTests.swift` at mission start: 1 test (`inProcessPairingPushPull`),
passing. Rust `federation_tests.rs`: 11 tests passing, including
`pull_rejects_signed_envelope_from_unpaired_sender` (the existing unpaired-sender gate).

---

## Symbol — `FederationSyncEngine.pull()` / `pull()` (Rust)

**Change class:** security hardening — behaviour change in verification path; no API
change, no type change. External callers (tests) observe the same `SyncReceipt`
return type.

**Scope:** `pull()` method in both Swift (`FederationSyncEngine.swift`) and Rust
(`federation.rs` → `FederationSyncEngine::pull`).

### Call sites chased

| File | Site | Classification | Verdict |
|---|---|---|---|
| `packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | `pull()` — verification block uses `registeredKey` (from `paired_peer`) for `envelopeSigningBytes` and `verify` | MUST_UPDATE | Fixed: verified via registry key |
| `packages/kits/ConvergenceKit/rust/src/federation.rs` | `pull()` — verification block updated to use `paired_peer.public_key` as the verify key | MUST_UPDATE | Fixed: both signing bytes and verify call use registry key |
| `packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/FederationPairingTests.swift` | Two new regression tests added | MUST_UPDATE | Added: unpaired-sender gate + F-3 spoofing gate |
| `packages/kits/ConvergenceKit/rust/tests/federation_tests.rs` | F-3 Rust mirror test | MUST_UPDATE | Added in this fix bundle (gap from original commit) |

### Out-of-scope

`push()` — constructs signing bytes from `self.identity` (the engine's own key). No
change to signing path; only the `pull()` verification path is affected.

---

## Files Modified

| File | Change | Role |
|---|---|---|
| `packages/kits/ConvergenceKit/Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | `pull()` verification uses registered peer key; rejection log records both keys | Swift primary fix |
| `packages/kits/ConvergenceKit/rust/src/federation.rs` | `pull()` verification updated symmetrically | Rust primary fix |
| `packages/kits/ConvergenceKit/Tests/ConvergenceKitFederationTests/FederationPairingTests.swift` | Added `pullRejectsSignedEnvelopeFromUnpairedSender` + `pullRejectsEnvelopeWithSpoofedSenderKeyAndAttackerSignature` | Swift regression tests |
| `packages/kits/ConvergenceKit/rust/tests/federation_tests.rs` | Added `pull_rejects_envelope_with_spoofed_sender_key_and_attacker_signature` + `pull_accepts_paired_envelope_and_ingests_record` | Rust regression tests (fix bundle) |

---

## MUST_UPDATE Resolution

All sites resolved. No deferrals.

Swift: FederationPairingTests at close: 3/3 tests passing.
Rust: `cargo test --test federation_tests` — all existing tests green; two new tests
added in this fix bundle for the F-3 gate and positive regression.
