import Foundation
import Testing
@testable import moot_bridge

// BridgeFrameRejectionTests.swift — the regression proof for MXE-MB.
//
// A malformed client line used to be indistinguishable from a valid id-less
// notification: both produced a nil `id`, so both took the notification branch
// and the raw bytes were written to BOTH backends. A JSON-RPC backend answers a
// malformed frame with a parseError; that response was never read, so the NEXT
// sendAndReceive consumed it instead of its own result and every response after
// that was skewed by one for the life of the process.
//
// Two layers of proof here:
//
//   1. `BridgeServer.classifyFrame` unit tests — the three-way split itself, and
//      the parseError/invalidRequest distinction, with no process and no I/O.
//
//   2. A live wired suite that runs a real `BridgeServer` over real
//      `RawMCPBackend` transports against two STUB backends. The stubs append
//      every line they receive to a log file, which is the only way to assert
//      the mission's actual requirement — that a rejected frame reaches NO
//      backend. The stubs also answer a frame they cannot parse with a
//      parseError, exactly as a real backend does, so the desynchronization is
//      reproduced faithfully rather than assumed.
//
// The stub backends are `/usr/bin/awk` scripts, so this suite has no dependency
// on mempalace-mcp or mootx01 being installed and runs everywhere the live
// acceptance suite skips.

// MARK: - Unit: the three-way split

@Suite("BridgeServer.classifyFrame")
struct BridgeFrameClassificationTests {

    /// A well-formed request carrying an id classifies as `.request`, and the
    /// method and id the classifier extracted are the ones downstream uses.
    @Test func requestWithIDIsARequest() {
        let line = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)
        guard case .request(_, let method, let id) = BridgeServer.classifyFrame(line) else {
            Issue.record("expected .request")
            return
        }
        #expect(method == "tools/list")
        #expect(id == .number(1))
    }

    /// A well-formed envelope with no id is a genuine notification — the one
    /// case that legitimately reaches both backends.
    @Test func envelopeWithoutIDIsANotification() {
        let line = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        #expect(BridgeServer.classifyFrame(line) == .notification)
    }

    /// An explicit `"id": null` is a REQUEST, not a notification: JSON-RPC 2.0
    /// permits a null id, and the classifier tests for presence of the key
    /// rather than for a non-null value. This is the pre-change behaviour and it
    /// is preserved deliberately.
    @Test func explicitNullIDIsStillARequest() {
        let line = Data(#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#.utf8)
        guard case .request(_, let method, let id) = BridgeServer.classifyFrame(line) else {
            Issue.record("expected .request for an explicit null id")
            return
        }
        #expect(method == "tools/list")
        #expect(id == .null)
    }

    /// Unparseable bytes are a parseError (-32700) — the frame never became JSON,
    /// so there is nothing to say about its envelope.
    @Test func unparseableLineIsParseError() {
        for bad in ["{", "not json at all", #"{"jsonrpc": "2.0""#, #"{"a":}"#] {
            guard case .reject(let code, _) = BridgeServer.classifyFrame(Data(bad.utf8)) else {
                Issue.record("expected .reject for \(bad)")
                return
            }
            #expect(code == BridgeServer.parseErrorCode, "wrong code for \(bad)")
        }
    }

    /// PINNED PORT DIVERGENCE. Foundation's JSON parser accepts a trailing comma
    /// in an object; Rust's serde_json rejects it as a syntax error. So
    /// `{"jsonrpc":"2.0","method":"x",}` is a perfectly good notification to this
    /// port and a parseError to the Rust twin.
    ///
    /// This is recorded rather than papered over, because the invariant that
    /// matters still holds in both ports: each bridge delegates parsing to its own
    /// vertical's standard parser — the same parser its own backends use
    /// (AriaMcpKit's Swift leg is Foundation-based, its Rust leg is serde_json) —
    /// so a bridge never forwards a frame that its backends would then fail to
    /// read. The desynchronization the mission fixes cannot occur on either side
    /// of the divergence. Normalizing it would mean hand-rolling a strict JSON
    /// parser in each port to second-guess the standard one, which buys nothing.
    @Test func foundationAcceptsATrailingCommaWhereSerdeJSONWouldNot() {
        let trailingComma = Data(#"{"jsonrpc":"2.0","method":"notifications/x",}"#.utf8)
        #expect(BridgeServer.classifyFrame(trailingComma) == .notification)
    }

    /// Valid JSON that is not a JSON-RPC envelope is invalidRequest (-32600), NOT
    /// parseError. Collapsing the two would tell a client "bad JSON" when the
    /// JSON was fine and only the envelope was wrong.
    @Test func validJSONThatIsNotAnEnvelopeIsInvalidRequest() {
        let notEnvelopes = [
            #"[1,2,3]"#,                                  // bare array
            #""just a string""#,                          // bare string
            #"42"#,                                       // bare number
            #"true"#,                                     // bare bool
            #"null"#,                                     // bare null
            #"{}"#,                                       // object, no fields
            #"{"id":1,"method":"tools/list"}"#,           // no jsonrpc
            #"{"jsonrpc":"1.0","id":1,"method":"x"}"#,    // wrong jsonrpc version
            #"{"jsonrpc":"2.0","id":1}"#,                 // no method
            #"{"jsonrpc":"2.0","id":1,"method":7}"#,      // method is not a string
        ]
        for line in notEnvelopes {
            guard case .reject(let code, _) = BridgeServer.classifyFrame(Data(line.utf8)) else {
                Issue.record("expected .reject for \(line)")
                return
            }
            #expect(code == BridgeServer.invalidRequestCode, "wrong code for \(line)")
        }
    }

    /// The two codes are the JSON-RPC 2.0 standard values, matching the ones
    /// AriaMcpKit's backend answers with. A client must not be able to tell
    /// whether its bad frame was refused by the bridge or by a backend.
    @Test func codesMatchTheJSONRPCStandard() {
        #expect(BridgeServer.parseErrorCode == -32700)
        #expect(BridgeServer.invalidRequestCode == -32600)
    }
}

// MARK: - Wired: rejected frames reach no backend

@Suite("moot-bridge frame rejection (stub backends)", .serialized)
struct BridgeFrameRejectionWiredTests {

    /// A malformed line is answered by the BRIDGE with a parseError carrying a
    /// null id, and reaches NEITHER backend.
    ///
    /// This is the regression test. Against pre-fix code the malformed line went
    /// out on the notification path, so both backend logs contained it and the
    /// client got no error at all.
    @Test func malformedLineIsRejectedAndNotForwarded() async throws {
        let rig = try StubRig()
        defer { rig.tearDown() }

        let responses = try await rig.drive(["{"])

        try #require(responses.count == 1, "the bridge owes the client exactly one error")
        let error = try #require(responses[0]["error"])
        #expect(error["code"] == JSONValue.number(Double(BridgeServer.parseErrorCode)))
        #expect(responses[0]["id"] == JSONValue.null, "a refused frame has no id to echo")

        #expect(rig.linesReceivedByA().isEmpty, "backend A must receive nothing at all")
        #expect(rig.linesReceivedByB().isEmpty, "backend B must receive nothing at all")
    }

    /// THE DESYNCHRONIZATION TEST. A malformed line followed by two valid
    /// requests: each request must receive ITS OWN response.
    ///
    /// Against pre-fix code the malformed line was forwarded, each backend
    /// answered it with an unread parseError, and the id-1 request then read that
    /// stale error while id 2 read id 1's result — the exact skew Codex observed.
    @Test func malformedLineDoesNotDesynchronizeTheSession() async throws {
        let rig = try StubRig()
        defer { rig.tearDown() }

        let responses = try await rig.drive([
            "{",
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#,
        ])

        // #require, not #expect: a regression here yields FEWER responses, and
        // indexing on past the end would crash the runner instead of reporting
        // the failure. Fail cleanly and stop.
        try #require(responses.count == 3, "one error plus one response per request")

        // The first response is the bridge's refusal; it is not correlated to any
        // request, so it carries a null id and must not be mistaken for one.
        #expect(responses[0]["id"] == JSONValue.null)
        #expect(responses[0]["error"] != nil)

        // Every subsequent response carries its OWN request's id. The stub echoes
        // the id it was asked with into `result.echo`, so a skew would show up as
        // an echo that disagrees with the envelope id.
        #expect(responses[1]["id"] == JSONValue.number(1))
        #expect(responses[1]["result"]?["echo"] == JSONValue.number(1))
        #expect(responses[2]["id"] == JSONValue.number(2))
        #expect(responses[2]["result"]?["echo"] == JSONValue.number(2))

        // And the malformed line reached neither backend, so neither had a stale
        // parseError sitting on its stdout to hand to the next reader.
        #expect(!rig.linesReceivedByA().contains("{"))
        #expect(!rig.linesReceivedByB().contains("{"))
    }

    /// Valid JSON that is not a JSON-RPC envelope is refused as invalidRequest
    /// and, like a malformed frame, reaches no backend.
    @Test func nonEnvelopeJSONIsRejectedAndNotForwarded() async throws {
        let rig = try StubRig()
        defer { rig.tearDown() }

        let marker = #"{"hello":"world"}"#
        let responses = try await rig.drive([marker])

        try #require(responses.count == 1)
        #expect(responses[0]["error"]?["code"]
                == JSONValue.number(Double(BridgeServer.invalidRequestCode)))
        #expect(responses[0]["id"] == JSONValue.null)

        #expect(rig.linesReceivedByA().isEmpty)
        #expect(rig.linesReceivedByB().isEmpty)
    }

    /// A GENUINE notification is unaffected: valid envelope, no id, still
    /// forwarded to both backends, still no response to the client. The fix
    /// narrows the notification path; it must not close it.
    @Test func genuineNotificationStillReachesBothBackends() async throws {
        let rig = try StubRig()
        defer { rig.tearDown() }

        let notification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let responses = try await rig.drive([notification])

        #expect(responses.isEmpty, "a notification is owed no response")
        #expect(rig.linesReceivedByA() == [notification])
        #expect(rig.linesReceivedByB() == [notification])
    }

    /// The ordinary path is untouched: a request gets its own response back with
    /// its own id.
    @Test func normalRequestStillCorrelates() async throws {
        let rig = try StubRig()
        defer { rig.tearDown() }

        let responses = try await rig.drive([
            #"{"jsonrpc":"2.0","id":41,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":42,"method":"initialize","params":{}}"#,
        ])

        try #require(responses.count == 2)
        #expect(responses[0]["id"] == JSONValue.number(41))
        #expect(responses[0]["result"]?["echo"] == JSONValue.number(41))
        #expect(responses[1]["id"] == JSONValue.number(42))
        #expect(responses[1]["result"]?["echo"] == JSONValue.number(42))
    }
}

// MARK: - The stub rig

/// A live `BridgeServer` wired to two stub backends over real `RawMCPBackend`
/// transports, plus the pipes to drive it as a client would.
///
/// The stubs are `/usr/bin/awk` scripts rather than mempalace-mcp / mootx01
/// because these tests need two things a real backend cannot give: a record of
/// exactly which lines reached the backend, and a guarantee the suite runs on a
/// machine where neither memory server is installed.
private struct StubRig {

    private let root: URL
    private let backendALogURL: URL
    private let backendBLogURL: URL
    private let server: BridgeServer
    private let backends: [BridgeBackend]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moot-bridge-frame-rejection-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let scriptURL = root.appendingPathComponent("stub.awk")
        try Self.stubProgram.write(to: scriptURL, atomically: true, encoding: .utf8)
        backendALogURL = root.appendingPathComponent("backendA.log")
        backendBLogURL = root.appendingPathComponent("backendB.log")
        FileManager.default.createFile(atPath: backendALogURL.path, contents: nil)
        FileManager.default.createFile(atPath: backendBLogURL.path, contents: nil)

        // The log path travels as an env-var prefix on the command string, which
        // RawMCPBackend hands to /usr/bin/env — the same mechanism the real
        // config uses for MOOTX01_DATA_DIR. Paths carry no spaces (the command is
        // whitespace-split), which the UUID-suffixed temp dir guarantees.
        // The verbs are never exercised here — these tests never issue a
        // tools/call, so no write is ever classified or fanned out. Named
        // distinctly so an accidental fan-out would be obvious in a stub log.
        let verbMap = VerbMap(write: "stub_write", query: "stub_query",
                              constantArgs: [:], resultFormat: .mootText)
        let backends = [
            BridgeBackend(
                transport: RawMCPBackend(
                    name: "stubA",
                    command: "\(Self.logEnvVar)=\(backendALogURL.path) /usr/bin/awk -f \(scriptURL.path)"),
                name: "stubA", verbMap: verbMap),
            BridgeBackend(
                transport: RawMCPBackend(
                    name: "stubB",
                    command: "\(Self.logEnvVar)=\(backendBLogURL.path) /usr/bin/awk -f \(scriptURL.path)"),
                name: "stubB", verbMap: verbMap),
        ]
        self.backends = backends
        server = BridgeServer(backends: backends, primaryIndex: 0, stats: BridgeStats())
    }

    // The settle sequence appended to every `drive()`, and the reason it exists.
    //
    // A notification is fire-and-forget: the bridge writes it and reads nothing
    // back, so nothing in the protocol says when a stub has consumed it. That
    // makes BOTH "the stub received it" and "the stub did NOT receive it" race
    // the stub's own write. A REQUEST is not fire-and-forget — the bridge blocks
    // until the stub answers, and because each stub is a single sequential
    // reader, its answer proves it has already processed every earlier line. That
    // is a real happens-before edge; a sleep never is.
    //
    // One request only synchronizes the PRIMARY, though — requests never reach
    // the secondary. So the sequence barriers the primary, flips the primary with
    // the bridge's own bridge_set_primary tool (handled inside the bridge, so it
    // generates no backend traffic of its own), then barriers the new primary.
    // After it, both stubs are known to have drained.
    private static let barrierA = #"{"jsonrpc":"2.0","id":99,"method":"initialize","params":{}}"#
    private static let switchToB = #"{"jsonrpc":"2.0","id":98,"method":"tools/call","params":{"name":"bridge_set_primary","arguments":{"backend":"stubB"}}}"#
    private static let barrierB = #"{"jsonrpc":"2.0","id":97,"method":"initialize","params":{}}"#

    /// Feeds `lines` to the bridge as a client would, then the settle sequence,
    /// and returns the responses to `lines` alone — the settle responses are
    /// verified and stripped here so a test never has to know they exist.
    func drive(_ lines: [String]) async throws -> [JSONValue] {
        for backend in backends { try await backend.transport.start() }

        let clientToBridge = Pipe()
        let bridgeToClient = Pipe()

        let all = lines + [Self.barrierA, Self.switchToB, Self.barrierB]
        clientToBridge.fileHandleForWriting.write(Data((all.joined(separator: "\n") + "\n").utf8))
        clientToBridge.fileHandleForWriting.closeFile()  // EOF → the run loop returns

        try await server.run(clientIn: clientToBridge.fileHandleForReading,
                             clientOut: bridgeToClient.fileHandleForWriting)

        bridgeToClient.fileHandleForWriting.closeFile()
        let out = bridgeToClient.fileHandleForReading.readDataToEndOfFile()
        for backend in backends { await backend.transport.stop() }

        let responses = String(decoding: out, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }

        // The settle sequence answered in order, which is what makes the log
        // assertions sound. If it did not, the rig itself is broken and no
        // conclusion drawn from the logs would be trustworthy.
        try #require(responses.count >= 3, "settle sequence produced no responses")
        let tail = responses.suffix(3)
        #expect(tail[tail.startIndex]["id"] == JSONValue.number(99), "barrier A unanswered")
        #expect(tail[tail.startIndex + 1]["id"] == JSONValue.number(98), "primary flip unanswered")
        #expect(tail[tail.startIndex + 2]["id"] == JSONValue.number(97), "barrier B unanswered")
        return Array(responses.dropLast(3))
    }

    /// Every CLIENT line backend A actually received, in order. The assertion the
    /// mission asks for — "neither backend receives the line" — is a statement
    /// about backend stdin, which nothing but a stub can observe.
    ///
    /// The settle barrier is the rig's own traffic, not the client's, so it is
    /// verified and stripped.
    func linesReceivedByA() -> [String] { Self.clientLines(of: backendALogURL, barrier: Self.barrierA) }
    /// Every CLIENT line backend B actually received, in order.
    func linesReceivedByB() -> [String] { Self.clientLines(of: backendBLogURL, barrier: Self.barrierB) }

    private static func clientLines(of url: URL, barrier: String) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n").map(String.init)
        guard lines.last == barrier else {
            Issue.record("the settle barrier must be the last line this backend saw; got \(lines)")
            return lines
        }
        lines.removeLast()
        return lines
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// The env var carrying each stub's log path.
    private static let logEnvVar = "MOOT_BRIDGE_STUB_LOG"

    /// The stub backend: log every received line, then answer like a real
    /// JSON-RPC server.
    ///
    /// `fflush()` after every write is load-bearing — without it awk
    /// block-buffers into the pipe and the bridge blocks forever on a response
    /// that has been written but not yet flushed.
    private static let stubProgram = """
    # Stub MCP backend for the moot-bridge frame-rejection tests.
    #
    # Appends every line received to $\(logEnvVar) so a test can assert what did
    # and did not reach the backend, then replies the way a real JSON-RPC server
    # replies:
    #   line with a numeric "id"      -> a result echoing that id
    #   line with "method" and no id  -> a notification: no reply
    #   anything else                 -> parseError with a null id. This is the
    #     unread response that desynchronizes a session when the bridge forwards
    #     a frame it should have refused, so the stub must produce it.
    {
        log_path = ENVIRON["\(logEnvVar)"]
        print $0 >> log_path
        fflush(log_path)
        if (match($0, /"id"[ ]*:[ ]*[0-9]+/)) {
            id_text = substr($0, RSTART, RLENGTH)
            sub(/^"id"[ ]*:[ ]*/, "", id_text)
            printf "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":%s,\\"result\\":{\\"tools\\":[],\\"echo\\":%s}}\\n", id_text, id_text
        } else if (index($0, "\\"method\\"") > 0) {
            # a notification — a real backend sends nothing back
        } else {
            printf "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":null,\\"error\\":{\\"code\\":-32700,\\"message\\":\\"stub backend: parse error\\"}}\\n"
        }
        fflush()
    }
    """
}
