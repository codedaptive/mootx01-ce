// AdminPlaneGatedTests.swift
//
// P6 verify line (gated end-to-end): the admin verbs are reachable ONLY through
// the gated control surfaces and behave identically on both:
//   * provisioning + lifecycle drive a real (scratch InMemory) estate over the
//     UDS control channel, and the result carries the estate UUID + mount state;
//   * the same admin verb over HTTP is REJECTED without a token (401) and over a
//     cross-origin Origin (403) — admin = privileged write, never ungated;
//   * the provisioned estate's mount state is reflected in GET /api/estates.
//
// Scratch only: every estate is InMemory under a temp estates dir; nothing on the
// filesystem outside the OS temp dir is touched.

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

private let apToken = "0123456789abcdef0123456789abcdef"

private func makeTempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-ap-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("stats.sqlite", isDirectory: false)
}

private func makeTempSocketPath() -> String {
    "/tmp/mm-ap-\(UUID().uuidString.prefix(8)).sock"
}

private func makeTempEstatesDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-ap-estates-\(UUID().uuidString)", isDirectory: true)
}

private func makeStartedHost(socketPath: String) async throws -> (host: ResidentHost, port: UInt16) {
    let cfg = ResidentHostConfig(
        manager: ManagerConfig(storeURL: makeTempStoreURL(), retentionWindow: 7200),
        httpPort: 0,
        controlToken: apToken,
        controlSocketPath: socketPath,
        estatesDirectory: makeTempEstatesDir()
    )
    let host = ResidentHost(config: cfg)
    try await host.start()
    let port = await host.boundHTTPPort()
    return (host, port)
}

/// Round-trip one request line over the UDS control channel.
private func udsRoundTrip(socketPath: String, request: String) async -> String {
    await Task.detached(priority: .userInitiated) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: cap) { strncpy($0, src, cap - 1) }
            }
        }
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return "" }
        _ = Array(request.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return "" }
        return String(bytes: buf[0..<n], encoding: .utf8) ?? ""
    }.value
}

/// One HTTP request over loopback → (status, body).
private func httpRequest(
    port: UInt16, method: String, path: String,
    headers: [String: String] = [:], body: Data? = nil
) async throws -> (status: Int, body: String) {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    req.httpMethod = method
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    return (status, String(data: data, encoding: .utf8) ?? "")
}

/// A provision request body (JSON) for a scratch InMemory GLK estate.
private func provisionBodyJSON(name: String) -> String {
    let req = EstateAdminRequest(
        estateName: name, kind: "GLK", backend: "InMemory",
        zoomWindowLow: 1, zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork", syncMode: "None", owner: "ap-tests")
    let data = try! APIJSON.encode(req)
    return String(data: data, encoding: .utf8)!
}

// MARK: - Admin verbs over the gated UDS channel

@Suite("Admin plane — gated UDS")
struct AdminPlaneUDSTests {

    @Test("provision over UDS returns ok + estate UUID + mounted, and reflects in /api/estates")
    func provisionOverUDS() async throws {
        try await withIntellectusLock {
        let path = makeTempSocketPath()
        let (host, port) = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        let body = provisionBodyJSON(name: "ProvUDS")
        let resp = await udsRoundTrip(
            socketPath: path,
            request: "/api/control/estate/provision\t\(body)\n")
        #expect(resp.contains("\"ok\":true"))

        let result = try JSONDecoder().decode(
            EstateAdminResult.self,
            from: Data(resp.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        #expect(result.ok)
        #expect(result.mountState == "mounted")
        let uuid = try #require(result.estateUUID)

        // Reflected in the read plane's Estates view.
        let (status, estatesBody) = try await httpRequest(port: port, method: "GET", path: "/api/estates")
        #expect(status == 200)
        let payload = try JSONDecoder().decode(EstatesPayload.self, from: Data(estatesBody.utf8))
        let admin = try #require(payload.admin)
        #expect(admin.hosted.contains { $0.estateUUID == uuid && $0.mountState == "mounted" })
        }  // withIntellectusLock
    }

    @Test("quiesce then destroy over UDS, with mount-state reflection")
    func lifecycleOverUDS() async throws {
        try await withIntellectusLock {
        let path = makeTempSocketPath()
        let (host, port) = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        // Provision first.
        let provResp = await udsRoundTrip(
            socketPath: path,
            request: "/api/control/estate/provision\t\(provisionBodyJSON(name: "Life"))\n")
        let prov = try JSONDecoder().decode(
            EstateAdminResult.self,
            from: Data(provResp.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        let uuid = try #require(prov.estateUUID)

        // Quiesce.
        let qBody = try! APIJSON.encode(EstateLifecycleRequest(estateUUID: uuid))
        let qResp = await udsRoundTrip(
            socketPath: path,
            request: "/api/control/estate/quiesce\t\(String(data: qBody, encoding: .utf8)!)\n")
        #expect(qResp.contains("\"mountState\":\"quiesced\""))

        // Reflected in /api/estates.
        let (_, estatesBody) = try await httpRequest(port: port, method: "GET", path: "/api/estates")
        let payload = try JSONDecoder().decode(EstatesPayload.self, from: Data(estatesBody.utf8))
        #expect(payload.admin?.hosted.first { $0.estateUUID == uuid }?.mountState == "quiesced")

        // Destroy with the matching confirm name.
        let dBody = try! APIJSON.encode(EstateLifecycleRequest(estateUUID: uuid, confirmName: "Life"))
        let dResp = await udsRoundTrip(
            socketPath: path,
            request: "/api/control/estate/destroy\t\(String(data: dBody, encoding: .utf8)!)\n")
        #expect(dResp.contains("\"ok\":true"))

        // Gone from the read plane.
        let (_, after) = try await httpRequest(port: port, method: "GET", path: "/api/estates")
        let afterPayload = try JSONDecoder().decode(EstatesPayload.self, from: Data(after.utf8))
        #expect(afterPayload.admin?.hosted.contains { $0.estateUUID == uuid } == false)
        }  // withIntellectusLock
    }

    @Test("destroy over UDS with a wrong confirm name is refused (ok:false)")
    func destroyConfirmGuardOverUDS() async throws {
        try await withIntellectusLock {
        let path = makeTempSocketPath()
        let (host, _) = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        let provResp = await udsRoundTrip(
            socketPath: path,
            request: "/api/control/estate/provision\t\(provisionBodyJSON(name: "Guarded"))\n")
        let prov = try JSONDecoder().decode(
            EstateAdminResult.self,
            from: Data(provResp.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        let uuid = try #require(prov.estateUUID)

        let dBody = try! APIJSON.encode(EstateLifecycleRequest(estateUUID: uuid, confirmName: "WRONG"))
        let dResp = await udsRoundTrip(
            socketPath: path,
            request: "/api/control/estate/destroy\t\(String(data: dBody, encoding: .utf8)!)\n")
        #expect(dResp.contains("\"ok\":false"))
        #expect(dResp.lowercased().contains("confirm"))
        }  // withIntellectusLock
    }

    @Test("a malformed provision body over UDS is rejected without crashing")
    func malformedBodyOverUDS() async throws {
        let path = makeTempSocketPath()
        let (host, _) = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        let resp = await udsRoundTrip(
            socketPath: path,
            request: "/api/control/estate/provision\t{\"not\":\"valid\"}\n")
        #expect(resp.contains("\"ok\":false"))
    }
}

// MARK: - Admin verbs are gated over HTTP (privileged write)

@Suite("Admin plane — HTTP gate")
struct AdminPlaneHTTPGateTests {

    @Test("provision over HTTP without a token is rejected 401 (no estate created)")
    func provisionUngatedRejected() async throws {
        let path = makeTempSocketPath()
        let (host, port) = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        let (status, _) = try await httpRequest(
            port: port, method: "POST", path: "/api/control/estate/provision",
            body: Data(provisionBodyJSON(name: "ShouldNotExist").utf8))
        #expect(status == 401)

        // Nothing was provisioned — the gate ran before the engine.
        let (_, estatesBody) = try await httpRequest(port: port, method: "GET", path: "/api/estates")
        let payload = try JSONDecoder().decode(EstatesPayload.self, from: Data(estatesBody.utf8))
        #expect(payload.admin?.hosted.isEmpty ?? true)
    }

    @Test("provision over HTTP with a cross-origin Origin is rejected 403")
    func provisionCrossOriginRejected() async throws {
        let path = makeTempSocketPath()
        let (host, port) = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        // Origin check runs before the token, so even a valid token is rejected.
        let (status, _) = try await httpRequest(
            port: port, method: "POST", path: "/api/control/estate/provision",
            headers: ["Authorization": "Bearer \(apToken)", "Origin": "http://evil.example.com"],
            body: Data(provisionBodyJSON(name: "X").utf8))
        #expect(status == 403)
    }

    @Test("provision over HTTP with a valid token + loopback Origin succeeds")
    func provisionGatedSucceeds() async throws {
        try await withIntellectusLock {
        let path = makeTempSocketPath()
        let (host, port) = try await makeStartedHost(socketPath: path)
        defer { Task { await host.stop() } }

        let (status, body) = try await httpRequest(
            port: port, method: "POST", path: "/api/control/estate/provision",
            headers: ["Authorization": "Bearer \(apToken)", "Origin": "http://127.0.0.1:\(port)"],
            body: Data(provisionBodyJSON(name: "GatedOK").utf8))
        #expect(status == 200)
        let result = try JSONDecoder().decode(EstateAdminResult.self, from: Data(body.utf8))
        #expect(result.ok)
        #expect(result.estateUUID != nil)
        }  // withIntellectusLock
    }
}
