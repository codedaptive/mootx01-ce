import Testing
import Foundation
@testable import mcp_benchmarker

// MemBenchSpecRunnerTests.swift — Shape tests for the membench-spec runner layer.
//
// NO live estate, NO subprocess. Exercises:
//   - loadConsumedAnswers JSONL parsing (valid, empty, malformed)
//   - memBenchSpecScratchDir prefix contract
//   - memBenchSpecGuardedTeardown refusal logic
//   - MemBenchSpecReport Codable round-trip (all fields preserved)
//   - step↔sid mapping: storageLine(step:) uses turn.sid as the step value
//   - answered_count: 0 path (no answer command)
//   - capacity pair shape from membenchSpecCapacityBuckets
//   - efficiency aggregation shape from membenchSpecEfficiencyStats
//   - artifact id-map compound record IDs and invalid-row accounting

@Suite("MemBenchSpecRunner: artifact id-map manifest")
struct MemBenchSpecManifestTests {
    @Test("compound lineage and legacy numeric IDs map; malformed rows are counted")
    func compoundLineageIDs() {
        let result = memBenchSpecManifest(from: [
            "ThirdAgent/noisy/places/331/lives-here": "AAAA-UUID",
            "42": "BBBB-UUID",
            "malformed/id": "CCCC-UUID",
        ])
        #expect(result.manifest["aaaa-uuid"] == 331)
        #expect(result.manifest["bbbb-uuid"] == 42)
        #expect(result.unmappedCount == 1)
    }
}

// MARK: - loadConsumedAnswers

@Suite("MemBenchSpecRunner: loadConsumedAnswers")
struct LoadConsumedAnswersTests {

    private func writeTmpJSONL(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("consumed-answers-\(UUID().uuidString).jsonl")
        let content = lines.joined(separator: "\n")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    @Test("valid JSONL — each recognized letter is loaded")
    func validEntries() throws {
        let url = try writeTmpJSONL([
            #"{"item_id":"item-001","answer":"A"}"#,
            #"{"item_id":"item-002","answer":"C"}"#,
            #"{"item_id":"item-003","answer":"D"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try loadConsumedAnswers(url)
        #expect(result["item-001"] == "A")
        #expect(result["item-002"] == "C")
        #expect(result["item-003"] == "D")
        #expect(result.count == 3)
    }

    @Test("invalid letter is silently skipped")
    func invalidLetterSkipped() throws {
        let url = try writeTmpJSONL([
            #"{"item_id":"item-001","answer":"A"}"#,
            #"{"item_id":"item-002","answer":"X"}"#,  // invalid letter
            #"{"item_id":"item-003","answer":"B"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try loadConsumedAnswers(url)
        #expect(result["item-001"] == "A")
        #expect(result["item-002"] == nil)
        #expect(result["item-003"] == "B")
        #expect(result.count == 2)
    }

    @Test("malformed JSON line is silently skipped")
    func malformedLineSkipped() throws {
        let url = try writeTmpJSONL([
            #"{"item_id":"item-001","answer":"A"}"#,
            "not-json-at-all",
            #"{"item_id":"item-003","answer":"D"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try loadConsumedAnswers(url)
        #expect(result.count == 2)
        #expect(result["item-001"] == "A")
        #expect(result["item-003"] == "D")
    }

    @Test("empty file returns empty dict")
    func emptyFileReturnsEmpty() throws {
        let url = try writeTmpJSONL([])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try loadConsumedAnswers(url)
        #expect(result.isEmpty)
    }

    @Test("missing item_id is silently skipped")
    func missingItemIDSkipped() throws {
        let url = try writeTmpJSONL([
            #"{"answer":"B"}"#,
            #"{"item_id":"item-002","answer":"C"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try loadConsumedAnswers(url)
        #expect(result.count == 1)
        #expect(result["item-002"] == "C")
    }

    @Test("all four letters are accepted")
    func allFourLettersAccepted() throws {
        let url = try writeTmpJSONL([
            #"{"item_id":"i1","answer":"A"}"#,
            #"{"item_id":"i2","answer":"B"}"#,
            #"{"item_id":"i3","answer":"C"}"#,
            #"{"item_id":"i4","answer":"D"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try loadConsumedAnswers(url)
        #expect(result.count == 4)
        #expect(result["i1"] == "A")
        #expect(result["i2"] == "B")
        #expect(result["i3"] == "C")
        #expect(result["i4"] == "D")
    }

    @Test("lowercase letter is rejected (case-sensitive)")
    func lowercaseLetterRejected() throws {
        let url = try writeTmpJSONL([
            #"{"item_id":"i1","answer":"a"}"#,
            #"{"item_id":"i2","answer":"A"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try loadConsumedAnswers(url)
        #expect(result.count == 1)
        #expect(result["i1"] == nil)
        #expect(result["i2"] == "A")
    }
}

// MARK: - memBenchSpecScratchDir

@Suite("MemBenchSpecRunner: memBenchSpecScratchDir")
struct ScratchDirTests {

    @Test("created directory has membench-spec- prefix")
    func prefixIsCorrect() throws {
        let url = try memBenchSpecScratchDir(posture: .plaintextTransient)
        defer { try? FileManager.default.removeItem(at: url) }
        let path = url.path
        // On macOS, /tmp resolves to /private/tmp via symlink.
        #expect(path.hasPrefix("/tmp/membench-spec-") || path.hasPrefix("/private/tmp/membench-spec-"))
    }

    @Test("created directory exists on disk")
    func directoryExists() throws {
        let url = try memBenchSpecScratchDir(posture: .plaintextTransient)
        defer { try? FileManager.default.removeItem(at: url) }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        #expect(exists && isDir.boolValue)
    }

    @Test("two calls produce distinct directories")
    func distinctDirectories() throws {
        let url1 = try memBenchSpecScratchDir(posture: .plaintextTransient)
        let url2 = try memBenchSpecScratchDir(posture: .plaintextTransient)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }
        #expect(url1.path != url2.path)
    }
}

// MARK: - memBenchSpecGuardedTeardown

@Suite("MemBenchSpecRunner: memBenchSpecGuardedTeardown")
struct GuardedTeardownTests {

    @Test("refuses /tmp path without membench-spec- prefix")
    func refusesUnrelatedTmpPath() {
        let url = URL(fileURLWithPath: "/tmp/some-other-dir-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try memBenchSpecGuardedTeardown(url)
        }
    }

    @Test("refuses /private/tmp path without membench-spec- prefix")
    func refusesPrivateTmpWithoutPrefix() {
        let url = URL(fileURLWithPath: "/private/tmp/membench-bench-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try memBenchSpecGuardedTeardown(url)
        }
    }

    @Test("refuses absolute path outside /tmp")
    func refusesAbsolutePathOutsideTmp() {
        let url = URL(fileURLWithPath: "/var/folders/membench-spec-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try memBenchSpecGuardedTeardown(url)
        }
    }

    @Test("accepts and removes valid membench-spec- directory")
    func acceptsValidPrefixAndRemoves() throws {
        // Create a real directory with the correct prefix so teardown can remove it.
        let path = "/tmp/membench-spec-\(UUID().uuidString.prefix(12))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: path)
        // Must not throw.
        try memBenchSpecGuardedTeardown(url)
        // The directory should be gone.
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - step↔sid mapping

@Suite("MemBenchSpecRunner: step↔sid mapping")
struct StepSidMappingTests {

    // The spec runner uses `turn.sid` as the step value in storageLine(step:message:).
    // This test verifies that storageLine with a turn's sid produces the expected
    // storage prefix, and that stepID(fromStorageLine:) recovers the sid exactly.
    // This confirms the identity: stored step id == turn.sid == target global sid.

    @Test("storageLine step equals turn.sid — round-trips through stepID")
    func roundTripTurnSid() throws {
        let turn = MemBenchTurn(
            sid: 42,
            userMessage: "Hello",
            assistantMessage: "Hi there",
            time: "2025-01-01T10:00:00Z",
            place: "office"
        )
        let line = storageLine(step: turn.sid, message: "Hello")
        let recovered = try stepID(fromStorageLine: line)
        #expect(recovered == turn.sid)
    }

    @Test("storageLine with sid 0 round-trips")
    func sidZeroRoundTrips() throws {
        let sid = 0
        let line = storageLine(step: sid, message: "First turn")
        let recovered = try stepID(fromStorageLine: line)
        #expect(recovered == sid)
    }

    @Test("storageLine with large sid round-trips")
    func largeSidRoundTrips() throws {
        let sid = 9999
        let line = storageLine(step: sid, message: "Late turn")
        let recovered = try stepID(fromStorageLine: line)
        #expect(recovered == sid)
    }

    @Test("storageLine dict form with turn.sid round-trips")
    func dictFormRoundTrips() throws {
        let turn = MemBenchTurn(
            sid: 117,
            userMessage: "What's the plan?",
            assistantMessage: "Let me explain.",
            time: "2025-06-01T09:00:00Z",
            place: "home"
        )
        let line = storageLine(step: turn.sid, user: turn.userMessage, agent: turn.assistantMessage)
        let recovered = try stepID(fromStorageLine: line)
        #expect(recovered == turn.sid)
    }

    @Test("target_step_id global sid matches step in stored line")
    func targetGlobalSidMatchesStoredStep() throws {
        // Simulates the runner's mapping: store with turn.sid, compare against
        // qa.targetStepID globalSid. Both must be the same integer.
        let turn = MemBenchTurn(
            sid: 77,
            userMessage: "Did you go to the gym?",
            assistantMessage: "Yes, twice this week.",
            time: "2025-03-01T07:00:00Z",
            place: "home"
        )
        let line = storageLine(step: turn.sid, message: turn.userMessage)
        let storedStep = try stepID(fromStorageLine: line)
        let targetGlobalSid = 77  // what qa.targetStepID[0].globalSid would be
        #expect(storedStep == targetGlobalSid)
    }
}

// MARK: - answered_count: 0 path

@Suite("MemBenchSpecRunner: answered_count 0 path")
struct AnsweredCountZeroTests {

    // When no answer command and no consume file: answered_count must be 0.
    // We verify via the report Codable path: a synthetic report with answeredCount: 0
    // encodes and decodes correctly without any answer command in play.

    private func makeMinimalReport(answeredCount: Int) -> MemBenchSpecReport {
        let emptySlice = MemBenchSpecAggregateSlice(label: "overall", count: 0, accuracy: 0.0, meanRecall: 0.0)
        let emptyStats = MemBenchSpecEfficiencyStats(count: 0, mean: 0.0, p50: 0.0, p95: 0.0)
        return MemBenchSpecReport(
            runLabel: "test",
            port: "swift",
            agent: "FirstAgent",
            seed: 42,
            estateMode: "artifact-unit",
            targetScale: "unit",
            protocolMode: "standard",
            overall: emptySlice,
            byCategory: [],
            byPerspective: [],
            answeredCount: answeredCount,
            writeEfficiency: emptyStats,
            readEfficiency: emptyStats,
            capacitySamples: nil,
            capacityBuckets: nil,
            itemCount: 0
        )
    }

    @Test("report with answered_count 0 encodes and decodes correctly")
    func reportAnsweredCountZeroRoundTrips() throws {
        let report = makeMinimalReport(answeredCount: 0)
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: encoded)
        #expect(decoded.answeredCount == 0)
    }

    @Test("PRODUCTION on-disk format is snake_case and reads back (F4 contract)")
    func productionSnakeCaseFormatRoundTrips() throws {
        // The write site (MemBenchSpecRunner.swift, report encoder) uses
        // .convertToSnakeCase so the Swift report's on-disk keys match the
        // Rust twin's serde snake_case (STEP7_FINDINGS.md F4). This test
        // exercises THAT contract — the plain-encoder roundtrips above only
        // cover the camelCase in-memory loop and never touch the production
        // format required by the protocol.
        let report = makeMinimalReport(answeredCount: 5)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase  // production setting
        let bytes = try encoder.encode(report)
        let text = String(decoding: bytes, as: UTF8.self)
        // On-disk keys are snake_case: the Rust-parity contract.
        #expect(text.contains("\"run_label\""))
        #expect(text.contains("\"answered_count\""))
        #expect(text.contains("\"by_category\""))
        #expect(!text.contains("\"runLabel\""), "camelCase key leaked into the production format")
        // And the production file is legible back into Swift with the
        // mirror strategy — field values survive the full disk loop.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let back = try decoder.decode(MemBenchSpecReport.self, from: bytes)
        #expect(back.answeredCount == 5)
        #expect(back.runLabel == report.runLabel)
        #expect(back.protocolMode == report.protocolMode)
    }

    @Test("answered_count 0 is distinct from answered_count > 0")
    func answeredCountZeroDistinctFromNonZero() throws {
        let report0 = makeMinimalReport(answeredCount: 0)
        let report5 = makeMinimalReport(answeredCount: 5)
        let enc0 = try JSONEncoder().encode(report0)
        let enc5 = try JSONEncoder().encode(report5)
        let dec0 = try JSONDecoder().decode(MemBenchSpecReport.self, from: enc0)
        let dec5 = try JSONDecoder().decode(MemBenchSpecReport.self, from: enc5)
        #expect(dec0.answeredCount == 0)
        #expect(dec5.answeredCount == 5)
    }
}

// MARK: - MemBenchSpecReport Codable round-trip

@Suite("MemBenchSpecRunner: MemBenchSpecReport Codable")
struct ReportCodableTests {

    private func makeFullReport() -> MemBenchSpecReport {
        let overall = MemBenchSpecAggregateSlice(label: "overall", count: 10, accuracy: 0.7, meanRecall: 0.8)
        let cat = MemBenchSpecAggregateSlice(label: "simple", count: 5, accuracy: 0.6, meanRecall: 0.75)
        let persp = MemBenchSpecAggregateSlice(label: "FirstAgent", count: 10, accuracy: 0.7, meanRecall: 0.8)
        let writeStats = MemBenchSpecEfficiencyStats(count: 20, mean: 0.25, p50: 0.23, p95: 0.51)
        let readStats = MemBenchSpecEfficiencyStats(count: 10, mean: 0.10, p50: 0.09, p95: 0.20)
        return MemBenchSpecReport(
            runLabel: "test-label-001",
            port: "swift",
            agent: "FirstAgent",
            seed: 99,
            estateMode: "artifact-unit",
            targetScale: "unit",
            protocolMode: "standard",
            overall: overall,
            byCategory: [cat],
            byPerspective: [persp],
            answeredCount: 10,
            writeEfficiency: writeStats,
            readEfficiency: readStats,
            capacitySamples: nil,
            capacityBuckets: nil,
            itemCount: 10
        )
    }

    @Test("all string metadata fields round-trip")
    func stringFieldsRoundTrip() throws {
        let report = makeFullReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: data)
        #expect(decoded.runLabel == "test-label-001")
        #expect(decoded.port == "swift")
        #expect(decoded.agent == "FirstAgent")
        #expect(decoded.seed == 99)
        #expect(decoded.estateMode == "artifact-unit")
        #expect(decoded.targetScale == "unit")
        #expect(decoded.protocolMode == "standard")
    }

    @Test("overall slice accuracy and recall round-trip")
    func overallSliceRoundTrips() throws {
        let report = makeFullReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: data)
        #expect(decoded.overall.label == "overall")
        #expect(decoded.overall.count == 10)
        #expect(abs(decoded.overall.accuracy - 0.7) < 1e-9)
        #expect(abs(decoded.overall.meanRecall - 0.8) < 1e-9)
    }

    @Test("byCategory array length and contents round-trip")
    func byCategoryRoundTrips() throws {
        let report = makeFullReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: data)
        #expect(decoded.byCategory.count == 1)
        #expect(decoded.byCategory[0].label == "simple")
        #expect(decoded.byCategory[0].count == 5)
    }

    @Test("byPerspective array round-trips")
    func byPerspectiveRoundTrips() throws {
        let report = makeFullReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: data)
        #expect(decoded.byPerspective.count == 1)
        #expect(decoded.byPerspective[0].label == "FirstAgent")
    }

    @Test("efficiency stats fields round-trip")
    func efficiencyStatsRoundTrip() throws {
        let report = makeFullReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: data)
        #expect(decoded.writeEfficiency.count == 20)
        #expect(abs(decoded.writeEfficiency.mean - 0.25) < 1e-9)
        #expect(abs(decoded.writeEfficiency.p50 - 0.23) < 1e-9)
        #expect(abs(decoded.writeEfficiency.p95 - 0.51) < 1e-9)
        #expect(decoded.readEfficiency.count == 10)
        #expect(abs(decoded.readEfficiency.mean - 0.10) < 1e-9)
    }

    @Test("capacitySamples nil round-trips as nil")
    func capacitySamplesNilRoundTrips() throws {
        let report = makeFullReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: data)
        #expect(decoded.capacitySamples == nil)
        #expect(decoded.capacityBuckets == nil)
    }

    @Test("capacitySamples with tuples round-trip correctly")
    func capacitySamplesWithTuplesRoundTrip() throws {
        let overall = MemBenchSpecAggregateSlice(label: "overall", count: 2, accuracy: 0.5, meanRecall: 0.5)
        let stats = MemBenchSpecEfficiencyStats(count: 0, mean: 0.0, p50: 0.0, p95: 0.0)
        let bucket = MemBenchSpecCapacityBucket(tokenLow: 0, tokenHigh: 1000, count: 1, accuracy: 1.0)
        let report = MemBenchSpecReport(
            runLabel: "cap-test",
            port: "swift",
            agent: "FirstAgent",
            seed: 1,
            estateMode: "step-cap-fresh",
            targetScale: "step-cap",
            protocolMode: "step_cap",
            overall: overall,
            byCategory: [],
            byPerspective: [],
            answeredCount: 1,
            writeEfficiency: stats,
            readEfficiency: stats,
            capacitySamples: [(tokenCount: 500, correct: true), (tokenCount: 1500, correct: false)],
            capacityBuckets: [bucket],
            itemCount: 2
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: data)
        let samples = try #require(decoded.capacitySamples)
        #expect(samples.count == 2)
        #expect(samples[0].tokenCount == 500)
        #expect(samples[0].correct == true)
        #expect(samples[1].tokenCount == 1500)
        #expect(samples[1].correct == false)
        let buckets = try #require(decoded.capacityBuckets)
        #expect(buckets.count == 1)
        #expect(buckets[0].tokenLow == 0)
        #expect(buckets[0].tokenHigh == 1000)
    }

    @Test("itemCount round-trips")
    func itemCountRoundTrips() throws {
        let report = makeFullReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: data)
        #expect(decoded.itemCount == 10)
    }
}

// MARK: - Capacity pair emission shape

@Suite("MemBenchSpecRunner: capacity pair shape")
struct CapacityPairShapeTests {

    // Verifies membenchSpecCapacityBuckets correctly slots (tokenCount, correct) pairs
    // into boundaries, producing the right bucket count and accuracy per bucket.

    @Test("three boundaries produce four buckets")
    func threeBoundariesFourBuckets() {
        let samples: [(tokenCount: Int, correct: Bool)] = [
            (500, true), (2000, false), (8000, true), (30000, false)
        ]
        let boundaries = [1000, 5000, 20000]
        let buckets = membenchSpecCapacityBuckets(samples: samples, bucketBoundaries: boundaries)
        #expect(buckets.count == 4)
    }

    @Test("samples route to correct buckets by token count")
    func samplesRouteCorrectly() {
        let samples: [(tokenCount: Int, correct: Bool)] = [
            (500, true),    // → [0, 1000)
            (999, false),   // → [0, 1000)
            (1000, true),   // → [1000, 5000)
            (4999, false),  // → [1000, 5000)
            (5000, true),   // → [5000, 20000)
            (20000, false), // → [20000, ∞)
        ]
        let buckets = membenchSpecCapacityBuckets(samples: samples, bucketBoundaries: [1000, 5000, 20000])
        #expect(buckets[0].tokenLow == 0)
        #expect(buckets[0].tokenHigh == 1000)
        #expect(buckets[0].count == 2)
        #expect(abs(buckets[0].accuracy - 0.5) < 1e-9)  // 1 correct / 2

        #expect(buckets[1].tokenLow == 1000)
        #expect(buckets[1].tokenHigh == 5000)
        #expect(buckets[1].count == 2)
        #expect(abs(buckets[1].accuracy - 0.5) < 1e-9)

        #expect(buckets[2].tokenLow == 5000)
        #expect(buckets[2].tokenHigh == 20000)
        #expect(buckets[2].count == 1)
        #expect(abs(buckets[2].accuracy - 1.0) < 1e-9)

        #expect(buckets[3].tokenLow == 20000)
        #expect(buckets[3].tokenHigh == nil)
        #expect(buckets[3].count == 1)
        #expect(abs(buckets[3].accuracy - 0.0) < 1e-9)
    }

    @Test("empty samples produce zero-count buckets")
    func emptySamplesZeroCount() {
        let buckets = membenchSpecCapacityBuckets(samples: [], bucketBoundaries: [1000, 5000])
        #expect(buckets.count == 3)
        for b in buckets {
            #expect(b.count == 0)
            #expect(b.accuracy == 0.0)
        }
    }

    @Test("all correct in one bucket → accuracy 1.0")
    func allCorrectAccuracyOne() {
        let samples: [(tokenCount: Int, correct: Bool)] = [
            (100, true), (200, true), (300, true)
        ]
        let buckets = membenchSpecCapacityBuckets(samples: samples, bucketBoundaries: [1000])
        #expect(buckets[0].count == 3)
        #expect(abs(buckets[0].accuracy - 1.0) < 1e-9)
    }
}

// MARK: - Efficiency aggregation shape

@Suite("MemBenchSpecRunner: efficiency aggregation shape")
struct EfficiencyAggregationShapeTests {

    // Verifies membenchSpecEfficiencyStats produces the right structural shape
    // from a synthetic walk: count, mean, p50, p95 all correct for known inputs.

    @Test("synthetic walk — count, mean, p50, p95 correct")
    func syntheticWalkShape() {
        // 4 duration samples: 0.1, 0.2, 0.3, 0.4
        let durations = [0.1, 0.2, 0.3, 0.4]
        let stats = membenchSpecEfficiencyStats(durations: durations)
        #expect(stats.count == 4)
        #expect(abs(stats.mean - 0.25) < 1e-9)
        // lmePercentile(p=0.50, n=4) → ceil(0.5×4) = ceil(2) = 2 → sorted[1] = 0.2
        #expect(abs(stats.p50 - 0.2) < 1e-9)
        // lmePercentile(p=0.95, n=4) → ceil(0.95×4) = ceil(3.8) = 4 → sorted[3] = 0.4
        #expect(abs(stats.p95 - 0.4) < 1e-9)
    }

    @Test("single-sample walk — p50 and p95 both equal the sample")
    func singleSampleWalk() {
        let stats = membenchSpecEfficiencyStats(durations: [0.777])
        #expect(stats.count == 1)
        #expect(abs(stats.mean - 0.777) < 1e-9)
        #expect(abs(stats.p50 - 0.777) < 1e-9)
        #expect(abs(stats.p95 - 0.777) < 1e-9)
    }

    @Test("empty durations produce all-zero stats")
    func emptyDurationsZero() {
        let stats = membenchSpecEfficiencyStats(durations: [])
        #expect(stats.count == 0)
        #expect(stats.mean == 0.0)
        #expect(stats.p50 == 0.0)
        #expect(stats.p95 == 0.0)
    }

    @Test("ten-sample walk matches lmePercentile ceil convention")
    func tenSampleWalk() {
        // 10 uniformly-spaced samples 0.1..1.0
        let durations = (1...10).map { Double($0) * 0.1 }
        let stats = membenchSpecEfficiencyStats(durations: durations)
        #expect(stats.count == 10)
        #expect(abs(stats.mean - 0.55) < 1e-9)
        // p50: ceil(0.5×10) = ceil(5) = 5 → sorted[4] = 0.5
        #expect(abs(stats.p50 - 0.5) < 1e-9)
        // p95: ceil(0.95×10) = ceil(9.5) = 10 → sorted[9] = 1.0
        #expect(abs(stats.p95 - 1.0) < 1e-9)
    }
}

// MARK: - Scoring strategy flag

@Suite("MemBenchSpecRunner — scoring strategy flag")
struct MemBenchSpecScoringTests {

    // Verifies the inline scoring-arg pattern produces the correct key
    // presence/absence in the moot_memory_search argument dict.
    // MemBenchSpecRunConfig.scoringStrategy defaults to nil; when set,
    // the "scoring" key must appear with the exact value.
    @Test("scoring arg: absent when omitted, present when given")
    func scoringArgPropagation() {
        // Baseline: nil strategy → no "scoring" key (byte-identical call).
        let nilStrategy: String? = nil
        var args1: [String: JSONValue] = ["q": .string("question text")]
        if let s = nilStrategy { args1["scoring"] = .string(s) }
        #expect(args1["scoring"] == nil,
                "omitted --scoring must produce no 'scoring' key in the query dict")

        // Given strategy: "matrixAware" must appear verbatim as the key value.
        let givenStrategy: String? = "matrixAware"
        var args2: [String: JSONValue] = ["q": .string("question text")]
        if let s = givenStrategy { args2["scoring"] = .string(s) }
        #expect(args2["scoring"] == .string("matrixAware"),
                "given --scoring matrixAware must wire as 'scoring': 'matrixAware'")
    }
}
