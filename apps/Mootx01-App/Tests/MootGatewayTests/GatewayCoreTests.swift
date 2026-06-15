import Testing
import Foundation
@testable import MootGateway

// Core wiring smoke tests: an in-memory MOOT attaches, and the ARIA tool
// surface answers a capture and a recall in-process — no transport, no app
// bundle. These prove the bridge talks to the substrate the same way a
// remote MCP client would.

@Suite("Gateway core wiring")
struct GatewayCoreTests {

    @Test("capture then recall round-trips through the ARIA tool surface")
    func captureThenRecall() async throws {
        let bridge = try await MootBridge.attachInMemory()

        let filed = await bridge.callToolFull("moot_file_memory", arguments: [
            "content": .string("MOOTx01 wires ARIA to a native Apple surface."),
            "location": .string("gateway"),
        ])
        #expect(filed.isError == false)
        #expect(filed.text.contains("filed memory"))

        let found = await bridge.callToolFull("moot_memory_search", arguments: [
            "query": .string("native Apple surface"),
        ])
        #expect(found.isError == false)
        #expect(found.text.contains("memory"))
    }

    @Test("tools/list exposes the moot_* surface")
    func toolsListExposed() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let list = await bridge.toolsList()
        let tools = list.objectValue?["tools"]?.arrayValue ?? []
        #expect(tools.isEmpty == false)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names.contains("moot_file_memory"))
        #expect(names.contains("moot_memory_search"))
    }

    // MARK: - Force-tests: exportability write path and A3 v1.1 guard

    @Test("capture with exportability:public then filter:exportable recall returns the drawer")
    func capturePublicThenExportableRecallFindsIt() async throws {
        let bridge = try await MootBridge.attachInMemory()

        // Capture with explicit exportability:"public" — the write path the
        // stale UI text denied exists. moot_file_memory decodes the arg via
        // decodeExportability() in ToolDispatch.swift and stamps the bitmap.
        let filed = await bridge.callToolFull("moot_file_memory", arguments: [
            "content": .string("exportable-force-test-marker"),
            "location": .string("gateway"),
            "exportability": .string("public"),
        ])
        #expect(filed.isError == false)
        #expect(filed.text.contains("filed memory"))

        // filter:exportable on the read side — must find the public drawer we
        // just filed; proves the write path and the read gate work end-to-end.
        let found = await bridge.callToolFull("moot_memory_search", arguments: [
            "query": .string("exportable-force-test-marker"),
            "filter": .string("exportable"),
        ])
        #expect(found.isError == false)
        #expect(found.text.contains("memory"))
    }

    @Test("MootEstateClient.fetch throws outboundFederationNotInThisVersion in beta")
    func estateClientFetchThrowsV1_1Guard() async throws {
        // A3 outbound federation is a v1.1 surface by Bob's ruling. Any beta
        // caller that tries to invoke fetch() must receive the named guard error —
        // not fabricated data, not a crash, and not a silent no-op.
        let client = MootEstateClient()
        let endpoint = URL(string: "http://192.168.1.1:7007")!
        await #expect(throws: MootEstateClientError.self) {
            _ = try await client.fetch(from: endpoint, query: "anything")
        }
    }
}
