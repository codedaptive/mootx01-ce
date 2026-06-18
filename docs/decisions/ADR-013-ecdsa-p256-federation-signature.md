---
status: decided
question: What digital-signature algorithm should federation use for per-estate identity and the signed pairing handshake, given the EE FedRAMP charter's FIPS-validated-cryptography requirement?
authors: MOOTx01 maintainers
date: 2026-06-17
version: 1.0.0
relates_to:
  - docs/decisions/DECISION_SYNCKIT_DESIGN_2026-05-19.md
  - docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md
  - docs/reference/CONVERGENCEKIT_SPEC.md
  - docs/reference/CONVERGENCEKIT_INTERFACE.md
supersedes:
  - "DECISION_SYNCKIT_DESIGN_2026-05-19 §8 (per-estate Ed25519 identity) — the signature ALGORITHM only; the per-estate-identity and signed-handshake design is retained"
  - "DECISION_FEDERATION_SHARING_MODEL_2026-05-21 (Ed25519 identity references) — signature algorithm only"
description: Federation per-estate identity and the signed handshake use ECDSA P-256 (deterministic per RFC 6979 where the validated module supports it), replacing Ed25519, because Ed25519 is not in the approved boundary of the FIPS-validated crypto modules EE must ship.
---

# ADR-013 — ECDSA P-256 for federation signatures

## Context

Federation gives one estate a cryptographic identity and a signed pairing
handshake. The prior decisions chose **Ed25519** for this: per-estate Ed25519
identity (`DECISION_SYNCKIT_DESIGN_2026-05-19` §8) and Ed25519-authenticated
disclosure (`DECISION_FEDERATION_SHARING_MODEL_2026-05-21`). Ed25519 is, on its
technical merits, an excellent modern signature scheme — deterministic by
construction (no per-signature nonce footgun), fast, small keys.

The **Enterprise Edition charter has carried FedRAMP the entire time.** FedRAMP
inherits NIST 800-53 **SC-13 (Cryptographic Protection)**, which requires
cryptography that protects federal data to be performed by a **FIPS 140-validated
module operating in its approved mode.** The gating fact for an algorithm is not
"the FIPS *standard* approves it" but "the specific validated *module* we ship
lists it inside its CMVP-certified approved boundary." Those move on different
clocks.

We verified the actual module certificates (2026-06-17):

- **Apple CoreCrypto v13.0** (the FIPS 140-3 module validated for current
  macOS/iOS): **Ed25519 / EdDSA is implemented but NOT FIPS-approved** — it is
  available only outside approved mode. **ECDSA P-256 is approved** (ECDSA per
  FIPS 186-4, CAVP A3509; P-256 enumerated).
- **OpenSSL FIPS provider** (Windows/Linux port): EdDSA was explicitly **removed
  from approved** in the 3.0/3.1 providers (OpenSSL PR #20343) and became an
  **approved** algorithm only in the **3.4.0** provider (CMVP #5132, deploying
  March 2026). ECDSA P-256 has been approved across all of these for years.

So Ed25519 cannot be used in approved mode with the Apple module that is
validated today, and we do not control when Apple moves EdDSA into the approved
boundary. ECDSA P-256 is approved on **both** platforms, now.

Federation ships in **v1.1**; this decision is made now so the v1.1
implementation targets FIPS-correct crypto from the start rather than being
retrofitted after the fact.

## Decision

**Federation per-estate identity and the signed pairing handshake use ECDSA over
NIST P-256**, in **both editions** (CE and EE), as the single federation
signature scheme. Signatures SHALL be produced by the platform's FIPS-validated
module in approved mode: the OpenSSL FIPS provider (Rust/Windows/Linux) and Apple
CoreCrypto via CommonCrypto/Security (Apple).

Deterministic signing per **RFC 6979** is PREFERRED — it matches the substrate's
reproducibility model and keeps signatures byte-identical across ports — and
SHALL be used where the validated module exposes it (the OpenSSL FIPS provider
does). Where a validated module does not expose deterministic ECDSA, randomized
ECDSA in approved mode is acceptable; the signature is then verify-checked rather
than byte-matched in conformance, exactly as randomized AES-GCM ciphertext
already is (PERSISTENCEKIT_SPEC B-12a; the `aes-gcm` nonce exemption). **FIPS
approved-mode operation is the hard requirement; determinism is preferred, not
required.**

The per-estate-identity design and the signed-handshake protocol from the
superseded decisions are otherwise retained — only the signature algorithm
changes (Ed25519 → ECDSA P-256).

## Alternatives considered

- **B — Pluggable signature seam (Ed25519 for CE, ECDSA for EE).** Mirrors the
  existing `AeadProvider`-style provider seam and the edition split. Rejected as
  the default: it splits federation interop (a CE Ed25519 estate and an EE ECDSA
  estate cannot verify each other unless both stacks ship on both sides), forcing
  signature-suite negotiation into the handshake and adding misconfiguration
  surface. One scheme is simpler and avoids the interop fork. (Available as a
  fallback only if CE later has a concrete reason to keep Ed25519.)
- **C — Keep Ed25519, rely on a validated module that includes EdDSA.** Rejected
  on verified evidence: the Apple module validated today excludes EdDSA from
  approved mode, and OpenSSL only just added it (3.4.0, 2026). This is a
  scheduling bet on Apple's next validation cycle that we do not control; it
  would fail an Apple FIPS audit with the current module.
- **D — Keep Ed25519 with a POA&M risk acceptance.** Rejected: FedRAMP
  authorizing officials are strict on SC-13 cryptographic compliance, and a
  waiver for the *core federation identity* is among the least likely to be
  granted — a sustained finding, not a fix.

## Consequences

- ConvergenceKit's federation identity and handshake signing/verification change
  from Ed25519 to ECDSA P-256 on **both ports** when federation is built in v1.1;
  new shared conformance vectors are authored for the signature path.
- **Verify before implementation:** whether the Apple validated module exposes
  RFC 6979 *deterministic* ECDSA through the API surface we use
  (CryptoKit/CommonCrypto/Security). If not, federation signatures on Apple are
  randomized-but-approved and conformance verifies rather than byte-matches.
- ECDSA P-256 signatures and verification are larger/slower than Ed25519, and
  ECDSA carries a nonce-handling footgun that RFC 6979 (deterministic) or a
  validated module's compliant RBG removes — never hand-roll the nonce.
- Supersession is scoped to the **signature algorithm**. The per-estate identity,
  key custody, signed-handshake protocol, capability negotiation, and the
  per-record (Mode 2) federation-encryption model from the prior decisions are
  unchanged.
- Edition-neutral: choosing one scheme keeps CE↔EE federation interoperable and
  avoids a dual-stack. CE inherits a FIPS-approved scheme at no cost.

## References

- NIST 800-53 **SC-13** (Cryptographic Protection); FedRAMP FIPS-validated-crypto requirement.
- Apple corecrypto v13.0 FIPS 140-3 security policy (NIST 140sp4919) — EdDSA non-approved, ECDSA P-256 approved (CAVP A3509). Parsed record: sec-certs.org module 25b99b9c636ea2d7.
- OpenSSL FIPS provider: PR #20343 (EdDSA reverted from approved); 3.4.0 provider CMVP #5132 (adds FIPS 186-5 Ed25519, March 2026).
- RFC 6979 (Deterministic ECDSA); FIPS 186-4/186-5 (ECDSA/EdDSA).

## Changelog

### 1.0.0 -- 2026-06-17
Initial decision. Selects ECDSA P-256 (deterministic per RFC 6979 where the
validated module supports it) as the single federation signature scheme for both
editions, superseding the Ed25519 signature choice, on the basis of verified
CMVP module evidence that Ed25519 is outside the approved boundary of the Apple
CoreCrypto module validated today.
