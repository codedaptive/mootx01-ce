import Testing
@testable import AriaMCP

/// Coverage that the AI-client-oriented tool surface holds the contract
/// described in ARIA_MCP_SPEC (MCP-INT-01 surface replacement).
///
/// The five-tier interface tools carry `.interface` provenance; the
/// federation tool carries `.federation`. Recipe and lens tools carry
/// `.recipe`; vault tools carry `.vault`. There are no `.lexicon` tools.
///
/// Every test projects with `tools(environment: [:])` — an explicit empty
/// environment — so the contract (78 tools: vault on by default, opt-in
/// memory tool off) holds regardless of what the test runner's process
/// environment or a concurrently running suite has set.
@Suite("Tool projection")
struct ToolProjectionTests {

    /// Every interface tool must carry `.interface` provenance. No
    /// `.lexicon` provenance should appear anywhere in the list.
    @Test func testNoLexiconProvenance() {
        for tool in ToolProjection.tools(environment: [:]) {
            if case .interface = tool.provenance { continue }
            if case .federation = tool.provenance { continue }
            if case .recipe = tool.provenance { continue }
            if case .vault = tool.provenance { continue }
            Issue.record("Unexpected provenance on tool \(tool.name)")
        }
    }

    /// out-of-band sensitivity grants, the structural rule: "There is no moot_unlock tool and
    /// there never will be" — the sensitivity-unlock approval channel is
    /// physically separate from the MCP surface a prompt-injected model
    /// could reach. This guard fails loudly if any future tool addition
    /// accidentally (or deliberately) introduces an unlock-shaped verb on
    /// the MCP surface — approval must only ever happen via the
    /// out-of-band `mootx01 unlock`/`lock` CLI.
    @Test func testNoUnlockToolOnMCPSurface() {
        for tool in ToolProjection.tools(environment: [:]) {
            let lower = tool.name.lowercased()
            #expect(!lower.contains("unlock"),
                    "out-of-band sensitivity grants violation: '\(tool.name)' looks like an unlock verb on the MCP surface")
            #expect(!(lower.contains("lock") && !lower.contains("block") && !lower.contains("clock")),
                    "out-of-band sensitivity grants violation: '\(tool.name)' looks like a lock/unlock verb on the MCP surface")
        }
    }

    /// Hard contract gate: the total tool count must be exactly 80.
    /// The v2 catalog (AriaV2SelectedCatalog) defines the complete surface —
    /// all operations whose typed handlers are executable in this build.
    /// Vault tools are included by default (MOOTX01_VAULT != "0" with empty env).
    /// Any accidental addition or removal fails here before it ships.
    @Test func testTotalToolCount() {
        // 81 tools in the v2 catalog (vault-on with empty environment):
        // - moot_help (v2 surface discovery)
        // - 7 recall/search: moot_file_memory, moot_memory_get, moot_memory_list,
        //   moot_memory_search, moot_transcript_recall, moot_update_memory,
        //   moot_withdraw_memory, moot_erase_memory, moot_confirm_memory,
        //   moot_move_memory (10 total Tier 1-5 memory tools)
        // - 23 reasoning lenses + 8 recall operations (incl. moot_recall_similar) + grounded synthesize
        // - 3 dataset tools, 5 vault tools
        // - 4 KG/journal tool groups, 2 connection tools
        // - estate diagnostics, migration, monitoring, contradiction hunter, dream
        // - 3 maintenance: reindex, reclassify_fdc, palace_import
        // - federated_recall, json_import
        #expect(ToolProjection.tools(environment: [:]).count == 81,
                "tools() must return exactly 81 tools (v2 catalog, vault-on); got \(ToolProjection.tools(environment: [:]).count)")
    }

    /// All 21 interface tools must be present.
    @Test func testInterfaceToolsArePresent() {
        let names = Set(ToolProjection.tools(environment: [:]).map(\.name))
        let expected: [String] = [
            // Tier 1
            "moot_file_memory", "moot_memory_search", "moot_memory_get",
            "moot_update_memory", "moot_withdraw_memory", "moot_erase_memory",
            "moot_confirm_memory", "moot_move_memory",
            // Tier 2
            "moot_link_memories", "moot_connection_search", "moot_connection_map",
            "moot_review_tunnel",
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
        let names = Set(ToolProjection.tools(environment: [:]).map(\.name))
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
        for tool in ToolProjection.tools(environment: [:]) {
            #expect(
                tool.name.hasPrefix(ToolProjection.toolNamePrefix),
                "\(tool.name) is missing the moot_ prefix"
            )
        }
    }
    @Test func testFileMemoryRequiredFieldsAndNoInternals() {
        guard let tool = ToolProjection.tools(environment: [:]).first(where: { $0.name == "moot_file_memory" }) else {
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

    /// `moot_erase_memory` must require `confirmation` (safety gate).
    /// The v2 surface uses `confirmation` (boolean const: true) not `confirmed`.
    @Test func testEraseMemoryRequiresConfirmed() {
        guard let tool = ToolProjection.tools(environment: [:]).first(where: { $0.name == "moot_erase_memory" }) else {
            Issue.record("moot_erase_memory not found")
            return
        }
        let required = tool.inputSchema.objectValue?["required"]?
            .arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(required.contains("confirmation"), "moot_erase_memory must require confirmation=true")
    }

    /// `moot_memory_search` accepts query OR near (PR-03 anchor pivot), so
    /// neither is schema-required; the runtime enforces exactly-one. The
    /// schema must advertise BOTH properties.
    @Test func testMemorySearchAdvertisesQueryAndNear() {
        guard let tool = ToolProjection.tools(environment: [:]).first(where: { $0.name == "moot_memory_search" }) else {
            Issue.record("moot_memory_search not found")
            return
        }
        let required = tool.inputSchema.objectValue?["required"]?
            .arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(!required.contains("query"),
                "query must not be schema-required (query OR near, runtime-enforced)")
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        #expect(properties["query"] != nil, "query property must be advertised")
        #expect(properties["near"] != nil, "near property must be advertised")
    }

    /// Rider-default policy fn (2026-08-02 ruling): on unless the env
    /// carries the literal "0".
    @Test func testSubjectRiderEnabledDefaultsOn() {
        #expect(ToolProjection.subjectRiderEnabled(environment: [:]))
        #expect(ToolProjection.subjectRiderEnabled(environment: ["MOOTX01_SUBJECT_RIDER": "1"]))
        #expect(!ToolProjection.subjectRiderEnabled(environment: ["MOOTX01_SUBJECT_RIDER": "0"]))
        #expect(ToolProjection.subjectRiderEnabled(environment: ["MOOTX01_SUBJECT_RIDER": ""]))
    }

    /// `estate_id` must be optional (in properties, not in required) on every
    /// tool that exposes it. The v2 catalog uses snake_case `estate_id`.
    @Test func testEstateIDIsOptionalOnInterfaceTools() {
        for tool in ToolProjection.tools(environment: [:]) {
            let schema = tool.inputSchema.objectValue
            // Only check tools that actually declare estate_id.
            guard schema?["properties"]?.objectValue?["estate_id"] != nil else { continue }
            let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            #expect(
                !required.contains("estate_id"),
                "\(tool.name) must never require estate_id"
            )
        }
    }

}

