import Testing
import Foundation
import AppIntents
@testable import MootGateway
import MootIntentKit

// The adapter shells are not dead stubs: their perform()/route() bodies run
// against a live estate in-process. These tests exercise them the same way
// the app's "Apple Surfaces" tab does, and pin the discovered edges so a
// regression that silently "fixes" them is noticed.
//
// Intent types (CaptureDrawerIntent, RecallDrawerIntent, MootURLRouter,
// CaptureSink) now live in MootIntentKit; MootGateway tests import both.

@Suite("Adapter shells run in-process")
struct AdapterShellTests {

    /// Give the shared runtime an in-memory estate before exercising intents,
    /// so the test does not touch ~/.mootx01. Also registers the bridge with
    /// IntentRuntimeBridge so intent perform() fallback resolves correctly.
    private func freshInMemoryRuntime() async throws {
        await GatewayRuntime.shared.configure(databaseURL: nil)
        let bridge = try await GatewayRuntime.shared.bridge()
        await IntentRuntimeBridge.shared.register(bridge)
    }

    @Test("CaptureDrawerIntent.perform() files a drawer")
    @MainActor
    func captureIntentRuns() async throws {
        try await freshInMemoryRuntime()
        // perform() returns an opaque IntentResult; not throwing is the proof
        // that the intent reached the substrate and the substrate accepted.
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
        // publicOnly sets filter:exportable; it must not throw even though it returns nothing
        // here — no public drawer was captured in this test (expected: correct gate behavior).
        _ = try await RecallDrawerIntent(query: "intent-shell", publicOnly: true).perform()
    }

    @Test("MootURLRouter routes a capture x-callback URL through the tool surface")
    func urlRouterRoutesCapture() async throws {
        let bridge = try await MootBridge.attachInMemory()
        // "app" is in the callback-scheme allowlist so the x-success URL is
        // returned; this mirrors how a real host would configure the router.
        let router = MootURLRouter(permittedCallbackSchemes: ["app"])
        let url = URL(string: "mootx01://x-callback-url/capture?content=hello%20moot&location=urls&x-success=app://done")!
        // MootBridge conforms to MootToolCalling, so it passes directly.
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
        // MootBridge conforms to MootToolCalling, so it passes directly.
        let text = try await sink.capture(.init(text: "shared from another app"), using: bridge)
        #expect(text.contains("filed memory"))
    }

    @Test("Private-by-default drawer is correctly excluded by filter:exportable")
    func exportPolicyGateExcludesPrivateDrawer() async throws {
        let bridge = try await MootBridge.attachInMemory()
        // Capture without specifying exportability — the default is private.
        _ = await bridge.callToolFull("moot_file_memory", arguments: [
            "content": .string("a private-by-default drawer"),
            "location": .string("edge"),
        ])
        let exportable = await bridge.callToolFull("moot_memory_search", arguments: [
            "query": .string("private-by-default"),
            "filter": .string("exportable"),
        ])
        // The captured drawer is private; filter:exportable correctly excludes it.
        // This is expected gate behavior, not a system gap. The write path is real:
        // pass exportability:"public" to moot_file_memory or use
        // moot_update_memory correctExportability(public) to make a drawer public.
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

    @Test("HTTPTransport throws a named connectionRefused when no daemon is running")
    func httpTransportThrowsWhenNoDaemon() async throws {
        // Port 1 is below the ephemeral range and not bound on any macOS/Linux
        // system in test; connect() returns ECONNREFUSED immediately on loopback.
        let transport = HTTPTransport(endpoint: URL(string: "http://127.0.0.1:1")!, timeout: 2.0)
        await #expect(throws: GatewayTransportError.self) {
            _ = try await transport.send(.init(id: .integer(1), method: "ping", params: nil))
        }
    }

    // MARK: M-ING-1 — ingestion targeting on the capture surface

    @Test("CaptureDrawerIntent routes wing and eventTime to the drawer (M-ING-1)")
    @MainActor
    func captureIntentWingAndEventTimeLand() async throws {
        let bridge = try await MootBridge.attachInMemory()
        // Fixed instant (2025-06-15T15:06:40Z): eventTime models when a mined
        // fact was TRUE, so the test pins a date that cannot be "now".
        let past = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await CaptureDrawerIntent(
            content: "m-ing-1 targeting probe",
            location: "health",
            wing: "Personal Life",
            eventTime: past,
            caller: bridge
        ).perform()

        // Recover the drawer id from the search surface, then read it back in
        // full — the get output carries the wing and event_time lines.
        let search = await bridge.callToolFull("moot_memory_search", arguments: [
            "query": .string("m-ing-1 targeting probe"),
            "wing": .string("Personal Life"),
        ])
        #expect(search.isError == false)
        let hits = MootBridge.parseDrawerLines(search.text)
        try #require(hits.count == 1)

        let get = await bridge.callToolFull("moot_memory_get", arguments: [
            "id": .string(hits[0].id),
        ])
        #expect(get.isError == false)
        #expect(get.text.contains("wing: Personal Life"))
        #expect(get.text.contains("event_time: 2025-06-15"))
    }

    @Test("CaptureDrawerIntent defaults are unchanged when targeting is omitted (M-ING-1)")
    @MainActor
    func captureIntentTargetingDefaultsUnchanged() async throws {
        let bridge = try await MootBridge.attachInMemory()
        _ = try await CaptureDrawerIntent(
            content: "m-ing-1 default probe",
            location: "tests",
            caller: bridge
        ).perform()
        let search = await bridge.callToolFull("moot_memory_search", arguments: [
            "query": .string("m-ing-1 default probe"),
        ])
        let hits = MootBridge.parseDrawerLines(search.text)
        try #require(hits.count == 1)
        let get = await bridge.callToolFull("moot_memory_get", arguments: [
            "id": .string(hits[0].id),
        ])
        // nil wing/eventTime → server defaults: the default wing, streaming
        // capture time (today, not a pinned past date).
        #expect(get.text.contains("wing: Agentic Memory"))
        #expect(!get.text.contains("event_time: 2025-06-15"))
    }
}
