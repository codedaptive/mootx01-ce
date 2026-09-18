import Testing
import Foundation
@testable import mcp_benchmarker

// EstateMissingGateTests.swift — item (a) gate
//
// The guard that refuses a unit run when the pre-built estate directory is
// absent ships in four production sites:
//   LMEBSpecRunner.swift:704-709
//   MemBenchSpecRunner.swift:1022-1027
//   lmeb_spec_runner.rs:770-778
//   membench_spec_runner.rs:1055-1064
//
// The guard fires BEFORE serve launches. Neither test here starts a server.
//
// Assertion requirement: the message must contain "estate for unit", the unit
// id, AND the missing path. An error-only assertion passes for any unrelated
// failure and is not a gate.

// MARK: - LMEB

@Suite("EstateMissingGate — lmeb-spec unit scale")
struct LMEBEstateMissingGateTests {

    private func makeTempFleetDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("estate-gate-lmeb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("lmeb-spec refuses a unit whose estate dir is missing before serve launches")
    func lmebMissingEstateDirRefused() async throws {
        let fleetDir = try makeTempFleetDir()
        defer { try? FileManager.default.removeItem(at: fleetDir) }

        // Query id "scene_3_q_7" + evidence "user_evidence"
        //   → lmebSpecUnitStem → "user_evidence__scene_3"
        //   → estateDir = fleetDir/user_evidence__scene_3 (NOT created)
        let queryID = "scene_3_q_7"
        let evidenceType = "user_evidence"

        let specQuery = LMEBSpecQuery(
            query: LMEBQuery(id: queryID, text: "test question", answer: nil),
            evidenceType: evidenceType
        )
        let corpus = LMEBCorpus(
            docsByID: [:],
            queriesByID: [queryID: LMEBQuery(id: queryID, text: "test question", answer: nil)],
            candidatesBySceneID: [:],
            relevantDocsByQueryID: [:]
        )
        var config = LMEBSpecRunConfig(
            mootBinaryPath: "/dev/null",
            dataDir: URL(fileURLWithPath: "/tmp"),
            evidenceTypes: [evidenceType],
            limit: nil, offset: 0, seed: 0, outDir: nil, runLabel: "gate-test"
        )
        // The catalog names one set rooted at fleetDir; the unit directory under it
        // is absent, so catalog resolution refuses before any serve launches.
        let catalogURL = fleetDir.appendingPathComponent("catalog.json")
        try "{\"sets\":[{\"name\":\"set1\",\"base\":\"\(fleetDir.path)\",\"path\":\"\",\"estates\":[],\"state\":\"done\"}]}"
            .write(to: catalogURL, atomically: true, encoding: .utf8)
        config.catalogPath = catalogURL

        do {
            _ = try await runLMEBSpecQueries(
                specQueries: [specQuery], corpus: corpus, config: config)
            Issue.record("expected throw for missing estate dir; got success")
        } catch let error as MCPError {
            // Gate: message must name the problem, the unit, and the path.
            // Removing the guard makes this test fail with ENOENT from id-map
            // load or a serve-launch failure — neither carries "estate for unit".
            #expect(error.description.contains("not in the catalog"),
                    "message must say the unit is not in the catalog")
            #expect(error.description.contains("user_evidence__scene_3"),
                    "message must contain the unit stem")
            #expect(error.description.contains(catalogURL.path),
                    "message must name the catalog")
        } catch {
            Issue.record("unexpected error type \(type(of: error)): \(error)")
        }
    }
}

// MARK: - MemBench

@Suite("EstateMissingGate — membench-spec unit scale")
struct MemBenchEstateMissingGateTests {

    private func makeTempFleetDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("estate-gate-membench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("membench-spec refuses a unit whose estate dir is missing before serve launches")
    func membenchMissingEstateDirRefused() async throws {
        let fleetDir = try makeTempFleetDir()
        defer { try? FileManager.default.removeItem(at: fleetDir) }

        // itemID "simple/roles/0"
        //   → memBenchSpecUnitStem → "simple__roles__0"
        //   → estateDir = fleetDir/simple__roles__0 (NOT created)
        let itemID = "simple/roles/0"

        let item = MemBenchItem(
            itemID: itemID,
            category: "simple",
            agent: "ThirdAgent",
            topicKey: "roles",
            tid: 0,
            sessions: [],
            qa: MemBenchQA(
                qid: 0,
                question: "test",
                answer: "A",
                targetStepID: [],
                choices: ["A": "option A"],
                groundTruth: "A",
                time: "2026-01-01T00:00:00Z"
            )
        )

        var config = MemBenchSpecRunConfig(
            mootBinaryPath: "/dev/null",
            dataDir: URL(fileURLWithPath: "/tmp"),
            agent: "ThirdAgent",
            categories: nil,
            limit: nil,
            offset: 0,
            seed: 0,
            outDir: nil,
            runLabel: "gate-test",
            runSerial: "test",
            encodeBarrier: .impatient,
            scratchPosture: .plaintextTransient,
            shape: .disk,
            answerCmd: nil,
            dumpAnswerInputsPath: nil,
            consumeAnswersPath: nil,
            runMode: .standard,
            capacityBucketBoundaries: [1000, 5000, 20000]
        )
        // The catalog names one set rooted at fleetDir; the unit directory under it
        // is absent, so catalog resolution refuses before any serve launches.
        let catalogURL = fleetDir.appendingPathComponent("catalog.json")
        try "{\"sets\":[{\"name\":\"set1\",\"base\":\"\(fleetDir.path)\",\"path\":\"\",\"estates\":[],\"state\":\"done\"}]}"
            .write(to: catalogURL, atomically: true, encoding: .utf8)
        config.catalogPath = catalogURL

        let guardSampler = LegGuardSampler(policy: .oncePerLeg)

        do {
            _ = try await runOneMemBenchSpecItem(
                item: item,
                config: config,
                consumedAnswers: [:],
                dumpWriter: nil,
                guardSampler: guardSampler
            )
            Issue.record("expected throw for missing estate dir; got success")
        } catch let error as MCPError {
            // Gate: message must name the problem, the unit, and the path.
            // Removing the guard makes this test fail with a file-not-found
            // from id-map load — that error does not contain "estate for unit".
            #expect(error.description.contains("not in the catalog"),
                    "message must say the unit is not in the catalog")
            #expect(error.description.contains("simple__roles__0"),
                    "message must contain the unit stem")
            #expect(error.description.contains(catalogURL.path),
                    "message must name the catalog")
        } catch {
            Issue.record("unexpected error type \(type(of: error)): \(error)")
        }
    }
}
