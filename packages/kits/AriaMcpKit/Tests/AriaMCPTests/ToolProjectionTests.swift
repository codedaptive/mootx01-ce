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

    /// ADR-025 §3, the structural rule: "There is no moot_unlock tool and
    /// there never will be" — the sensitivity-unlock approval channel is
    /// physically separate from the MCP surface a prompt-injected model
    /// could reach. This guard fails loudly if any future tool addition
    /// accidentally (or deliberately) introduces an unlock-shaped verb on
    /// the MCP surface — approval must only ever happen via the
    /// out-of-band `mootx01 unlock`/`lock` CLI.
    @Test func testNoUnlockToolOnMCPSurface() {
        for tool in ToolProjection.tools() {
            let lower = tool.name.lowercased()
            #expect(!lower.contains("unlock"),
                    "ADR-025 §3 violation: '\(tool.name)' looks like an unlock verb on the MCP surface")
            #expect(!(lower.contains("lock") && !lower.contains("block") && !lower.contains("clock")),
                    "ADR-025 §3 violation: '\(tool.name)' looks like a lock/unlock verb on the MCP surface")
        }
    }

    /// Hard contract gate: the total tool count must be exactly 63.
    /// 20 interface + 1 federation + 11 recipe + 23 lens + 5 vault + 3 maintenance.
    /// The 20th interface tool is moot_memory_get (Tier 1 — fetch one memory
    /// drawer by id, in full; docs_internal/V1_1_PARKING_LOT.md's
    /// fetch-drawer-by-ID gap, build-now per Bob's ruling).
    /// The 23rd lens tool is moot_lens_node_motion (diffusion node-layer lens,
    /// ADR-DIFFUSION-001) added alongside moot_lens_contradiction.
    /// The 11th recipe tool is moot_recollect (DA1 — three distillation tools:
    /// moot_consolidate, moot_recall_distilled, moot_recollect). The three
    /// maintenance tools are moot_reindex (corpus/vector backfill),
    /// moot_drain_status (background drain progress), and moot_palace_import
    /// (PAR-PB-1, direct palace import).
    /// Any accidental addition or removal fails here before it ships.
    @Test func testTotalToolCount() {
        #expect(ToolProjection.tools().count == 63,
                "tools() must return exactly 63 tools; got \(ToolProjection.tools().count)")
    }

    /// All 20 interface tools must be present.
    @Test func testInterfaceToolsArePresent() {
        let names = Set(ToolProjection.tools().map(\.name))
        let expected: [String] = [
            // Tier 1
            "moot_file_memory", "moot_memory_search", "moot_memory_get",
            "moot_update_memory", "moot_withdraw_memory", "moot_erase_memory",
            "moot_confirm_memory", "moot_move_memory",
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
    ///
    /// Item 2 hardening: `requesterEstateID` is now optional (anti-spoof gate
    /// binds the requester to the default estate when omitted). The required
    /// list must be empty. The property is still present in the schema so
    /// callers can supply it for verification (it must match the default).
    @Test func testFederationToolIsPresentAboveTheProjection() throws {
        let federation = ToolProjection.tools().filter { $0.provenance == .federation }
        #expect(federation.count == 1, "exactly one federation tool is expected")
        let tool = try #require(federation.first)
        #expect(tool.name == ToolDispatcher.federatedSearchToolName)
        #expect(tool.name == "moot_federated_search")
        let schema = tool.inputSchema.objectValue
        // requesterEstateID is optional; required must be empty (Item 2 hardening).
        let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(!required.contains("requesterEstateID"),
            "requesterEstateID must not be required after Item 2 anti-spoof hardening")
        #expect(required.isEmpty, "federation tool has no required fields after Item 2")
        // The property is present in the schema (so clients know it exists).
        #expect(schema?["properties"]?.objectValue?["requesterEstateID"] != nil,
            "requesterEstateID must remain in properties as an optional field")
        #expect(schema?["properties"]?.objectValue?["estateID"] == nil,
            "federation tool fans across estates, not a single estateID target")
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

    /// `moot_reindex` must pass the `InterfaceTools.isInterfaceTool` membership
    /// gate so the serve host routes it to `runReindex` instead of throwing
    /// "Unknown tool" (-32601).
    ///
    /// Regression gate: the `names` Set in `InterfaceTools` previously omitted
    /// `moot_reindex`, causing the outer dispatcher to fall through to the
    /// unknown-tool throw even though the dispatch switch already had the case.
    @Test func testMootReindexPassesMembershipGate() {
        // The gate that the serve host evaluates before reaching the dispatch switch.
        #expect(
            InterfaceTools.isInterfaceTool("moot_reindex"),
            "moot_reindex must be in the InterfaceTools membership gate"
        )
    }

    /// `moot_palace_import` must pass the `InterfaceTools.isInterfaceTool` membership
    /// gate so the serve host routes it to `runPalaceImport` instead of throwing
    /// "Unknown tool" (-32601). Regression gate matching `testMootReindexPassesMembershipGate`.
    @Test func testMootPalaceImportPassesMembershipGate() {
        #expect(
            InterfaceTools.isInterfaceTool("moot_palace_import"),
            "moot_palace_import must be in the InterfaceTools membership gate"
        )
    }

    /// Every tool in the `InterfaceTools` dispatch switch must also be in the
    /// membership gate — the two sets must stay in sync. This catches the class
    /// of bug where a case is added to the switch but omitted from `names`.
    ///
    /// The expected set is the canonical 20 Tier 1–5 tools plus maintenance
    /// tools (`moot_reindex`, `moot_drain_status`, `moot_palace_import`). If a
    /// new tool is added to the switch, add it here too.
    @Test func testMembershipGateCoversAllDispatchCases() {
        // All tools that appear in the InterfaceTools dispatch switch.
        let dispatchCases: [String] = [
            // Tier 1
            "moot_file_memory", "moot_memory_search", "moot_memory_get",
            "moot_update_memory", "moot_withdraw_memory", "moot_erase_memory",
            "moot_confirm_memory", "moot_move_memory",
            // Tier 2
            "moot_link_memories", "moot_connection_search", "moot_connection_map",
            // Tier 3
            "moot_file_fact", "moot_fact_search", "moot_retire_fact",
            "moot_fact_timeline",
            // Tier 4
            "moot_write_journal", "moot_read_journal",
            // Tier 5
            "moot_estate_status", "moot_estate_map", "moot_estate_ping",
            // Maintenance / admin
            "moot_reindex", "moot_drain_status", "moot_palace_import",
        ]
        for name in dispatchCases {
            #expect(
                InterfaceTools.isInterfaceTool(name),
                "\(name) is in the dispatch switch but missing from the membership gate"
            )
        }
    }
}
