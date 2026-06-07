// ControlChannelTests.swift
//
// P3 verify line for the gated control channel: the Unix domain socket is
// created at 0600, control verbs (monitoring on/off, set retention) applied
// over it mutate the store, and the change is reflected in /api/config.
//
// These tests drive a REAL UDS via a raw POSIX client socket (Network.framework
// has no convenient UDS client for a test, and a hand-rolled connect() keeps the
// test free of extra dependencies).

import Testing
import Foundation
import ObserverSink
@testable import MootManager

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Helpers

private func makeTempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-uds-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("stats.sqlite", isDirectory: false)
}

private func makeTempSocketPath() -> String {
    "/tmp/mmc-\(UUID().uuidString.prefix(8)).sock"
}

private func makeTempEstatesDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-estates-\(UUID().uuidString)", isDirectory: true)
}

private let testToken = "0123456789abcdef0123456789abcdef"

/// Start a host and return it plus the control socket path.
private func makeStartedHost(socketPath: String) async throws -> ResidentHost {
    let cfg = ResidentHostConfig(
        manager: ManagerConfig(storeURL: makeTempStoreURL(), retentionWindow: 7200),
        httpPort: 0,
        controlToken: testToken,
        controlSocketPath: socketPath,
        estatesDirectory: makeTempEstatesDir()
    )
    let host = ResidentHost(config: cfg)
    try await host.start()
    return host
}

/// Connect to the UDS, write `request`, read the response line. Blocking POSIX
/// calls wrapped in a detached task so the test stays async.
private func udsRoundTrip(socketPath: String, request: String) async -> String {
    await Task.detached(priority: .userInitiated) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dstPtr in
                    strncpy(dstPtr, src, pathCapacity - 1)
                }
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)

        let reqBytes = Array(request.utf8)
        _ = reqBytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return "" }
        return String(bytes: buf[0..<n], encoding: .utf8) ?? ""
    }.value
}

// MARK: - Resident host config resolution

struct ResidentHostConfigTests {

    @Test("fromEnvironment resolves port, token, and a default socket beside the store")
    func envResolution() {
        let env = [
            ManagerConfig.storePathEnvKey: "/tmp/x/stats.sqlite",
            ResidentHostConfig.httpPortEnvKey: "9099",
            ResidentHostConfig.controlTokenEnvKey: testToken,
        ]
        let cfg = ResidentHostConfig.fromEnvironment(env)
        #expect(cfg.httpPort == 9099)
        #expect(cfg.controlToken == testToken)
        // Default control socket sits beside the store file.
        #expect(cfg.controlSocketPath == "/tmp/x/control.sock")
        #expect(cfg.manager.storeURL.path == "/tmp/x/stats.sqlite")
    }

    @Test("fromEnvironment defaults the HTTP port and empty token when absent")
    func envDefaults() {
        let cfg = ResidentHostConfig.fromEnvironment([
            ManagerConfig.storePathEnvKey: "/tmp/y/stats.sqlite"
        ])
        #expect(cfg.httpPort == ResidentHostConfig.defaultHTTPPort)
        #expect(cfg.controlToken == "")   // no default token → HTTP control disabled
    }
}

// MARK: - Socket permissions

struct ControlChannelPermissionTests {

    @Test("UDS is created at 0600 (owner-only)")
    func socketModeIs0600() async throws {
        let path = makeTempSocketPath()
        let host = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        #expect(FileManager.default.fileExists(atPath: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        // Mask to the permission bits; must be exactly 0600.
        #expect(perms & 0o777 == 0o600)
    }

    @Test("stopping the host removes the socket file")
    func stopRemovesSocket() async throws {
        let path = makeTempSocketPath()
        let host = try await makeStartedHost(socketPath: path)
        #expect(FileManager.default.fileExists(atPath: path))
        await host.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - Control verbs over UDS

struct ControlChannelVerbTests {

    @Test("monitoring on/off over UDS mutates the store and shows in /api/config")
    func monitoringVerbsOverUDS() async throws {
        let path = makeTempSocketPath()
        let host = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }
        let manager = host.managerHandle()

        // Default off.
        #expect(try await manager.isMonitoring() == false)

        let onResp = await udsRoundTrip(socketPath: path,
                                            request: "/api/control/monitoring/on\n")
        #expect(onResp.contains("\"ok\":true"))
        #expect(try await manager.isMonitoring() == true)
        let cfgOn = try await manager.configPayload()
        #expect(cfgOn.monitoringEnabled == true)

        let offResp = await udsRoundTrip(socketPath: path,
                                             request: "/api/control/monitoring/off\n")
        #expect(offResp.contains("\"ok\":true"))
        #expect(try await manager.isMonitoring() == false)
    }

    @Test("set retention over UDS updates the effective window and /api/config")
    func retentionVerbOverUDS() async throws {
        let path = makeTempSocketPath()
        let host = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }
        let manager = host.managerHandle()

        // Configured default window is 7200s.
        #expect(try await manager.configPayload().retentionSeconds == 7200)

        let resp = await udsRoundTrip(
            socketPath: path,
            request: "/api/control/retention\t{\"seconds\":3600}\n")
        #expect(resp.contains("\"ok\":true"))
        #expect(resp.contains("3600"))

        let cfg = try await manager.configPayload()
        #expect(cfg.retentionSeconds == 3600)
    }

    @Test("set retention rejects a non-positive window")
    func retentionRejectsNonPositive() async throws {
        let path = makeTempSocketPath()
        let host = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        let resp = await udsRoundTrip(
            socketPath: path,
            request: "/api/control/retention\t{\"seconds\":0}\n")
        #expect(resp.contains("\"ok\":false"))
        // Window unchanged.
        #expect(try await host.managerHandle().configPayload().retentionSeconds == 7200)
    }

    @Test("unknown verb over UDS returns ok:false")
    func unknownVerbOverUDS() async throws {
        let path = makeTempSocketPath()
        let host = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        let resp = await udsRoundTrip(socketPath: path,
                                          request: "/api/control/bogus\n")
        #expect(resp.contains("\"ok\":false"))
    }
}
