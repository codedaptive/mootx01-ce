import Testing
import Foundation
@testable import mcp_benchmarker

// JourneyDriverTests.swift — unit tests for JourneyDriver argument builders.
//
// These tests exercise the D3 exercisers against canned fixture replies —
// no live server is required. Each test verifies:
//   1. The argument map produced by the builder has the correct shape.
//   2. When the argument map's output field is passed through the existing
//      parseToolResult parser, the correct UUID list is extracted.
//
// The three new PR-03 verb surfaces tested here:
//   - near:<uuid> pivots via moot_memory_search / moot_recall_shaped
//   - batch-hydrate via moot_memory_get ids+depth
//   - enumerate missing_subject via moot_memory_list

// MARK: - Fixture builders (shared with LiveRunParsingTests)

private func textResult(_ text: String) -> JSONValue {
    .object(["content": .array([
        .object(["type": .string("text"), "text": .string(text)])
    ])])
}

@Suite("JourneyDriver argument builders (D3)") struct JourneyDriverTests {

    private let pivot = "7CF35028-84BE-40D0-A8CB-7FCFE8EB6018"
    private let id1   = "84B0178B-A133-4F43-91D0-2854E7AC45FB"
    private let id2   = "A2C35028-84BE-40D0-A8CB-7FCFE8EB6019"
    private let id3   = "B3D46139-95CF-51E1-B9DC-8FDGF9FC7120"
    private let wing  = "Agentic Memory"

    // MARK: HydrationDepth

    @Test("HydrationDepth raw values are the PR-03 wire strings")
    func hydrationDepthRawValues() {
        #expect(HydrationDepth.subject.rawValue == "subject")
        #expect(HydrationDepth.distilled.rawValue == "distilled")
        #expect(HydrationDepth.full.rawValue == "full")
    }

    @Test("HydrationDepth CaseIterable covers all three tiers")
    func hydrationDepthAllCases() {
        #expect(HydrationDepth.allCases.count == 3)
    }

    // MARK: nearPivotSearchArgs

    @Test("nearPivotSearchArgs emits near as its own argument, never a query string")
    func nearPivotSearchArgsShape() {
        let args = nearPivotSearchArgs(uuid: pivot)
        #expect(args["near"] == .string(pivot))
        // query and near are mutually exclusive; emitting both is rejected by
        // the server, and emitting only query runs a text search for the
        // literal string instead of the anchor pivot.
        #expect(args["query"] == nil)
    }

    @Test("nearPivotSearchArgs extraArgs are merged after required fields")
    func nearPivotSearchArgsExtraArgs() {
        let args = nearPivotSearchArgs(uuid: pivot, extraArgs: ["limit": .number(5)])
        guard case .number(let n) = args["limit"] else {
            Issue.record("limit must be a number"); return
        }
        #expect(n == 5)
        // Required field must still be present, and no query key introduced.
        #expect(args["near"] == .string(pivot))
        #expect(args["query"] == nil)
    }

    @Test("nearPivotSearchArgs canned reply parses pivot UUID neighbours")
    func nearPivotSearchCannedReply() {
        // Fixture: two neighbours returned for the pivot query.
        let reply = """
        found 2 memory(s)
        \(id1) · Alpha result near pivot. · fdc:A · qid:Q1 · 2020-01-01T00:00:00Z
        \(id2) · Beta result near pivot. · - · - · -
        """
        let result = MCPClient.parseToolResult(textResult(reply), format: .mootText)
        #expect(result.orderedIDs == [id1, id2])
    }

    // MARK: nearPivotShapedArgs

    @Test("nearPivotShapedArgs emits near as its own argument, never a query string")
    func nearPivotShapedArgsShape() {
        let args = nearPivotShapedArgs(uuid: pivot)
        #expect(args["near"] == .string(pivot))
        #expect(args["query"] == nil)
    }

    @Test("nearPivotShapedArgs canned reply parses UUID list from shaped result")
    func nearPivotShapedCannedReply() {
        let reply = """
        found 1 memory(s)
        \(id1) · Shaped recall neighbour. · fdc:X · qid:Q5 · 2020-05-01T00:00:00Z
        """
        let result = MCPClient.parseToolResult(textResult(reply), format: .mootText)
        #expect(result.orderedIDs == [id1])
    }

    // MARK: batchHydrateArgs

    @Test("batchHydrateArgs default depth is .full")
    func batchHydrateDefaultDepth() {
        let args = batchHydrateArgs(ids: [id1, id2])
        guard case .string(let d) = args["depth"] else {
            Issue.record("depth must be a string"); return
        }
        #expect(d == "full")
    }

    @Test("batchHydrateArgs subject depth produces subject wire value")
    func batchHydrateSubjectDepth() {
        let args = batchHydrateArgs(ids: [id1], depth: .subject)
        #expect(args["depth"] == .string("subject"))
    }

    @Test("batchHydrateArgs distilled depth produces distilled wire value")
    func batchHydrateDistilledDepth() {
        let args = batchHydrateArgs(ids: [id1, id2], depth: .distilled)
        #expect(args["depth"] == .string("distilled"))
    }

    @Test("batchHydrateArgs ids array preserves order")
    func batchHydrateIDsOrder() {
        let ordered = [id1, id2, id3]
        let args = batchHydrateArgs(ids: ordered, depth: .full)
        // v2: key renamed ids → memory_ids
        guard case .array(let arr) = args["memory_ids"] else {
            Issue.record("memory_ids must be an array"); return
        }
        #expect(arr.count == 3)
        #expect(arr[0] == .string(id1))
        #expect(arr[1] == .string(id2))
        #expect(arr[2] == .string(id3))
    }

    @Test("batchHydrateArgs canned reply parses hydrated content")
    func batchHydrateCannedReply() {
        // Fixture: two items returned from a batch-get, with content after UUID.
        let reply = """
        \(id1) [import/test] The quick brown fox content body.
        \(id2) [import/test] Another item full body content.
        """
        let result = MCPClient.parseToolResult(textResult(reply), format: .mootText)
        #expect(result.orderedIDs == [id1, id2])
        #expect(result.items[0].content?.contains("quick brown fox") == true)
        #expect(result.items[1].content?.contains("Another item") == true)
    }

    // MARK: missingSubjectArgs

    @Test("missingSubjectArgs supplies the required wing alongside the filter")
    func missingSubjectArgsShape() {
        let args = missingSubjectArgs(wing: wing)
        #expect(args["filter"] == .string("missing_subject"))
        // wing is required by moot_memory_list; without it the call fails
        // schema validation before it ever reaches the enumerator.
        #expect(args["wing"] == .string(wing))
    }

    @Test("missingSubjectArgs extraArgs are merged")
    func missingSubjectArgsExtraArgs() {
        let args = missingSubjectArgs(wing: wing, extraArgs: ["room": .string("import/test")])
        #expect(args["filter"] == .string("missing_subject"))
        #expect(args["wing"] == .string(wing))
        #expect(args["room"] == .string("import/test"))
    }

    // MARK: Live-contract key sets

    // These assert each builder's key set against the tool schemas rather than
    // against a per-test literal, so a builder that drifts from the contract
    // fails here even if its own shape test was written to match the drift.
    //
    // LIMITATION, stated because it is how the query:"near:<uuid>" defect
    // shipped in the first place: these key sets are TRANSCRIBED, not imported.
    // The benchmarker's Package.swift depends on IntellectusLib, ObserverSink,
    // and swift-subprocess — deliberately no MOOTx01 kit at the MCP boundary —
    // so AriaMcpKit's ProjectedTool schemas are not reachable from this target
    // and cannot be asserted against directly. If the server contract moves,
    // this table goes stale silently. Sources, verified at authoring time:
    //   moot_memory_search  — ToolProjection.swift:211-219 (query XOR near),
    //                         enforced at ToolDispatch.swift:1369-1387
    //   moot_recall_shaped  — RecipeTools.swift:172-181 (query XOR near),
    //                         enforced at RecipeTools.swift:833-846
    //   moot_memory_list    — ToolProjection.swift:229-234, required: ["wing"]
    private static let memorySearchPermitted: Set<String> = [
        "query", "near", "limit", "filter", "wing", "media_type",
        "explain", "scoring", "ordering", "estateID",
    ]
    private static let recallShapedPermitted: Set<String> = [
        "query", "near", "preset", "limit", "filter", "wing", "estateID",
    ]
    private static let memoryListPermitted: Set<String> = [
        "wing", "room", "filter", "estateID",
    ]
    private static let memoryListRequired: Set<String> = ["wing"]

    @Test("nearPivotSearchArgs key set satisfies the moot_memory_search contract")
    func nearPivotSearchArgsContract() {
        let keys = Set(nearPivotSearchArgs(uuid: pivot).keys)
        #expect(keys.isSubset(of: Self.memorySearchPermitted))
        // Exactly one of query/near — the server rejects both and treats
        // neither as a usage error.
        #expect(keys.intersection(["query", "near"]) == ["near"])
    }

    @Test("nearPivotShapedArgs key set satisfies the moot_recall_shaped contract")
    func nearPivotShapedArgsContract() {
        let keys = Set(nearPivotShapedArgs(uuid: pivot).keys)
        #expect(keys.isSubset(of: Self.recallShapedPermitted))
        #expect(keys.intersection(["query", "near"]) == ["near"])
    }

    @Test("missingSubjectArgs key set satisfies the moot_memory_list contract")
    func missingSubjectArgsContract() {
        let keys = Set(missingSubjectArgs(wing: wing).keys)
        #expect(keys.isSubset(of: Self.memoryListPermitted))
        #expect(Self.memoryListRequired.isSubset(of: keys))
    }

    @Test("missingSubjectArgs canned reply parses id-only rows")
    func missingSubjectCannedReply() {
        // Fixture: two id-only rows (no subject column in legacy format).
        let reply = """
        found 2 memory(s)
        \(id1) [import/test]
        \(id2) [import/test]
        """
        let result = MCPClient.parseToolResult(textResult(reply), format: .mootText)
        // IDs are extracted regardless of whether content is present.
        #expect(result.orderedIDs.contains(id1))
        #expect(result.orderedIDs.contains(id2))
    }
}
