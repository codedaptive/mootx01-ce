import Testing
import Foundation
import AppIntents
@testable import MootGateway

// The adapter shells are not dead stubs: their perform()/route() bodies run
// against a live estate in-process. These tests exercise them the same way
// the app's "Apple Surfaces" tab does, and pin the discovered edges so a
// regression that silently "fixes" them is noticed.

@Suite("Adapter shells run in-process")
struct AdapterShellTests {

    /// Give the shared runtime an in-memory estate before exercising intents,
    /// so the test does not touch ~/.mootx01.
    private func freshInMemoryRuntime() async throws {
        await GatewayRuntime.shared.configure(databaseURL: nil)
        _ = try await GatewayRuntime.shared.bridge()
    }

    @Test("CaptureDrawerIntent.perform() files a drawer")
    @MainActor
    func captureIntentRuns() async throws {
        try await freshInMemoryRuntime()
        // perform() returns an opaque IntentResult; not throwing is the proof
        // that the shell reached the substrate and the substrate accepted.
        _ = try await CaptureDrawerIntent(
            content: "intent-shell capture",
            location: "tests"
        ).perform()
    }

    @Test("RecallDrawerIntent.perform() runs and honors the export gate shape")
    @MainActor
    func recallIntentRuns() async throws {
        try await freshInMemoryRuntime()
        _ = try await RecallDrawerIntent(query: "intent-shell", publicOnly: false).perform()
        // publicOnly sets filter:exportable; it must not throw even though it
        // returns nothing (the half-wired export edge).
        _ = try await RecallDrawerIntent(query: "intent-shell", publicOnly: true).perform()
    }

    @Test("MootURLRouter routes a capture x-callback URL through the tool surface")
    func urlRouterRoutesCapture() async throws {
        let bridge = try await MootBridge.attachInMemory()
        // "app" is in the callback-scheme allowlist so the x-success URL is
        // returned; this mirrors how a real host would configure the router.
        let router = MootURLRouter(permittedCallbackSchemes: ["app"])
        let url = URL(string: "mootx01://x-callback-url/capture?content=hello%20moot&location=urls&x-success=app://done")!
        let outcome = await router.route(url, using: bridge)
        guard case .routed(let returnURL, let text, let isError) = outcome else {
            Issue.record("expected routed outcome, got \(outcome)")
            return
        }
        #expect(isError == false)
        #expect(text.contains("filed memory"))
        // The x-success callback is echoed back with the result appended.
        #expect(returnURL?.absoluteString.contains("app://done") == true)
        #expect(returnURL?.absoluteString.contains("result=") == true)
    }

    @Test("MootURLRouter rejects an unknown verb without touching the substrate")
    func urlRouterRejectsUnknownVerb() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let router = MootURLRouter()
        let url = URL(string: "mootx01://x-callback-url/teleport?content=x")!
        let outcome = await router.route(url, using: bridge)
        guard case .notHandled = outcome else {
            Issue.record("expected notHandled for unknown verb")
            return
        }
    }

    @Test("CaptureSink files shared content")
    func shareSinkCaptures() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let sink = CaptureSink()
        let text = try await sink.capture(.init(text: "shared from another app"), using: bridge)
        #expect(text.contains("filed memory"))
    }

    @Test("Export policy is half-wired: capture then exportable-recall returns nothing")
    func exportPolicyEdgeHolds() async throws {
        let bridge = try await MootBridge.attachInMemory()
        _ = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("a private-by-default drawer"),
            "location": .string("edge"),
        ])
        let exportable = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("private-by-default"),
            "filter": .string("exportable"),
        ])
        // The captured drawer is private; the exportable filter excludes it.
        // If this ever starts returning the drawer, a caller path to mark
        // public was added — update GatewayEdges.findings to match.
        #expect(exportable.isError == false)
        #expect(exportable.text.contains("found 0 memory") || exportable.text.contains("0 memory(s)"))
    }

    @Test("InProcessTransport returns the real dispatcher response")
    func inProcessTransportReturnsResponse() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let transport = InProcessTransport(bridge: bridge)
        // A ping must come back as a real JSON-RPC result, not nil.
        let response = try await transport.send(.init(id: .integer(1), method: "ping", params: nil))
        #expect(response != nil)
        if case .result = response?.payload {} else {
            Issue.record("expected a result payload from ping over InProcessTransport")
        }
    }

    @Test("HTTP transport seam throws a named error rather than silently no-op'ing")
    func httpTransportSeamThrows() async throws {
        let seam = HTTPTransportSeam(endpoint: URL(string: "http://127.0.0.1:7777")!)
        await #expect(throws: GatewayTransportError.self) {
            _ = try await seam.send(.init(id: .integer(1), method: "ping", params: nil))
        }
    }
}
