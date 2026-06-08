# ADR-LOOPBACKHTTP-001 — Shared `LoopbackHTTP` library

Status: Accepted (2026-06-07)
Deciders: Bob; MOOTx01 maintainers.

## Context

The resident-HTTP build makes mootx01 a headless resident HTTP MCP daemon
alongside the existing moot-mgr monitor daemon. Both are separate resident
processes, and **each needs a loopback-pinned, zero-dependency HTTP/1.1 server**:
moot-mgr for its dashboard read-API + control channel (port 7077), mootx01 for
its MCP JSON-RPC + SSE transport (port 4242). A separate process cannot share
another process's socket, so two running listeners are unavoidable — but two
*implementations* are not.

moot-mgr already contains a working, security-audited POSIX implementation
(`POSIXSocket.swift`, `HTTPWire.swift`): loopback bind hard-pinned to
`INADDR_LOOPBACK`, UDS at 0600, request parser, response writer, SSE support.

## Decision

Extract that implementation into a new shared Swift library
`packages/libs/LoopbackHTTP` and consume it app→lib from both daemons:
moot-mgr (this mission, P1a) and ARIA_MCP's HTTP MCP transport (P1b). Duplicating
the code instead would create two hand-rolled, security-critical loopback-bind
paths that drift independently — precisely the divergence the parity doctrine
exists to prevent.

The in-repo dependency is permitted per CLAUDE.md "Package.swift / Cargo.toml
edits — controlled, not forbidden"; precedent is ADR-VAULTKIT-002. Layering is
downstream→upstream (app → zero-dependency lib); no inversion.

### Three binding conditions (from architecture review)

1. **General response/streaming seam.** The shared API is NOT moot-mgr's closed
   four-case `HTTPResponse` enum. It is a general response value (status +
   headers + body) with caller-side constructors, plus a consumer-driven SSE
   primitive: the library owns `text/event-stream` framing; each consumer owns
   its own stream source and connection lifetime. This lets the MCP transport
   (P1b) consume a finished contract rather than inherit a refactor.

2. **Configurable request limits.** Header/body size caps are per-listener
   parameters, not hardcoded constants. moot-mgr keeps its existing 64KB
   defaults (behavior-neutral); the MCP listener sets limits appropriate to
   `tools/call` bodies. The previous silent body truncation must not corrupt
   large MCP requests.

3. **Edition-neutral, auth-free invariant.** No authentication, authorization,
   token, Origin, or OAuth logic ever enters `LoopbackHTTP`. It exposes only a
   generic request→response (+ streaming) seam. Consumers compose credential
   logic above the transport: nothing in Community Edition, bearer+Origin in
   moot-mgr, OAuth 2.1 in the EE-only v2 remote layer. The library ships
   unchanged in both editions.

### Rust parity

`LoopbackHTTP` is **Swift-only**. The Swift+Rust parity discipline governs
deterministic substrate compute conformance-gated at shared test vectors; it does
not extend to OS-transport glue. The only Rust-needing consumer, ARIA_MCP-rust,
is a complete Rust vertical that under the no-FFI law hand-rolls its own
`std::net` HTTP transport, with parity between the ARIA_MCP verticals enforced at
the JSON-RPC wire, not the transport layer. moot-mgr has no Rust port. A Rust
port of `LoopbackHTTP` would have no consumer.

## Consequences

- One audited loopback HTTP implementation; no drift between the two daemons.
- moot-mgr gains a dependency and an `import LoopbackHTTP`; its HTTP files lose
  ~350 lines (moved) and its response/SSE construction migrates to the general
  seam, behavior-neutral (verified by the existing moot-mgr test suite passing
  unchanged).
- P1b (ARIA_MCP HTTP transport) consumes the same lib against a decided contract.

## Revisit when

- A **Rust moot-mgr build** is undertaken (roadmapped, not scheduled): it would
  introduce a Rust consumer with no wire-conformance gate above it and reopen the
  Swift-only carve-out. This is the explicit re-review trigger.
- The EE v2 remote/OAuth layer lands: confirm it composes auth strictly *above*
  the transport and adds nothing to `LoopbackHTTP` (condition 3).

## Notes

- `DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md` is cited by name across the
  codebase but the file is absent from the repo and docs repo; the rule is stated
  authoritatively in CLAUDE.md. This ADR cites the CLAUDE.md rule text +
  ADR-VAULTKIT-002 precedent rather than the dangling path.
