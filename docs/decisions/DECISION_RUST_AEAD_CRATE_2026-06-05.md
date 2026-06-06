# Decision: Rust AEAD crate — C-1 per-crate exception for `aes-gcm`

**Date:** 2026-06-05
**Stream:** w3-pk-encryption (PAR-4-PK / PAR-5-PK)
**Status:** Accepted

---

## Context

At-rest row encryption (Mission ENC-01) shipped in Swift via CryptoKit
`AES.GCM`. The Rust port (PAR-5-PK) requires an AES-GCM-256 implementation
to maintain behavioral parity with the Swift side so persisted rows are
cross-decryptable between Swift and Rust.

The project's C-1 constraint prohibits external crate dependencies without
a recorded per-crate exception. This document is that exception.

---

## Decision

**Use the RustCrypto `aes-gcm` crate (v0.10) as the default Rust AEAD
implementation for at-rest row encryption.**

`aes-gcm` is approved as the first external crypto crate in this codebase.

---

## Rationale

1. **Never hand-roll an AEAD.** Implementing AES-GCM from scratch carries
   catastrophic risk: timing side-channels, nonce reuse vulnerabilities, tag
   truncation bugs. The RustCrypto ecosystem is the audited, widely-deployed
   standard for pure-Rust symmetric crypto. `aes-gcm` is the obvious and
   correct choice.

2. **Not conformance-byte-identity-gated.** Random nonces make each
   encryption non-deterministic by design (nonce reuse is a GCM safety
   violation). The at-rest encryption is therefore excluded from the
   conformance-byte-identity gate. What matters is cross-decryptability
   (same standard AES-GCM-256 algorithm, same wire layout), not
   identical byte-for-byte ciphertext.

3. **Cross-decryptability with Swift.** Both `aes-gcm` (Rust) and CryptoKit
   (Swift) implement the standard NIST AES-GCM-256 algorithm. The wire layout
   is `[12-byte nonce][16-byte GCM tag][ciphertext]` in both ports. A row
   written by Swift can be decrypted by Rust and vice versa, proven by the
   NIST KAT in both test suites.

4. **FedRAMP swap point.** The `AeadProvider` trait (Rust) / protocol (Swift)
   is the swap seam. A future FedRAMP/FIPS-validated hand-rolled AEAD drops
   in by conforming to this trait, with zero changes to `RowCrypto` or any
   storage call site. `aes-gcm` is the *default* implementation behind the
   seam, not a hard dependency of any public API.

---

## Swappable-seam architecture

Both Swift and Rust ship a swappable seam:

| | Swift | Rust |
|---|---|---|
| Seam type | `AeadProvider` protocol | `AeadProvider` trait |
| Default provider | `CryptoKitAeadProvider` | `AesGcmAeadProvider` |
| Default algorithm | CryptoKit AES.GCM | `aes-gcm` crate AES-GCM-256 |
| Wire layout | `[nonce][tag][ct]` | `[nonce][tag][ct]` (same) |
| Injection point | `RowCrypto.encrypt/decrypt(provider:)` | `RowCrypto::encrypt/decrypt(provider)` |

A FedRAMP/FIPS-validated alternative provider:
1. Implements `AeadProvider` (the trait/protocol)
2. Is injected at the `provider` parameter of `RowCrypto`
3. Requires ZERO changes to `RowCrypto`, `SQLiteBackend`, or any consumer

---

## FedRAMP / FIPS path

The future FedRAMP/FIPS hand-port is the swap behind the same seam.
When that replacement is ready:
1. It conforms to `AeadProvider` / `AeadProvider` trait
2. It passes the NIST KAT in both Swift and Rust
3. It is injected at `SQLiteBackend` construction time via `EstateConfiguration`
4. The `aes-gcm` crate is demoted from the default (or removed)
5. This ADR is updated to record the swap

---

## Crate details

| Field | Value |
|---|---|
| Crate | `aes-gcm` |
| Version | `^0.10` |
| Source | crates.io (RustCrypto project) |
| Features | `aes` (platform-accelerated AES block cipher where available) |
| Usage | Internal to `encryption.rs`; not re-exported in any public API |
| Approval type | C-1 per-crate exception (first crypto crate) |

---

## Rejected alternatives

- **Hand-roll AES-GCM:** Rejected. Implementing an authenticated cipher
  from scratch is never acceptable. The risks are too severe and the
  standard library already exists.

- **Use `ring`:** Rejected. `ring` has C bindings and is harder to swap
  for a pure-Rust FIPS-compliant alternative. RustCrypto `aes-gcm` is
  pure Rust and aligns with the codebase's build model.

- **Delay Rust encryption until FedRAMP variant is ready:** Rejected.
  The Swift side already has at-rest encryption. Rust parity requires
  a working AEAD now, behind a seam, so the FedRAMP variant can drop in
  cleanly.
