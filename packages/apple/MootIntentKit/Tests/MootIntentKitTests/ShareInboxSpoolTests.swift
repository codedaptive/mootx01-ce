import Testing
import Foundation
import MootIntentKit
import AriaMCP   // JSONValue, for the refusing-bridge conformance

// MARK: - ShareInboxSpool tests
//
// The Share Extension side (enqueue) and the host-app side (drain) of the
// share-capture handoff, exercised against a temp directory and a live
// in-memory estate. The extension process never opens the estate — these
// tests prove the spool alone carries the content across.

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

        try spool.enqueue(.init(text: "spooled from the share sheet", location: "shared"))
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

        try spool.enqueue(.init(text: "drain me once"))
        _ = await spool.drain(using: bridge)
        let second = await spool.drain(using: bridge)
        #expect(second.captured == 0)
        #expect(second.remaining == 0)
    }

    @Test("multiple enqueued items all drain, oldest first")
    func multipleItemsDrain() async throws {
        let spool = try makeTempSpool()
        let bridge = try await TestBridge.makeInMemory()

        try spool.enqueue(.init(text: "first shared item"))
        try spool.enqueue(.init(text: "second shared item"))
        try spool.enqueue(.init(text: "third shared item"))
        let outcome = await spool.drain(using: bridge)
        #expect(outcome.captured == 3)
        #expect(outcome.remaining == 0)
    }

    @Test("a malformed spool file is quarantined, not retried forever and not fatal")
    func malformedFileQuarantined() async throws {
        let spool = try makeTempSpool()
        let bridge = try await TestBridge.makeInMemory()

        try spool.enqueue(.init(text: "valid item beside garbage"))
        // Drop a non-JSON file into the spool directory.
        let garbage = spool.directory.appendingPathComponent("zzz-garbage.json")
        try Data("not json".utf8).write(to: garbage)

        let outcome = await spool.drain(using: bridge)
        #expect(outcome.captured == 1, "the valid item still drains")
        #expect(outcome.remaining == 0, "garbage is quarantined out of the spool")
        // The quarantined file is preserved for diagnosis, outside the drain path.
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: spool.directory.appendingPathComponent("quarantine", isDirectory: true),
            includingPropertiesForKeys: nil)
        #expect(quarantined.count == 1)
    }

    @Test("a failed capture leaves the item spooled for the next drain")
    func failedCaptureStaysSpooled() async throws {
        let spool = try makeTempSpool()

        try spool.enqueue(.init(text: "capture target refuses"))
        let refusing = RefusingBridge()
        let outcome = await spool.drain(using: refusing)
        #expect(outcome.captured == 0)
        #expect(outcome.remaining == 1, "refused items stay for retry")
    }
}

/// A caller that refuses every tool call — the substrate-down case.
private actor RefusingBridge: MootToolCalling {
    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult {
        IntentCallResult(text: "estate unavailable", isError: true)
    }
}
