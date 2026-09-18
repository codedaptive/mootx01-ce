// CommunityLANTests.swift
//
// Wave D2: CORE-08 LAN serving endpoint tests.
//
// Tests the five LAN tools registered through CommunityContractDispatch against
// a real temp directory, a real in-process TCP socket (127.0.0.1:0 for
// sandbox-safety — no real LAN exposure), and a real capture ledger.
//
// ACCEPTANCE COVERAGE (per CORE-08 spec):
//
//   E8-T1   five LAN tools appear in communityToolList when coordinator is injected
//   E8-T2   LAN tools absent from list when coordinator is nil (B1-R16 gate)
//   E8-T3   fresh coordinator status = stopped (frozen-policy default-off)
//   E8-T4   lan_policy returns correct eligibleCount/ineligibleCount from ledger
//   E8-T5   lan_start returns started{endpoint,authentication:valid} with authority
//   E8-T6   HTTP GET /records with valid token returns eligible record IDs
//   E8-T7   HTTP GET /records/{eligibleID} with valid token returns record
//   E8-T8   HTTP GET /records/{ineligibleID} returns 404 (restricted sensitivity)
//   E8-T9   HTTP GET /records/{ineligibleID} returns 404 (exportEligible=false)
//   E8-T10  HTTP GET /records/{ineligibleID} returns 404 (lanEligible=false)
//   E8-T11  HTTP GET with no token → 401 unauthorized
//   E8-T12  HTTP GET with wrong token → 401 unauthorized
//   E8-T13  Expired credential → lan-credential-expired distinguishable
//   E8-T14  capture new eligible record + refresh_eligibility → visible without restart
//   E8-T15  ineligible-after-policy-change disappears after refresh (counts + HTTP)
//   E8-T16  lan_stop → socket really closed (connection attempt fails)
//   E8-T17  restart (new coordinator, same sidecar) → serving NOT restored (status=stopped)
//   E8-T18  lan_start denied without authority → denied{lan-authority-missing}
//   E8-T19  unknown argument fields fail closed (invalidParams thrown)
//   E8-T20  contract shape: every response carries the discriminator field
//   E8-T21  lan_refresh_eligibility → refused when policyForbidsRefresh=true
//
// Method: RED → GREEN. Tests authored first; CommunityLANCoordinator makes them green.
// Transport: 127.0.0.1 with port 0 (OS-assigned) for sandbox safety.

import Testing
import Foundation
@testable import MootCommunityDaemon
import AriaMCP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Test infrastructure

/// Per-test scratch directory with a pre-populated capture ledger.
///
/// The ledger is the format `CommunityCaptureCoordinator` writes:
///   { "<requestID>": { "recordID": "...", "destinationID": "...", "sensitivity": "...",
///                      "exportEligible": <bool>, "lanEligible": <bool> } }
///
/// We write it directly here rather than going through the capture coordinator to
/// avoid needing a real estate (the LAN coordinator reads only the ledger file).
private struct LANScratch {
    let layoutURL: URL

    init() throws {
        layoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("d2-lan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: layoutURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() { try? FileManager.default.removeItem(at: layoutURL) }

    var ledgerURL: URL { layoutURL.appendingPathComponent("capture-ledger.json") }

    /// Write a ledger with the specified entries.
    ///
    /// Each tuple: (requestIDSuffix, recordID, sensitivity, exportEligible, lanEligible).
    func writeLedger(_ entries: [(String, String, String, Bool, Bool)]) throws {
        var dict: [String: [String: Any]] = [:]
        for (suffix, recordID, sensitivity, export, lanE) in entries {
            dict["req-\(suffix)"] = [
                "recordID": recordID,
                "destinationID": "personal/capture",
                "sensitivity": sensitivity,
                "exportEligible": export,
                "lanEligible": lanE,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: ledgerURL)
    }

    /// Make a test coordinator bound to 127.0.0.1:0 (sandbox-safe).
    func makeCoordinator(hasAuthority: Bool = true) -> CommunityLANCoordinator {
        CommunityLANCoordinator(layoutURL: layoutURL, hasAuthority: hasAuthority)
    }
}

// MARK: - Synchronous HTTP helper

/// Perform a synchronous HTTP GET.
/// Called from async test bodies; the blocking syscalls run on the calling thread,
/// which is a test worker thread — not the Swift cooperative pool, so blocking is safe.
private func httpGET(url: String, token: String? = nil) throws -> (Int, Data) {
    guard let parsed = URL(string: url),
          let host = parsed.host,
          let port = parsed.port else {
        throw NSError(domain: "LANTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Bad URL: \(url)"])
    }

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NSError(domain: "POSIX", code: Int(errno)) }
    defer { close(fd) }

    // Three-second timeout so a test does not hang indefinitely if the server is slow.
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    inet_pton(AF_INET, host, &addr.sin_addr)

    let connectResult = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        throw NSError(domain: "POSIX", code: Int(errno),
                      userInfo: [NSLocalizedDescriptionKey: "connect failed errno=\(errno)"])
    }

    let path = parsed.path.isEmpty ? "/" : parsed.path
    var req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
    if let t = token { req += "Authorization: Bearer \(t)\r\n" }
    req += "\r\n"

    let reqData = Data(req.utf8)
    var sent = 0
    while sent < reqData.count {
        let n = reqData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!.advanced(by: sent), reqData.count - sent)
        }
        guard n > 0 else {
            throw NSError(domain: "POSIX", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "write failed"])
        }
        sent += n
    }

    var response = Data()
    while true {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
        if n <= 0 { break }
        response.append(contentsOf: buf[0..<n])
    }

    guard let responseText = String(data: response, encoding: .utf8),
          let firstLine = responseText.components(separatedBy: "\r\n").first else {
        throw NSError(domain: "LANTest", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "empty response"])
    }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else {
        throw NSError(domain: "LANTest", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "bad status: \(firstLine)"])
    }

    let bodyData: Data
    if let sepRange = response.range(of: Data("\r\n\r\n".utf8)) {
        bodyData = Data(response[sepRange.upperBound...])
    } else {
        bodyData = Data()
    }
    return (status, bodyData)
}

/// Attempt a TCP connection to host:port (synchronous, 1-second timeout).
/// Returns true if the OS accepted the connection.
private func canConnect(host: String, port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var tv = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    inet_pton(AF_INET, host, &addr.sin_addr)

    let result = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

/// Spin-wait up to `timeout` seconds for `condition` to become true.
/// Uses usleep (C function, not Thread.sleep) so it is callable from non-async contexts.
private func waitFor(timeout: TimeInterval = 2.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(50_000) // 50 ms between polls
    }
    return condition()
}

/// Extract the discriminating field from a JSONValue response.
private func discriminator(_ v: JSONValue) -> String? {
    if case .object(let fields) = v {
        if case .string(let s) = fields["state"] { return s }
        if case .string(let s) = fields["outcome"] { return s }
    }
    return nil
}

/// Extract a String field from a JSONValue object.
private func stringField(_ v: JSONValue, _ key: String) -> String? {
    if case .object(let fields) = v, case .string(let s) = fields[key] { return s }
    return nil
}

/// Extract an Int field from a JSONValue object (accepts integer or double).
private func intField(_ v: JSONValue, _ key: String) -> Int? {
    if case .object(let fields) = v {
        if case .integer(let i) = fields[key] { return Int(i) }
        if case .double(let d) = fields[key] { return Int(d) }
    }
    return nil
}

// MARK: - Test suite

// Network-binding tests must run serially — concurrent binds on overlapping ports
// and overlapping accept loops cause timing races in the 50-ms setup window.
// `.serialized` prevents Swift Testing's default parallel dispatch within this suite.
@Suite("CommunityLAN (CORE-08)", .serialized)
struct CommunityLANTests {

    // MARK: E8-T1

    @Test("E8-T1: five LAN tools appear in communityToolList when coordinator is injected")
    func lanToolsAppearsWhenInjected() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        let coord = scratch.makeCoordinator()
        let dispatch = CommunityContractDispatch(
            state: CommunityProviderState(instanceIdentifier: UUID(), estateIdentifier: UUID()),
            lifecycle: nil,
            capture: nil,
            review: nil,
            obsidian: nil,
            transfer: nil,
            lan: coord
        )
        let lanNames = dispatch.communityToolList.map(\.name).filter { $0.hasPrefix("moot_community_lan_") }
        #expect(lanNames.count == 5, "expected 5 LAN tools, got \(lanNames.count)")
        #expect(lanNames.contains("moot_community_lan_status"))
        #expect(lanNames.contains("moot_community_lan_policy"))
        #expect(lanNames.contains("moot_community_lan_start"))
        #expect(lanNames.contains("moot_community_lan_stop"))
        #expect(lanNames.contains("moot_community_lan_refresh_eligibility"))
    }

    // MARK: E8-T2

    @Test("E8-T2: LAN tools absent from communityToolList when coordinator is nil (B1-R16 gate)")
    func lanToolsAbsentWhenNil() async throws {
        let dispatch = CommunityContractDispatch(
            state: CommunityProviderState(instanceIdentifier: UUID(), estateIdentifier: UUID())
        )
        let lanNames = dispatch.communityToolList.map(\.name).filter { $0.hasPrefix("moot_community_lan_") }
        #expect(lanNames.isEmpty, "expected no LAN tools when coordinator is nil, got: \(lanNames)")
    }

    // MARK: E8-T3

    @Test("E8-T3: fresh coordinator status = stopped (frozen-policy default-off)")
    func freshCoordinatorIsStopped() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        let coord = scratch.makeCoordinator()
        let result = await coord.status()
        #expect(discriminator(result) == "stopped", "expected stopped, got \(result)")
    }

    // MARK: E8-T4

    @Test("E8-T4: lan_policy returns correct eligible/ineligible counts from ledger")
    func policyCountsFromLedger() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([
            ("a", "rec-a", "normal",     true,  true),   // eligible
            ("b", "rec-b", "elevated",   true,  true),   // eligible
            ("c", "rec-c", "normal",     true,  true),   // eligible
            ("d", "rec-d", "restricted", true,  true),   // ineligible: sensitivity
            ("e", "rec-e", "normal",     false, true),   // ineligible: exportEligible
            ("f", "rec-f", "normal",     true,  false),  // ineligible: lanEligible
            ("g", "rec-g", "secret",     false, false),  // ineligible: all three
        ])

        let coord = scratch.makeCoordinator()
        let result = await coord.policy()

        #expect(intField(result, "eligibleCount") == 3,
                "eligibleCount should be 3, got \(result)")
        #expect(intField(result, "ineligibleCount") == 4,
                "ineligibleCount should be 4, got \(result)")
        #expect(stringField(result, "policyDescription") != nil,
                "policyDescription should be present")
    }

    // MARK: E8-T5

    @Test("E8-T5: lan_start returns started{endpoint,authentication:valid} with authority")
    func lanStartReturnsStartedWithAuthority() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        let coord = scratch.makeCoordinator(hasAuthority: true)
        let result = await coord.start()
        defer { Task { _ = await coord.stop() } }

        #expect(discriminator(result) == "started", "expected started, got \(result)")
        #expect(stringField(result, "endpoint")?.hasPrefix("http://") == true,
                "endpoint should be http://, got \(result)")
        #expect(stringField(result, "authentication") == "valid",
                "authentication should be valid, got \(result)")

        let status = await coord.status()
        #expect(discriminator(status) == "active",
                "status should be active after start, got \(status)")
    }

    // MARK: E8-T6

    @Test("E8-T6: HTTP GET /records with valid token returns eligible record IDs")
    func httpListEligibleRecords() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([
            ("a", "rec-eligible-a", "normal",   true,  true),
            ("b", "rec-eligible-b", "elevated", true,  true),
            ("c", "rec-ineligible", "secret",   false, false),
        ])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let token = await coord.testToken() else {
            Issue.record("start/token failed: \(startResult)"); return
        }

        // Wait for the accept loop to enter accept(2) before sending HTTP.
        try await Task.sleep(nanoseconds: 50_000_000)

        let (status, body) = try httpGET(url: "\(endpoint)/records", token: token)
        #expect(status == 200, "expected 200, got \(status)")
        let ids = (try? JSONSerialization.jsonObject(with: body) as? [String]) ?? []
        #expect(ids.contains("rec-eligible-a"))
        #expect(ids.contains("rec-eligible-b"))
        #expect(!ids.contains("rec-ineligible"))
    }

    // MARK: E8-T7

    @Test("E8-T7: HTTP GET /records/{eligibleID} with valid token returns record")
    func httpFetchEligibleRecord() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([
            ("a", "rec-fetch-me", "normal", true, true),
        ])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let token = await coord.testToken() else {
            Issue.record("start/token failed"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let (status, body) = try httpGET(url: "\(endpoint)/records/rec-fetch-me", token: token)
        #expect(status == 200, "expected 200, got \(status)")
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        #expect(obj["recordID"] as? String == "rec-fetch-me")
    }

    // MARK: E8-T8

    @Test("E8-T8: HTTP GET ineligible record (restricted sensitivity) returns 404")
    func ineligibleBySensitivity() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([
            ("r", "rec-restricted", "restricted", true, true),
        ])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let token = await coord.testToken() else {
            Issue.record("start/token failed"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        // By direct recordID.
        let (statusDirect, _) = try httpGET(url: "\(endpoint)/records/rec-restricted", token: token)
        #expect(statusDirect == 404, "ineligible record by ID should return 404, got \(statusDirect)")

        // By listing — must not appear.
        let (_, listBody) = try httpGET(url: "\(endpoint)/records", token: token)
        let ids = (try? JSONSerialization.jsonObject(with: listBody) as? [String]) ?? []
        #expect(!ids.contains("rec-restricted"), "ineligible record must not appear in listing")
    }

    // MARK: E8-T9

    @Test("E8-T9: HTTP GET ineligible record (exportEligible=false) returns 404")
    func ineligibleByExport() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([
            ("e", "rec-no-export", "normal", false, true),
        ])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let token = await coord.testToken() else {
            Issue.record("start/token failed"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let (status, _) = try httpGET(url: "\(endpoint)/records/rec-no-export", token: token)
        #expect(status == 404, "exportEligible=false record should return 404, got \(status)")
    }

    // MARK: E8-T10

    @Test("E8-T10: HTTP GET ineligible record (lanEligible=false) returns 404")
    func ineligibleByLAN() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([
            ("l", "rec-no-lan", "normal", true, false),
        ])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let token = await coord.testToken() else {
            Issue.record("start/token failed"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let (statusDirect, _) = try httpGET(url: "\(endpoint)/records/rec-no-lan", token: token)
        #expect(statusDirect == 404, "lanEligible=false by ID should return 404, got \(statusDirect)")

        let (_, listBody) = try httpGET(url: "\(endpoint)/records", token: token)
        let ids = (try? JSONSerialization.jsonObject(with: listBody) as? [String]) ?? []
        #expect(!ids.contains("rec-no-lan"), "lanEligible=false must not appear in listing")
    }

    // MARK: E8-T11

    @Test("E8-T11: HTTP GET with no token returns 401 unauthorized")
    func noTokenReturns401() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([("a", "rec-a", "normal", true, true)])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint") else {
            Issue.record("start failed"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let (status, _) = try httpGET(url: "\(endpoint)/records", token: nil)
        #expect(status == 401, "no token should return 401, got \(status)")
    }

    // MARK: E8-T12

    @Test("E8-T12: HTTP GET with wrong token returns 401 unauthorized")
    func wrongTokenReturns401() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([("a", "rec-a", "normal", true, true)])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint") else {
            Issue.record("start failed"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let (status, _) = try httpGET(url: "\(endpoint)/records", token: "wrong-\(UUID())")
        #expect(status == 401, "wrong token should return 401, got \(status)")
    }

    // MARK: E8-T13

    @Test("E8-T13: expired credential returns lan-credential-expired distinguishable error")
    func expiredCredentialDistinguishable() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([("a", "rec-a", "normal", true, true)])

        let coord = scratch.makeCoordinator()
        // Sub-millisecond validity ensures the token expires before the next request.
        await coord.setTokenValidity(seconds: 0.001)

        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let token = await coord.testToken() else {
            Issue.record("start/token failed"); return
        }

        // Wait for expiry (0.001 s validity + 100 ms margin).
        try await Task.sleep(nanoseconds: 150_000_000)

        let (status, body) = try httpGET(url: "\(endpoint)/records", token: token)
        #expect(status == 401, "expired token should return 401, got \(status)")
        let bodyStr = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyStr.contains("lan-credential-expired"),
                "body should contain 'lan-credential-expired', got: \(bodyStr)")

        // Status shows authentication: expired.
        let statusResult = await coord.status()
        #expect(stringField(statusResult, "authentication") == "expired",
                "status authentication should be expired, got \(statusResult)")
    }

    // MARK: E8-T14

    @Test("E8-T14: capture new eligible record + refresh_eligibility → visible without restart")
    func refreshMakesNewRecordVisible() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        // Start with zero eligible records.
        try scratch.writeLedger([
            ("old", "rec-ineligible-old", "secret", false, false),
        ])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let token = await coord.testToken() else {
            Issue.record("start/token failed"); return
        }

        // Confirm zero eligible before any refresh.
        let beforePolicy = await coord.policy()
        #expect(intField(beforePolicy, "eligibleCount") == 0)

        // Simulate a new capture: update the ledger to add an eligible record.
        try scratch.writeLedger([
            ("old", "rec-ineligible-old", "secret", false, false),
            ("new", "rec-newly-eligible", "normal", true, true),
        ])

        // Refresh eligibility counts — takes effect on live server without restart.
        let refreshResult = await coord.refreshEligibility()
        #expect(discriminator(refreshResult) == "updated", "expected updated, got \(refreshResult)")
        #expect(intField(refreshResult, "eligibleCount") == 1,
                "eligibleCount should be 1 after refresh, got \(refreshResult)")

        // Verify the live server now serves the new record (ledger is read per-request).
        try await Task.sleep(nanoseconds: 50_000_000)
        let (status, body) = try httpGET(url: "\(endpoint)/records", token: token)
        #expect(status == 200)
        let ids = (try? JSONSerialization.jsonObject(with: body) as? [String]) ?? []
        #expect(ids.contains("rec-newly-eligible"),
                "newly eligible record should appear after refresh, ids=\(ids)")
    }

    // MARK: E8-T15

    @Test("E8-T15: record made ineligible after ledger update disappears after refresh")
    func ineligibleAfterRefreshDisappears() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        // Start with one eligible record.
        try scratch.writeLedger([
            ("a", "rec-will-be-gone", "normal", true, true),
        ])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let token = await coord.testToken() else {
            Issue.record("start/token failed"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        // Before: record is visible in listing.
        let (_, beforeBody) = try httpGET(url: "\(endpoint)/records", token: token)
        let beforeIds = (try? JSONSerialization.jsonObject(with: beforeBody) as? [String]) ?? []
        #expect(beforeIds.contains("rec-will-be-gone"))

        // Make the record ineligible by raising its sensitivity.
        try scratch.writeLedger([
            ("a", "rec-will-be-gone", "restricted", true, true),
        ])

        // Refresh — eligibility change takes effect immediately on the live server.
        let refreshResult = await coord.refreshEligibility()
        #expect(discriminator(refreshResult) == "updated")
        #expect(intField(refreshResult, "eligibleCount") == 0)

        // Listing: record must not appear.
        let (after, afterBody) = try httpGET(url: "\(endpoint)/records", token: token)
        #expect(after == 200)
        let afterIds = (try? JSONSerialization.jsonObject(with: afterBody) as? [String]) ?? []
        #expect(!afterIds.contains("rec-will-be-gone"),
                "record should not appear after becoming ineligible, ids=\(afterIds)")

        // Direct fetch: ineligible → same 404 as unknown (no information leakage).
        let (directStatus, _) = try httpGET(url: "\(endpoint)/records/rec-will-be-gone", token: token)
        #expect(directStatus == 404, "direct fetch of now-ineligible record should return 404")
    }

    // MARK: E8-T16

    @Test("E8-T16: lan_stop closes the socket (connection attempt fails after stop)")
    func stopClosesSocket() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let parsedURL = URL(string: endpoint),
              let port = parsedURL.port else {
            Issue.record("start failed: \(startResult)"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        // Before stop: connection should succeed.
        #expect(canConnect(host: "127.0.0.1", port: port),
                "connection should succeed before stop")

        let stopResult = await coord.stop()
        #expect(discriminator(stopResult) == "stopped",
                "stop should return stopped, got \(stopResult)")

        // Give the OS a moment to close the socket.
        try await Task.sleep(nanoseconds: 150_000_000)

        // After stop: connection must fail.
        let canStillConnect = waitFor(timeout: 1.5) { !canConnect(host: "127.0.0.1", port: port) }
        #expect(canStillConnect, "connection should fail after stop (port \(port) should be closed)")

        let statusResult = await coord.status()
        #expect(discriminator(statusResult) == "stopped",
                "status should be stopped after stop, got \(statusResult)")
    }

    // MARK: E8-T17

    @Test("E8-T17: restart (new coordinator instance, same sidecar) does NOT restore serving")
    func restartDoesNotRestoreServing() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        // First coordinator: start to prove it works, then stop.
        let coord1 = scratch.makeCoordinator()
        let start1 = await coord1.start()
        #expect(discriminator(start1) == "started")
        _ = await coord1.stop()

        // Second coordinator: new instance, same layout directory.
        // Frozen-policy invariant: serving state is NEVER stored to disk,
        // so a new instance always starts stopped regardless of sidecar contents.
        let coord2 = scratch.makeCoordinator()
        let status2 = await coord2.status()
        #expect(discriminator(status2) == "stopped",
                "new coordinator instance should start stopped (frozen policy), got \(status2)")
    }

    // MARK: E8-T18

    @Test("E8-T18: lan_start denied without authority returns denied{lan-authority-missing}")
    func startDeniedWithoutAuthority() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        let coord = scratch.makeCoordinator(hasAuthority: false)
        let result = await coord.start()
        #expect(discriminator(result) == "denied", "expected denied, got \(result)")
        #expect(stringField(result, "reason") == "lan-authority-missing",
                "reason should be lan-authority-missing, got \(result)")
    }

    // MARK: E8-T19

    @Test("E8-T19: unknown argument fields fail closed (invalidParams)")
    func unknownFieldsFailClosed() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        let coord = scratch.makeCoordinator()
        let dispatch = CommunityContractDispatch(
            state: CommunityProviderState(instanceIdentifier: UUID(), estateIdentifier: UUID()),
            lifecycle: nil,
            capture: nil,
            review: nil,
            obsidian: nil,
            transfer: nil,
            lan: coord
        )

        // Empty-argument endpoints must throw invalidParams when given extra fields.
        await #expect(throws: (any Error).self) {
            _ = try await dispatch.dispatch(
                name: "moot_community_lan_status",
                arguments: .object(["unexpectedField": .string("value")])
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await dispatch.dispatch(
                name: "moot_community_lan_start",
                arguments: .object(["unknown": .bool(true)])
            )
        }
    }

    // MARK: E8-T20

    @Test("E8-T20: every LAN response carries the required discriminator field")
    func contractShapeValidation() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        let coord = scratch.makeCoordinator()

        // lan_status: state field.
        let statusResult = await coord.status()
        #expect(discriminator(statusResult) != nil,
                "lan_status must have state, got \(statusResult)")

        // lan_policy: eligibleCount + ineligibleCount + policyDescription.
        let policyResult = await coord.policy()
        #expect(intField(policyResult, "eligibleCount") != nil)
        #expect(intField(policyResult, "ineligibleCount") != nil)
        #expect(stringField(policyResult, "policyDescription") != nil)

        // lan_start: outcome field.
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }
        #expect(discriminator(startResult) != nil,
                "lan_start must have outcome, got \(startResult)")

        // lan_stop: outcome field.
        let stopResult = await coord.stop()
        #expect(discriminator(stopResult) != nil,
                "lan_stop must have outcome, got \(stopResult)")

        // lan_refresh_eligibility: outcome field.
        let refreshResult = await coord.refreshEligibility()
        #expect(discriminator(refreshResult) != nil,
                "lan_refresh_eligibility must have outcome, got \(refreshResult)")
    }

    // MARK: E8-T21

    @Test("E8-T21: lan_refresh_eligibility returns refused when policyForbidsRefresh=true")
    func refreshRefusedWhenForbidden() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        let coord = scratch.makeCoordinator()
        await coord.enablePolicyForbidsRefresh()

        let result = await coord.refreshEligibility()
        #expect(discriminator(result) == "refused", "expected refused, got \(result)")
        #expect(stringField(result, "reason") == "lan-policy-forbidden",
                "reason should be lan-policy-forbidden, got \(result)")
    }

    // MARK: F7-T1 — stop/start credential rotation
    //
    // Regression for the fd-reuse race condition (Fable finding F7):
    // stop() now awaits serverTask.value before returning. This guarantees
    // the accept loop has fully exited before stop() returns. Consequently:
    // - start() can safely bind to a new port after stop() returns
    // - a new credential is generated on start()
    // - the old token (captured before stop) is rejected by the new server
    //
    // If stop() returned before awaiting the loop (the bug), the old accept loop
    // could still be executing accept(2) on the closed fd number. When start()
    // then binds a new socket and the OS reuses the same fd number, the stale
    // loop accepts connections that arrive at the new socket — but with the OLD
    // credential — allowing authentication bypass with the old bearer token.

    @Test("F7-T1: stop/start credential rotation — old token rejected after restart")
    func stopStartCredentialRotation() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([("a", "rec-a", "normal", true, true)])

        let coord = scratch.makeCoordinator()

        // First start: capture the endpoint and bearer token.
        let startResult1 = await coord.start()
        guard discriminator(startResult1) == "started" else {
            Issue.record("First start failed: \(startResult1)"); return
        }

        // Give accept loop time to enter accept(2).
        try await Task.sleep(nanoseconds: 50_000_000)

        // Capture the first token before stop.
        guard let oldToken = await coord.testToken() else {
            Issue.record("testToken nil after first start"); return
        }

        // stop() must await the accept loop before returning.
        let stopResult = await coord.stop()
        #expect(discriminator(stopResult) == "stopped",
                "stop must return stopped, got \(stopResult)")

        // Immediately start again — a new credential is generated.
        let startResult2 = await coord.start()
        defer { Task { _ = await coord.stop() } }
        guard discriminator(startResult2) == "started",
              let newEndpoint = stringField(startResult2, "endpoint") else {
            Issue.record("Second start failed: \(startResult2)"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let newToken = await coord.testToken()
        #expect(newToken != nil, "testToken must be non-nil after second start")
        #expect(newToken != oldToken,
                "second start must produce a NEW credential, not recycle the old one")

        // Old token must be rejected by the new server (401 unauthorized).
        let (statusOldToken, _) = try httpGET(url: "\(newEndpoint)/records", token: oldToken)
        #expect(statusOldToken == 401,
                "old token must be rejected after credential rotation, got \(statusOldToken)")

        // New token must be accepted.
        let (statusNewToken, _) = try httpGET(url: "\(newEndpoint)/records", token: newToken)
        #expect(statusNewToken == 200,
                "new token must be accepted by the new server, got \(statusNewToken)")
    }

    // MARK: F7-T2 — stop returns after accept loop exits
    //
    // Verifies the structural guarantee of the fix: when stop() returns, the
    // accept loop has exited and the server is fully quiesced. We confirm this
    // by measuring that stop() itself returns (does not hang) when there is no
    // in-flight connection — i.e., `await serverTask.value` resolves promptly
    // once the loop is cancelled.

    @Test("F7-T2: stop() returns promptly (loop exits on cancellation within deadline)")
    func stopReturnsPromptly() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        guard discriminator(startResult) == "started" else {
            Issue.record("start failed: \(startResult)"); return
        }

        // Give the loop time to enter accept(2).
        try await Task.sleep(nanoseconds: 50_000_000)

        // Measure stop() duration. The loop must notice cancellation and exit
        // within a generous 2-second deadline (real hardware exits in < 1 ms).
        let before = Date()
        let stopResult = await coord.stop()
        let elapsed = Date().timeIntervalSince(before)

        #expect(discriminator(stopResult) == "stopped",
                "stop must return stopped, got \(stopResult)")
        #expect(elapsed < 2.0,
                "stop() must return within 2 s (accept loop exits on cancel); took \(elapsed) s")
    }

    // MARK: F8-T1 — token comparison is functionally correct
    //
    // Regression for the timing side-channel (Fable finding F8):
    // The token comparison was changed from `token == credential.token` (String ==,
    // which can short-circuit on first differing byte) to a constant-time SHA-256
    // digest comparison. The behavioral contract — wrong tokens are rejected with
    // 401 — is unchanged; these tests verify the contract holds for various
    // near-valid token inputs.
    //
    // True constant-time guarantees cannot be verified in a behavioral test. The
    // behavioral checks here confirm the fix did not break correctness; the
    // implementation review confirms the algorithm (XOR accumulator over 32 bytes,
    // no early exit).

    @Test("F8-T1: token comparison — near-valid tokens are all rejected (constant-time fix)")
    func nearValidTokensRejected() async throws {
        let scratch = try LANScratch()
        defer { scratch.remove() }

        try scratch.writeLedger([("a", "rec-a", "normal", true, true)])

        let coord = scratch.makeCoordinator()
        let startResult = await coord.start()
        defer { Task { _ = await coord.stop() } }

        guard discriminator(startResult) == "started",
              let endpoint = stringField(startResult, "endpoint"),
              let validToken = await coord.testToken() else {
            Issue.record("start/token failed"); return
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        // Near-valid tokens: one byte/character off from the real token.
        // All must return 401.
        //
        // Notes on excluded cases:
        //   - uppercased(): Swift UUID tokens are already uppercase; uppercasing is a no-op.
        //   - " " + token: HTTP Bearer parsing skips over the leading space in the header
        //     value and extracts the token correctly — this is correct HTTP behavior,
        //     not a security flaw. The constant-time check is on the parsed token value.
        //   - token + " ": HTTP response parsing treats the token as ending at the space;
        //     the server never compares a token with a trailing space.
        // The four cases below are genuine near-valid tokens that differ by exactly one
        // character and must all be rejected by the constant-time comparison.
        let nearValidTokens: [String] = [
            String(validToken.dropFirst()),     // one char shorter at front
            String(validToken.dropLast()),      // one char shorter at end
            validToken + "x",                   // one char longer at end
            "x" + validToken,                   // one char longer at front
            validToken.lowercased(),            // case change (UUID is uppercase → lowercased differs)
        ]

        for badToken in nearValidTokens {
            let (status, _) = try httpGET(url: "\(endpoint)/records", token: badToken)
            #expect(status == 401,
                    "near-valid token '\(badToken.prefix(20))…' must be rejected with 401, got \(status)")
        }
    }
}
