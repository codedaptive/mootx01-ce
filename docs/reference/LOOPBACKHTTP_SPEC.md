---
title: LoopbackHTTP Specification
version: 1.0.2
status: active
description: Specifies the shared loopback-pinned HTTP/1.1 server primitive (POSIXSocket, HTTPRequest, HTTPResponse, SSEStream) used by the MOOTx01 resident daemons.
spec_type: kit
authors: MOOTx01 maintainers
date: 2026-06-15
relates_to:
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#23-loopback-http-boundary
  - docs/reference/MOOT_MGR_SPEC.md
  - docs/reference/ARIA_MCP_SPEC.md
---

# LoopbackHTTP Specification

## 1. Purpose

`LoopbackHTTP` is the shared, zero-dependency, loopback-pinned HTTP/1.1 server
primitive for the MOOTx01 resident daemons. It provides:

1. **`POSIXSocket`** — loopback TCP and Unix-domain listening sockets plus
   blocking read/write helpers, wrapping the system C socket API (libc / Darwin)
   with no external package.
2. **`HTTPRequest`** — a minimal HTTP/1.1 request parser (request line, headers,
   optional Content-Length body) with per-listener size limits.
3. **`HTTPResponse`** — a general buffered response value (status + headers +
   body) the caller composes, with convenience constructors and a wire writer.
4. **`SSEStream`** — a Server-Sent-Events primitive that owns the
   `text/event-stream` framing while the consumer owns the stream source and the
   connection lifetime.

It was extracted from moot-mgr (the loopback HTTP contract) so the moot-mgr monitor
daemon (default port 4200) and the resident mootx01 MCP daemon (default port 4242) share ONE
audited loopback-bind implementation rather than two hand-rolled copies that
drift. moot-mgr consumes it today; the mootx01 HTTP MCP transport consumes it
next.

## 2. Module location

```
packages/libs/LoopbackHTTP/
├── Package.swift                         ← Swift package (swift-tools-version:6.2)
├── Sources/LoopbackHTTP/
│   ├── POSIXSocket.swift                 ← socket helpers + SocketError
│   └── HTTPWire.swift                    ← HTTPRequest + HTTPResponse + SSEStream
└── Tests/LoopbackHTTPTests/
    └── LoopbackHTTPTests.swift           ← socketpair wire-contract tests
```

## 3. Dependencies

None. `LoopbackHTTP` imports only `Foundation` and the platform socket module
(`Darwin` on Apple platforms, `Glibc` on Linux, via a `#if canImport(Glibc)`
guard). It is a floor-level platform-glue library; consumers depend on it
app→lib (downstream→upstream), never the reverse. No external (third-party)
packages.

## 4. Security boundary

- **Loopback only.** `POSIXSocket.listenLoopbackTCP` hard-pins `sin_addr` to
  `INADDR_LOOPBACK` (`127.0.0.1`), never `INADDR_ANY` / `0.0.0.0`. Off-host peers
  cannot reach a listener built on it (concepts §1.6).
- **UDS at 0600.** `POSIXSocket.listenUnix` creates the socket file and
  immediately `chmod`s it to `0600` (owner-only) before `listen`, so the
  filesystem permission bits are the access gate for a privileged channel.
- **No transport-layer auth.** See §6.

## 5. Response / streaming seam

The response surface is a general value, not a fixed set of consumer-specific
cases (the loopback HTTP contract, condition 1):

- `HTTPResponse` is `{ status: Int, headers: [String:String], body: Data }`.
  Convenience constructors (`.json`, `.asset`, `.notFound`) build common shapes
  without being the only shapes a consumer can produce. `send(fd:)` computes
  `Content-Length` from the body, emits headers in a deterministic order
  (Content-Type, Content-Length, remaining keys sorted) plus `Connection: close`.
- SSE is a separate `SSEStream`: the library owns the wire framing (the
  `text/event-stream` response head and `data: …\n\n` frame encoding); the
  consumer owns the stream's source, cadence, lifetime, and fd close. A buffered
  response never carries a "keep open" sentinel.

## 6. Edition-neutral, auth-free invariant

No authentication, authorization, token, Origin, or OAuth logic lives in this
library (the loopback HTTP contract, condition 3). `HTTPRequest` exposes `bearerToken`
and `origin` as read-only conveniences for a consumer to inspect; the decision to
accept or reject is the consumer's, composed above the transport. This keeps the
same binary shipping unchanged in Community Edition (loopback, no auth) and
Enterprise Edition (whose v2 remote/OAuth layer composes above this transport).

**CSRF note — SSE and the Origin header.** `HTTPRequest.wantsEventStream` is
true when the client sets `Accept: text/event-stream` or appends `?stream=1`.
A browser SSE request via `?stream=1` is a plain GET, so the browser's CORS
preflight does NOT fire for same-origin policies. A malicious page on a
different origin can therefore open an SSE connection to a loopback port that
the browser can reach. Consumers that expose sensitive data over SSE MUST
validate `request.origin` before calling `SSEStream.writeHead()` and MUST
reject connections from unexpected origins. The transport does not enforce
this; accept/reject policy belongs to
the consumer layer.

## 7. Request limits

`HTTPRequest.read(fd:maxHeaderBytes:maxBodyBytes:)` takes per-listener size caps
(the loopback HTTP contract, condition 2). Defaults are `64 * 1024` for both, matching
moot-mgr's prior hardcoded behavior. A body declared larger than `maxBodyBytes`
is read up to the cap; a consumer that must not truncate (e.g. an MCP
`tools/call` listener) sets a cap large enough that a valid request cannot be
truncated, or rejects an over-large `Content-Length` before reading.

## 8. Swift-only port

`LoopbackHTTP` ships **Swift only**. The Swift+Rust parity discipline governs
deterministic substrate compute conformance-gated at shared test vectors; it does
not extend to OS-transport glue (there is nothing to conformance-gate in a socket
bind). The only Rust-needing consumer, the aria-mcp Rust port, is a complete Rust vertical
that under the no-FFI law hand-rolls its own `std::net` HTTP transport, with
parity between the aria-mcp verticals enforced at the JSON-RPC wire. moot-mgr has
no Rust port. **Re-review trigger:** a roadmapped Rust moot-mgr build would
introduce a Rust consumer without a wire-conformance gate and reopen this
carve-out (the loopback HTTP contract).

## 9. Tests

`Tests/LoopbackHTTPTests/LoopbackHTTPTests.swift` (6 tests, Swift Testing)
exercises the real socket paths over a connected `socketpair`:

1. GET parse — path, query, headers, `wantsEventStream`, `origin`, `bearerToken`
2. POST body read up to Content-Length
3. Per-listener body cap bounds the body read
4. Buffered response writes status line, headers, body
5. `notFound` is a 404 JSON response
6. SSE stream writes the event-stream head then `data:` frames

End-to-end coverage of the listener under a live loopback socket continues to
live in moot-mgr's own suite.

## 10. Invariants

- **I-1**: Listeners bind loopback only (`INADDR_LOOPBACK`) or UDS at `0600`.
  Never `INADDR_ANY`.
- **I-2**: No authentication/authorization/Origin/OAuth logic in this library.
- **I-3**: `HTTPResponse` is a general value; SSE framing is owned here, stream
  source and lifetime are owned by the consumer.
- **I-4**: Request size caps are per-listener parameters, not hardcoded.
- **I-5**: Zero external dependencies; Swift + platform socket module only.

## Changelog

### 1.0.2 -- 2026-07-16
Added CSRF note to §6 (auth-free invariant): SSE `?stream=1` requests bypass CORS preflight; consumers MUST validate `request.origin` before upgrading to an event stream. No invariant changes — this documents existing required behavior that was only in the source doccomments.

### 1.0.1 -- 2026-06-15
Corrected the moot-mgr daemon port from the retired debug port `7077` to its current default `4200` (the mootx01 daemon default is `4242`). Both are defaults that hunt upward to the next free port if the base is already bound.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
