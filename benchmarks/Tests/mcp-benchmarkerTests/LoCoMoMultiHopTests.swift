import Testing
import Foundation
@testable import mcp_benchmarker

// LoCoMoMultiHopTests — pure logic for the two-pass multi-hop strategy:
// sub-cue decomposition, RRF pool fusion, bridge-token extraction, and the
// driver's pass-2 trigger. No live estate, no binary; the driver runs
// against stub closures.
struct LoCoMoMultiHopTests {

    // ── Decomposition ─────────────────────────────────────────────────────

    @Test func subCuesDropStopwordsAndShortTokensKeepDigits() {
        #expect(multiHopSubCues(from: "What did Melanie study at the academy in 2019?")
            == ["melanie", "study", "academy", "2019"])
        // Cap honors maxCues in first-appearance order.
        #expect(multiHopSubCues(from: "alpha bravo charlie delta echo foxtrot golf",
                                maxCues: 3)
            == ["alpha", "bravo", "charlie"])
    }

    // ── Fusion ────────────────────────────────────────────────────────────

    @Test func fusionRanksCrossPoolCorroborationAboveSinglePoolRank() {
        // "b" appears in both pools (ranks 1 and 0); "a" leads pool 0 only.
        // Corroboration must outscore a single first place: RRF(b) =
        // 1/62 + 1/61 > RRF(a) = 1/61.
        let fused = fuseMultiHopPools([["a", "b"], ["b", "c"]])
        #expect(fused.first?.id == "b")
        #expect(fused.first?.poolCount == 2)
    }

    @Test func fusionDeduplicatesWithinOnePoolAndTieBreaksDeterministically() {
        // "a" repeated in one pool contributes only its best rank; "a" and
        // "b" then tie exactly (rank 0 in one pool each) and the tie breaks
        // by first appearance — pool-major order.
        let fused = fuseMultiHopPools([["a", "a"], ["b"]])
        #expect(fused.map(\.id) == ["a", "b"])
        #expect(fused[0].score == fused[1].score)
    }

    // ── Bridge extraction ─────────────────────────────────────────────────

    @Test func bridgeTokensExcludeQuestionTokensAndStopwords() {
        let tokens = multiHopBridgeTokens(
            fromContents: ["Melanie's sister Caroline studied astrophysics at Cambridge"],
            question: "What did Melanie's sister study?")
        // "melanie", "sister", "study" come from the question; "studied" is a
        // distinct token and correctly survives (token-level exclusion, not
        // stemming — deterministic beats clever here).
        #expect(tokens.contains("caroline"))
        #expect(tokens.contains("astrophysics"))
        #expect(!tokens.contains("melanie"))
        #expect(!tokens.contains("sister"))
    }

    // ── Driver ────────────────────────────────────────────────────────────

    @Test func driverSkipsBridgeWhenPoolsCorroborate() async throws {
        // Every pool returns "x" first → corroborated head → no hydrate call.
        var hydrateCalls = 0
        let outcome = try await runMultiHopStrategy(
            question: "melanie academy",
            search: { _ in ["x", "y"] },
            hydrate: { _ in hydrateCalls += 1; return "" }
        )
        #expect(outcome.bridged == false)
        #expect(hydrateCalls == 0)
        #expect(outcome.ids.first == "x")
    }

    @Test func driverBridgesWhenPoolsAreDisjoint() async throws {
        // Pools are pairwise disjoint (no corroboration); the bridge query
        // (question + extracted tokens) unlocks the answer id, which the
        // final fusion must surface. The stub keys on the bridge token.
        var searchCalls: [String] = []
        let outcome = try await runMultiHopStrategy(
            question: "melanie sister study",
            search: { query in
                searchCalls.append(query)
                if query.contains("caroline") { return ["answer", "d1"] }
                switch searchCalls.count {
                case 1: return ["d1"]
                case 2: return ["d2"]
                case 3: return ["d3"]
                default: return ["d4"]
                }
            },
            hydrate: { _ in "her sister Caroline moved away" }
        )
        #expect(outcome.bridged == true)
        #expect(searchCalls.last?.contains("caroline") == true,
                "the bridge re-query must carry the extracted bridge token")
        #expect(outcome.ids.contains("answer"),
                "the bridge pool's answer must survive the final fusion")
    }
}
