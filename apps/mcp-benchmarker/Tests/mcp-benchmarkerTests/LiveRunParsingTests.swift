import Testing
import Foundation
@testable import mcp_benchmarker

// LiveRunParsingTests.swift — Swift Testing coverage for the live-run fixes:
// config-driven argument mapping, target-assigned-ID correlation, and the two
// real result formats (MemPalace text-JSON, MOOTx01 plain text). These exercise
// the same logic the live head-to-head depends on, using captured raw shapes as
// fixtures so no live server is needed.
//
// The fixtures are the verbatim shapes captured from the running servers on
// 2026-06-06 (see BENCHMARKER_001_BLAST_RADIUS.md): MemPalace `list_drawers`
// and `search`, and MOOTx01 `moot_file_memory` / `moot_memory_search`.

// MARK: - Fixture builders

/// Wraps a server's text payload in the MCP `content` text-block envelope, the
/// shape `parseToolResult` receives from `sendRequest`.
private func textResult(_ text: String) -> JSONValue {
    .object(["content": .array([
        .object(["type": .string("text"), "text": .string(text)])
    ])])
}

struct LiveRunParsingTests {

    // MARK: - MemPalace list_drawers (jsonObjects, drawer_id / content_preview)

    @Test("MemPalace list_drawers parses drawer_id + content_preview in order")
    func mempalaceListDrawers() {
        let payload = """
        {
          "drawers": [
            { "drawer_id": "d1", "wing": "w", "room": "r", "content_preview": "alpha content" },
            { "drawer_id": "d2", "wing": "w", "room": "r", "content_preview": "beta content" }
          ],
          "count": 2
        }
        """
        let result = MCPClient.parseToolResult(
            textResult(payload),
            format: .jsonObjects(idKey: "drawer_id", contentKey: "content_preview"))
        #expect(result.orderedIDs == ["d1", "d2"])
        #expect(result.items.map(\.content) == ["alpha content", "beta content"])
        #expect(result.writeAssignedID == nil)
    }

    // MARK: - MemPalace search (jsonObjects, no id, content under `text`)

    @Test("MemPalace search parses content from `text` with no stable id")
    func mempalaceSearch() {
        let payload = """
        {
          "query": "q",
          "results": [
            { "text": "first hit", "wing": "w", "similarity": 0.9 },
            { "text": "second hit", "wing": "w", "similarity": 0.7 }
          ]
        }
        """
        let result = MCPClient.parseToolResult(
            textResult(payload),
            format: .jsonObjects(idKey: nil, contentKey: "text"))
        // No id key → no ordered ids, but content is recovered in order.
        #expect(result.orderedIDs.isEmpty)
        #expect(result.items.map(\.content) == ["first hit", "second hit"])
    }

    // MARK: - MOOTx01 write response (mootText, filed memory <UUID>)

    @Test("MOOTx01 write response yields the target-assigned UUID")
    func mootWriteAssignedID() {
        let payload = """
        filed memory 7CF35028-84BE-40D0-A8CB-7FCFE8EB6018
        room: import/test
        lineage: 8D976526-1598-42CF-8257-E3233F414BA8
        """
        let result = MCPClient.parseToolResult(textResult(payload), format: .mootText)
        // The assigned id is the filed-memory UUID, NOT the lineage UUID.
        #expect(result.writeAssignedID == "7CF35028-84BE-40D0-A8CB-7FCFE8EB6018")
    }

    // MARK: - MOOTx01 search response (mootText, ranked <UUID> [loc] content)

    @Test("MOOTx01 search response parses ranked UUIDs and content in order")
    func mootSearchRanked() {
        let payload = """
        found 2 memory(s)
        7CF35028-84BE-40D0-A8CB-7FCFE8EB6018  [import/test]  The benchmarker proves mootx01 outperforms MemPalace.
        84B0178B-A133-4F43-91D0-2854E7AC45FB  [import/test]  Apple Silicon Metal kernel dispatch.
        """
        let result = MCPClient.parseToolResult(textResult(payload), format: .mootText)
        #expect(result.orderedIDs == [
            "7CF35028-84BE-40D0-A8CB-7FCFE8EB6018",
            "84B0178B-A133-4F43-91D0-2854E7AC45FB",
        ])
        #expect(result.items.first?.content == "The benchmarker proves mootx01 outperforms MemPalace.")
        // The `found N` header line carries no UUID and is not an item.
        #expect(result.items.count == 2)
        // No write id on a search response.
        #expect(result.writeAssignedID == nil)
    }

    @Test("MOOTx01 search content survives when a hit has no location bracket")
    func mootSearchNoBracket() {
        let payload = """
        found 1 memory(s)
        7CF35028-84BE-40D0-A8CB-7FCFE8EB6018  bare content with no bracket
        """
        let result = MCPClient.parseToolResult(textResult(payload), format: .mootText)
        #expect(result.items.first?.content == "bare content with no bracket")
    }

    // MARK: - Empty / malformed results

    @Test("Empty result parses to no items for both formats")
    func emptyResults() {
        let json = MCPClient.parseToolResult(
            textResult("{}"), format: .jsonObjects(idKey: "id", contentKey: "content"))
        #expect(json.items.isEmpty)
        let moot = MCPClient.parseToolResult(textResult("found 0 memory(s)"), format: .mootText)
        #expect(moot.items.isEmpty)
        #expect(moot.writeAssignedID == nil)
    }

    // MARK: - structuredContent channel still works (jsonObjects)

    @Test("jsonObjects reads structuredContent before falling back to text")
    func structuredContentPreferred() {
        let result = JSONValue.object([
            "structuredContent": .object([
                "results": .array([
                    .object(["id": .string("s1"), "content": .string("c1")]),
                ])
            ]),
            "content": .array([
                .object(["type": .string("text"), "text": .string("ignored text block")])
            ]),
        ])
        let parsed = MCPClient.parseToolResult(
            result, format: .jsonObjects(idKey: "id", contentKey: "content"))
        #expect(parsed.orderedIDs == ["s1"])
        #expect(parsed.items.first?.content == "c1")
    }
}

// MARK: - Config decode of the new verbMap fields

struct LiveRunConfigTests {

    private func loadVerbMap(_ verbMapJSON: String) throws -> EndpointConfig.VerbMap {
        let json = """
        {
          "source": {
            "name": "s", "transport": { "stdio": { "command": "x" } },
            "verbMap": \(verbMapJSON), "role": "source"
          },
          "target": {
            "name": "t", "transport": { "stdio": { "command": "y" } },
            "verbMap": { "write": "w", "query": "q", "list": null }, "role": "target"
          }
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try BenchmarkerConfig.load(from: url).source.verbMap
    }

    @Test("Terse verbMap defaults the new arg/format fields")
    func defaultsApply() throws {
        let vm = try loadVerbMap(#"{ "write": "w", "query": "q", "list": "l" }"#)
        #expect(vm.contentArg == "content")
        #expect(vm.queryArg == "query")
        #expect(vm.constantArgs == ["location": "import/mempalace"])
        #expect(vm.resultFormat == .jsonObjects(idKey: "id", contentKey: "content"))
    }

    @Test("MemPalace source verbMap decodes drawer_id / content_preview format")
    func mempalaceFormatDecodes() throws {
        let vm = try loadVerbMap("""
        {
          "write": "mempalace_add_drawer",
          "query": "mempalace_search",
          "list": "mempalace_list_drawers",
          "resultFormat": { "kind": "jsonObjects", "idKey": "drawer_id", "contentKey": "content_preview" }
        }
        """)
        #expect(vm.list == "mempalace_list_drawers")
        #expect(vm.resultFormat == .jsonObjects(idKey: "drawer_id", contentKey: "content_preview"))
    }

    @Test("MOOTx01 target verbMap decodes mootText + single location constant")
    func mootTextFormatDecodes() throws {
        let vm = try loadVerbMap("""
        {
          "write": "moot_file_memory",
          "query": "moot_memory_search",
          "list": null,
          "constantArgs": { "location": "import/mempalace" },
          "resultFormat": { "kind": "mootText" }
        }
        """)
        #expect(vm.write == "moot_file_memory")
        #expect(vm.resultFormat == .mootText)
        #expect(vm.constantArgs == ["location": "import/mempalace"])
    }

    @Test("MemPalace write verbMap decodes two constant args (wing + room)")
    func mempalaceTwoConstantArgs() throws {
        // The export direction: MemPalace `add_drawer` requires wing AND room,
        // so the constantArgs map carries two keys (proves the multi-constant
        // generalization the single-key form could not express).
        let vm = try loadVerbMap("""
        {
          "write": "mempalace_add_drawer",
          "query": "mempalace_search",
          "list": "mempalace_list_drawers",
          "constantArgs": { "wing": "wing_import", "room": "general" }
        }
        """)
        #expect(vm.constantArgs == ["wing": "wing_import", "room": "general"])
    }

    @Test("Explicit empty constantArgs sends no constant write arguments")
    func emptyConstantArgs() throws {
        let vm = try loadVerbMap(#"{ "write": "w", "query": "q", "list": "l", "constantArgs": {} }"#)
        #expect(vm.constantArgs.isEmpty)
    }
}

// MARK: - Content-order normalization for cross-server rank comparison

struct ContentOrderTests {

    @Test("normalizedContentOrder lowercases, collapses whitespace, bounds length")
    func normalization() {
        let items = [
            MCPResultItem(id: nil, content: "  Alpha   BETA\n\tGamma  "),
            MCPResultItem(id: nil, content: nil),  // dropped (no content)
            MCPResultItem(id: nil, content: "second"),
        ]
        let order = BenchmarkEngine.normalizedContentOrder(items)
        #expect(order == ["alpha beta gamma", "second"])
    }

    @Test("Truncated preview matches full content on the shared 64-char prefix")
    func prefixMatch() {
        let full = String(repeating: "x", count: 100) + "TAIL"
        let preview = String(repeating: "x", count: 80)  // a truncated preview
        let a = BenchmarkEngine.normalizedContentOrder([MCPResultItem(id: nil, content: full)])
        let b = BenchmarkEngine.normalizedContentOrder([MCPResultItem(id: nil, content: preview)])
        // Both bounded to 64 chars → identical, so they rank-correlate as the same item.
        #expect(a == b)
    }
}
