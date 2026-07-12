import Testing
import Foundation
import AriaMCP
import MootIntentKit
@testable import MootGateway

// MARK: - Owner-presence credential provider (test doubles)

/// Counts resolutions so tests can assert the owner was NOT prompted when
/// serving is impossible (e.g. on battery under on-power-only).
private actor CountingCredentialProvider: LANCredentialProviding {
    let credential: LANCredential
    let shouldThrow: Bool
    private var count = 0

    init(credential: LANCredential = .generate(), shouldThrow: Bool = false) {
        self.credential = credential
        self.shouldThrow = shouldThrow
    }

    func resolve() async throws -> LANCredential {
        count += 1
        if shouldThrow {
            throw LANCredentialError.ownerAuthenticationFailed("mock denied")
        }
        return credential
    }

    func resolveCount() async -> Int { count }
}

// MARK: - Power gate

@Suite("PowerCondition — the on-power serving gate")
struct PowerConditionTests {
    @Test("only onPower allows serving; unknown is fail-closed")
    func gate() {
        #expect(PowerCondition.onPower.allowsServing)
        #expect(!PowerCondition.onBattery.allowsServing)
        #expect(!PowerCondition.unknown.allowsServing, "ambiguous state must not serve")
    }

    @Test("a fixed source reports its condition")
    func fixedSource() {
        #expect(FixedPowerSource(.onPower).current() == .onPower)
        #expect(FixedPowerSource(.onBattery).current().allowsServing == false)
    }
}

// MARK: - Credential

@Suite("LANCredential — bearer token")
struct LANCredentialTests {
    @Test("generated tokens are unique and base64url (no +/=)")
    func generation() {
        let a = LANCredential.generate()
        let b = LANCredential.generate()
        #expect(a.token != b.token)
        #expect(!a.token.contains("+") && !a.token.contains("/") && !a.token.contains("="))
        #expect(a.token.count >= 40, "256 bits base64url is ~43 chars")
    }

    @Test("matches only the exact token; a near-miss fails")
    func matching() {
        let cred = LANCredential(token: "abc123")
        #expect(cred.matches(presented: "abc123"))
        #expect(!cred.matches(presented: "abc124"))
        #expect(!cred.matches(presented: "abc123 "))
        #expect(!cred.matches(presented: ""))
    }

    @Test("bearer header parsing: case-insensitive scheme, rejects malformed")
    func bearerParse() {
        #expect(LANCredential.bearerToken(fromAuthorizationHeader: "Bearer xyz") == "xyz")
        #expect(LANCredential.bearerToken(fromAuthorizationHeader: "bearer xyz") == "xyz")
        #expect(LANCredential.bearerToken(fromAuthorizationHeader: "Basic xyz") == nil)
        #expect(LANCredential.bearerToken(fromAuthorizationHeader: "Bearer ") == nil)
        #expect(LANCredential.bearerToken(fromAuthorizationHeader: nil) == nil)
    }

    @Test("store round-trips and regenerate changes the token")
    func store() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lancred-\(UUID().uuidString)", isDirectory: true)
        let store = try LANCredentialStore(directory: dir)
        let first = store.loadOrCreate()
        #expect(store.loadOrCreate().token == first.token, "persisted token is stable")
        let rotated = store.regenerate()
        #expect(rotated.token != first.token)
        #expect(store.loadOrCreate().token == rotated.token)
    }
}

// MARK: - Request gate

@Suite("LANRequestGate — parse, auth, posture")
struct LANRequestGateTests {

    private let cred = LANCredential(token: "secret-token")

    private func rawPOST(auth: String?, body: String) -> Data {
        var head = "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
        if let auth { head += "Authorization: \(auth)\r\n" }
        head += "Content-Length: \(body.utf8.count)\r\n\r\n"
        return Data((head + body).utf8)
    }

    @Test("a well-formed authorized POST is admitted as a JSON-RPC request")
    func admitAuthorized() {
        let raw = rawPOST(auth: "Bearer secret-token",
                          body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let parsed = try! #require(LANRequestGate.parse(raw))
        guard case .authorized(let rpc) = LANRequestGate.admit(parsed, credential: cred) else {
            Issue.record("expected authorized"); return
        }
        #expect(rpc.method == "tools/list")
    }

    @Test("missing bearer → 401 before the body is even considered")
    func rejectNoAuth() {
        let raw = rawPOST(auth: nil, body: "not even json")
        let parsed = try! #require(LANRequestGate.parse(raw))
        #expect(LANRequestGate.admit(parsed, credential: cred) == .rejected(status: 401, reason: "Missing or malformed Authorization: Bearer header"))
    }

    @Test("wrong token → 401")
    func rejectWrongToken() {
        let raw = rawPOST(auth: "Bearer wrong",
                          body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let parsed = try! #require(LANRequestGate.parse(raw))
        guard case .rejected(let status, _) = LANRequestGate.admit(parsed, credential: cred) else {
            Issue.record("expected rejection"); return
        }
        #expect(status == 401)
    }

    @Test("GET → 405")
    func rejectGET() {
        let raw = Data("GET / HTTP/1.1\r\nAuthorization: Bearer secret-token\r\n\r\n".utf8)
        let parsed = try! #require(LANRequestGate.parse(raw))
        guard case .rejected(let status, _) = LANRequestGate.admit(parsed, credential: cred) else {
            Issue.record("expected rejection"); return
        }
        #expect(status == 405)
    }

    @Test("authorized but non-JSON body → 400")
    func rejectBadBody() {
        let raw = rawPOST(auth: "Bearer secret-token", body: "not json")
        let parsed = try! #require(LANRequestGate.parse(raw))
        guard case .rejected(let status, _) = LANRequestGate.admit(parsed, credential: cred) else {
            Issue.record("expected rejection"); return
        }
        #expect(status == 400)
    }

    @Test("an incomplete body (Content-Length not yet satisfied) does not parse")
    func partialBodyBuffers() {
        let head = "POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"partial\":true}"
        #expect(LANRequestGate.parse(Data(head.utf8)) == nil, "keep buffering until the body is whole")
    }

    // MARK: export posture

    @Test("remote recall is forced to filter:exportable, overriding any caller filter")
    func exportPostureForced() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"moot_memory_search","arguments":{"query":"x","filter":"unconfirmed"}}}"#
        let value = try! JSONValue.parse(Data(body.utf8))
        let rpc = try! #require(JSONRPCRequest.decode(value))
        let posted = LANRequestGate.enforceRemoteExportPosture(rpc)
        let filter = posted.params?.objectValue?["arguments"]?.objectValue?["filter"]?.stringValue
        #expect(filter == "exportable", "remote caller cannot escape the public-only gate")
    }

    @Test("non-recall calls pass through export posture unchanged")
    func exportPostureIgnoresNonRecall() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let rpc = try! #require(JSONRPCRequest.decode(try! JSONValue.parse(Data(body.utf8))))
        #expect(LANRequestGate.enforceRemoteExportPosture(rpc).method == "tools/list")
    }

    // MARK: write allowlist

    @Test("read-only tools are remotely permitted; writes and heavy verbs are not")
    func writeAllowlist() {
        func call(_ name: String) -> JSONRPCRequest {
            JSONRPCRequest(id: .integer(1), method: "tools/call",
                           params: .object(["name": .string(name)]))
        }
        #expect(LANRequestGate.isRemotelyPermitted(call("moot_memory_search")))
        #expect(LANRequestGate.isRemotelyPermitted(call("moot_fact_search")))
        #expect(!LANRequestGate.isRemotelyPermitted(call("moot_file_memory")), "no remote writes")
        #expect(!LANRequestGate.isRemotelyPermitted(call("moot_erase_memory")), "no remote erase")
        #expect(!LANRequestGate.isRemotelyPermitted(call("moot_reindex")), "no remote heavy verbs")
        #expect(LANRequestGate.isRemotelyPermitted(JSONRPCRequest(id: nil, method: "tools/list", params: nil)))
        #expect(!LANRequestGate.isRemotelyPermitted(JSONRPCRequest(id: nil, method: "resources/read", params: nil)))
    }
}

// MARK: - Server owner-presence gating

@Suite("MootLANServer — owner-presence and power gating")
struct MootLANServerGateTests {

    @Test("on battery under on-power-only: waits for power AND never prompts the owner")
    func batteryDefersWithoutPrompt() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let provider = CountingCredentialProvider()
        let server = MootLANServer(
            bridge: bridge, credentialProvider: provider,
            power: FixedPowerSource(.onBattery),
            config: .init(onPowerOnly: true))

        await server.start()

        #expect(await server.currentState() == .waitingForPower)
        #expect(await provider.resolveCount() == 0,
            "the owner must NOT be asked to unlock for a server that cannot serve on battery")
    }

    @Test("on power but owner authentication fails: denied, not listening")
    func ownerDenialBlocksServing() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let provider = CountingCredentialProvider(shouldThrow: true)
        let server = MootLANServer(
            bridge: bridge, credentialProvider: provider,
            power: FixedPowerSource(.onPower),
            config: .init(onPowerOnly: true))

        await server.start()

        guard case .denied = await server.currentState() else {
            Issue.record("expected .denied when the owner does not authenticate")
            return
        }
        #expect(await provider.resolveCount() == 1, "resolution was attempted exactly once")
    }
}
