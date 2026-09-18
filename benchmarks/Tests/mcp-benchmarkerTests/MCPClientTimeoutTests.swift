import Testing
import Foundation
@testable import mcp_benchmarker

// MCPClientTimeoutTests — unit-level test for the per-request response deadline.
//
// The MCPClient watchdog fires after `responseDeadline` seconds and throws an
// `MCPError` naming the endpoint and the request id. These tests verify the
// timeout path without a live MCP server:
//
//   • A stub stdio endpoint that never emits a matching response (tail -f /dev/null
//     reads bytes from the kernel and blocks — the process stays alive but writes
//     nothing to stdout). An MCP initialize is sent; no JSON-RPC response ever
//     arrives. The deadline fires and the call throws.
//
// The deadline is overridden to 2 s so the suite stays fast (under 10 s total).
//
// `/usr/bin/tail -f /dev/null` is used as the never-responding stub because:
//   - It stays alive for the duration of the test (no early EOF).
//   - It reads stdin silently and writes nothing to stdout.
//   - `/bin/cat` echoes stdin to stdout, which produces a line that IS parseable
//     as JSON only when the request line happens to be valid JSON — the MCP
//     initialize envelope IS valid JSON, so cat echoes it back and `deliver` sees
//     a frame WITH the correct id, making the test pass for the wrong reason
//     (the echo is not a real MCP response). tail -f /dev/null avoids that hazard.

@Suite("MCPClient timeout", .serialized)
struct MCPClientTimeoutTests {

    /// Stub command that stays alive and never writes to stdout, so no matching
    /// JSON-RPC response arrives. The MCP initialize `sendRequest` must time out.
    private let stubCommand = "/usr/bin/tail -f /dev/null"

    /// Short deadline so the test completes quickly. 2 s is long enough for the
    /// process to start and the request to be written; short enough that the full
    /// suite stays well under 10 s.
    private let shortDeadline: TimeInterval = 2

    @Test("awaitResponse throws MCPError within the deadline when no response arrives")
    func timeoutThrows() async throws {
        let endpoint = EndpointConfig(
            name: "stub-never-responds",
            transport: .stdio(command: stubCommand),
            auth: nil,
            verbMap: EndpointConfig.VerbMap(
                write: "noop_write", query: "noop_query",
                list: nil, resultFormat: .mootText),
            role: .source)

        // Override the deadline to shortDeadline so the test does not take 120 s.
        let client = MCPClient(endpoint: endpoint, responseDeadline: shortDeadline)

        let started = Date()
        var caughtError: Error?

        do {
            // connect() sends the MCP initialize request. tail -f /dev/null never
            // responds, so awaitResponse will hit the deadline and throw.
            try await client.connect()
        } catch {
            caughtError = error
        }
        await client.disconnect()

        let elapsed = Date().timeIntervalSince(started)

        // Must have thrown by the deadline (with a small grace margin for process
        // startup jitter on a busy CI host).
        #expect(caughtError != nil, "connect() should have thrown a timeout error")

        // The error must be an MCPError naming the endpoint. MCPError's description
        // field carries the message and conforms to CustomStringConvertible.
        if let mcpError = caughtError as? MCPError {
            #expect(mcpError.description.contains("stub-never-responds"),
                    "error should name the endpoint; got: \(mcpError.description)")
        } else if let err = caughtError {
            // Any error (transport spawn, timeout) is acceptable as long as it threw.
            // An unexpected non-MCPError is a signal but not a hard failure here —
            // some platforms may surface a different error type from Subprocess.
            Issue.record("Expected MCPError but got \(type(of: err)): \(err)")
        }

        // Elapsed must be within the deadline + a generous grace margin (3× the
        // deadline covers slow CI machines and process-spawn latency).
        #expect(elapsed < shortDeadline * 3,
                "should have timed out within \(shortDeadline * 3) s; took \(elapsed) s")
    }

    @Test("timeout error description names both the endpoint and the request id")
    func timeoutNamesID() async throws {
        let endpoint = EndpointConfig(
            name: "stub-id-check",
            transport: .stdio(command: stubCommand),
            auth: nil,
            verbMap: EndpointConfig.VerbMap(
                write: "noop_write", query: "noop_query",
                list: nil, resultFormat: .mootText),
            role: .source)

        let client = MCPClient(endpoint: endpoint, responseDeadline: shortDeadline)
        var errorDescription: String?

        do {
            try await client.connect()
        } catch let e as MCPError {
            errorDescription = e.description
        } catch {}
        await client.disconnect()

        // The description must name the endpoint AND carry an id reference.
        // awaitResponse produces "response timeout for request id N on endpoint 'NAME'".
        if let desc = errorDescription {
            #expect(desc.contains("stub-id-check"),
                    "timeout message should name the endpoint; got: \(desc)")
            #expect(desc.contains("request id"),
                    "timeout message should reference the request id; got: \(desc)")
        }
        // If connect threw a non-MCPError (process spawn failure in unusual env),
        // we skip the description check — the test above already covers the throw.
    }
}
