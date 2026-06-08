// swift-tools-version:6.2
//
// LoopbackHTTP — a zero-dependency, loopback-pinned HTTP/1.1 server primitive.
//
// Extracted from moot-mgr (ADR-LOOPBACKHTTP-001) so the moot-mgr monitor daemon
// and the resident mootx01 MCP daemon share ONE audited loopback-bind
// implementation instead of two hand-rolled copies that drift. The library wraps
// the system C socket API (libc / Darwin) only — no external packages, per the
// kit dependency rules. It binds strictly to 127.0.0.1 (never INADDR_ANY) and
// owns HTTP/1.1 request parsing, buffered-response writing, and SSE framing.
//
// EDITION-NEUTRAL / AUTH-FREE INVARIANT (ADR-LOOPBACKHTTP-001, condition 3):
// no authentication, authorization, token, Origin, or OAuth logic ever lives
// here. The library exposes only a generic request -> response (+ streaming)
// seam; consumers compose credential logic ABOVE the transport (nothing in
// Community Edition, bearer+Origin in moot-mgr, OAuth 2.1 in the EE-only v2
// remote layer). This keeps the same binary shipping unchanged in both editions.
//
// Swift-only (ADR-LOOPBACKHTTP-001): the Swift+Rust parity discipline governs
// deterministic substrate compute gated at shared vectors, not OS-transport
// glue. ARIA_MCP-rust hand-rolls its own std::net transport under the no-FFI
// law; parity is enforced at the JSON-RPC wire.
//
// Platforms: macOS 26 / iOS 26 (Apple Silicon); also builds on Linux Swift via
// the Glibc import guard in POSIXSocket.swift.

import PackageDescription

let package = Package(
    name: "LoopbackHTTP",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "LoopbackHTTP", targets: ["LoopbackHTTP"]),
    ],
    targets: [
        .target(
            name: "LoopbackHTTP",
            path: "Sources/LoopbackHTTP"
        ),
        .testTarget(
            name: "LoopbackHTTPTests",
            dependencies: ["LoopbackHTTP"],
            path: "Tests/LoopbackHTTPTests"
        ),
    ]
)
