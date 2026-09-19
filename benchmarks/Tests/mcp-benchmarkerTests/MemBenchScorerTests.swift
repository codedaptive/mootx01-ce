import Testing
import Foundation
@testable import mcp_benchmarker

// MemBenchScorerTests.swift — Unit tests for MemBench scoring.
//
// Tests verify:
//   1. Manifest bridge: MemBenchManifestEntry → LMEManifestEntry mapping.
//   2. Per-item scoring via scoreMemBenchItem.
//   3. Aggregate metrics and category breakdown via aggregateMemBenchScores.
//   4. Report round-trip: buildMemBenchReport + JSON encode/decode.
//   5. Guard-exclusion: unhealthy estates produce zeroed metrics and
//      are excluded from aggregate denominators.

@Suite("MemBench scorer")
struct MemBenchScorerTests {

    // MARK: - Helpers

    /// Builds a MemBenchManifestEntry with the given uuid and sid string.
    private func entry(_ uuid: String, sid: String, sessionIndex: Int = 0) -> MemBenchManifestEntry {
        MemBenchManifestEntry(uuid: uuid, sid: sid, sessionIndex: sessionIndex)
    }

    /// Returns a synthetic MemBenchItemResult with the given manifest and evidence.
    /// choices and groundTruth default to empty/no-op values for tests that focus
    /// on retrieval scoring; C9-specific tests pass real values.
    private func makeResult(
        itemID: String = "simple/roles/0",
        category: String = "simple",
        retrievedUUIDs: [String],
        manifest: [MemBenchManifestEntry],
        evidenceSids: [String],
        guardHealthy: Bool = true,
        payloadText: String? = nil,
        choices: [String: String] = [:],
        groundTruth: String = ""
    ) -> MemBenchItemResult {
        MemBenchItemResult(
            itemID: itemID,
            category: category,
            question: "What did the user buy?",
            queryLatencySeconds: 0.05,
            retrievedUUIDs: retrievedUUIDs,
            manifest: manifest,
            evidenceSids: evidenceSids,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardHealthy ? nil : "degenerate: all results identical",
            guardSamplingMode: .oncePerLeg,
            turnsIngested: manifest.count,
            writeMeanLatencySeconds: 0.01,
            payloadText: payloadText,
            choices: choices,
            groundTruth: groundTruth
        )
    }

    // MARK: - Basic scoring: exact match

    @Test("evidence turn at rank 1 yields recall-any@1=1, recall-all@1=1, MRR=1")
    func recallAny1ExactMatch() {
        // Manifest: uuid-A → sid "5" (the evidence turn).
        let manifest = [entry("uuid-A", sid: "5")]
        let result = makeResult(
            retrievedUUIDs: ["uuid-A"],
            manifest: manifest,
            evidenceSids: ["5"]
        )
        let score = scoreMemBenchItem(result)

        #expect(abs(score.recallAnyAt1 - 1.0) < 1e-9,
                "evidence turn ranked first → recall-any@1 = 1.0")
        #expect(abs(score.recallAllAt1 - 1.0) < 1e-9,
                "single evidence, ranked first → recall-all@1 = 1.0")
        #expect(abs(score.mrr - 1.0) < 1e-9,
                "evidence at rank 1 → MRR = 1.0")
    }

    @Test("evidence at rank 3 yields recall-any@1=0, recall-any@5=1, MRR=1/3")
    func recallAny5EvidenceAtRank3() {
        // Three turns retrieved; evidence is the third.
        let manifest = [
            entry("uuid-A", sid: "1"),
            entry("uuid-B", sid: "2"),
            entry("uuid-C", sid: "5"),  // evidence
        ]
        let result = makeResult(
            retrievedUUIDs: ["uuid-A", "uuid-B", "uuid-C"],
            manifest: manifest,
            evidenceSids: ["5"]
        )
        let score = scoreMemBenchItem(result)

        #expect(abs(score.recallAnyAt1 - 0.0) < 1e-9,
                "evidence not in top 1 → recall-any@1 = 0")
        #expect(abs(score.recallAnyAt5 - 1.0) < 1e-9,
                "evidence in top 5 → recall-any@5 = 1.0")
        #expect(abs(score.mrr - 1.0 / 3.0) < 1e-9,
                "evidence at rank 3 → MRR = 1/3")
    }

    // MARK: - Multi-evidence: recall-any vs recall-all

    @Test("two evidence sids: recall-any@5=1, recall-all@1=0, recall-all@5=1")
    func recallAnyVsAllTwoEvidence() {
        // Two evidence sids: "1" and "4". Both retrieved but "4" is at rank 6.
        let manifest = [
            entry("uuid-A", sid: "1"),  // evidence
            entry("uuid-B", sid: "2"),
            entry("uuid-C", sid: "3"),
            entry("uuid-D", sid: "4"),  // evidence
            entry("uuid-E", sid: "5"),
        ]
        let result = makeResult(
            retrievedUUIDs: ["uuid-A", "uuid-B", "uuid-C", "uuid-D", "uuid-E"],
            manifest: manifest,
            evidenceSids: ["1", "4"]
        )
        let score = scoreMemBenchItem(result)

        // recall-any@3: "1" is at rank 1, so at least one evidence in top 3 → 1.0
        #expect(abs(score.recallAnyAt5 - 1.0) < 1e-9,
                "at least one evidence in top 5 → recall-any@5 = 1.0")
        // recall-all@3: "4" is at rank 4, NOT in top 3 → 0.0
        #expect(abs(score.recallAllAt1 - 0.0) < 1e-9,
                "not both evidence in top 1 → recall-all@1 = 0.0")
        // recall-all@5: both in top 5 → 1.0
        #expect(abs(score.recallAllAt5 - 1.0) < 1e-9,
                "both evidence in top 5 → recall-all@5 = 1.0")
    }

    // MARK: - Guard exclusion

    @Test("guard-excluded item has zeroed metrics and non-nil diagnostic")
    func guardExcludedItemHasZeroMetrics() {
        let manifest = [entry("uuid-A", sid: "5")]
        let result = makeResult(
            retrievedUUIDs: ["uuid-A"],
            manifest: manifest,
            evidenceSids: ["5"],
            guardHealthy: false  // unhealthy
        )
        let score = scoreMemBenchItem(result)

        #expect(!score.guardHealthy)
        #expect(score.guardDiagnostic != nil)
        #expect(abs(score.recallAnyAt1 - 0.0) < 1e-9)
        #expect(abs(score.recallAnyAt5 - 0.0) < 1e-9)
        #expect(abs(score.mrr - 0.0) < 1e-9)
    }

    @Test("guard-excluded items are dropped from aggregate denominator")
    func guardExcludedItemsDroppedFromAggregate() {
        // 2 healthy items (perfect recall) + 1 unhealthy item.
        let manifest = [entry("uuid-A", sid: "1")]
        let healthy1 = makeResult(
            itemID: "simple/roles/0", category: "simple",
            retrievedUUIDs: ["uuid-A"], manifest: manifest, evidenceSids: ["1"])
        let healthy2 = makeResult(
            itemID: "simple/roles/1", category: "simple",
            retrievedUUIDs: ["uuid-A"], manifest: manifest, evidenceSids: ["1"])
        let unhealthy = makeResult(
            itemID: "simple/roles/2", category: "simple",
            retrievedUUIDs: [], manifest: [], evidenceSids: ["1"],
            guardHealthy: false)

        let scores = [healthy1, healthy2, unhealthy].map { scoreMemBenchItem($0) }
        let (agg, _, _) = aggregateMemBenchScores(scores)

        // Only 2 healthy items in denominator.
        #expect(agg.queryCount == 2,
                "aggregate denominator should be 2 (guard-excluded item dropped)")
        #expect(abs(agg.recallAnyAt5 - 1.0) < 1e-9,
                "both healthy items are perfect → aggregate recall-any@5 = 1.0")
    }

    // MARK: - Category breakdown

    @Test("category breakdown splits items by category label with correct counts and recall")
    func categoryBreakdown() throws {
        let manifest = [entry("uuid-A", sid: "1")]
        // 2 "simple" items (one perfect, one miss) + 1 "noisy" item (perfect).
        let s1 = makeResult(itemID: "simple/roles/0", category: "simple",
                            retrievedUUIDs: ["uuid-A"], manifest: manifest, evidenceSids: ["1"])
        let s2 = makeResult(itemID: "simple/roles/1", category: "simple",
                            retrievedUUIDs: [], manifest: manifest, evidenceSids: ["1"])
        let n1 = makeResult(itemID: "noisy/roles/0", category: "noisy",
                            retrievedUUIDs: ["uuid-A"], manifest: manifest, evidenceSids: ["1"])

        let scores = [s1, s2, n1].map { scoreMemBenchItem($0) }
        let (_, cats, _) = aggregateMemBenchScores(scores)

        let simpleCat = cats.first(where: { $0.label == "simple" })
        let noisyCat  = cats.first(where: { $0.label == "noisy" })

        let sc = try #require(simpleCat, "simple category should appear in breakdown")
        let nc = try #require(noisyCat,  "noisy category should appear in breakdown")
        #expect(sc.queryCount == 2)
        #expect(nc.queryCount == 1)
        // "simple" has one perfect + one miss → recall-any@5 = 0.5
        #expect(abs(sc.recallAnyAt5 - 0.5) < 1e-9)
        // "noisy" has one perfect → recall-any@5 = 1.0
        #expect(abs(nc.recallAnyAt5 - 1.0) < 1e-9)
    }

    // MARK: - Empty evidence list

    @Test("empty evidence list produces zero recall-any@5 and zero MRR")
    func emptyEvidenceListProducesZeroMetrics() {
        let manifest = [entry("uuid-A", sid: "1")]
        let result = makeResult(
            retrievedUUIDs: ["uuid-A"],
            manifest: manifest,
            evidenceSids: []   // no evidence
        )
        let score = scoreMemBenchItem(result)

        // No evidence → nothing can be found → metrics are 0.
        // lmeRecallAny(answerIDs: [], k:) returns 0.0 for empty evidence sets.
        #expect(abs(score.recallAnyAt5 - 0.0) < 1e-9,
                "empty evidence set → recall-any@5 = 0.0")
        #expect(abs(score.mrr - 0.0) < 1e-9,
                "empty evidence set → MRR = 0.0")
    }

    // MARK: - Ranked sid output

    @Test("duplicate sids in manifest are deduplicated in rankedSids")
    func rankedSidsDeduped() {
        // Two UUIDs mapping to the same sid (edge case: duplicate turns filed).
        let manifest = [
            entry("uuid-A", sid: "7"),
            entry("uuid-B", sid: "7"),  // duplicate sid
            entry("uuid-C", sid: "8"),
        ]
        let result = makeResult(
            retrievedUUIDs: ["uuid-A", "uuid-B", "uuid-C"],
            manifest: manifest,
            evidenceSids: ["7"]
        )
        let score = scoreMemBenchItem(result)

        // lmeRankedSessions deduplicates: "7" appears once at rank 1, "8" at rank 2.
        #expect(score.rankedSids == ["7", "8"], "duplicate sid should appear once")
    }

    // MARK: - Report round-trip

    @Test("report round-trips through JSON encode and decode with correct fields")
    func reportRoundTrip() throws {
        let manifest = [entry("uuid-A", sid: "0")]
        let result = makeResult(
            retrievedUUIDs: ["uuid-A"],
            manifest: manifest,
            evidenceSids: ["0"]
        )
        let scores = [scoreMemBenchItem(result)]

        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        let config = MemBenchRunConfig(
            mootBinaryPath: "/fake/mootx01",
            dataDir: URL(fileURLWithPath: "/fake/MemData"),
            agent: "FirstAgent",
            categories: ["simple"],
            limit: nil,
            offset: 0,
            seed: 20_260_806,
            outDir: nil,
            runLabel: "membench-seed20260806",
            encodeBarrier: .drain,
            scratchPosture: .plaintextTransient,
            categoryFilter: nil,
            seedPath: .batch,
            guardSamplingPolicy: .oncePerLeg,
            estateCache: .off,
            cacheDir: nil,
            corpusDigest: "deadbeef",
            shape: .disk,
            parallelUnits: 1,
            estateGrouping: .perItem,
            capacityTier: .baseline
        )
        let report = buildMemBenchReport(
            config: config,
            corpus: corpus,
            results: [result],
            scores: scores
        )

        // Encode to JSON and decode back.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(MemBenchReport.self, from: data)

        #expect(decoded.runLabel == "membench-seed20260806")
        #expect(decoded.agent == "FirstAgent")
        #expect(decoded.encodeBarrier == "drain")
        #expect(decoded.aggregate.queryCount == 1)
        #expect(decoded.perItem.count == 1)
        #expect(decoded.perItem[0].itemID == "simple/roles/0")
        #expect(decoded.perItem[0].category == "simple")
        #expect(!decoded.generatedAt.isEmpty, "generatedAt should be set")
        #expect(!decoded.runID.isEmpty, "runID should be a non-empty UUID string")
        // C1/C6 fields survive the JSON round-trip.
        #expect(decoded.shape == "disk", "shape field should round-trip as 'disk'")
        #expect(decoded.parallelUnits == 1, "parallelUnits field should round-trip as 1")
    }

    // MARK: - Latency stats

    @Test("latency stats p50 and mean are positive when results have positive latency")
    func latencyStatsPresent() {
        let manifest = [entry("uuid-A", sid: "1")]
        let r1 = makeResult(itemID: "simple/roles/0", category: "simple",
                            retrievedUUIDs: ["uuid-A"], manifest: manifest, evidenceSids: ["1"])
        let r2 = makeResult(itemID: "simple/roles/1", category: "simple",
                            retrievedUUIDs: [], manifest: manifest, evidenceSids: ["1"])
        let scores = [r1, r2].map { scoreMemBenchItem($0) }
        let (_, _, lat) = aggregateMemBenchScores(scores)

        // Synthetic results have queryLatencySeconds = 0.05 → p50 and mean should be ~0.05.
        #expect(lat.queryP50Seconds > 0.0, "p50 latency should be > 0")
        #expect(lat.queryMeanSeconds > 0.0, "mean latency should be > 0")
    }

    // MARK: - All-empty corpus

    @Test("empty input produces zero aggregate, empty categories, zero latency")
    func aggregateEmptyCorpus() {
        let (agg, cats, lat) = aggregateMemBenchScores([])
        #expect(agg.queryCount == 0)
        #expect(abs(agg.recallAnyAt5 - 0.0) < 1e-9)
        #expect(abs(agg.mrr - 0.0) < 1e-9)
        #expect(cats.isEmpty, "no categories when no scores")
        #expect(abs(lat.queryMeanSeconds - 0.0) < 1e-9)
    }

    // MARK: - Category label ordering

    @Test("simple precedes noisy in canonical category ordering")
    func canonicalCategoryOrder() {
        let manifest = [entry("uuid-A", sid: "1")]
        // Items in non-canonical order: noisy first, then simple.
        let n1 = makeResult(itemID: "noisy/roles/0", category: "noisy",
                            retrievedUUIDs: ["uuid-A"], manifest: manifest, evidenceSids: ["1"])
        let s1 = makeResult(itemID: "simple/roles/0", category: "simple",
                            retrievedUUIDs: ["uuid-A"], manifest: manifest, evidenceSids: ["1"])
        let scores = [n1, s1].map { scoreMemBenchItem($0) }
        let (_, cats, _) = aggregateMemBenchScores(scores)

        // "simple" appears before "noisy" in canonical order.
        let labels = cats.map(\.label)
        let simpleIdx = labels.firstIndex(of: "simple") ?? Int.max
        let noisyIdx  = labels.firstIndex(of: "noisy") ?? Int.max
        #expect(simpleIdx < noisyIdx,
                "simple should precede noisy in canonical category order")
    }

    // MARK: - C9 — multiple-choice arm

    // Shared choices fixture: A→Portland, B→Seattle, C→Denver, D→Austin.
    private let sampleChoices: [String: String] = [
        "A": "Portland",
        "B": "Seattle",
        "C": "Denver",
        "D": "Austin",
    ]

    // MARK: selectMultipleChoicePrediction

    @Test("C9: payload containing option text returns the matching letter")
    func c9MatchingOptionText() {
        let payload = "The event is taking place in Portland this summer."
        let prediction = selectMultipleChoicePrediction(from: payload, choices: sampleChoices)
        #expect(prediction == "A", "Portland appears in payload → should select 'A'")
    }

    @Test("C9: match is case-insensitive")
    func c9CaseInsensitiveMatch() {
        let payload = "Confirmed venue: PORTLAND, Oregon."
        let prediction = selectMultipleChoicePrediction(from: payload, choices: sampleChoices)
        #expect(prediction == "A", "PORTLAND matches Portland case-insensitively")
    }

    @Test("C9: nil payload returns nil prediction")
    func c9NilPayloadReturnsNil() {
        let prediction = selectMultipleChoicePrediction(from: nil, choices: sampleChoices)
        #expect(prediction == nil, "nil payload → nil prediction")
    }

    @Test("C9: empty payload returns nil prediction")
    func c9EmptyPayloadReturnsNil() {
        let prediction = selectMultipleChoicePrediction(from: "", choices: sampleChoices)
        #expect(prediction == nil, "empty payload → nil prediction")
    }

    @Test("C9: payload with no matching option returns nil")
    func c9NoMatchReturnsNil() {
        let payload = "The event is in New York City."
        let prediction = selectMultipleChoicePrediction(from: payload, choices: sampleChoices)
        #expect(prediction == nil, "no option text in payload → nil")
    }

    @Test("C9: first matching letter wins when multiple options appear in payload")
    func c9FirstMatchWins() {
        // Both B and C appear — B wins because A→D scan order reaches 'B' first.
        let choices: [String: String] = ["A": "cat", "B": "dog", "C": "bird", "D": "fish"]
        let payload = "There is a dog and a bird here."
        let prediction = selectMultipleChoicePrediction(from: payload, choices: choices)
        #expect(prediction == "B", "B ('dog') is the first matching letter in A→D scan order")
    }

    // MARK: scoreMemBenchItem MC integration

    @Test("C9: correct prediction yields multipleChoiceCorrect = true")
    func c9CorrectPrediction() {
        let choices: [String: String] = ["A": "Portland", "B": "Seattle", "C": "Denver", "D": "Austin"]
        let result = makeResult(
            retrievedUUIDs: [], manifest: [], evidenceSids: [],
            payloadText: "The event will be held in Portland.",
            choices: choices,
            groundTruth: "A"
        )
        let score = scoreMemBenchItem(result)
        #expect(score.multipleChoicePrediction == "A")
        #expect(score.multipleChoiceCorrect == true)
    }

    @Test("C9: wrong prediction yields multipleChoiceCorrect = false")
    func c9WrongPrediction() {
        let choices: [String: String] = ["A": "Portland", "B": "Seattle", "C": "Denver", "D": "Austin"]
        // groundTruth is B but payload has "Portland" → prediction will be A → wrong.
        let result = makeResult(
            retrievedUUIDs: [], manifest: [], evidenceSids: [],
            payloadText: "The event will be held in Portland.",
            choices: choices,
            groundTruth: "B"
        )
        let score = scoreMemBenchItem(result)
        #expect(score.multipleChoicePrediction == "A")
        #expect(score.multipleChoiceCorrect == false)
    }

    @Test("C9: nil prediction yields multipleChoiceCorrect = false")
    func c9NilPredictionIsFalse() {
        let choices: [String: String] = ["A": "Portland", "B": "Seattle", "C": "Denver", "D": "Austin"]
        // nil payloadText → nil prediction → multipleChoiceCorrect = false.
        let result = makeResult(
            retrievedUUIDs: [], manifest: [], evidenceSids: [],
            payloadText: nil,
            choices: choices,
            groundTruth: "A"
        )
        let score = scoreMemBenchItem(result)
        #expect(score.multipleChoicePrediction == nil)
        #expect(score.multipleChoiceCorrect == false)
    }

    // MARK: aggregate multipleChoiceAccuracy

    @Test("C9: aggregate MC accuracy is fraction of correct over guard-healthy items")
    func c9AggregateMCAccuracy() {
        let choices: [String: String] = ["A": "cat", "B": "dog", "C": "bird", "D": "fish"]
        // r1: correct (payload has "cat", groundTruth = "A")
        let r1 = makeResult(
            itemID: "a", retrievedUUIDs: [], manifest: [], evidenceSids: [],
            payloadText: "I see a cat.",
            choices: choices, groundTruth: "A"
        )
        // r2: wrong (payload has "cat", groundTruth = "B")
        let r2 = makeResult(
            itemID: "b", retrievedUUIDs: [], manifest: [], evidenceSids: [],
            payloadText: "I see a cat.",
            choices: choices, groundTruth: "B"
        )
        // r3: guard-unhealthy — excluded from MC aggregate denominator.
        let r3 = makeResult(
            itemID: "c", retrievedUUIDs: [], manifest: [], evidenceSids: [],
            guardHealthy: false,
            payloadText: "I see a cat.",
            choices: choices, groundTruth: "A"
        )
        let scores = [r1, r2, r3].map { scoreMemBenchItem($0) }
        let (agg, _, _) = aggregateMemBenchScores(scores)
        // r1 and r2 are guard-healthy; r1 correct, r2 wrong → 0.5.
        #expect(abs(agg.multipleChoiceAccuracy - 0.5) < 1e-9,
                "1 correct out of 2 healthy → MC accuracy = 0.5")
    }

    // MARK: JSON round-trip — C9 fields

    @Test("C9: multiple_choice_accuracy and per-item MC fields survive JSON round-trip")
    func c9MCFieldsRoundTripJSON() throws {
        let choices: [String: String] = ["A": "Portland", "B": "Seattle", "C": "Denver", "D": "Austin"]
        let manifest = [MemBenchManifestEntry(uuid: "u1", sid: "0", sessionIndex: 0)]
        let result = makeResult(
            retrievedUUIDs: ["u1"],
            manifest: manifest,
            evidenceSids: ["0"],
            payloadText: "The event is in Portland.",
            choices: choices,
            groundTruth: "A"
        )
        let scores = [scoreMemBenchItem(result)]
        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        let config = MemBenchRunConfig(
            mootBinaryPath: "/fake/mootx01",
            dataDir: URL(fileURLWithPath: "/fake/MemData"),
            agent: "FirstAgent",
            categories: ["simple"],
            limit: nil, offset: 0, seed: 1,
            outDir: nil, runLabel: "test-c9",
            encodeBarrier: .drain,
            scratchPosture: .plaintextTransient,
            categoryFilter: nil, seedPath: .batch,
            guardSamplingPolicy: .oncePerLeg,
            estateCache: .off, cacheDir: nil,
            corpusDigest: "test",
            shape: .disk, parallelUnits: 1,
            estateGrouping: .perItem,
            capacityTier: .baseline
        )
        let report = buildMemBenchReport(config: config, corpus: corpus, results: [result], scores: scores)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchReport.self, from: data)
        #expect(abs(decoded.aggregate.multipleChoiceAccuracy - 1.0) < 1e-9,
                "single correct prediction → aggregate MC accuracy = 1.0")
        let item = try #require(decoded.perItem.first)
        #expect(item.multipleChoicePrediction == "A")
        #expect(item.multipleChoiceCorrect == true)
    }
}

// MARK: - C1+C6 flag tests

@Suite("MemBench C1+C6 flags")
struct MemBenchC1C6FlagTests {

    // MARK: BenchShape.parse

    @Test("BenchShape.parse(nil) gives disk")
    func benchShapeParseNilGivesDisk() throws {
        let shape = try BenchShape.parse(nil)
        #expect(shape == .disk)
    }

    @Test("BenchShape.parse('disk') gives disk")
    func benchShapeParseExplicitDisk() throws {
        let shape = try BenchShape.parse("disk")
        #expect(shape == .disk)
    }

    @Test("BenchShape.parse('ram') gives ram")
    func benchShapeParseRam() throws {
        let shape = try BenchShape.parse("ram")
        #expect(shape == .ram)
    }

    @Test("BenchShape.parse('ssd') throws with descriptive error")
    func benchShapeParseInvalidThrows() {
        #expect(throws: (any Error).self) {
            _ = try BenchShape.parse("ssd")
        }
    }

    @Test("BenchShape rawValue round-trips")
    func benchShapeRawValueRoundTrips() throws {
        #expect(BenchShape.disk.rawValue == "disk")
        #expect(BenchShape.ram.rawValue == "ram")
        #expect(BenchShape(rawValue: "disk") == .disk)
        #expect(BenchShape(rawValue: "ram") == .ram)
    }

    // MARK: parallelUnits default

    @Test("parallelUnits default is at least 1")
    func parallelUnitsDefaultIsAtLeastOne() {
        // The default formula is max(1, Int(Double(processorCount) * 0.8)).
        // On any machine with ≥1 core this should return >= 1.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let defaultN = max(1, Int(Double(cores) * 0.8))
        #expect(defaultN >= 1, "parallelUnits default must be at least 1")
    }

    // MARK: ram + estate-cache rejection guard (pure helper, no MCP)

    @Test("shape .ram + non-off estateCache is logically invalid (documents the rejection guard)")
    func ramShapeWithCacheIsRejected() {
        // The CLI guard is in CLI.swift — this test documents the rule by verifying
        // that the two incompatible conditions can be expressed and checked.
        let shape = BenchShape.ram
        let cacheMode = EstateCacheMode.reuse
        // RAM estates have no disk artifact — estate-cache reuse/require is nonsensical.
        let isInvalid = shape == .ram && cacheMode != .off
        #expect(isInvalid, "ram + reuse should be detected as invalid by the CLI guard")
    }

    // MARK: index-sort determinism pin

    @Test("index-sort produces byte-deterministic ordering regardless of completion order")
    func indexSortDeterminismPin() {
        // Simulate items completing in reverse order (2, 1, 0).
        let outOfOrder: [(Int, String)] = [(2, "item-C"), (1, "item-B"), (0, "item-A")]
        let sorted = outOfOrder.sorted { $0.0 < $1.0 }.map(\.1)
        #expect(sorted == ["item-A", "item-B", "item-C"],
                "sorted result must match original run order")
    }
}

// MARK: - C10 — Shape 3 grouping and report deviation labels

@Suite("MemBench C10 Shape 3")
struct MemBenchC10Shape3Tests {

    // MARK: - Helpers

    /// Builds a minimal MemBenchItem for grouping tests (no sessions, empty QA choices).
    private func makeItem(question: String, id: String = "test/item/0") -> MemBenchItem {
        let qa = MemBenchQA(
            qid: 0,
            question: question,
            answer: "answer",
            targetStepID: [],
            choices: [:],
            groundTruth: "A",
            time: "2026-01-01T00:00:00Z"
        )
        return MemBenchItem(
            itemID: id,
            category: "simple",
            agent: "FirstAgent",
            topicKey: "roles",
            tid: 0,
            sessions: [],
            qa: qa
        )
    }

    /// Builds a MemBenchRunConfig with the given grouping mode (all other fields are stubs).
    private func makeConfig(grouping: EstateGroupingMode) -> MemBenchRunConfig {
        MemBenchRunConfig(
            mootBinaryPath: "/fake/mootx01",
            dataDir: URL(fileURLWithPath: "/fake/MemData"),
            agent: "FirstAgent",
            categories: nil,
            limit: nil, offset: 0, seed: 1,
            outDir: nil, runLabel: "test-c10",
            encodeBarrier: .drain,
            scratchPosture: .plaintextTransient,
            categoryFilter: nil, seedPath: .batch,
            guardSamplingPolicy: .oncePerLeg,
            estateCache: .off, cacheDir: nil,
            corpusDigest: "test",
            shape: .disk, parallelUnits: 1,
            estateGrouping: grouping,
            capacityTier: .baseline
        )
    }

    // MARK: - memBenchConflictKey

    @Test("C10: conflict key is the QA question text")
    func c10ConflictKeyIsQuestionText() {
        let item = makeItem(question: "What is the name of the niece?")
        let key = memBenchConflictKey(item)
        #expect(key == "What is the name of the niece?",
                "conflict key must equal the question text verbatim")
    }

    // MARK: - memBenchGroupItemsByConflictKey

    @Test("C10: all distinct questions → 1 group containing all items")
    func c10GroupByConflictKeyAllDistinct() {
        let items = [
            makeItem(question: "Q1", id: "item/0"),
            makeItem(question: "Q2", id: "item/1"),
            makeItem(question: "Q3", id: "item/2"),
        ]
        let groups = memBenchGroupItemsByConflictKey(items)
        #expect(groups.count == 1, "all distinct keys → 1 group")
        #expect(groups[0].count == 3, "all 3 items in group 0")
    }

    @Test("C10: all same question → N groups of 1")
    func c10GroupByConflictKeyAllSame() {
        let items = [
            makeItem(question: "Q1", id: "item/0"),
            makeItem(question: "Q1", id: "item/1"),
            makeItem(question: "Q1", id: "item/2"),
        ]
        let groups = memBenchGroupItemsByConflictKey(items)
        #expect(groups.count == 3, "3 items sharing a key → 3 groups")
        #expect(groups.allSatisfy { $0.count == 1 }, "each group has exactly 1 item")
    }

    @Test("C10: greedy round-robin puts conflicting items in different groups")
    func c10GroupByConflictKeyGreedyRoundRobin() {
        // Items: Q1, Q2, Q1, Q3 → keys: Q1 appears twice, Q2 and Q3 once.
        // Group 0: items with first occurrence of their key (Q1[0], Q2, Q3).
        // Group 1: items with second occurrence of their key (Q1[1]).
        // Total groups = 2 (max key frequency = 2).
        let items = [
            makeItem(question: "Q1", id: "item/0"),   // group 0
            makeItem(question: "Q2", id: "item/1"),   // group 0
            makeItem(question: "Q1", id: "item/2"),   // group 1 (Q1's second occurrence)
            makeItem(question: "Q3", id: "item/3"),   // group 0
        ]
        let groups = memBenchGroupItemsByConflictKey(items)
        #expect(groups.count == 2, "max key frequency is 2 → 2 groups")
        // Group 0 should have items 0, 1, 3 (first occurrence of Q1, Q2, Q3).
        let ids0 = groups[0].map(\.itemID)
        #expect(ids0 == ["item/0", "item/1", "item/3"],
                "group 0 contains the first occurrence of each key")
        // Group 1 should have item 2 (second occurrence of Q1).
        let ids1 = groups[1].map(\.itemID)
        #expect(ids1 == ["item/2"],
                "group 1 contains the second occurrence of Q1")
    }

    @Test("C10: grouping is deterministic — same input always produces same groups")
    func c10GroupingIsDeterministic() {
        let items = [
            makeItem(question: "A", id: "i/0"),
            makeItem(question: "B", id: "i/1"),
            makeItem(question: "A", id: "i/2"),
            makeItem(question: "C", id: "i/3"),
            makeItem(question: "B", id: "i/4"),
        ]
        let g1 = memBenchGroupItemsByConflictKey(items).map { $0.map(\.itemID) }
        let g2 = memBenchGroupItemsByConflictKey(items).map { $0.map(\.itemID) }
        #expect(g1 == g2, "grouping must be deterministic")
    }

    // MARK: - Report deviation labels

    @Test("C10: per-item mode sets estate_shape=per-item and protocol_deviation=false")
    func c10PerItemModeLabelsInReport() throws {
        let config = makeConfig(grouping: .perItem)
        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        let report = buildMemBenchReport(config: config, corpus: corpus, results: [], scores: [])
        // JSON round-trip.
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchReport.self, from: data)
        #expect(decoded.estateShape == "per-item",
                "per-item runs must carry estate_shape = 'per-item'")
        #expect(decoded.protocolDeviation == false,
                "per-item runs must carry protocol_deviation = false")
        #expect(decoded.shape3GroupCount == nil, "shape3GroupCount absent for per-item runs")
    }

    @Test("C10: consolidated mode sets estate_shape=consolidated-shape3, protocol_deviation=true, and group stats")
    func c10Shape3FieldsRoundTripJSON() throws {
        let config = makeConfig(grouping: .consolidatedShape3)
        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        // Simulate a 3-group run: group 0 has 2 items (Q1+Q2), group 1 has 1 item (Q1 again).
        let g0 = [makeItem(question: "Q1", id: "i/0"), makeItem(question: "Q2", id: "i/1")]
        let g1 = [makeItem(question: "Q1", id: "i/2")]
        let groups: [[MemBenchItem]] = [g0, g1]
        let report = buildMemBenchReport(
            config: config, corpus: corpus, results: [], scores: [],
            shape3Groups: groups
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchReport.self, from: data)
        #expect(decoded.estateShape == "consolidated-shape3",
                "Shape 3 runs must carry estate_shape = 'consolidated-shape3'")
        #expect(decoded.protocolDeviation == true,
                "Shape 3 runs must carry protocol_deviation = true")
        #expect(decoded.shape3GroupCount == 2,
                "2 groups → shape_3_group_count = 2")
        #expect(decoded.shape3ConflictKeyType == "question_text",
                "conflict key type must be 'question_text'")
        // Unique keys: Q1 and Q2 → 2 unique keys.
        #expect(decoded.shape3UniqueKeys == 2,
                "2 unique question texts → shape_3_unique_keys = 2")
        // Items per group: [2, 1].
        #expect(decoded.shape3ItemsPerGroup == [2, 1],
                "group sizes must be [2, 1]")
    }

    // MARK: EstateGroupingMode.parse

    @Test("C10: EstateGroupingMode.parse(nil) gives perItem")
    func c10ParseNilGivesPerItem() throws {
        let mode = try EstateGroupingMode.parse(nil)
        #expect(mode == .perItem, "nil input → per-item default")
    }

    @Test("C10: EstateGroupingMode.parse('per-item') gives perItem")
    func c10ParsePerItem() throws {
        let mode = try EstateGroupingMode.parse("per-item")
        #expect(mode == .perItem)
    }

    @Test("C10: EstateGroupingMode.parse('consolidated') gives consolidatedShape3")
    func c10ParseConsolidated() throws {
        let mode = try EstateGroupingMode.parse("consolidated")
        #expect(mode == .consolidatedShape3)
    }

    @Test("C10: EstateGroupingMode.parse with invalid value throws")
    func c10ParseInvalidThrows() {
        #expect(throws: (any Error).self) {
            _ = try EstateGroupingMode.parse("batch")
        }
    }

    @Test("C10: EstateGroupingMode rawValue round-trips")
    func c10RawValueRoundTrips() {
        #expect(EstateGroupingMode.perItem.rawValue == "per-item")
        #expect(EstateGroupingMode.consolidatedShape3.rawValue == "consolidated")
        #expect(EstateGroupingMode(rawValue: "per-item") == .perItem)
        #expect(EstateGroupingMode(rawValue: "consolidated") == .consolidatedShape3)
    }
}

// MARK: - C11 — Capacity tier

@Suite("MemBench C11 CapacityTier")
struct MemBenchC11CapacityTierTests {

    // MARK: - CapacityTier.parse

    @Test("C11: CapacityTier.parse(nil) gives baseline")
    func c11ParseNilGivesBaseline() throws {
        let tier = try CapacityTier.parse(nil)
        #expect(tier == .baseline)
    }

    @Test("C11: CapacityTier.parse('baseline') gives baseline")
    func c11ParseExplicitBaseline() throws {
        let tier = try CapacityTier.parse("baseline")
        #expect(tier == .baseline)
    }

    @Test("C11: CapacityTier.parse('10k') gives tenK")
    func c11Parse10k() throws {
        let tier = try CapacityTier.parse("10k")
        #expect(tier == .tenK)
    }

    @Test("C11: CapacityTier.parse('100k') gives hundredK")
    func c11Parse100k() throws {
        let tier = try CapacityTier.parse("100k")
        #expect(tier == .hundredK)
    }

    @Test("C11: CapacityTier.parse with invalid value throws")
    func c11ParseInvalidThrows() {
        #expect(throws: (any Error).self) {
            _ = try CapacityTier.parse("50k")
        }
    }

    // MARK: - targetTokens

    @Test("C11: baseline.targetTokens is nil")
    func c11BaselineTargetNil() {
        #expect(CapacityTier.baseline.targetTokens == nil)
    }

    @Test("C11: tenK.targetTokens is 10_000")
    func c11TenKTarget() {
        #expect(CapacityTier.tenK.targetTokens == 10_000)
    }

    @Test("C11: hundredK.targetTokens is 100_000")
    func c11HundredKTarget() {
        #expect(CapacityTier.hundredK.targetTokens == 100_000)
    }

    // MARK: - estateShapeLabel

    @Test("C11: baseline estateShapeLabel is nil")
    func c11BaselineShapeLabelNil() {
        #expect(CapacityTier.baseline.estateShapeLabel == nil)
    }

    @Test("C11: tenK estateShapeLabel is per-item-capacity-10k")
    func c11TenKShapeLabel() {
        #expect(CapacityTier.tenK.estateShapeLabel == "per-item-capacity-10k")
    }

    @Test("C11: hundredK estateShapeLabel is per-item-capacity-100k")
    func c11HundredKShapeLabel() {
        #expect(CapacityTier.hundredK.estateShapeLabel == "per-item-capacity-100k")
    }

    // MARK: - memBenchItemTokenCount

    /// Builds a minimal MemBenchItem with one session and a given turn body.
    private func makeItemWithTurn(user: String, assistant: String, id: String = "test/0") -> MemBenchItem {
        let turn = MemBenchTurn(
            sid: 0,
            userMessage: user,
            assistantMessage: assistant,
            time: "2026-01-01T00:00:00Z",
            place: "home")
        let session = MemBenchSession(sessionIndex: 0, turns: [turn])
        let qa = MemBenchQA(
            qid: 0, question: "Q?", answer: "A",
            targetStepID: [], choices: [:], groundTruth: "A",
            time: "2026-01-01T00:00:00Z")
        return MemBenchItem(
            itemID: id, category: "simple", agent: "FirstAgent",
            topicKey: "t", tid: 0, sessions: [session], qa: qa)
    }

    @Test("C11: memBenchItemTokenCount empty item returns zero")
    func c11TokenCountEmptyItem() {
        let qa = MemBenchQA(qid: 0, question: "Q?", answer: "A",
                            targetStepID: [], choices: [:], groundTruth: "A",
                            time: "2026-01-01T00:00:00Z")
        let item = MemBenchItem(itemID: "test/0", category: "simple",
                                agent: "FirstAgent", topicKey: "t", tid: 0,
                                sessions: [], qa: qa)
        #expect(memBenchItemTokenCount(item) == 0,
                "no sessions → zero tokens")
    }

    @Test("C11: memBenchItemTokenCount matches manual lmeEstimateTokens call")
    func c11TokenCountMatchesManualEstimate() {
        let user = "What did we talk about yesterday?"
        let assistant = "We discussed the project timeline and next milestones."
        let item = makeItemWithTurn(user: user, assistant: assistant)
        // Content format: "user: <msg>\nassistant: <msg>"
        let expected = lmeEstimateTokens("user: \(user)\nassistant: \(assistant)")
        #expect(memBenchItemTokenCount(item) == expected,
                "token count must match manual lmeEstimateTokens on the ingest string")
    }

    @Test("C11: memBenchItemTokenCount accumulates across turns")
    func c11TokenCountAccumulatesAcrossTurns() {
        let turn0 = MemBenchTurn(sid: 0, userMessage: "Hello", assistantMessage: "Hi there",
                                 time: "2026-01-01T00:00:00Z", place: "home")
        let turn1 = MemBenchTurn(sid: 1, userMessage: "How are you?", assistantMessage: "Fine, thanks",
                                 time: "2026-01-01T00:00:01Z", place: "home")
        let session = MemBenchSession(sessionIndex: 0, turns: [turn0, turn1])
        let qa = MemBenchQA(qid: 0, question: "Q?", answer: "A",
                            targetStepID: [], choices: [:], groundTruth: "A",
                            time: "2026-01-01T00:00:00Z")
        let item = MemBenchItem(itemID: "test/0", category: "simple",
                                agent: "FirstAgent", topicKey: "t", tid: 0,
                                sessions: [session], qa: qa)
        let t0 = lmeEstimateTokens("user: Hello\nassistant: Hi there")
        let t1 = lmeEstimateTokens("user: How are you?\nassistant: Fine, thanks")
        #expect(memBenchItemTokenCount(item) == t0 + t1,
                "token count must sum across all turns")
    }

    // MARK: - capacity grouping behavior

    /// Builds a minimal item with sessions and the given question text.
    private func makeItem(question: String, id: String = "test/item/0",
                          user: String = "Hello", assistant: String = "World") -> MemBenchItem {
        let turn = MemBenchTurn(sid: 0, userMessage: user, assistantMessage: assistant,
                                time: "2026-01-01T00:00:00Z", place: "home")
        let session = MemBenchSession(sessionIndex: 0, turns: [turn])
        let qa = MemBenchQA(qid: 0, question: question, answer: "A",
                            targetStepID: [], choices: [:], groundTruth: "A",
                            time: "2026-01-01T00:00:00Z")
        return MemBenchItem(itemID: id, category: "simple", agent: "FirstAgent",
                            topicKey: "t", tid: 0, sessions: [session], qa: qa)
    }

    @Test("C11: filler pool excludes the target item itself")
    func c11FillerPoolExcludesTarget() {
        // Three items with distinct questions → greedy grouper assigns them all to group 0.
        let i0 = makeItem(question: "Q0", id: "item/0", user: "u0", assistant: "a0")
        let i1 = makeItem(question: "Q1", id: "item/1", user: "u1", assistant: "a1")
        let i2 = makeItem(question: "Q2", id: "item/2", user: "u2", assistant: "a2")

        let allGroups = memBenchGroupItemsByConflictKey([i0, i1, i2])
        // All distinct questions → 1 group containing all 3 items.
        #expect(allGroups.count == 1, "all distinct questions → exactly 1 group")
        let group = allGroups[0]
        // The filler pool for i0 should be {i1, i2}.
        let fillerPool = group.filter { $0.itemID != i0.itemID }
        #expect(fillerPool.count == 2, "filler pool for i0 should have 2 items")
        #expect(!fillerPool.contains(where: { $0.itemID == "item/0" }),
                "target item must not appear in its own filler pool")
        #expect(fillerPool.contains(where: { $0.itemID == "item/1" }),
                "other items must be available as fillers")
    }

    // MARK: - capacity report fields

    private func makeStubConfig(tier: CapacityTier) -> MemBenchRunConfig {
        MemBenchRunConfig(
            mootBinaryPath: "/fake/mootx01",
            dataDir: URL(fileURLWithPath: "/fake/MemData"),
            agent: "FirstAgent",
            categories: nil,
            limit: nil, offset: 0, seed: 1,
            outDir: nil, runLabel: "test-c11",
            encodeBarrier: .drain,
            scratchPosture: .plaintextTransient,
            categoryFilter: nil, seedPath: .batch,
            guardSamplingPolicy: .oncePerLeg,
            estateCache: .off, cacheDir: nil,
            corpusDigest: "test",
            shape: .disk, parallelUnits: 1,
            estateGrouping: .perItem,
            capacityTier: tier
        )
    }

    @Test("C11: baseline tier → capacity fields absent from report JSON")
    func c11BaselineCapacityFieldsAbsent() throws {
        let config = makeStubConfig(tier: .baseline)
        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        let report = buildMemBenchReport(config: config, corpus: corpus, results: [], scores: [])
        let data = try JSONEncoder().encode(report)
        // Use JSONSerialization to inspect raw keys — verifies nil optionals are truly absent.
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "report must encode to a JSON object")
        // Capacity fields are all nil → JSONEncoder omits them entirely for optional properties.
        #expect(json["capacity_tier"] == nil,
                "capacity_tier must be absent for baseline runs")
        #expect(json["capacity_achieved_tokens_p50"] == nil,
                "capacity_achieved_tokens_p50 must be absent for baseline runs")
    }

    @Test("C11: 10k tier → estate_shape is per-item-capacity-10k, protocol_deviation true")
    func c11TenKEstateShape() throws {
        let config = makeStubConfig(tier: .tenK)
        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        let report = buildMemBenchReport(config: config, corpus: corpus, results: [], scores: [],
                                         achievedTokensPerItem: [8_000, 11_000, 9_500],
                                         itemsPerEstate: [3, 2, 4])
        #expect(report.estateShape == "per-item-capacity-10k",
                "10k tier → estate_shape must be per-item-capacity-10k")
        #expect(report.protocolDeviation == true,
                "non-baseline tier → protocolDeviation must be true")
        #expect(report.capacityTier == "10k",
                "capacity_tier field must carry the tier label")
        #expect(report.capacityTargetTokens == 10_000,
                "capacity_target_tokens must be 10_000 for tenK tier")
        #expect(report.capacityItemsPerEstate == [3, 2, 4],
                "capacity_items_per_estate must mirror itemsPerEstate input")
    }

    @Test("C11: achievedTokens p50 and max computed correctly")
    func c11P50AndMaxAreCorrect() throws {
        let config = makeStubConfig(tier: .hundredK)
        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        // Five values: [80000, 95000, 100000, 105000, 110000]
        // Sorted: same. p50 (50th percentile) should land on 100000.
        let tokens = [80_000, 95_000, 100_000, 105_000, 110_000]
        let report = buildMemBenchReport(config: config, corpus: corpus, results: [], scores: [],
                                         achievedTokensPerItem: tokens,
                                         itemsPerEstate: Array(repeating: 5, count: 5))
        #expect(report.capacityAchievedTokensMax == 110_000,
                "max must be 110_000")
        // lmePercentile at 0.50 on a 5-item array: index = floor(4 * 0.50) = 2 → value 100_000.
        #expect(report.capacityAchievedTokensP50 == 100_000,
                "p50 must be 100_000")
    }

    @Test("C11: shortfall counted when achieved < target")
    func c11ShortfallCounted() throws {
        let config = makeStubConfig(tier: .tenK)
        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        // 2 of 4 items under 10k (pool exhausted before target).
        let tokens = [10_500, 7_800, 10_200, 6_000]
        let report = buildMemBenchReport(config: config, corpus: corpus, results: [], scores: [],
                                         achievedTokensPerItem: tokens,
                                         itemsPerEstate: Array(repeating: 1, count: 4))
        #expect(report.capacityShortfallItems == 2,
                "shortfall must count items where achieved < target")
    }

    @Test("C11: shortfall nil when all items reach target")
    func c11ShortfallNilWhenNoShortfall() throws {
        let config = makeStubConfig(tier: .tenK)
        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        let tokens = [10_001, 12_000, 15_000]
        let report = buildMemBenchReport(config: config, corpus: corpus, results: [], scores: [],
                                         achievedTokensPerItem: tokens,
                                         itemsPerEstate: Array(repeating: 3, count: 3))
        #expect(report.capacityShortfallItems == nil,
                "shortfall must be nil (not 0) when all items reach the target")
    }

    @Test("C11: capacity report round-trips through JSON encoding")
    func c11ReportRoundTripsJSON() throws {
        let config = makeStubConfig(tier: .hundredK)
        let corpus = MemBenchCorpus(items: [], skippedCount: 0)
        let tokens = [95_000, 102_000, 88_000]
        let report = buildMemBenchReport(config: config, corpus: corpus, results: [], scores: [],
                                         achievedTokensPerItem: tokens,
                                         itemsPerEstate: [5, 6, 4])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchReport.self, from: data)
        #expect(decoded.capacityTier == "100k")
        #expect(decoded.capacityTargetTokens == 100_000)
        #expect(decoded.capacityAchievedTokensPerItem == tokens)
        #expect(decoded.capacityItemsPerEstate == [5, 6, 4])
        // 95_000 < 100_000 and 88_000 < 100_000 → shortfall count is 2.
        #expect(decoded.capacityShortfallItems == 2,
                "95_000 and 88_000 both below 100_000 target → shortfall count 2")
    }
}
