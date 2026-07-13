import Testing
import Foundation
import MootIntentKit
import AriaMCP   // JSONValue, for the refusing-bridge conformance

// MARK: - ShareInboxSpool tests
//
// The extension side (enqueue) and the host side (drain) of the share-capture
// handoff, exercised against a temp queue directory and a live in-memory
// estate. The extension process never opens the estate — the spool (QueueKit
// maildir) alone carries the content across.

@Suite("ShareInboxSpool — extension enqueues, host drains into the estate")
struct ShareInboxSpoolTests {

    private func makeTempSpool() throws -> ShareInboxSpool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-tests-\(UUID().uuidString)", isDirectory: true)
        return try ShareInboxSpool(directory: dir)
    }

    @Test("enqueue then drain: the shared item lands in the estate as a drawer")
    func enqueueDrainRoundTrip() async throws {
        let spool = try makeTempSpool()
        let bridge = try await TestBridge.makeInMemory()

        try await spool.enqueue(.init(text: "spooled from the share sheet", location: "shared"))
        let outcome = await spool.drain(using: bridge)
        #expect(outcome.captured == 1)
        #expect(outcome.remaining == 0)

        let recalled = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("spooled from the share sheet"),
        ])
        #expect(recalled.text.contains("spooled from the share sheet"))
    }

    @Test("drain is idempotent: a drained spool captures nothing on the second pass")
    func drainIdempotent() async throws {
        let spool = try makeTempSpool()
        let bridge = try await TestBridge.makeInMemory()

        try await spool.enqueue(.init(text: "drain me once"))
        _ = await spool.drain(using: bridge)
        let second = await spool.drain(using: bridge)
        #expect(second.captured == 0)
        #expect(second.remaining == 0)
    }

    @Test("multiple enqueued items all drain")
    func multipleItemsDrain() async throws {
        let spool = try makeTempSpool()
        let bridge = try await TestBridge.makeInMemory()

        try await spool.enqueue(.init(text: "first shared item"))
        try await spool.enqueue(.init(text: "second shared item"))
        try await spool.enqueue(.init(text: "third shared item"))
        let outcome = await spool.drain(using: bridge)
        #expect(outcome.captured == 3)
        #expect(outcome.remaining == 0)
    }

    @Test("a failed capture leaves the item in-flight for the next drain")
    func failedCaptureRetried() async throws {
        let spool = try makeTempSpool()

        try await spool.enqueue(.init(text: "capture target refuses"))
        let refusing = RefusingBridge()
        let first = await spool.drain(using: refusing)
        #expect(first.captured == 0)
        #expect(first.remaining == 1, "refused items are not lost")

        // A later drain with a working estate reclaims and captures it.
        let bridge = try await TestBridge.makeInMemory()
        let second = await spool.drain(using: bridge)
        #expect(second.captured == 1, "the reclaimed item captures on retry")
    }
}

/// A caller that refuses every tool call — the substrate-down case.
private actor RefusingBridge: MootToolCalling {
    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult {
        IntentCallResult(text: "estate unavailable", isError: true)
    }
}
