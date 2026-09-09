// ServePortHunt.swift
//
// Port availability probing and port hunt for the resident HTTP daemon.
// Extracted from ServeCommand so the loopback-bind probe and the hunt
// loop can be exercised in unit tests without importing the executable
// target. ServeCommand calls these helpers; it owns the logging and the
// ExitCode.failure throw on exhaustion.

#if os(macOS)
import Foundation
import Darwin

/// Port probing helpers for `mootx01 serve --http auto`.
///
/// Public so `ServeCommand` (in the `mootx01` executable target) can call
/// these without a bridge. Tests use `@testable import MootInstallerCore`.
public enum ServePortHunt {

    /// How many ports above the base to probe before declaring exhaustion.
    /// `ServeCommand.resolveResidentPort` passes this as the `range` argument.
    public static let huntRange: UInt16 = 100

    /// True when nothing is currently bound on `port` on 127.0.0.1.
    ///
    /// Uses a blocking `bind(2)` without `SO_REUSEADDR`, matching Rust
    /// `serve.rs::port_free` (`TcpListener::bind("127.0.0.1:port")`). This
    /// is the correct probe for a daemon that binds loopback: a wildcard
    /// bind with `SO_REUSEADDR` would report an existing loopback-only
    /// listener as free, and `--http auto` would hand back a port the
    /// runtime cannot actually bind.
    public static func portIsAvailable(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // Probe 127.0.0.1 only. inet_addr returns the address in network
        // byte order, correct on both little-endian and big-endian hosts.
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Returns the first available port in `base...(base + range)`, or `nil`
    /// when every candidate is occupied.
    ///
    /// `ServeCommand.resolveResidentPort` calls this with `range: huntRange`
    /// and throws `ExitCode.failure` when the result is `nil`.
    public static func hunt(from base: UInt16, range: UInt16 = huntRange) -> UInt16? {
        for offset: UInt16 in 0...range {
            let candidate = base &+ offset   // wrapping add; range is small (≤100)
            if portIsAvailable(candidate) { return candidate }
        }
        return nil
    }
}
#endif
