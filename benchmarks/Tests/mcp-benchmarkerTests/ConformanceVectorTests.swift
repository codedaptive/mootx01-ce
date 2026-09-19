import Testing
import Foundation
@testable import mcp_benchmarker

// ConformanceVectorTests.swift — Swift leg of the cross-language conformance check.
//
// Drives the SAME shared JSON vectors in benchmarks/conformance/ that
// the Rust leg drives. Same inputs → identical outputs on both legs is the
// conformance contract (BENCHMARKER_OPTIMIZER_CONTRACT.md §4).
//
// Swift leg of the cross-language conformance check. Same JSON vectors,
// same contract as the Rust leg.

// MARK: - Fixture path helpers

/// Resolves the path to `benchmarks/conformance/<filename>` from
/// this test file's location:
/// .../Tests/mcp-benchmarkerTests/ConformanceVectorTests.swift
///   → Tests/mcp-benchmarkerTests/
///   → Tests/
///   → benchmarks/ (package root)
///   → benchmarks/conformance/<filename>
private func conformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("conformance")
        .appendingPathComponent(filename)
}

private func loadJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else {
        throw NSError(domain: "ConformanceVectors", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected top-level object in \(url.lastPathComponent)"])
    }
    return dict
}

// MARK: - Divergence conformance vectors

@Suite struct ConformanceVectorDivergenceTests {

    @Test("Jaccard divergence: all shared vectors match Rust leg")
    func jaccardVectors() throws {
        let json = try loadJSON(conformancePath("divergence_vectors.json"))
        let cases = try #require(json["jaccard"] as? [[String: Any]])
        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let expectedArr = (c["expected"] as? [String]) ?? []
            let gotArr = (c["got"] as? [String]) ?? []
            let expectedResult = try #require(c["result"] as? Double)
            let actual = jaccardDivergence(expected: Set(expectedArr), got: Set(gotArr))
            #expect(
                abs(actual - expectedResult) < 1e-9,
                "jaccard vector '\(id)': expected \(expectedResult), got \(actual)"
            )
        }
    }

    @Test("Rank divergence: all shared vectors match Rust leg")
    func rankVectors() throws {
        let json = try loadJSON(conformancePath("divergence_vectors.json"))
        let cases = try #require(json["rank"] as? [[String: Any]])
        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let expectedArr = (c["expected"] as? [String]) ?? []
            let gotArr = (c["got"] as? [String]) ?? []
            let expectedResult = try #require(c["result"] as? Double)
            let actual = rankDivergence(expected: expectedArr, got: gotArr)
            #expect(
                abs(actual - expectedResult) < 1e-9,
                "rank vector '\(id)': expected \(expectedResult), got \(actual)"
            )
        }
    }
}

// MARK: - DegeneracyGuard conformance vectors

@Suite struct ConformanceVectorGuardTests {

    @Test("classify: all shared vectors match Rust leg")
    func classifyVectors() throws {
        let json = try loadJSON(conformancePath("guard_vectors.json"))
        let cases = try #require(json["classify_cases"] as? [[String: Any]])
        let guard_ = DegeneracyGuard()

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let expectedVerdict = try #require(c["expected_verdict"] as? String)
            let probeRankingsRaw = try #require(c["probe_rankings"] as? [[String]])
            let verdict = guard_.classify(probeRankings: probeRankingsRaw)

            let discriminant: String
            switch verdict {
            case .healthy:                      discriminant = "healthy"
            case .queryInvariant:               discriminant = "queryInvariant"
            case .degradedFallback:             discriminant = "degradedFallback"
            case .confirmationContradiction:    discriminant = "confirmationContradiction"
            }

            #expect(
                discriminant == expectedVerdict,
                "classify vector '\(id)': expected '\(expectedVerdict)', got '\(discriminant)'"
            )
        }
    }

    @Test("checkFallback: all shared vectors match Rust leg")
    func fallbackVectors() throws {
        let json = try loadJSON(conformancePath("guard_vectors.json"))
        let cases = try #require(json["fallback_cases"] as? [[String: Any]])
        let guard_ = DegeneracyGuard()

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let expected = try #require(c["expected"] as? Bool)
            let textBlocks = (c["text_blocks"] as? [String]) ?? []
            let actual = guard_.checkFallback(textBlocks: textBlocks)
            #expect(actual == expected, "fallback vector '\(id)': expected \(expected), got \(actual)")
        }
    }

    @Test("checkConfirmation: all shared vectors match Rust leg")
    func confirmationVectors() throws {
        let json = try loadJSON(conformancePath("guard_vectors.json"))
        let cases = try #require(json["confirmation_cases"] as? [[String: Any]])
        let guard_ = DegeneracyGuard()

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let expected = try #require(c["expected"] as? Bool)
            let confirmedCount = try #require(c["confirmed_count"] as? Int)
            let total = try #require(c["total"] as? Int)
            let recall = try #require(c["recall"] as? Double)
            let actual = guard_.checkConfirmation(confirmedCount: confirmedCount,
                                                  total: total,
                                                  recall: recall)
            #expect(actual == expected, "confirmation vector '\(id)': expected \(expected), got \(actual)")
        }
    }
}

// MARK: - Token efficiency conformance vectors (LME-03)

@Suite struct ConformanceVectorTokenEfficiencyTests {

    @Test("lmeEstimateTokens: all shared vectors match Rust leg")
    func tokenEstimatorVectors() throws {
        let json = try loadJSON(conformancePath("token_efficiency_vectors.json"))
        let cases = try #require(json["token_estimator_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let input = try #require(c["input"] as? String)
            let expected = try #require(c["expected_tokens"] as? Int)
            let actual = lmeEstimateTokens(input)
            #expect(
                actual == expected,
                "token estimator vector '\(id)': expected \(expected), got \(actual)"
            )
        }
    }

    @Test("lmeEvidenceHit: all shared vectors match Rust leg")
    func evidenceHitVectors() throws {
        let json = try loadJSON(conformancePath("token_efficiency_vectors.json"))
        let cases = try #require(json["evidence_hit_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let evidenceText = try #require(c["evidence_text"] as? String)
            let payloadText = try #require(c["payload_text"] as? String)
            let expected = try #require(c["expected_hit"] as? Bool)
            let actual = lmeEvidenceHit(evidenceText: evidenceText, payloadText: payloadText)
            #expect(
                actual == expected,
                "evidence hit vector '\(id)': expected \(expected), got \(actual)"
            )
        }
    }
}
