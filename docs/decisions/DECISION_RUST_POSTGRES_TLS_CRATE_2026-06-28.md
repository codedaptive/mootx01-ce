---
status: decided
question: Which Rust crate to adopt for PostgreSQL TLS transport, and under what C-1 per-crate exception
authors: MOOTx01 maintainers
date: 2026-06-28
relates_to:
  - docs/reference/PERSISTENCEKIT_SPEC.md
  - docs/reference/PERSISTENCEKIT_INTERFACE.md
supersedes: none
context:
  - PostgreSQL TLS transport ships in Swift via NIOSSL (through PostgresNIO); the Rust port needs an equivalent TLS connector for the sync `postgres` 0.19 crate.
  - The C-1 constraint prohibits external crate dependencies without a recorded per-crate exception.
  - CAND-029 (SECFIX-WS2-PK F3) added the PostgresTlsMode knob to the Rust port but left open_connection fail-closed for Prefer/Require pending dep approval.
---

# Decision: Rust PostgreSQL TLS crate — C-1 per-crate exception for `postgres-native-tls`

## Context

The Swift PostgreSQL backend (`PostgreSQLPool.swift`) achieves TLS via
NIOSSL (`TLSConfiguration.makeClientConfiguration()` wrapped in
`NIOSSLContext`), with parity semantics across three modes: `disable`,
`prefer` (default — TLS if offered, plaintext fallback), and `require`
(TLS mandatory; fail if the server does not offer it).

The Rust `postgres` 0.19 crate ships `NoTls` as its only built-in
transport. TLS transports are separate optional crates (`postgres-openssl`
or `postgres-native-tls`). Adding either requires a C-1 per-crate
exception.

This document is that exception, completing CAND-029.

---

## Decision

**Use `postgres-native-tls = "0.5"` as the Rust TLS transport for the
PostgreSQL backend.**

`postgres-native-tls` is approved as a production dependency of
`persistence-kit`.

**Companion crate `native-tls = "0.2"` is approved under the same
exception.** `postgres-native-tls` does not re-export `native_tls`, so
`Pool::open_connection` constructs `TlsConnector::builder()` directly and
needs `native-tls` named explicitly. `native-tls` is already a transitive
dependency of `postgres-native-tls` (pulled in regardless), so making it
explicit adds **no new package to the resolved dependency graph** — it only
pins the version constraint (0.2.x) we already resolve. This mirrors the Swift
side, where `swift-nio-ssl` (a transitive dependency of `postgres-nio`) is
named explicitly so the target may import `NIOSSL`. Both wrap the platform TLS
stack; neither bundles a cryptographic implementation.

---

## Rationale

### Supply-chain surface

`postgres-native-tls` wraps the **platform TLS stack**, not a bundled
implementation:

| Platform | Underlying TLS stack |
|---|---|
| macOS / iOS | `Security.framework` (Apple, platform-native) |
| Windows | `SChannel` (Microsoft, platform-native) |
| Linux | `OpenSSL` (system-installed, not bundled) |

This avoids vendoring a full OpenSSL build into the binary (as
`postgres-openssl` would require on macOS and Windows). The TLS
implementation is maintained by the OS vendor, not by the crate.
Supply-chain surface is minimized: one thin adapter crate, zero
bundled cryptographic implementations.

### Parity with Swift

The Swift port uses `NIOSSL`, which also delegates to the platform TLS
stack (Security.framework on Apple). `postgres-native-tls` mirrors this
posture on the Rust side. Both ports use the same three-mode semantics:

| Mode | Swift (`NIOSSL`) | Rust (`postgres-native-tls`) |
|---|---|---|
| `disable` | `.disable` | `NoTls` (unchanged) |
| `prefer` | `.prefer(NIOSSLContext)` | `MakeTlsConnector` + `sslmode=prefer` |
| `require` | `.require(NIOSSLContext)` | `MakeTlsConnector` + `sslmode=require` |

### Correctness of `prefer` fallback

`sslmode=prefer` in the postgres connection string, combined with a
`MakeTlsConnector`, instructs the `postgres` crate to attempt TLS
negotiation and accept a plaintext connection if the server declines.
This matches Swift's `.prefer(context)` behaviour and the documented
PostgreSQL sslmode semantics.

`sslmode=require` causes the connection to fail if the server does not
offer TLS — the correct, fail-closed behavior for production connections
over untrusted networks.

---

## Rejected alternative

**`postgres-openssl = "0.5"`:** Rejected. This crate vendors a full
OpenSSL build into the binary on macOS and Windows, dramatically
increasing supply-chain surface compared to using the platform TLS
stack. `postgres-native-tls` achieves identical behavior with a lighter
dependency footprint.

---

## Crate details

| Field | Value |
|---|---|
| Crate | `postgres-native-tls` |
| Version | `0.5` |
| Source | crates.io |
| Underlying TLS | Platform stack via `native-tls` (transitive dep) |
| Usage | Internal to `postgres.rs` `Pool::open_connection`; not re-exported |
| Approval type | C-1 per-crate exception |

---

## FedRAMP / custom CA path

`native_tls::TlsConnector::builder()` exposes `add_root_certificate()`,
`identity()`, and certificate-verification controls. When FedRAMP or
custom-CA requirements land, the connector can be configured at
`Pool::open_connection` via `EstateConfiguration` without changing the
public `Storage` API. The connector construction is intentionally isolated
to a single private function (`build_tls_connector`) for this reason.
