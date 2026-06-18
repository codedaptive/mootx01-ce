---
status: decided
question: What at-rest encryption mechanism does the Apple port (iOS + macOS) use, given that Apple Data Protection is iOS-only, native macOS has no per-file encryption primitive, SIP/app-group containers are disableable access-control rather than encryption, and the EE FedRAMP charter requires FIPS-validated cryptography?
authors: MOOTx01 maintainers
date: 2026-06-18
version: 1.3.2
relates_to:
  - docs/reference/PERSISTENCEKIT_SPEC.md
  - docs/reference/PERSISTENCEKIT_INTERFACE.md
  - docs/decisions/ADR-005-mootx01-app-envelope-and-parity-boundary.md
  - docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md
supersedes:
  - "Conversational decision (2026-06-17) to use Apple Data Protection as the PRIMARY at-rest mechanism on Apple — Data Protection is retained, but as a defense-in-depth layer on iOS, not the guarantee"
description: SQLCipher whole-file encryption is the single at-rest mechanism on all platforms; on Apple it runs on the CommonCrypto backend (Apple CoreCrypto, FIPS-validated) with the data key wrapped by a Secure Enclave key in the Keychain. App-group container (SIP), FileVault, and iOS Data Protection are additive defense-in-depth layers, not the primary guarantee.
---

# ADR-014 — SQLCipher at-rest encryption on Apple

## Context

The planned encryption lockdown must protect estate databases — schema and
content — so the bytes are **ciphertext that requires a key**, surviving a
hostile local process even when the machine is unlocked and running. The Rust
port (Windows/Linux) achieves this with SQLCipher. The Apple port needed its own
answer, and we worked through the candidates against two hard requirements:
confidentiality that doesn't depend on the user making a correct choice, and
**FIPS-validated cryptography** (the EE FedRAMP charter; NIST 800-53 SC-13).

What we established, with evidence:

- **Apple Data Protection (`FileProtectionType`) is iOS-family only** — the
  entitlement and per-file mechanism are *not* available on native macOS (Apple
  doc: "Available on iOS, iPadOS, Mac Catalyst, tvOS, visionOS, watchOS" — no
  macOS). So it cannot be the macOS mechanism.
- **App-group container / SIP is access control, not encryption,** and is
  *disableable* (`csrutil disable`) and *socially engineerable*: a non-group
  process triggers a user authorization prompt (macOS 15+), which a confused user
  can grant — and the grant is remembered. It does not make the bytes ciphertext.
- **FileVault** is full-disk and at-rest-only: transparent to any local process
  once the Mac is unlocked. Not a per-app keyed guarantee.
- A **custom CryptoKit VFS** would be hand-rolled crypto on a non-validated
  module boundary — a FIPS problem, and explicitly against the directive to not
  build in-house crypto.
- **SQLCipher on the CommonCrypto backend** encrypts the whole file (schema
  included) under a key, and CommonCrypto resolves to **Apple CoreCrypto, which
  is FIPS-validated and Apple-maintained (patched via OS updates)** — no OpenSSL
  on Apple.

## Decision

**SQLCipher whole-file encryption is the single at-rest mechanism for the SQLite
backend on every platform** (per-backend coverage below). On Apple it is built
with `SQLITE_HAS_CODEC` + the **CommonCrypto**
crypto provider (`SQLCIPHER_CRYPTO_CC`) → Apple CoreCrypto (FIPS-validated); the
SQLCipher data key is a 256-bit key **wrapped by a Secure Enclave key and stored
in the Keychain**, gated by user authentication. This applies to **both iOS and
macOS**, unifying the product on one encryption model with two FIPS-validated
backends (OpenSSL FIPS provider on Windows/Linux, CoreCrypto on Apple).

The following are retained as **additive defense-in-depth layers, not the
primary guarantee**:
- **macOS:** the estate lives in an **app-group container** (SIP — the prompt /
  visibility layer) and under **FileVault** (at-rest disk layer).
- **iOS:** **Data Protection** (`FileProtectionType.completeUntilFirstUserAuthentication`,
  already wired) as a free OS layer on top of SQLCipher.

## Dependency placement

SQLCipher lives in **`PersistenceKitSQLite`** — the existing SQLite backend
adapter whose entire job is the SQLite implementation — never in the pure
`PersistenceKit` core or any other kit. This is the Ports-and-Adapters rule (a
database-driver dependency belongs in its adapter, not the domain), keeps the
open-and-key logic cohesive in one module, and matches the Rust structure
(`rusqlite`/SQLCipher in `persistence-kit`). It is recorded as a **scoped
exception** to the "zero external Swift package dependencies in kits" rule,
narrowed to the SQLite adapter — the one module whose purpose is wrapping the
SQLite C library. (The popular alternative, GRDB + SQLCipher, is rejected: GRDB
is Swift-only and would break the Swift↔Rust parity model.)

## Supply chain (CE vs EE)

The boundary that must hold is narrow: **the EE FIPS-hardened / FedRAMP-validated
build never lives in the public/forkable CE repo.** It is NOT "no third-party
source in CE" — plain open-source SQLCipher source is fine in CE (decision A,
2026-06-18). A fork getting plain BSD SQLCipher is not a disaster; a fork getting
the EE FIPS build would be.

- **CE** compiles the **official SQLCipher Community Edition amalgamation**
  (BSD-licensed, CommonCrypto build). On **Apple** it is **vendored in-tree**
  (`PersistenceKit/Sources/SQLCipher/sqlite3.c`, generated from Zetetic v4.16.0)
  — the official SwiftPM package is a binary `xcframework` we reject, and the
  Community path *is* "compile the source." On **Rust** it is the crates.io
  `bundled-sqlcipher` source-compile. Attribution (the BSD notice) is reproduced
  in the app's about/licensing surface.
- **EE** re-vendors the same Community source and FIPS-builds it (auditable,
  hermetic) in the EE repo only — that FIPS build is the EE-only artifact that
  never flows back to CE.

Never a prebuilt binary library on either edition.

## Backend coverage

Whole-file encryption is intrinsically a SQLite (embedded-file) concept; the
at-rest mechanism is **not uniform across PersistenceKit's backends**. The Mode 2
content seam is wired in the SQLite and PostgreSQL backends; InMemory stores
plaintext. The contract per backend (mirrored in PERSISTENCEKIT_SPEC B-12):

- **SQLite** — **Mode 3** whole-file SQLCipher (this ADR). Schema and content are
  ciphertext under the key; this is the structure-protection guarantee.
- **PostgreSQL** — **DECIDED: encrypt the data (we encrypt it, not the
  deployment).** There is no app-level whole-file analogue (the server owns the
  schema), so content is encrypted **client-side via Mode 2 (per-row AEAD) before
  the value reaches Postgres** — the bytes are ciphertext at rest in the database
  regardless of the server. Wired on both ports via the shared Mode 2 seam in
  PersistenceKit core, applied by `PostgreSQLRowStore`. Deployment TDE / TLS /
  RBAC remain as defense-in-depth, not the primary answer.
- **InMemory** — **DECIDED: protect the data in RAM.** The in-memory store holds
  content **encrypted** (the same AEAD seam, Mode 2) so a memory dump, debugger,
  or swap yields ciphertext, plus RAM hardening (no-swap / `mlock`, zero-on-free).
  (Currently plaintext — to build.)

**Mode 2 (per-row AEAD) is the cross-backend content-encryption mechanism** and is
the path to give PostgreSQL content encryption; **Mode 3 (whole-file) is
SQLite-only.**

## Lifecycle consequence — protected estate removal

Once an estate is SIP-container-protected (and encrypted), an external process
cannot simply `rm` the database file — deletion must go through the app/owner
that belongs to the app group. Therefore:

- **`mootx01` gains an estate-removal command** (e.g. `mootx01 estate remove
  <name>`) that performs the deletion from inside the protection boundary,
  including the SQLCipher sidecars and the container entry.
- **That command is itself authorization-gated** — it destroys data, so it is an
  availability-sensitive operation and must not be invocable casually. Gate it
  with the existing control token (`MOOT_MGR_CONTROL_TOKEN`) and explicit
  confirmation; on Apple it SHOULD additionally require Secure-Enclave / local
  authentication (LAContext) since it touches the Keychain-wrapped key. The
  command also disposes of the estate's Keychain key entry.

## Alternatives considered

- **App-group container alone.** Rejected: access control, not encryption;
  disableable and socially engineerable (the user is the weak link). Kept as a
  defense-in-depth layer only.
- **Apple Data Protection as the primary mechanism.** Rejected: not available on
  native macOS at all. Retained on iOS as an additive layer.
- **Custom CryptoKit/CommonCrypto VFS.** Rejected: hand-rolled crypto on an
  unvalidated module boundary (FIPS problem), and against the no-in-house-crypto
  directive. SQLCipher is a known, auditable quantity.
- **RowCrypto (per-row content) only.** Rejected: leaves the schema readable and
  alterable — does not meet the structure-protection bar.

## Consequences

- **Vendor the SQLCipher amalgamation (CommonCrypto, no OpenSSL)** as an in-tree
  SwiftPM C target; this is blocked on acquiring the source (the build sandbox
  denied the upstream clone — requires explicit authorization or a dropped-in
  source tree).
- **Swift `SQLiteConnection`** links the vendored SQLCipher and issues
  `sqlite3_key`; the existing Data Protection `setAttributes` call stays as the
  iOS additive layer.
- **Apple key management is new work:** a Secure-Enclave-wrapped 256-bit data key
  in the Keychain, **per estate** (keyed by the estate file path via
  `KeychainKeyStore(service:estateURL:)`), shared between the app and the managed
  server (ADR-005) — both point at the same file, so they derive the same account
  and load the same key. This is the Apple analogue of the Rust per-estate
  `db.key` (a `db.key` file inside each estate's directory). The estate-remove path
  disposes the key (`KeychainKeyStore.deleteKey()` on Apple; the `db.key` goes with
  the directory on Rust), so a key never outlives the data it protected.
- **Approved port divergences (the result is identical; the means differ):**
  - **FIPS provider** — OpenSSL FIPS on Rust (Windows/Linux), Apple CommonCrypto
    (CoreCrypto) on Apple. Both are SQLCipher under one `PRAGMA key`.
  - **Key storage** — a `0600` `db.key` file on Rust; a Keychain item on Apple.
  - **RAM-swap protection** — the Rust resident daemon calls `mlockall`; the Apple
    port relies on **macOS's encrypted virtual memory** (swap is OS-encrypted), so
    no `mlock` is needed. Confirmed and approved 2026-06-18.
- **macOS app-group container:** add `com.apple.security.application-groups`, put
  the estate path in the group container, and add the managed server to the same
  group.
- **PERSISTENCEKIT_SPEC B-12 / INTERFACE** update to describe Apple Mode 3 as
  SQLCipher (CommonCrypto) with Data Protection/container/FileVault as layers,
  when the integration lands.
- One encryption model across four platforms simplifies the FedRAMP audit story
  and the conformance surface.

## Long-term direction

SQLCipher on Apple is the **current means, not the destination.** Apple ships no
native encrypted-SQLite codec today, so a third-party codec is required to get
whole-file encryption with a FIPS-validated cipher. This is adopted with an
explicit exit condition: **when Apple provides a suitable first-party equivalent
(a native encrypted SQLite, or another Apple-native path that meets the
requirement), migrate to it as soon as reasonable** — first-party Apple crypto is
Apple-maintained, FIPS-validated, and patched via OS updates, shedding the
third-party CVE/vendoring burden. The crypto *backend* is already first-party
(CommonCrypto → CoreCrypto); only the SQLite *codec* (SQLCipher) is third-party,
and it is the piece to replace when Apple offers a native one.

## Changelog

### 1.3.2 -- 2026-06-18
Apple key management is now **per-estate** (keyed by the estate file path), the
Apple analogue of the Rust per-estate `db.key`; both ports dispose the key on
estate-remove (`KeychainKeyStore.deleteKey()` on Apple) so a key never outlives
its data. Recorded the approved port divergences: FIPS provider (OpenSSL vs
CommonCrypto), key storage (file vs Keychain), and RAM-swap protection — Rust
`mlockall` vs Apple's encrypted virtual memory (no `mlock` needed on Apple,
confirmed 2026-06-18).

### 1.3.1 -- 2026-06-18
Backend coverage status update: the PostgreSQL Mode 2 content seam is now wired
on both ports (Swift + Rust). The per-row AEAD seam was lifted into PersistenceKit
core so the SQLite and PostgreSQL backends share one byte-compatible
implementation; `PostgreSQLRowStore` applies it. InMemory at-rest remains
plaintext (RAM protection is the resident daemon's `mlock`, Rust-side).

### 1.3.0 -- 2026-06-18
Supply-chain decision A: the CE boundary is "no EE-FIPS build in the forkable CE
repo," NOT "no third-party source in CE." CE vendors the official SQLCipher
Community amalgamation in-tree on Apple (Zetetic v4.16.0, CommonCrypto); the EE
FIPS build remains EE-only. Replaces the earlier "CE is registry-linked, no
vendored source" framing.

### 1.2.0 -- 2026-06-18
Recorded two decisions on the non-SQLite backends (replacing the earlier
"deployment's job" / "N/A" framing): **encrypt PostgreSQL** (client-side Mode 2
AEAD; we encrypt the data, deployment TDE/TLS is defense-in-depth) and **protect
InMemory data in RAM** (content held encrypted + RAM hardening: no-swap/mlock,
zero-on-free). Both currently unwired — to build.

### 1.1.0 -- 2026-06-18
Added Dependency placement (SQLCipher lives in the `PersistenceKitSQLite`
adapter, scoped exception — Ports-and-Adapters, matches Rust), the CE-vs-EE
supply-chain split (CE registry-linked, no vendored source in the public repo;
EE re-vendors + FIPS-builds), and Backend coverage (Mode 3 whole-file is
SQLite-only; Postgres uses Mode 2 client-side AEAD + deployment TDE/TLS/RBAC,
currently unwired; InMemory at-rest is N/A). Qualified the Decision to "the
SQLite backend on every platform."

### 1.0.1 -- 2026-06-17
Added the Long-term direction section: SQLCipher on Apple is the current means
with an explicit Apple-native exit condition — migrate to a first-party Apple
equivalent (e.g. native encrypted SQLite) as soon as one exists and meets the
requirement.

### 1.0.0 -- 2026-06-17
Initial decision. SQLCipher (CommonCrypto/CoreCrypto, FIPS-validated, Secure-
Enclave-wrapped Keychain key) is the single at-rest mechanism on Apple (iOS +
macOS); app-group container, FileVault, and iOS Data Protection are additive
defense-in-depth layers. Supersedes the conversational choice of Apple Data
Protection as the primary Apple mechanism, on the evidence that Data Protection
is iOS-only and SIP/FileVault are not keyed-ciphertext guarantees. Records the
authorization-gated `mootx01 estate remove` lifecycle command required once
estates are SIP-protected.
