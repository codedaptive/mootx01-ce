import Testing
@testable import AriaMCP

/// Coverage that the AI-client-oriented tool surface holds the contract
/// described in ARIA_MCP_SPEC (MCP-INT-01 surface replacement).
///
/// The five-tier interface tools carry `.interface` provenance; the
/// federation tool carries `.federation`. Recipe and lens tools carry
/// `.recipe`; vault tools carry `.vault`. There are no `.lexicon` tools.
@Suite("Tool projection")
struct ToolProjectionTests {

    /// Every interface tool must carry `.interface` provenance. No
    /// `.lexicon` provenance should appear anywhere in the list.
    @Test func testNoLexiconProvenance() {
        for tool in ToolProjection.tools() {
            if case .interface = tool.provenance { continue }
            if case .federation = tool.provenance { continue }
            if case .recipe = tool.provenance { continue }
            if case .vault = tool.provenance { continue }
            Issue.record("Unexpected provenance on tool \(tool.name)")
        }
    }

    /// Hard contract gate: the total tool count must be exactly 54.
    /// 19 interface + 1 federation + 7 recipe + 21 lens + 5 vault + 1 maintenance.
    /// The 7th recipe tool is moot_dream (matrix rebuild + dreaming cycle);
    /// the maintenance tool is moot_reindex (corpus/vector backfill).
    /// Any accidental addition or removal fails here before it ships.
    @Test func testTotalToolCount() {
        #expect(ToolProjection.tools().count == 54,
                "tools() must return exactly 54 tools; got \(ToolProjection.tools().count)")
    }

    /// All 19 interface tools must be present.
    @Test func testInterfaceToolsArePresent() {
        let names = Set(ToolProjection.tools().map(\.name))
        let expected: [String] = [
            // Tier 1
            "moot_file_memory", "moot_memory_search", "moot_update_memory",
            "moot_withdraw_memory", "moot_erase_memory", "moot_confirm_memory",
            "moot_move_memory",
            // Tier 2
            "moot_link_memories", "moot_connection_search", "moot_connection_map",
            // Tier 3
            "moot_file_fact", "moot_fact_search", "moot_retire_fact",
            "moot_fact_timeline",
            // Tier 4
            "moot_write_journal", "moot_read_journal",
            // Tier 5
            "moot_estate_status", "moot_estate_map", "moot_estate_ping",
        ]
        for name in expected {
            #expect(names.contains(name), "\(name) missing from tools()")
        }
    }

    /// Old lexicon tool names must not be present in the new surface.
    @Test func testOldToolNamesAreGone() {
        let names = Set(ToolProjection.tools().map(\.name))
        let removed: [String] = [
            "moot_capture_drawer", "moot_drawer_recall", "moot_mutate_drawer",
            "moot_withdraw_drawer", "moot_expunge_drawer", "moot_reanchor_drawer",
            "moot_capture_tunnel", "moot_tunnel_recall",
            "moot_cross_estate_recall",
        ]
        for name in removed {
            #expect(!names.contains(name), "\(name) should no longer be on the surface")
        }
    }

    /// Every tool name must start with the product namespace prefix.
    @Test func testAllToolNamesHaveProductPrefix() {
        for tool in ToolProjection.tools() {
            #expect(
                tool.name.hasPrefix(ToolProjection.toolNamePrefix),
                "\(tool.name) is missing the moot_ prefix"
            )
        }
    }

    /// The federation tool must be present, carry `.federation` provenance,
    /// and use the renamed `federatedSearchToolName` constant.
    @Test func testFederationToolIsPresentAboveTheProjection() throws {
        let federation = ToolProjection.tools().filter { $0.provenance == .federation }
        #expect(federation.count == 1, "exactly one federation tool is expected")
        let tool = try #require(federation.first)
        #expect(tool.name == ToolDispatcher.federatedSearchToolName)
        #expect(tool.name == "moot_federated_search")
        // Federation tool requires the requester identity and carries no estateID
        // (it fans across estates rather than targeting one).
        let schema = tool.inputSchema.objectValue
        let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(required.contains("requesterEstateID"))
        #expect(schema?["properties"]?.objectValue?["estateID"] == nil)
    }

    /// `moot_file_memory` must require `content` and `location`, and must
    /// NOT expose internal infrastructure fields (udcCode, embeddingModelID,
    /// latticeAnchor, addedBy).
    @Test func testFileMemoryRequiredFieldsAndNoInternals() {
        guard let tool = ToolProjection.tools().first(where: { $0.name == "moot_file_memory" }) else {
            Issue.record("moot_file_memory not found")
            return
        }
        let schema = tool.inputSchema.objectValue
        let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(required.contains("content"), "content must be required")
        #expect(required.contains("location"), "location must be required")
        let properties = schema?["properties"]?.objectValue ?? [:]
        // Internal fields must not be surfaced.
        #expect(properties["udcCode"] == nil, "udcCode must not appear on AI-client surface")
        #expect(properties["embeddingModelID"] == nil, "embeddingModelID must not appear")
        #expect(properties["addedBy"] == nil, "addedBy must not appear")
        #expect(properties["latticeAnchor"] == nil, "latticeAnchor must not appear")
    }

    /// `moot_erase_memory` must require `confirmed` (safety gate).
    @Test func testEraseMemoryRequiresConfirmed() {
        guard let tool = ToolProjection.tools().first(where: { $0.name == "moot_erase_memory" }) else {
            Issue.record("moot_erase_memory not found")
            return
        }
        let required = tool.inputSchema.objectValue?["required"]?
            .arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(required.contains("confirmed"), "moot_erase_memory must require confirmed=true")
    }

    /// `moot_memory_search` must require `query`.
    @Test func testMemorySearchRequiresQuery() {
        guard let tool = ToolProjection.tools().first(where: { $0.name == "moot_memory_search" }) else {
            Issue.record("moot_memory_search not found")
            return
        }
        let required = tool.inputSchema.objectValue?["required"]?
            .arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(required.contains("query"), "moot_memory_search must require query")
    }

    /// `estateID` must be optional (in properties, not in required) on every
    /// interface tool.
    @Test func testEstateIDIsOptionalOnInterfaceTools() {
        for tool in ToolProjection.tools() {
            guard case .interface = tool.provenance else { continue }
            let schema = tool.inputSchema.objectValue
            #expect(
                schema?["properties"]?.objectValue?["estateID"] != nil,
                "\(tool.name) must expose an optional estateID property"
            )
            let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            #expect(
                !required.contains("estateID"),
                "\(tool.name) must never require estateID"
            )
        }
    }
}
