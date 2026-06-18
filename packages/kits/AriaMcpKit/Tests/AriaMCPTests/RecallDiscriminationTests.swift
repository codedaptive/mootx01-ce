// RecallDiscriminationTests.swift
//
// Tests for the RecallDiscrimination confidence/discrimination metric helper.
//
// Covers:
//   - Unit classification (single, low, high, medium)
//   - Edge cases (empty, one item, all-zero scores)
//   - Result-line wording
//   - Surface test: a low-discrimination recall result carries the low-confidence line
//   - Parity vectors: same score vectors → same DiscriminationLevel as Rust
//     (verified by matching the Rust parity_vectors_match_swift test)

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("RecallDiscrimination metric")
struct RecallDiscriminationTests {

    // MARK: - Classification unit tests

    @Test func emptyScoresReturnSingle() {
        #expect(RecallDiscrimination.classify([]) == .single)
    }

    @Test func oneScoreReturnsSingle() {
        #expect(RecallDiscrimination.classify([1.0]) == .single)
    }

    @Test func clearlySeparatedScoresReturnHigh() {
        // topGap = (1.0 - 0.5) / 1.0 = 0.5 >= HIGH_MARGIN (0.25)
        #expect(RecallDiscrimination.classify([1.0, 0.5, 0.3]) == .high)
    }

    @Test func nearFlatScoresReturnLow() {
        // topGap = (1.0 - 0.98) / 1.0 = 0.02 < LOW_MARGIN (0.05)
        // spread  = (1.0 - 0.95) / 1.0 = 0.05 < LOW_SPREAD (0.15)
        #expect(RecallDiscrimination.classify([1.0, 0.98, 0.97, 0.95]) == .low)
    }

    @Test func mediumGapReturnsMedium() {
        // topGap = (1.0 - 0.88) / 1.0 = 0.12  (>= LOW_MARGIN but < HIGH_MARGIN)
        #expect(RecallDiscrimination.classify([1.0, 0.88, 0.50]) == .medium)
    }

    @Test func allZeroScoresReturnLow() {
        // denom = EPS, topGap ≈ 0 → Low
        #expect(RecallDiscrimination.classify([0.0, 0.0, 0.0]) == .low)
    }

    @Test func twoItemsHighGapReturnHigh() {
        // topGap = (0.9 - 0.1) / 0.9 ≈ 0.89 >= HIGH_MARGIN
        #expect(RecallDiscrimination.classify([0.9, 0.1]) == .high)
    }

    // MARK: - Result-line content

    @Test func lowResultLineContainsKeyGuidance() {
        let line = RecallDiscrimination.resultLine(for: .low)
        #expect(line.contains("discrimination: low"))
        #expect(line.contains("effectively unranked"))
        #expect(line.contains("moot_recall_precise"))
    }

    @Test func highResultLineFormat() {
        let line = RecallDiscrimination.resultLine(for: .high)
        #expect(line == "discrimination: high — clear top result.")
    }

    @Test func mediumResultLineFormat() {
        let line = RecallDiscrimination.resultLine(for: .medium)
        #expect(line == "discrimination: medium — partial separation.")
    }

    @Test func singleResultLineFormat() {
        let line = RecallDiscrimination.resultLine(for: .single)
        #expect(line == "discrimination: n/a — single/zero results.")
    }

    // MARK: - Parity vectors (must match Rust parity_vectors_match_swift)

    @Test func parityVectorHighSeparation() {
        // Vector A: high separation → High (mirrors Rust parity test)
        #expect(RecallDiscrimination.classify([1.0, 0.6]) == .high)
    }

    @Test func parityVectorFlatSpread() {
        // Vector B: flat spread, tiny gap → Low (mirrors Rust parity test)
        #expect(RecallDiscrimination.classify([1.0, 0.99, 0.98, 0.97]) == .low)
    }

    @Test func parityVectorMediumSeparation() {
        // Vector C: medium separation → Medium (mirrors Rust parity test)
        #expect(RecallDiscrimination.classify([1.0, 0.9, 0.4]) == .medium)
    }

    // MARK: - Surface integration: low-discrimination result carries the signal

    /// An estate with near-identical memories produces a moot_memory_search
    /// result that always contains the discrimination line.
    @Test(.timeLimit(.minutes(1)), .serialized)
    func memorySearchResultAlwaysContainsDiscriminationLine() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: "recall-disc-test")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // File several near-identical memories so recall scores cluster.
        for i in 1...5 {
            let frame = CaptureFrame(
                content: "apple fruit tree garden nature",
                channel: .typed,
                room: "garden",
                latticeAnchor: .udc("635"),
                addedBy: "test",
                embeddingModelID: "test-model-v1")
            _ = try await kit.capture(handle, frame)
            // Silence unused variable warning.
            _ = i
        }

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let args: JSONValue = .object(["query": .string("apple fruit garden")])
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search", arguments: args)

        let obj = try #require(result.objectValue)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)

        // Discrimination signal must always be present in the result.
        #expect(text.contains("discrimination:"))
        // The signal must be one of the four known levels.
        let hasKnownLevel = text.contains("discrimination: low")
            || text.contains("discrimination: medium")
            || text.contains("discrimination: high")
            || text.contains("discrimination: n/a")
        #expect(hasKnownLevel)
    }
}
