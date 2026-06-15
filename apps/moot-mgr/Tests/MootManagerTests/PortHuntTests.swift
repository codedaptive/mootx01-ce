// PortHuntTests.swift — spec §3 port selection for the moot-mgr resident host.
//
// Default (non-explicit) port hunts upward by retrying the bind on the next
// candidate; an explicitly requested port is exact — busy fails. The §3
// mgr.port file is maintained only by production (`writePortFile`) hosts,
// recorded with the BOUND port and removed on clean stop. Twin of the Rust
// tests/port_hunt_tests.rs vectors.

import Foundation
import Testing

@testable import MootManager

@Suite("ResidentHost — §3 port selection")
struct PortHuntTests {

    private let token = "0123456789abcdef0123456789abcdef"

    private func freshConfig(
        httpPort: UInt16,
        httpPortExplicit: Bool = true,
        writePortFile: Bool = false
    ) -> ResidentHostConfig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-hunt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ResidentHostConfig(
            manager: ManagerConfig(
                storeURL: dir.appendingPathComponent("stats.sqlite", isDirectory: false),
                retentionWindow: 1000
            ),
            httpPort: httpPort,
            controlToken: token,
            controlSocketPath: "/tmp/mm-h\(UUID().uuidString.prefix(8)).sock",
            estatesDirectory: dir.appendingPathComponent("estates", isDirectory: true),
            httpPortExplicit: httpPortExplicit,
            writePortFile: writePortFile
        )
    }

    /// Occupy an OS-assigned port ON 127.0.0.1 with a plain BSD socket (no
    /// reuse flags) so the host's LoopbackHTTP bind — which targets
    /// 127.0.0.1 specifically — genuinely conflicts. (An NWListener occupier
    /// binds the wildcard address, which does NOT conflict with a specific
    /// 127.0.0.1 bind.) Returns (fd, port); caller closes the fd.
    private func occupyPort() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // OS-assigned
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)
        #expect(listen(fd, 1) == 0)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        #expect(nameResult == 0)
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    @Test("Default (non-explicit) port hunts past a busy port")
    func defaultPortHunts() async throws {
        let (holder, busy) = try occupyPort()
        defer { close(holder) }

        let host = ResidentHost(config: freshConfig(httpPort: busy, httpPortExplicit: false))
        try await host.start()
        let bound = await host.boundHTTPPort()
        #expect(bound != busy, "must not claim the occupied port")
        #expect(bound > busy, "hunting goes upward")
        await host.stop()
    }

    @Test("Explicit port does not hunt — busy fails")
    func explicitPortFails() async throws {
        let (holder, busy) = try occupyPort()
        defer { close(holder) }

        let host = ResidentHost(config: freshConfig(httpPort: busy, httpPortExplicit: true))
        await #expect(throws: (any Error).self, "explicit busy port must fail, never hunt") {
            try await host.start()
        }
    }

    @Test("Port file records the BOUND port and is removed on stop")
    func portFileLifecycle() async throws {
        // Route the §3 port file into a scratch dir via MOOTX01_DATA_DIR.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-portfile-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("MOOTX01_DATA_DIR", scratch.path, 1)
        defer { unsetenv("MOOTX01_DATA_DIR") }

        let host = ResidentHost(config: freshConfig(httpPort: 0, writePortFile: true))
        try await host.start()
        let bound = await host.boundHTTPPort()

        let portFile = scratch.appendingPathComponent("mgr.port", isDirectory: false)
        let recorded = UInt16(
            (try String(contentsOf: portFile, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(recorded == bound, "port file records the BOUND port")

        await host.stop()
        #expect(!FileManager.default.fileExists(atPath: portFile.path),
                "mgr.port removed on clean stop")
    }
}
