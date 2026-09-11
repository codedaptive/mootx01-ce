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

    // MARK: - notFound level (Wave B, Part 1a)

    @Test func notFoundResultLineContainsKeyGuidance() {
        let line = RecallDiscrimination.resultLine(for: .notFound)
        #expect(line.contains("discrimination: not_found"))
        #expect(line.contains("distinctive tokens"))
        #expect(line.contains("moot_memory_search"))
    }

    @Test func notFoundIsNotEqualToLow() {
        // notFound and low are distinct levels — notFound means the token gate
        // fired (definitive absence), not just that scores were flat.
        #expect(DiscriminationLevel.notFound != DiscriminationLevel.low)
        #expect(DiscriminationLevel.notFound != DiscriminationLevel.single)
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

    // MARK: - Dense-lane-dark cap (FIX 1)

    @Test func highDiscriminationIsNotClaimedWhenDenseLaneIsDark() {
        // A "high" discrimination score computed from scores alone must be
        // capped to "medium" when the dense lane is dark — the ranking is
        // lexical-only and cannot be trusted as semantically ranked.
        // Scores give topGap ≥ HIGH_MARGIN (0.25), so classify() returns .high.
        // But with denseLaneDark=true the resultLine must NOT contain "high".
        let level = RecallDiscrimination.classify([1.0, 0.5, 0.3]) // topGap = 0.5 → .high
        #expect(level == .high)  // confirm the raw level is high
        let line = RecallDiscrimination.resultLine(for: level, denseLaneDark: true)
        #expect(!line.contains("discrimination: high"), "dark lane must cap high to medium")
        #expect(line.contains("discrimination: medium"), "dark lane cap produces medium signal")
        #expect(line.contains("semantic lane dark"), "caveat must name the dark lane")
        #expect(line.contains("moot_recall_precise"), "caveat must direct to precise recall")
    }

    @Test func denseLaneDarkFalseDoesNotCapHigh() {
        // When the dense lane is active the high signal is unchanged.
        let level = RecallDiscrimination.classify([1.0, 0.5, 0.3])
        let line = RecallDiscrimination.resultLine(for: level, denseLaneDark: false)
        #expect(line == "discrimination: high — clear top result.")
    }

    @Test func denseLaneDarkDoesNotCapMediumOrLow() {
        // The cap only applies to .high — medium and low are unchanged.
        let medium = RecallDiscrimination.resultLine(for: .medium, denseLaneDark: true)
        #expect(medium == "discrimination: medium — partial separation.")
        let low = RecallDiscrimination.resultLine(for: .low, denseLaneDark: true)
        #expect(low.contains("discrimination: low"))
        #expect(!low.contains("semantic lane dark"))
    }

    // MARK: - denseLaneDark predicate

    @Test func denseLaneDarkIsTheAbsenceOfTheSpanStage() {
        // The span stage is the one dense provider: no stage means lexical-only.
        #expect(RecallDiscrimination.denseLaneDark(spanRerankRegistered: false) == true)
        #expect(RecallDiscrimination.denseLaneDark(spanRerankRegistered: true) == false)
    }

    // MARK: - Surface integration: explain gate drives discrimination line

    /// Helper: create a fresh dispatcher backed by an in-memory estate.
    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "recall-discrimination-explain-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

    private func fileMemory(content: String, location: String, dispatcher: ToolDispatcher) async throws -> Void {
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string(location),
            ])
        )
    }

    /// An estate with near-identical memories must always carry the discrimination
    /// line in every moot_memory_search result — unconditionally, without opt-in.
    ///
    /// BLOCKED: v2 gates the discrimination line behind `explain: true` at
    /// AriaV2MemoryOperations.swift:728 (`if request.explain { ... }`). Without
    /// the flag, no discrimination line is emitted regardless of score spread.
    /// The v1 property — unconditional presence in every recall result — does not
    /// hold in v2. The five accepted label strings (low, medium, high, n/a,
    /// not_found) are preserved intact; do not narrow them when re-enabling.
    @Test(.disabled("BLOCKED: v2 gates the discrimination line behind explain:true (AriaV2MemoryOperations.swift:728). Without explain the line is absent unconditionally; v1 asserted always-present. Awaiting catalog decision. Do not delete; do not weaken to pass."))
    func memorySearchResultAlwaysContainsDiscriminationLine() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: "recall-disc-test")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())

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
            _ = i  // suppress unused-variable warning
        }

        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let args: JSONValue = .object(["query": .string("apple fruit garden")])
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search", arguments: args)

        let obj = try #require(result.objectValue)
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)

        // Discrimination signal must always be present — no explain flag required.
        #expect(text.contains("discrimination:"))
        // The signal must be one of the five known levels.
        let hasKnownLevel = text.contains("discrimination: low")
            || text.contains("discrimination: medium")
            || text.contains("discrimination: high")
            || text.contains("discrimination: n/a")
            || text.contains("discrimination: not_found")
        #expect(hasKnownLevel)
    }

    /// With explain:true on an estate seeded with near-identical memories, the
    /// moot_memory_search response MUST contain a "discrimination:" line. Three
    /// memories with closely-spaced content produce a low or medium
    /// discrimination signal — both are emitted in v2 compact text.
    @Test func explainTrueAppendsDiscriminationLine() async throws {
        let dispatcher = try await makeDispatcher()
        // Three memories with closely-related content produce a low or medium
        // signal; the discrimination line is emitted for both levels.
        try await fileMemory(content: "discrimination-gate-test content alpha", location: "lab", dispatcher: dispatcher)
        try await fileMemory(content: "discrimination-gate-test content beta", location: "lab", dispatcher: dispatcher)
        try await fileMemory(content: "discrimination-gate-test content gamma", location: "lab", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("discrimination-gate-test"),
                "explain": .bool(true),
            ])
        )
        let text = result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(
            text.contains("discrimination:"),
            "explain:true must append a discrimination line; got: \(text.prefix(400))"
        )
    }

    /// CONTRACT REVERSED 2026-09-11. This case previously asserted that the
    /// discrimination line was suppressed unless `explain` was passed, on the
    /// grounds that callers who do not ask for it should not pay the tokens.
    ///
    /// That premise does not hold: the line is emitted for LOW and MEDIUM
    /// only — high, single-result and not-found are silent — so it is not a
    /// per-call cost, it is a warning that appears exactly when the ranking is
    /// too weak to rely on. Gating it meant the ordinary caller received a
    /// poor ranking with nothing saying so, which is the one case where the
    /// signal is worth its tokens. v1 emitted it on every search under the
    /// same confidence condition.
    ///
    /// So the assertion is inverted rather than deleted: a weak result must
    /// carry its warning WITHOUT `explain`.
    @Test func weakDiscriminationIsReportedWithoutExplain() async throws {
        let dispatcher = try await makeDispatcher()
        try await fileMemory(content: "discrimination-gate-test content alpha", location: "lab", dispatcher: dispatcher)
        try await fileMemory(content: "discrimination-gate-test content beta", location: "lab", dispatcher: dispatcher)
        try await fileMemory(content: "discrimination-gate-test content gamma", location: "lab", dispatcher: dispatcher)
        let result = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: .object([
                "query": .string("discrimination-gate-test"),
                // explain omitted — default is false
            ])
        )
        let text = result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        // Three near-identical rows give a weak, indiscriminate ranking, so
        // the warning must be present even though explain was not passed.
        #expect(
            text.contains("discrimination:"),
            "a weak ranking must warn the caller without needing explain; got: \(text.prefix(400))"
        )
    }
}
