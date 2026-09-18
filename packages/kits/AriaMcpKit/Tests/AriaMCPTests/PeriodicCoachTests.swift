// PeriodicCoachTests.swift
//
// Golden-pin tests for PeriodicCoach.renderBlock().
//
// The canonical fixture is at:
//   Tests/Conformance/modes_coaching_fixture.json
//
// The Rust port's modes_tests.rs reads the same fixture and asserts the
// same expected_block, ensuring both ports produce byte-identical output.
// If either port diverges, the golden-pin test in that port fails.
//
// ## Template coverage
// The fixture targets Template 1 (search-heavy + hydration). Other templates
// are covered by unit-level tests below that verify their trigger conditions
// and output format without requiring the shared fixture.

import Testing
import Foundation
@testable import AriaMCP

@Suite("PeriodicCoach rendering")
struct PeriodicCoachTests {

    // MARK: - Fixture loading

    /// Absolute path to the shared Conformance fixture directory.
    ///
    /// Derived from this file's source location so the path is stable
    /// regardless of the SwiftPM build directory.
    static var conformanceFixtureURL: URL {
        URL(fileURLWithPath: #filePath)           // …/Tests/AriaMCPTests/PeriodicCoachTests.swift
            .deletingLastPathComponent()           // …/Tests/AriaMCPTests
            .deletingLastPathComponent()           // …/Tests
            .appendingPathComponent("Conformance/modes_coaching_fixture.json")
    }

    /// Decode the shared coaching fixture.
    private func loadFixture() throws -> (snapshot: CoachingSnapshot, expectedBlock: String) {
        let data = try Data(contentsOf: Self.conformanceFixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let snapDict  = json?["snapshot"] as? [String: Any]
        let expected  = json?["expected_block"] as? String
        let toolCounts = snapDict?["toolCounts"] as? [String: Int] ?? [:]
        let bigramCounts = snapDict?["bigramCounts"] as? [String: Int] ?? [:]
        let modeCounts = snapDict?["modeAttributionCounts"] as? [String: Int] ?? [:]
        let totalCalls = snapDict?["totalCalls"] as? Int ?? 0

        let snapshot = CoachingSnapshot(
            totalCalls: totalCalls,
            toolCounts: toolCounts,
            bigramCounts: bigramCounts,
            modeAttributionCounts: modeCounts
        )
        return (snapshot, expected ?? "")
    }

    // MARK: - Golden pin (shared with Rust)

    @Test("Golden-pin: renderBlock produces byte-identical output for fixture snapshot (both ports must pass)")
    func goldenPinFixtureBlock() throws {
        let (snapshot, expectedBlock) = try loadFixture()
        let actual = PeriodicCoach.renderBlock(for: snapshot)
        #expect(actual == expectedBlock,
                "Golden-pin mismatch.\nExpected:\n\(expectedBlock)\n\nActual:\n\(actual)")
    }

    // MARK: - Golden pin: tiebreak case (shared with Rust)

    static var tieFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance/modes_coaching_tie_fixture.json")
    }

    /// Decode the shared tie-break fixture.
    private func loadTieFixture() throws -> (snapshot: CoachingSnapshot, expectedBlock: String) {
        let data = try Data(contentsOf: Self.tieFixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let snapDict  = json?["snapshot"] as? [String: Any]
        let expected  = json?["expected_block"] as? String
        let toolCounts = snapDict?["toolCounts"] as? [String: Int] ?? [:]
        let bigramCounts = snapDict?["bigramCounts"] as? [String: Int] ?? [:]
        let modeCounts = snapDict?["modeAttributionCounts"] as? [String: Int] ?? [:]
        let totalCalls = snapDict?["totalCalls"] as? Int ?? 0
        let snapshot = CoachingSnapshot(
            totalCalls: totalCalls,
            toolCounts: toolCounts,
            bigramCounts: bigramCounts,
            modeAttributionCounts: modeCounts
        )
        return (snapshot, expected ?? "")
    }

    /// Gate: when two modes have equal attribution count, the sort is ascending by
    /// mode name (Filing < Recall). Without the tiebreak, Swift's dictionary sort
    /// is non-deterministic and the modes line order would vary between runs.
    @Test("Golden-pin tiebreak: tied attribution counts sort ascending by mode name (both ports must agree)")
    func goldenPinTieFixtureBlock() throws {
        let (snapshot, expectedBlock) = try loadTieFixture()
        let actual = PeriodicCoach.renderBlock(for: snapshot)
        #expect(actual == expectedBlock,
                "Tiebreak golden-pin mismatch.\nExpected:\n\(expectedBlock)\n\nActual:\n\(actual)")
    }

    // MARK: - Template 1: search-heavy without hydration

    @Test("Template 1 (search-heavy, no hydration): search count advice")
    func template1NoHydration() {
        let snapshot = CoachingSnapshot(
            totalCalls: 10,
            toolCounts: ["moot_memory_search": 7],
            bigramCounts: [:],
            modeAttributionCounts: [:]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.contains("[Moot coaching · call 10]"))
        #expect(block.contains("7 queries"))
        #expect(block.contains("moot_memory_get"))
    }

    // MARK: - Template 2: filing pattern

    @Test("Template 2 (filing, no confirm): suggest moot_confirm_memory")
    func template2FilingNoConfirm() {
        let snapshot = CoachingSnapshot(
            totalCalls: 5,
            toolCounts: ["moot_file_memory": 4],
            bigramCounts: [:],
            modeAttributionCounts: [:]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.contains("[Moot coaching · call 5]"))
        #expect(block.contains("moot_confirm_memory"))
    }

    @Test("Template 2 (filing with confirms): suggest moot_link_memories")
    func template2FilingWithConfirm() {
        let snapshot = CoachingSnapshot(
            totalCalls: 8,
            toolCounts: ["moot_file_memory": 5, "moot_confirm_memory": 2],
            bigramCounts: [:],
            modeAttributionCounts: [:]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.contains("moot_link_memories"))
    }

    // MARK: - Template 3: fact-heavy

    @Test("Template 3 (fact-heavy): suggest moot_fact_timeline")
    func template3FactHeavy() {
        let snapshot = CoachingSnapshot(
            totalCalls: 5,
            toolCounts: ["moot_file_fact": 4],
            bigramCounts: [:],
            modeAttributionCounts: [:]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.contains("moot_fact_timeline"))
    }

    // MARK: - Template 4: bigram pattern

    @Test("Template 4 (search→get bigram): reinforce the pattern")
    func template4SearchToGetBigram() {
        let snapshot = CoachingSnapshot(
            totalCalls: 6,
            toolCounts: ["moot_memory_search": 2, "moot_memory_get": 2],
            bigramCounts: ["moot_memory_search→moot_memory_get": 2],
            modeAttributionCounts: [:]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.contains("recall_temporal"))
    }

    // MARK: - Template 5: single-mode

    @Test("Template 5 (single mode): praise focused session")
    func template5SingleMode() {
        let snapshot = CoachingSnapshot(
            totalCalls: 5,
            toolCounts: ["moot_estate_status": 2],
            bigramCounts: [:],
            modeAttributionCounts: ["Vault": 4]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.contains("Vault"))
        #expect(block.contains("moot_estate_status"))
    }

    // MARK: - Fallback template

    @Test("Fallback template fires when no pattern matches")
    func fallbackTemplate() {
        let snapshot = CoachingSnapshot(
            totalCalls: 1,
            toolCounts: ["moot_estate_status": 1],
            bigramCounts: [:],
            modeAttributionCounts: [:]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.contains("[Moot coaching · call 1]"))
        #expect(block.contains("1 calls"))
        #expect(block.contains("moot_estate_status"))
    }

    // MARK: - Modes available line: no attribution

    @Test("modesAvailableLine with no attribution: shows all modes as available")
    func modesAvailableLineNoAttribution() {
        let snapshot = CoachingSnapshot(
            totalCalls: 2,
            toolCounts: ["moot_estate_status": 2],
            bigramCounts: [:],
            modeAttributionCounts: [:]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.contains("Modes available:"))
        #expect(block.contains("Recall"))
        #expect(block.contains("Filing"))
    }

    // MARK: - Block structure invariants

    @Test("Block always starts with header line [Moot coaching · call N]")
    func blockStartsWithHeader() {
        let snapshot = CoachingSnapshot(
            totalCalls: 50,
            toolCounts: [:],
            bigramCounts: [:],
            modeAttributionCounts: [:]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.hasPrefix("[Moot coaching · call 50]"))
    }

    @Test("Block always ends with Modes available line")
    func blockEndsWithModesLine() {
        let snapshot = CoachingSnapshot(
            totalCalls: 100,
            toolCounts: [:],
            bigramCounts: [:],
            modeAttributionCounts: [:]
        )
        let block = PeriodicCoach.renderBlock(for: snapshot)
        #expect(block.hasSuffix("."))
        #expect(block.contains("Modes available:"))
    }

    // MARK: - W1. Token-cap gate

    /// Gate (W1): the coaching block must stay within a ~80-token budget so it
    /// doesn't consume a significant fraction of the AI's context window.
    ///
    /// Token estimation: LLM tokenizers average ~4-6 bytes/token for English
    /// prose. 80 tokens * 6 bytes = 480 bytes. We use 500 bytes as the limit,
    /// which is generous enough not to flag legitimate content but would catch
    /// runaway blocks. Mirrors Rust test `coaching_block_under_token_cap`.
    ///
    /// How it fails if reverted: if a template expands to multi-paragraph output
    /// or the Modes line becomes very long, the block will exceed 500 bytes and
    /// the constraint fires, surfacing the regression before it ships.
    @Test("Coaching block stays within ~80-token budget (≤ 500 bytes)")
    func coachingBlockUnderTokenCap() {
        let heavySnapshot = CoachingSnapshot(
            totalCalls: 100,
            toolCounts: [
                "moot_memory_search": 40,
                "moot_memory_get": 20,
                "moot_file_memory": 15,
                "moot_confirm_memory": 8,
                "moot_file_fact": 7,
                "moot_estate_status": 5,
                "moot_list_lenses": 5,
            ],
            bigramCounts: ["moot_memory_search→moot_memory_get": 18],
            modeAttributionCounts: ["Recall": 60, "Filing": 25, "Lenses": 10, "Vault": 5]
        )
        let block = PeriodicCoach.renderBlock(for: heavySnapshot)
        let byteCount = block.utf8.count
        #expect(byteCount <= 500,
                "Coaching block must stay ≤ 500 bytes (~80 tokens); got \(byteCount) bytes:\n\(block)")
    }

    /// Golden-pin: template-5 with a genuine two-mode tie (Filing=3, Recall=3).
    ///
    /// Verifies the name-ascending tiebreak in `topMode` selects Filing over Recall
    /// (F < R), producing "Focused Filing session" in the block. Without the tiebreak
    /// fix `Dictionary.max(by:)` is non-deterministic across runs and could emit
    /// either mode, causing intermittent cross-port parity failures.
    ///
    /// Both Swift and Rust ports assert against the same
    /// `modes_coaching_template5_tie_fixture.json` fixture.
    @Test("Template-5 tie: Filing wins over Recall via name-ascending tiebreak (golden-pin)")
    func goldenPinTemplate5TieFixtureBlock() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // …/AriaMCPTests
            .deletingLastPathComponent()  // …/Tests
            .appendingPathComponent("Conformance/modes_coaching_template5_tie_fixture.json")

        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let snapJSON = json?["snapshot"] as? [String: Any],
            let totalCalls = snapJSON["totalCalls"] as? Int,
            let toolCountsRaw = snapJSON["toolCounts"] as? [String: Int],
            let bigramCountsRaw = snapJSON["bigramCounts"] as? [String: Int],
            let modeCountsRaw = snapJSON["modeAttributionCounts"] as? [String: Int],
            let expectedBlock = json?["expected_block"] as? String
        else {
            Issue.record("modes_coaching_template5_tie_fixture.json has unexpected structure")
            return
        }

        let snapshot = CoachingSnapshot(
            totalCalls: totalCalls,
            toolCounts: toolCountsRaw,
            bigramCounts: bigramCountsRaw,
            modeAttributionCounts: modeCountsRaw
        )
        let actual = PeriodicCoach.renderBlock(for: snapshot)
        #expect(actual == expectedBlock,
                "Template-5 tie block must match fixture (Filing wins via name-ascending tiebreak).\nExpected:\n\(expectedBlock)\n\nActual:\n\(actual)")
    }
}
