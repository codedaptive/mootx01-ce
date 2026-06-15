---
status: decided
question: Should the loopback HTTP/1.1 server be a single shared library or duplicated per daemon?
authors: MOOTx01 maintainers
date: 2026-06-07
relates_to:
  - docs/decisions/ADR-VAULTKIT-002.md
supersedes: none
context:
  - mootx01 and moot-mgr each run a separate resident process needing a loopback-pinned HTTP server.
  - moot-mgr already has a security-audited POSIX loopback implementation that could be extracted.
---

# ADR-LOOPBACKHTTP-001 — Shared `LoopbackHTTP` library

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
moot-mgr and aria-mcp's HTTP MCP transport. Duplicating
the code instead would create two hand-rolled, security-critical loopback-bind
paths that drift independently — precisely the divergence the parity doctrine
exists to prevent.

The in-repo dependency is permitted per the repository's package-dependency policy ("Package.swift / Cargo.toml
edits — controlled, not forbidden"; precedent is ADR-VAULTKIT-002). Layering is
downstream→upstream (app → zero-dependency lib); no inversion.

### Three binding conditions (from architecture review)

1. **General response/streaming seam.** The shared API is NOT moot-mgr's closed
   four-case `HTTPResponse` enum. It is a general response value (status +
   headers + body) with caller-side constructors, plus a consumer-driven SSE
   primitive: the library owns `text/event-stream` framing; each consumer owns
   its own stream source and connection lifetime. This lets the MCP transport
   consume a finished contract rather than inherit a refactor.

2. **Configurable request limits.** Header/body size caps are per-listener
   parameters, not hardcoded constants. moot-mgr keeps its existing 64KB
   defaults (behavior-neutral); the MCP listener sets limits appropriate to
   `tools/call` bodies. The previous silent body truncation must not corrupt
   large MCP requests.

3. **Edition-neutral, auth-free invariant.** No authentication, authorization,
   token, Origin, or OAuth logic ever enters `LoopbackHTTP`. It exposes only a
   generic request→response (+ streaming) seam. Consumers compose credential
   logic above the transport: nothing for the loopback default, bearer+Origin in
   moot-mgr, OAuth 2.1 in the v2 remote layer. The library ships unchanged
   regardless of which credential layer composes above it.

### Rust parity

`LoopbackHTTP` is **Swift-only**. The Swift+Rust parity discipline governs
deterministic substrate compute conformance-gated at shared test vectors; it does
not extend to OS-transport glue. The only Rust-needing consumer, the aria-mcp
Rust port, is a complete Rust vertical that under the no-FFI law hand-rolls its own
`std::net` HTTP transport, with parity between the aria-mcp verticals enforced at
the JSON-RPC wire, not the transport layer. moot-mgr has no Rust port. A Rust
port of `LoopbackHTTP` would have no consumer.

## Consequences

- One audited loopback HTTP implementation; no drift between the two daemons.
- moot-mgr gains a dependency and an `import LoopbackHTTP`; its HTTP files lose
  ~350 lines (moved) and its response/SSE construction migrates to the general
  seam, behavior-neutral (verified by the existing moot-mgr test suite passing
  unchanged).
- The aria-mcp HTTP transport consumes the same lib against a decided contract.

## Revisit when

- A **Rust moot-mgr build** is undertaken (roadmapped, not scheduled): it would
  introduce a Rust consumer with no wire-conformance gate above it and reopen the
  Swift-only carve-out. This is the explicit re-review trigger.
- The v2 remote/OAuth layer lands: confirm it composes auth strictly *above*
  the transport and adds nothing to `LoopbackHTTP` (condition 3).
