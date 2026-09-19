// RerankerTests.swift — unit tests for the Reranker module.
//
// Tests use a stub shell script fixture (printf) to prove:
//   1. A parseable reply reorders the ranked list correctly.
//   2. An unparseable reply leaves the ranking UNCHANGED and sets failed = true.
//   3. Metrics are recomputed on the reranked order (the correct IDs move to
//      earlier positions, improving recall@1).
//   4. parseRerankReply handles comma/whitespace separation and deduplication.
//   5. buildRerankPrompt generates the expected numbered list.
//   6. applyPermutation applies named-first ordering with correct tail handling.

import Testing
import Foundation
@testable import mcp_benchmarker

@Suite("Reranker")
struct RerankerTests {

    // MARK: - parseRerankReply

    @Test("parseRerankReply: space-separated integers")
    func parseSpaceSeparated() {
        let result = parseRerankReply("3 1 2", windowSize: 5)
        #expect(result == [3, 1, 2])
    }

    @Test("parseRerankReply: comma-separated integers")
    func parseCommaSeparated() {
        let result = parseRerankReply("2,4,1", windowSize: 5)
        #expect(result == [2, 4, 1])
    }

    @Test("parseRerankReply: mixed delimiters and surrounding prose")
    func parseMixedDelimiters() {
        // Models often reply with prose before/after the numbers.
        let reply = "I recommend: 3, 1, 2 as the best order."
        let result = parseRerankReply(reply, windowSize: 5)
        #expect(result == [3, 1, 2])
    }

    @Test("parseRerankReply: deduplicates repeated numbers")
    func parseDeduplicate() {
        let result = parseRerankReply("2 2 1", windowSize: 5)
        #expect(result == [2, 1], "duplicate 2 should appear only once")
    }

    @Test("parseRerankReply: ignores numbers out of range")
    func parseRejectsOutOfRange() {
        // windowSize = 3, so 4 and 0 are out of range.
        let result = parseRerankReply("0 4 1 2", windowSize: 3)
        #expect(result == [1, 2], "0 and 4 are out of [1,3] and must be dropped")
    }

    @Test("parseRerankReply: returns empty for no valid integers")
    func parseReturnsEmptyForGarbage() {
        let result = parseRerankReply("no idea which one", windowSize: 5)
        #expect(result.isEmpty)
    }

    @Test("parseRerankReply: handles newlines as separators")
    func parseHandlesNewlines() {
        let reply = "2\n1\n3"
        let result = parseRerankReply(reply, windowSize: 5)
        #expect(result == [2, 1, 3])
    }

    // MARK: - applyPermutation

    @Test("applyPermutation: named candidates move to front in reply order")
    func permutationNamedFirst() {
        let ids = ["A", "B", "C", "D", "E"]
        // Reply says 3, 1 — so C, A first; B, D, E follow in original order.
        let result = applyPermutation(ids: ids, named: [3, 1], window: 5)
        #expect(result == ["C", "A", "B", "D", "E"])
    }

    @Test("applyPermutation: unnamed candidates keep relative order in window")
    func permutationUnnamedRelativeOrder() {
        let ids = ["A", "B", "C", "D", "E", "F"]
        // window = 4, reply names 4, 2 — named: D, B; unnamed in window: A, C; tail: E, F
        let result = applyPermutation(ids: ids, named: [4, 2], window: 4)
        #expect(result == ["D", "B", "A", "C", "E", "F"])
    }

    @Test("applyPermutation: candidates beyond window are appended unchanged")
    func permutationTailPreserved() {
        let ids = ["A", "B", "C", "D", "E"]
        // window = 3, reply names 2 — named: B; unnamed in window: A, C; tail: D, E
        let result = applyPermutation(ids: ids, named: [2], window: 3)
        #expect(result == ["B", "A", "C", "D", "E"])
    }

    @Test("applyPermutation: all candidates named — pure permutation")
    func permutationAllNamed() {
        let ids = ["A", "B", "C"]
        let result = applyPermutation(ids: ids, named: [3, 1, 2], window: 3)
        #expect(result == ["C", "A", "B"])
    }

    // MARK: - buildRerankPrompt

    @Test("buildRerankPrompt: contains the question")
    func promptContainsQuestion() {
        let prompt = buildRerankPrompt(
            question: "What did Alice eat?",
            ids: ["id1", "id2"],
            previews: ["She had pizza.", "She had pasta."],
            window: 2
        )
        #expect(prompt.contains("What did Alice eat?"))
    }

    @Test("buildRerankPrompt: numbers the candidates 1-based")
    func promptNumbersCandidates() {
        let prompt = buildRerankPrompt(
            question: "Q",
            ids: ["id1", "id2", "id3"],
            previews: ["p1", "p2", "p3"],
            window: 3
        )
        #expect(prompt.contains("1. id1: p1"))
        #expect(prompt.contains("2. id2: p2"))
        #expect(prompt.contains("3. id3: p3"))
    }

    @Test("buildRerankPrompt: truncates long previews to 120 chars")
    func promptTruncatesLongPreviews() {
        let longPreview = String(repeating: "x", count: 200)
        let prompt = buildRerankPrompt(
            question: "Q",
            ids: ["id1"],
            previews: [longPreview],
            window: 1
        )
        // The preview in the prompt should be capped at rerankPreviewLength.
        let expected = String(repeating: "x", count: rerankPreviewLength)
        #expect(prompt.contains(expected))
        #expect(!prompt.contains(String(repeating: "x", count: rerankPreviewLength + 1)))
    }

    @Test("buildRerankPrompt: handles missing previews gracefully")
    func promptHandlesMissingPreviews() {
        // previews array shorter than ids — missing entries use empty string.
        let prompt = buildRerankPrompt(
            question: "Q",
            ids: ["id1", "id2"],
            previews: ["only one preview"],
            window: 2
        )
        #expect(prompt.contains("1. id1: only one preview"))
        // id2 gets an empty preview — line still present.
        #expect(prompt.contains("2. id2: "))
    }

    // MARK: - applyRerank (end-to-end with stub command)

    @Test("applyRerank: stub command reorders the ranked list")
    func rerankReorders() throws {
        // Stub: always replies "3 1 2" regardless of input.
        let stubCmd = #"printf '3 1 2'"#
        let ids = ["alpha", "beta", "gamma", "delta"]
        let previews = ["preview1", "preview2", "preview3", "preview4"]

        let (reranked, failed) = applyRerank(cmd: stubCmd, question: "test?", ids: ids, previews: previews)

        #expect(!failed, "stub command should succeed")
        // Named: 3→gamma, 1→alpha, 2→beta. Unnamed in window: delta. Tail: none (window=4>3 positions named).
        // Wait: window = min(10, 4) = 4. Named = [3,1,2]. Unnamed in window = [4 → delta].
        #expect(reranked == ["gamma", "alpha", "beta", "delta"])
    }

    @Test("applyRerank: unparseable reply returns original order and sets failed")
    func rerankUnparseable() {
        // Stub: replies with gibberish that contains no valid integers.
        let stubCmd = #"printf 'I cannot rank these.'"#
        let ids = ["alpha", "beta", "gamma"]
        let previews = ["p1", "p2", "p3"]

        let (reranked, failed) = applyRerank(cmd: stubCmd, question: "test?", ids: ids, previews: previews)

        #expect(failed, "unparseable reply should set failed = true")
        #expect(reranked == ids, "unparseable reply should leave ranking unchanged")
    }

    @Test("applyRerank: metric recomputation on reranked order — recall@1 improves")
    func rerankImprovesRecallAt1() throws {
        // Scenario: the correct answer ID is "gold" currently ranked 3rd.
        // Stub reranker promotes it to rank 1 (replies "3").
        // Before reranking: recall@1 = 0 (gold not in top 1).
        // After reranking: recall@1 = 1 (gold is now rank 1).
        let stubCmd = #"printf '3'"#
        let ids = ["wrong1", "wrong2", "gold", "wrong3"]
        let previews = ["p1", "p2", "p3 — the answer", "p4"]
        let evidenceIDs = ["gold"]

        let (reranked, failed) = applyRerank(cmd: stubCmd, question: "Where is gold?", ids: ids, previews: previews)

        #expect(!failed)
        // After reranking: gold should be rank 1.
        #expect(reranked.first == "gold", "gold should be promoted to rank 1 by the stub")

        // Verify recall@1 before vs after.
        let recallBefore = lmeRecallAtK(k: 1, rankedIDs: ids, evidenceIDs: evidenceIDs)
        let recallAfter  = lmeRecallAtK(k: 1, rankedIDs: reranked, evidenceIDs: evidenceIDs)
        #expect(recallBefore == 0.0, "gold at rank 3 should not be in top 1")
        #expect(recallAfter  == 1.0, "gold at rank 1 should give recall@1 = 1.0")
    }

    @Test("applyRerank: failed subprocess returns original order and sets failed")
    func rerankSubprocessFailure() {
        // Stub: exits with code 1 to simulate a subprocess failure.
        let stubCmd = #"exit 1"#
        let ids = ["a", "b", "c"]
        let previews = ["p1", "p2", "p3"]

        let (reranked, failed) = applyRerank(cmd: stubCmd, question: "q", ids: ids, previews: previews)

        #expect(failed)
        #expect(reranked == ids)
    }

    @Test("applyRerank: empty ids list returns unchanged and not failed")
    func rerankEmptyIds() {
        let (reranked, failed) = applyRerank(cmd: "printf '1'", question: "q", ids: [], previews: [])
        #expect(!failed)
        #expect(reranked.isEmpty)
    }
}

// MARK: - Recall-at-k helper for metric verification

/// Recall@k: 1.0 if any evidence ID appears in the top-k ranked IDs, else 0.0.
/// Used only in tests to verify that reranking improves metric scores.
private func lmeRecallAtK(k: Int, rankedIDs: [String], evidenceIDs: [String]) -> Double {
    let topK = Set(rankedIDs.prefix(k))
    return evidenceIDs.contains { topK.contains($0) } ? 1.0 : 0.0
}
