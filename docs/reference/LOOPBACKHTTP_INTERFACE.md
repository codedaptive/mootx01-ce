---
title: LoopbackHTTP Interface
version: 1.0.1
status: active
description: Public API surface of the LoopbackHTTP kit — the loopback-pinned POSIX socket and HTTP/SSE transport primitives.
spec_type: kit
authors: MOOTx01 maintainers
date: 2026-06-14
relates_to:
  - docs/reference/LOOPBACKHTTP_SPEC.md
  - docs/decisions/ADR-LOOPBACKHTTP-001.md
---

# LoopbackHTTP Interface

The public API surface of `LoopbackHTTP`. Swift only — see
§Rust below for the Swift-only rationale.

---

## Swift

### `POSIXSocket`

```swift
public enum POSIXSocket {

    /// Bind a TCP listening socket to 127.0.0.1:port and start listening.
    /// Hard-pinned to INADDR_LOOPBACK; never INADDR_ANY. port 0 = OS-assigned.
    public static func listenLoopbackTCP(port: UInt16) throws -> (fd: Int32, port: UInt16)

    /// Bind a Unix-domain listening socket at `path` and chmod it to 0600.
    /// Any stale file at `path` is unlinked first, so a leftover socket from
    /// a crashed run cannot block the bind.
    public static func listenUnix(path: String) throws -> Int32

    /// Accept one connection on a listening fd, or nil on interrupt/failure.
    /// On Darwin, each accepted fd is marked SO_NOSIGPIPE so that a peer close
    /// during a write surfaces as sendAll returning false (EPIPE) rather than
    /// raising SIGPIPE and killing the process. On Linux, MSG_NOSIGNAL is
    /// passed in sendAll instead (SO_NOSIGPIPE does not exist on Linux).
    public static func acceptOne(_ listenFD: Int32) -> Int32?

    /// Read up to `max` bytes. Empty Data on EOF; nil on error.
    public static func recv(_ fd: Int32, max: Int) -> Data?

    /// Write all of `data` to the fd. Returns true on success. A peer-closed
    /// connection returns false (EPIPE) rather than raising SIGPIPE — Darwin
    /// fds are marked SO_NOSIGPIPE at accept; Linux passes MSG_NOSIGNAL here.
    @discardableResult
    public static func sendAll(_ fd: Int32, _ data: Data) -> Bool
}
```

### `SocketError`

```swift
public enum SocketError: Error, Sendable, Equatable {
    /// A named syscall failed with this errno.
    case syscall(String, Int32)
    /// The UDS path did not fit the fixed sun_path buffer.
    case pathTooLong
}
```

### `HTTPRequest`

```swift
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String          // without the query string
    public let query: String         // raw, after '?', or ""
    public let headers: [String: String]   // header names lowercased
    public let body: Data

    public init(method: String, path: String, query: String,
                headers: [String: String], body: Data)

    /// Bearer token from Authorization, or nil. Convenience only — the
    /// accept/reject decision is the consumer's, never this library's.
    public var bearerToken: String? { get }

    /// Origin header value, or nil. Convenience only.
    public var origin: String? { get }

    /// True if Accept: text/event-stream or ?stream=1.
    public var wantsEventStream: Bool { get }

    /// Read and parse one request from `fd`. Header/body caps are per-listener
    /// (defaults 64 KiB each). Returns nil on malformed request or socket error.
    public static func read(
        fd: Int32,
        maxHeaderBytes: Int = 64 * 1024,
        maxBodyBytes: Int = 64 * 1024
    ) -> HTTPRequest?
}
```

### `HTTPResponse`

```swift
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data())

    /// A JSON response (sets Content-Type: application/json).
    public static func json(status: Int, body: Data) -> HTTPResponse

    /// A 200 static asset with Cache-Control: no-store.
    public static func asset(contentType: String, body: Data) -> HTTPResponse

    /// A 404 with {"error":"not_found"}.
    public static var notFound: HTTPResponse { get }

    /// Serialize and write to `fd`. Content-Length is computed from the body;
    /// headers emit deterministically (Content-Type, Content-Length, rest sorted)
    /// then Connection: close.
    public func send(fd: Int32)

    /// Reason phrase for the emitted status codes (200/400/401/403/404/413/500).
    public static func reason(_ status: Int) -> String
}
```

### `SSEStream`

```swift
public struct SSEStream: Sendable {
    public let fd: Int32
    public init(fd: Int32)

    /// Write the SSE response head (200 + text/event-stream + no-cache +
    /// keep-alive). Call once before any frame. False if the peer is gone.
    @discardableResult
    public func writeHead() -> Bool

    /// Send one SSE `data:` frame carrying `payload`. False on write failure.
    @discardableResult
    public func send(_ payload: String) -> Bool
}
```

---

## Rust

**None — `LoopbackHTTP` is Swift-only by decision (ADR-LOOPBACKHTTP-001).**

The Swift+Rust parity discipline governs deterministic substrate compute
conformance-gated at shared test vectors; it does not extend to OS-transport
glue. The only Rust-needing consumer (the aria-mcp Rust port) hand-rolls its own
`std::net` HTTP transport under the no-FFI law, with parity between the aria-mcp
verticals enforced at the JSON-RPC wire, not the transport implementation.
moot-mgr has no Rust port. A Rust port of `LoopbackHTTP` would have no consumer.

---

## Swift/Rust Concordance

`LoopbackHTTP` is Swift-only (see §Rust above). All public types are
Swift-only and Exempt from Swift+Rust parity requirements per
ADR-LOOPBACKHTTP-001.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| POSIX socket namespace | `POSIXSocket` | — | public enum (caseless namespace) / — | Swift caseless-enum namespace for POSIX socket operations; no Rust parity (OS-transport glue, per ADR-LOOPBACKHTTP-001) | — | Exempt (platform binding) |
| Socket error | `SocketError` | — | public enum / — | Swift-only error enum for socket-level failures; Rust aria-mcp uses `std::net` errors natively | — | Exempt (platform binding) |
| HTTP request wire type | `HTTPRequest` | — | public struct / — | Swift-only wire DTO for incoming HTTP requests; Rust side uses its own parse layer | — | Exempt (platform binding) |
| HTTP response wire type | `HTTPResponse` | — | public struct / — | Swift-only wire DTO for HTTP responses; Rust side builds responses directly | — | Exempt (platform binding) |
| Server-sent events stream | `SSEStream` | — | public struct / — | Swift-only SSE write helper; no Rust port (Apple-only MCP transport surface) | — | Exempt (platform binding) |

---

## Changelog

### 1.0.1 -- 2026-07-16
Added SIGPIPE-suppression note to `acceptOne` and `sendAll` (SO_NOSIGPIPE on Darwin / MSG_NOSIGNAL on Linux). Added stale-file-removal note to `listenUnix`. No API changes.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
