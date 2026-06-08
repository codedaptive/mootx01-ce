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

        let filed = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string("MOOTx01 wires ARIA to a native Apple surface."),
            "location": .string("gateway"),
        ])
        #expect(filed.isError == false)
        #expect(filed.text.contains("filed memory"))

        let found = await bridge.callTool("moot_memory_search", arguments: [
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
}
