// ServePortHuntTests.swift
//
// Functional tests for ServePortHunt — the loopback-bind probe and the
// port hunt used by `mootx01 serve --http auto`.
//
// The tests bind a socket on a kernel-assigned loopback port, hold it for
// the duration of the assertion, and verify that:
//   (a) portIsAvailable reports false for the held port
//   (b) hunt skips the held port and returns the next free one
//   (c) hunt returns nil when the only candidate is occupied
//
// (d) is a source-text guard that verifies ServeCommand.resolveResidentPort
// throws ExitCode.failure and logs the expected prefix when hunt returns nil.
// That code path is in the executable target and cannot be called directly
// from this test target.

#if os(macOS)
import Testing
import Foundation
import Darwin
@testable import MootInstallerCore

@Suite("ServePortHunt — port availability probe and auto hunt")
struct ServePortHuntTests {

    // MARK: - helpers

    /// Bind a SOCK_STREAM socket on 127.0.0.1 with a kernel-assigned port.
    /// Returns the file descriptor (caller must close) and the assigned port.
    /// The socket is left bound so the port is held for the test duration.
    private func bindLoopbackPort() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "ServePortHuntTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0   // let the kernel assign a free port
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok: Bool = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else {
            close(fd)
            throw NSError(domain: "ServePortHuntTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(errno)"])
        }
        // Read back the port the kernel assigned.
        var out = sockaddr_in()
        var outLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &outLen)
            }
        }
        return (fd, UInt16(bigEndian: out.sin_port))
    }

    // MARK: - tests

    /// `portIsAvailable` must return false for a port that is already bound on
    /// 127.0.0.1. A wildcard bind with SO_REUSEADDR would not catch this; the
    /// loopback-only probe without SO_REUSEADDR does.
    @Test func portIsAvailableReturnsFalseForOccupiedPort() throws {
        let (holdFd, occupiedPort) = try bindLoopbackPort()
        defer { close(holdFd) }
        #expect(!ServePortHunt.portIsAvailable(occupiedPort),
            "portIsAvailable must return false for an already-bound loopback port")
    }

    /// `hunt` must skip an occupied port and return the next free one.
    /// Verifies the core `--http auto` behaviour: a resident already on the
    /// default port must not block a second process that hunts upward.
    @Test func huntSkipsOccupiedPort() throws {
        let (holdFd, occupiedPort) = try bindLoopbackPort()
        defer { close(holdFd) }
        // Hunt with a range of 10 — enough that the next free port is found.
        let found = ServePortHunt.hunt(from: occupiedPort, range: 10)
        #expect(found != nil, "hunt must find a free port in range 10 above an occupied one")
        #expect(found != occupiedPort, "hunt must not return the occupied port")
    }

    /// When the only candidate in range is occupied, `hunt` must return nil.
    /// `ServeCommand.resolveResidentPort` translates nil to ExitCode.failure.
    @Test func huntReturnsNilWhenOnlyCandidateIsOccupied() throws {
        let (holdFd, occupiedPort) = try bindLoopbackPort()
        defer { close(holdFd) }
        // range: 0 — the hunt tries only `occupiedPort`.
        let found = ServePortHunt.hunt(from: occupiedPort, range: 0)
        #expect(found == nil,
            "hunt with range 0 over an occupied port must return nil (exhausted)")
    }

    /// Source-text guard: when hunt returns nil, ServeCommand.resolveResidentPort
    /// must throw ExitCode.failure and log the canonical prefix so operators can
    /// grep for it. This guard catches any accidental removal of that path.
    @Test func exhaustionPathThrowsAndLogsCanonicalPrefix() throws {
        let here = URL(fileURLWithPath: #filePath)
        let source = here
            .deletingLastPathComponent()   // strip filename
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Sources/mootx01/Commands/ServeCommand.swift")
        let lines = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(lines.contains { $0.contains("throw ExitCode.failure") },
            "ServeCommand.resolveResidentPort must throw ExitCode.failure on port exhaustion")
        #expect(lines.contains { $0.contains("mootx01: no free port in") },
            "ServeCommand.resolveResidentPort must log 'mootx01: no free port in' on exhaustion")
    }
}
#endif
