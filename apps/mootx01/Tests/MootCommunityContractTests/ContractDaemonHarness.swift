// ContractDaemonHarness.swift
//
// CORE-10: headless daemon process harness.
//
// Spawns the real mootx01-daemon binary with env-var overrides that activate
// the headless contract test mode, polls for its descriptor file, performs
// the REAL HMAC-SHA256 challenge/establish/MAC authentication ceremony over
// HTTP, and provides a `call(_:arguments:)` method for making authenticated
// MCP tool calls.
//
// The daemon binary is located via the MOOT_CONTRACT_TEST_DAEMON env var or
// at the canonical scratch-build path for this worktree.  If the binary does
// not exist, `ContractDaemonHarness.findDaemonBinary()` returns nil and
// callers skip their tests with a meaningful message.
//
// ARCHITECTURE NOTES
// ──────────────────
// • Each harness instance manages ONE daemon process.  Tests that need
//   different initial daemon states create separate instances.
// • The test root (auth root) is a fixed 32-byte value.  It never touches
//   the Keychain; the daemon uses FixedFirstPartyRootProvider internally.
// • The auth ceremony runs over real HTTP using URLSession (no mock).  The
//   session key derived from the ceremony is stored in `AuthenticatedSession`
//   and used for request MAC computation on every subsequent call.
// • The daemon is assigned a random free TCP port (via the OS by binding to
//   :0 if MOOT_CONTRACT_TEST_HTTP_PORT is 0) to allow parallel test runs
//   without port conflicts.

import Foundation
import AriaMCP
import MootDaemonProvider

// MARK: - Daemon binary location

/// Returns the path to the mootx01-daemon-contract-host binary, or nil if not found.
///
/// The contract-test harness spawns mootx01-daemon-contract-host (not mootx01-daemon)
/// because the production binary no longer contains an env-var bypass path that skips
/// DaemonProvider.activate() / provider lock / Keychain custody (F3). The dedicated
/// contract-host binary contains the headless path and calls the same
/// CommunityResidentMain.makeCommunityDispatch function as production (F2).
///
/// Search order:
///   1. `MOOT_CONTRACT_TEST_DAEMON` environment variable (set by CI or make).
///      May point to mootx01-daemon-contract-host or any compatible binary.
///   2. Canonical SPM scratch-build path for the contract-host binary.
func findDaemonBinary() -> URL? {
    // 1. Explicit override (CI can set this to any compatible binary path)
    if let envPath = ProcessInfo.processInfo.environment["MOOT_CONTRACT_TEST_DAEMON"],
       FileManager.default.isExecutableFile(atPath: envPath) {
        return URL(fileURLWithPath: envPath)
    }
    // 2. Canonical scratch-build location for the contract-host binary.
    // The production mootx01-daemon binary is at the same base path but is NOT
    // spawned here: it contains no headless env-var path (F3).
    let canonical = "/Volumes/dev/builds/mootx01-ee/community-1.1-core-r1/spm-mootx01/out/Products/Debug/mootx01-daemon-contract-host"
    if FileManager.default.isExecutableFile(atPath: canonical) {
        return URL(fileURLWithPath: canonical)
    }
    return nil
}

// MARK: - Session

/// An authenticated MCP session established via the challenge/establish ceremony.
struct AuthenticatedSession: Sendable {
    let sessionIdentifier: [UInt8]
    let sessionKey: [UInt8]
    /// The HTTP origin (scheme + host + port) for all further requests.
    let origin: String
    /// The path portion of the MCP tool-call endpoint.
    let requestPath: String
    /// Monotonically increasing sequence counter for request MACs.
    private(set) var sequence: UInt64 = 0

    mutating func nextSequence() -> UInt64 {
        sequence += 1
        return sequence
    }
}

// MARK: - Errors

enum HarnessError: Error, CustomStringConvertible {
    case daemonBinaryNotFound
    case daemonFailedToStart(String)
    case descriptorNotFound(waited: TimeInterval)
    case authFailed(String)
    case callFailed(Int, String)
    case badResponseMAC
    case invalidResponseJSON
    case jsonRPCError(code: Int, message: String)

    var description: String {
        switch self {
        case .daemonBinaryNotFound:
            return "mootx01-daemon binary not found — build with swift build before running contract tests"
        case .daemonFailedToStart(let msg):
            return "daemon failed to start: \(msg)"
        case .descriptorNotFound(let waited):
            return "descriptor file not found after \(Int(waited))s"
        case .authFailed(let msg):
            return "auth ceremony failed: \(msg)"
        case .callFailed(let status, let body):
            return "HTTP \(status): \(body)"
        case .badResponseMAC:
            return "response MAC verification failed"
        case .invalidResponseJSON:
            return "response JSON could not be parsed"
        case .jsonRPCError(let code, let msg):
            return "JSON-RPC error \(code): \(msg)"
        }
    }
}

// MARK: - ContractDaemonHarness

/// Manages one headless daemon subprocess for contract testing.
final class ContractDaemonHarness: @unchecked Sendable {

    // ── Configuration ────────────────────────────────────────────────────────

    /// Fixed 32-byte test auth root.  Used by FixedFirstPartyRootProvider in
    /// the headless daemon and by the test-side auth ceremony.
    static let testRoot: [UInt8] = (0..<32).map { UInt8($0 &* 7 &+ 11) }

    /// Hex encoding of testRoot for the env var.
    static let testRootHex: String = testRoot.map { String(format: "%02x", $0) }.joined()

    /// Maximum time to wait for the descriptor file to appear.
    static let descriptorPollTimeout: TimeInterval = 30.0

    /// How often to poll the descriptor file.
    static let descriptorPollInterval: TimeInterval = 0.1

    // ── State ────────────────────────────────────────────────────────────────

    private let process: Process
    private let estateDir: URL
    private let descriptorFile: URL
    /// The actual HTTP port the daemon bound to (read from the descriptor).
    private var boundPort: Int = 0
    /// The parsed descriptor, set after successful startup.
    private var descriptor: FirstPartyDescriptor?

    // ── Init ──────────────────────────────────────────────────────────────────

    /// Create a harness that spawns the daemon with the given estate directory.
    ///
    /// - Parameters:
    ///   - daemonBinary: the executable to spawn.
    ///   - estateDir: temp directory for estate files and the descriptor.
    ///   - additionalEnv: extra env vars (e.g. to pre-seed specific state).
    init(daemonBinary: URL, estateDir: URL, additionalEnv: [String: String] = [:]) {
        self.estateDir = estateDir
        self.descriptorFile = estateDir.appendingPathComponent("daemon-descriptor.v2.json")

        process = Process()
        process.executableURL = daemonBinary
        process.arguments = ["resident"]

        var env = ProcessInfo.processInfo.environment
        env["MOOT_CONTRACT_TEST_ESTATE_DIR"] = estateDir.path
        env["MOOT_CONTRACT_TEST_AUTH_ROOT_HEX"] = Self.testRootHex
        // Port 0 = let the OS assign a free port.
        env["MOOT_CONTRACT_TEST_HTTP_PORT"] = "0"
        for (k, v) in additionalEnv { env[k] = v }
        process.environment = env

        // Silence daemon stdout/stderr so test output stays clean.
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /// Start the daemon and block until it publishes its descriptor.
    ///
    /// Returns the parsed `FirstPartyDescriptor` so callers can inspect fields.
    @discardableResult
    func start() throws -> FirstPartyDescriptor {
        try process.run()

        // Poll for the descriptor file.
        let deadline = Date().addingTimeInterval(Self.descriptorPollTimeout)
        var parsedDescriptor: FirstPartyDescriptor?
        while Date() < deadline {
            if let data = try? Data(contentsOf: descriptorFile),
               let d = DescriptorPublisher.decode(data) {
                parsedDescriptor = d
                break
            }
            Thread.sleep(forTimeInterval: Self.descriptorPollInterval)
        }
        guard let d = parsedDescriptor else {
            stop()
            throw HarnessError.descriptorNotFound(waited: Self.descriptorPollTimeout)
        }
        self.descriptor = d
        // Extract port from the descriptor's endpoint URL.
        if let endpointURL = URL(string: d.endpoint), let port = endpointURL.port {
            self.boundPort = port
        } else {
            self.boundPort = 4242
        }
        return d
    }

    /// Send SIGTERM to the daemon and wait for exit.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    // ── Auth ceremony ─────────────────────────────────────────────────────────

    /// Perform the full challenge/establish ceremony and return an authenticated session.
    func authenticate() throws -> AuthenticatedSession {
        guard let d = descriptor else {
            throw HarnessError.authFailed("descriptor not loaded — call start() first")
        }

        let origin = "http://127.0.0.1:\(boundPort)"
        let installationRoot = Self.testRoot
        let descriptorDigest = d.digest()

        // ── Step 1: challenge ────────────────────────────────────────────────
        let clientNonce = (0..<FirstPartyAuthProtocol.nonceByteCount).map { _ in UInt8.random(in: 0...255) }
        let challengeBody: [String: String] = [
            "clientNonce": FirstPartyAuthProtocol.base64URLEncode(clientNonce),
            "descriptorDigest": FirstPartyAuthProtocol.base64URLEncode(descriptorDigest),
        ]
        let challengeData = try JSONSerialization.data(withJSONObject: challengeBody, options: [.sortedKeys])
        let challengeURL = URL(string: origin + FirstPartyAuthProtocol.challengePath)!
        let challengeResp = try syncHTTPPost(url: challengeURL, body: challengeData)
        guard let challengeObj = try? JSONSerialization.jsonObject(with: challengeResp.body) as? [String: Any],
              let sessRaw   = challengeObj["sessionIdentifier"] as? String,
              let sNonceRaw = challengeObj["serverNonce"] as? String,
              let issuedAt  = (challengeObj["issuedAt"] as? NSNumber).map({ UInt64(exactly: $0.uint64Value) }) ?? nil,
              let idleExp   = (challengeObj["idleExpiry"] as? NSNumber).map({ UInt64(exactly: $0.uint64Value) }) ?? nil,
              let absExp    = (challengeObj["absoluteExpiry"] as? NSNumber).map({ UInt64(exactly: $0.uint64Value) }) ?? nil,
              let sProofRaw = challengeObj["serverProof"] as? String,
              let sessionIdentifier = FirstPartyAuthProtocol.base64URLDecode(sessRaw),
              let serverNonce       = FirstPartyAuthProtocol.base64URLDecode(sNonceRaw),
              let serverProof       = FirstPartyAuthProtocol.base64URLDecode(sProofRaw)
        else {
            throw HarnessError.authFailed("bad challenge response: \(String(decoding: challengeResp.body, as: UTF8.self))")
        }

        // ── Verify serverProof ───────────────────────────────────────────────
        let transcript = FirstPartyAuthProtocol.sessionTranscript(
            descriptorDigest: descriptorDigest,
            providerIdentifier: d.providerIdentifier,
            serviceIdentifier: d.serviceIdentifier,
            endpoint: d.endpoint,
            instanceIdentifier: d.instanceIdentifier,
            estateIdentifier: d.estateIdentifier,
            binaryVersion: d.binaryVersion,
            descriptorSchemaVersion: d.schemaVersion,
            contractRevision: d.contractRevision,
            mcpProtocolVersion: d.mcpProtocolVersion,
            credentialGeneration: d.credentialGeneration,
            descriptorGeneration: d.descriptorGeneration,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            sessionIdentifier: sessionIdentifier,
            issuedAt: issuedAt,
            idleExpiry: idleExp,
            absoluteExpiry: absExp
        )
        let authKey = FirstPartyAuthProtocol.authKey(
            installationRoot: installationRoot, descriptorDigest: descriptorDigest
        )
        let expectedServerProof = FirstPartyAuthProtocol.serverProof(authKey: authKey, transcript: transcript)
        guard FirstPartyAuthProtocol.constantTimeEquals(expectedServerProof, serverProof) else {
            throw HarnessError.authFailed("server proof verification failed")
        }

        // ── Step 2: establish ────────────────────────────────────────────────
        let clientProof = FirstPartyAuthProtocol.clientProof(authKey: authKey, transcript: transcript)
        let establishBody: [String: String] = [
            "sessionIdentifier": FirstPartyAuthProtocol.base64URLEncode(sessionIdentifier),
            "clientProof": FirstPartyAuthProtocol.base64URLEncode(clientProof),
        ]
        let establishData = try JSONSerialization.data(withJSONObject: establishBody, options: [.sortedKeys])
        let establishURL = URL(string: origin + FirstPartyAuthProtocol.establishPath)!
        let establishResp = try syncHTTPPost(url: establishURL, body: establishData)
        guard (try? JSONSerialization.jsonObject(with: establishResp.body) as? [String: Any])?["establishmentProof"] != nil else {
            throw HarnessError.authFailed("bad establish response")
        }

        // ── Derive session key ───────────────────────────────────────────────
        let sessionKey = FirstPartyAuthProtocol.sessionKey(
            installationRoot: installationRoot, transcript: transcript
        )

        return AuthenticatedSession(
            sessionIdentifier: sessionIdentifier,
            sessionKey: sessionKey,
            origin: origin,
            requestPath: FirstPartyAuthProtocol.requestPath
        )
    }

    // ── MCP tool calls ────────────────────────────────────────────────────────

    /// Call an MCP tool and return the deserialized result.
    ///
    /// Computes the request MAC, sets all required headers, verifies the
    /// response MAC, and unwraps the JSON-RPC result object.
    ///
    /// - Parameters:
    ///   - method: the MCP tool name (e.g. `"moot_community_contract_identity"`).
    ///   - arguments: JSON-serializable arguments dictionary.
    ///   - session: the authenticated session (mutated for sequence tracking).
    /// - Returns: the `result` field from the JSON-RPC response as `[String: Any]`.
    func call(
        method: String,
        arguments: [String: Any],
        session: inout AuthenticatedSession
    ) throws -> [String: Any] {
        let seq = session.nextSequence()
        let requestID = Int.random(in: 1...Int.max)

        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "tools/call",
            "params": [
                "name": method,
                "arguments": arguments,
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: rpcBody, options: [.sortedKeys])

        // Compute request MAC
        let reqMAC = FirstPartyAuthProtocol.requestMAC(
            sessionKey: session.sessionKey,
            sessionIdentifier: session.sessionIdentifier,
            sequence: seq,
            method: "POST",
            path: session.requestPath,
            contentType: FirstPartyAuthProtocol.contentType,
            body: bodyData
        )

        let targetURL = URL(string: session.origin + session.requestPath)!
        var request = URLRequest(url: targetURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue(FirstPartyAuthProtocol.contentType, forHTTPHeaderField: "content-type")
        request.setValue(
            "\(FirstPartyAuthProtocol.authorizationScheme) \(FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier))",
            forHTTPHeaderField: FirstPartyAuthProtocol.authorizationHeader
        )
        request.setValue(
            FirstPartyAuthProtocol.formatSequenceHeader(seq),
            forHTTPHeaderField: FirstPartyAuthProtocol.sequenceHeaderWireName
        )
        request.setValue(
            FirstPartyAuthProtocol.base64URLEncode(reqMAC),
            forHTTPHeaderField: FirstPartyAuthProtocol.requestMACHeaderWireName
        )

        let httpResp = try syncHTTPRequest(request)
        guard httpResp.status == 200 else {
            throw HarnessError.callFailed(httpResp.status, String(decoding: httpResp.body, as: UTF8.self))
        }

        // Verify response MAC
        if let respMACRaw = httpResp.headers[FirstPartyAuthProtocol.responseMACHeader.lowercased()],
           let respMAC = FirstPartyAuthProtocol.base64URLDecode(respMACRaw) {
            let expected = FirstPartyAuthProtocol.responseMAC(
                sessionKey: session.sessionKey,
                sessionIdentifier: session.sessionIdentifier,
                sequence: seq,
                status: 200,
                contentType: FirstPartyAuthProtocol.contentType,
                body: httpResp.body
            )
            guard FirstPartyAuthProtocol.constantTimeEquals(expected, respMAC) else {
                throw HarnessError.badResponseMAC
            }
        }

        // Parse JSON-RPC response
        guard let rpcResp = try? JSONSerialization.jsonObject(with: httpResp.body) as? [String: Any] else {
            throw HarnessError.invalidResponseJSON
        }
        if let error = rpcResp["error"] as? [String: Any],
           let code = error["code"] as? Int,
           let msg  = error["message"] as? String {
            throw HarnessError.jsonRPCError(code: code, message: msg)
        }
        // The result is the MCP tools/call result, which is itself a JSON-RPC result
        // containing a `content` array.  Each content item has a `text` field with the
        // actual JSON the tool returned.  Extract the first text item.
        if let result = rpcResp["result"] as? [String: Any],
           let content = result["content"] as? [[String: Any]],
           let firstText = content.first?["text"] as? String,
           let innerData = firstText.data(using: .utf8),
           let innerJSON = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] {
            return innerJSON
        }
        // Fallback: the result IS the object (e.g. from a mock or test stub)
        if let result = rpcResp["result"] as? [String: Any] { return result }
        throw HarnessError.invalidResponseJSON
    }

    // MARK: - HTTP helpers (synchronous, for simple sequential test flow)

    private struct HTTPResult {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private func syncHTTPPost(url: URL, body: Data) throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(FirstPartyAuthProtocol.contentType, forHTTPHeaderField: "content-type")
        return try syncHTTPRequest(request)
    }

    private func syncHTTPRequest(_ request: URLRequest) throws -> HTTPResult {
        var result: HTTPResult?
        var httpError: Error?
        let sema = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error = error { httpError = error; return }
            guard let http = response as? HTTPURLResponse,
                  let data = data else { return }
            var headers = [String: String]()
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String, let vs = v as? String {
                    headers[ks.lowercased()] = vs
                }
            }
            result = HTTPResult(status: http.statusCode, headers: headers, body: data)
        }
        task.resume()
        sema.wait()
        if let err = httpError { throw err }
        guard let r = result else { throw HarnessError.authFailed("no HTTP response") }
        return r
    }
}

// MARK: - Plain-lane (third-party) helpers

extension ContractDaemonHarness {

    /// Send a JSON-RPC request to the PLAIN (unauthenticated third-party) lane and
    /// return the parsed response body.
    ///
    /// The plain lane is the standard MCP loopback path — any POST that is not the
    /// authenticated first-party subtree (`/mcp/first-party*`). It always receives
    /// `firstPartyIdentity == nil` in the dispatcher, so community tools are refused
    /// after the F1 fix.
    ///
    /// Uses the synchronous `DispatchSemaphore`-based HTTP helper so this method can
    /// be called from non-async test contexts (matching the rest of the harness API).
    ///
    /// - Parameters:
    ///   - method: JSON-RPC method (e.g. `"tools/list"` or `"tools/call"`).
    ///   - params: JSON-serializable params dictionary.
    ///   - port: The daemon's bound port (from the descriptor endpoint URL).
    /// - Returns: The full JSON-RPC response as `[String: Any]` (may contain `error`).
    func plainLaneRPC(
        method: String,
        params: [String: Any],
        port: Int
    ) throws -> [String: Any] {
        // The plain lane accepts POSTs to any non-first-party path.
        // Use "/mcp" — the conventional third-party MCP path.
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: rpcBody, options: [.sortedKeys])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // No Authorization, X-ARIA-Sequence, or X-ARIA-Request-MAC headers — plain lane.
        let resp = try syncHTTPRequest(request)
        guard let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HarnessError.invalidResponseJSON
        }
        return obj
    }

    /// Send a JSON-RPC `tools/list` request on the AUTHENTICATED first-party lane and
    /// return the list of tool name strings from `result.tools[].name`.
    ///
    /// This method uses the same MAC-signed request path as `call()`, so it exercises
    /// the real production composition path (F2): the dispatcher is wired with all six
    /// coordinator families, and `tools/list` on the first-party lane must include all
    /// 35 community tools.
    func listTools(session: inout AuthenticatedSession) throws -> [String] {
        let seq = session.nextSequence()
        let requestID = Int.random(in: 1...Int.max)

        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "tools/list",
            // tools/list takes no params; pass an empty object per the MCP spec.
            "params": [:] as [String: Any],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: rpcBody, options: [.sortedKeys])

        // Request MAC is identical to call() — same key, same path, different body.
        let reqMAC = FirstPartyAuthProtocol.requestMAC(
            sessionKey: session.sessionKey,
            sessionIdentifier: session.sessionIdentifier,
            sequence: seq,
            method: "POST",
            path: session.requestPath,
            contentType: FirstPartyAuthProtocol.contentType,
            body: bodyData
        )

        let targetURL = URL(string: session.origin + session.requestPath)!
        var request = URLRequest(url: targetURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue(FirstPartyAuthProtocol.contentType, forHTTPHeaderField: "content-type")
        request.setValue(
            "\(FirstPartyAuthProtocol.authorizationScheme) \(FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier))",
            forHTTPHeaderField: FirstPartyAuthProtocol.authorizationHeader
        )
        request.setValue(
            FirstPartyAuthProtocol.formatSequenceHeader(seq),
            forHTTPHeaderField: FirstPartyAuthProtocol.sequenceHeaderWireName
        )
        request.setValue(
            FirstPartyAuthProtocol.base64URLEncode(reqMAC),
            forHTTPHeaderField: FirstPartyAuthProtocol.requestMACHeaderWireName
        )

        let httpResp = try syncHTTPRequest(request)
        guard httpResp.status == 200 else {
            throw HarnessError.callFailed(httpResp.status, String(decoding: httpResp.body, as: UTF8.self))
        }

        // Verify response MAC
        if let respMACRaw = httpResp.headers[FirstPartyAuthProtocol.responseMACHeader.lowercased()],
           let respMAC = FirstPartyAuthProtocol.base64URLDecode(respMACRaw) {
            let expected = FirstPartyAuthProtocol.responseMAC(
                sessionKey: session.sessionKey,
                sessionIdentifier: session.sessionIdentifier,
                sequence: seq,
                status: 200,
                contentType: FirstPartyAuthProtocol.contentType,
                body: httpResp.body
            )
            guard FirstPartyAuthProtocol.constantTimeEquals(expected, respMAC) else {
                throw HarnessError.badResponseMAC
            }
        }

        guard let rpcResp = try? JSONSerialization.jsonObject(with: httpResp.body) as? [String: Any],
              let result = rpcResp["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]]
        else { throw HarnessError.invalidResponseJSON }

        return tools.compactMap { $0["name"] as? String }
    }

    /// The bound HTTP port for the running daemon (reads from the stored descriptor).
    ///
    /// Returns 0 if the daemon has not started or the descriptor endpoint is unparseable.
    var descriptorPort: Int {
        guard let d = descriptor,
              let u = URL(string: d.endpoint),
              let p = u.port else { return 0 }
        return p
    }
}

// MARK: - Convenience: make + start + auth + teardown

extension ContractDaemonHarness {

    /// Full lifecycle: create temp dir, spawn daemon, authenticate, run `body`, stop.
    ///
    /// The temp directory and its contents are removed after `body` returns or throws.
    static func withDaemon(
        binary: URL,
        additionalEnv: [String: String] = [:],
        _ body: (ContractDaemonHarness, inout AuthenticatedSession) throws -> Void
    ) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("moot-contract-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let harness = ContractDaemonHarness(
            daemonBinary: binary, estateDir: tmp, additionalEnv: additionalEnv
        )
        try harness.start()
        defer { harness.stop() }
        var session = try harness.authenticate()
        try body(harness, &session)
    }
}
