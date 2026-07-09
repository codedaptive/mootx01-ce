import Foundation
import Testing
@testable import LatticeLib

private struct SemanticFixture: Decodable {
    struct Candidate: Decodable {
        let code: String
        let score: Int64
        let matchedFeatures: Int

        private enum CodingKeys: String, CodingKey {
            case code, score
            case matchedFeatures = "matched_features"
        }
    }

    struct Decision: Decodable {
        let code: String
        let mainClass: String
        let score: Int64
        let runnerUpScore: Int64
        let matchedFeatures: Int

        private enum CodingKeys: String, CodingKey {
            case code, score
            case mainClass = "main_class"
            case runnerUpScore = "runner_up_score"
            case matchedFeatures = "matched_features"
        }
    }

    struct Vector: Decodable {
        let input: String
        let candidates: [Candidate]
        let decision: Decision?
        let finalCode: String

        private enum CodingKeys: String, CodingKey {
            case input, candidates, decision
            case finalCode = "final_code"
        }
    }

    let modelSHA256: String
    let modelVersion: String
    let vectors: [Vector]

    private enum CodingKeys: String, CodingKey {
        case vectors
        case modelSHA256 = "model_sha256"
        case modelVersion = "model_version"
    }
}

@Suite("FDC semantic micro-ranker")
struct FDCSemanticRankerTests {
    private func resourceURL(
        _ name: String,
        extension fileExtension: String,
        sourceFile: String = #filePath
    ) -> URL {
        URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LatticeLib/Resources/\(name).\(fileExtension)")
    }

    private func loadFixture(sourceFile: String = #filePath) throws -> SemanticFixture {
        let url = URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rust/tests/fixtures/fdc_semantic_conformance.json")
        return try JSONDecoder().decode(SemanticFixture.self, from: Data(contentsOf: url))
    }

    @Test("Swift and Rust share exact top-k, hierarchy, and final-code vectors")
    func semanticConformance() throws {
        let fixture = try loadFixture()
        #expect(FDC.semanticModelVersion == fixture.modelVersion)
        #expect(FDC.semanticModelSHA256 == fixture.modelSHA256)
        #expect(!fixture.vectors.isEmpty)

        for vector in fixture.vectors {
            let expectedCandidates = vector.candidates.map {
                FDCSemanticCandidate(
                    code: $0.code, score: $0.score, matchedFeatures: $0.matchedFeatures)
            }
            #expect(FDC.semanticCandidates(vector.input, limit: 3) == expectedCandidates)

            let expectedDecision = vector.decision.map {
                FDCSemanticDecision(
                    code: $0.code,
                    mainClass: $0.mainClass,
                    score: $0.score,
                    runnerUpScore: $0.runnerUpScore,
                    matchedFeatures: $0.matchedFeatures)
            }
            #expect(FDC.semanticDecision(vector.input) == expectedDecision)
            #expect(FDC.encode(vector.input) == vector.finalCode)
        }
    }

    @Test("query repetition cannot change semantic ranking")
    func repetitionInvariant() {
        #expect(
            FDC.semanticCandidates("mortgage lender credit", limit: 8)
                == FDC.semanticCandidates("mortgage mortgage lender credit", limit: 8))
    }

    @Test("model loader rejects bytes that do not match pinned SHA-256")
    func modelHashValidation() throws {
        let metadata = try Data(contentsOf: resourceURL("FDCSemanticRanker", extension: "json"))
        let model = try Data(contentsOf: resourceURL("FDCSemanticRanker", extension: "bin"))
        #expect(FDCSemanticRanker(metadataData: metadata, modelData: model) != nil)
        var corrupted = model
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 1
        #expect(FDCSemanticRanker(metadataData: metadata, modelData: corrupted) == nil)
    }

    @Test("feature extraction pins non-ASCII boundaries and input caps")
    func featureContractEdges() {
        #expect(
            FDCSemanticRanker.features("caf biology", dimension: 16_384)
                == FDCSemanticRanker.features("caf\u{e9} biology", dimension: 16_384))
        let prefix = (0..<300).map { "term\($0)" }.joined(separator: " ")
        #expect(
            FDCSemanticRanker.features(prefix, dimension: 16_384)
                == FDCSemanticRanker.features(prefix + " ignoredtail", dimension: 16_384))
    }

    @Test("opt-in semantic classification throughput benchmark")
    func throughputBenchmark() throws {
        guard ProcessInfo.processInfo.environment["BENCHMARK_FDC_SEMANTIC"] == "1" else {
            return
        }
        let vectors = try loadFixture().vectors
        _ = FDC.encode(vectors[0].input)
        var checksum = 0
        let elapsed = ContinuousClock().measure {
            for index in 0..<1_000 {
                checksum += FDC.encode(vectors[index % vectors.count].input)?.count ?? 0
            }
        }
        #expect(checksum > 0)
        print("FDC semantic Swift release: 1000 classifications in \(elapsed)")
    }
}
