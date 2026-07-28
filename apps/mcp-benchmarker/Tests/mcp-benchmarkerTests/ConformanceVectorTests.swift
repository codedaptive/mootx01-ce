import Testing
import Foundation
@testable import mcp_benchmarker

// ConformanceVectorTests.swift — Swift leg of the cross-language conformance check.
//
// Drives the SAME shared JSON vectors in tools/mcp-benchmarker/conformance/ that
// the Rust leg drives. Same inputs → identical outputs on both legs is the
// conformance contract (BENCHMARKER_OPTIMIZER_CONTRACT.md §4).
//
// Swift leg of the cross-language conformance check. Same JSON vectors,
// same contract as the Rust leg.

// MARK: - Fixture path helpers

/// Resolves the path to `tools/mcp-benchmarker/conformance/<filename>` from
/// this test file's location:
/// .../Tests/mcp-benchmarkerTests/ConformanceVectorTests.swift
///   → Tests/mcp-benchmarkerTests/
///   → Tests/
///   → tools/mcp-benchmarker/ (package root)
///   → tools/mcp-benchmarker/conformance/<filename>
private func conformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("conformance")
        .appendingPathComponent(filename)
}

/// Resolves a path to a shipped manifest: `tools/mcp-benchmarker/manifests/<filename>`.
private func manifestPath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("manifests")
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

// MARK: - CapabilityManifest conformance vectors

@Suite struct ConformanceVectorManifestTests {

    @Test("Shipped mempalace.json: Swift decode matches conformance vector")
    func mempalaceManifestVector() throws {
        let data = try Data(contentsOf: manifestPath("mempalace.json"))
        let manifest = try CapabilityManifest.decode(from: data)

        let json = try loadJSON(conformancePath("manifest_vectors.json"))
        let manifests = try #require(json["manifests"] as? [[String: Any]])
        let vec = try #require(manifests.first(where: { ($0["id"] as? String) == "mempalace" }))
        let expected = try #require(vec["expected"] as? [String: Any])

        #expect(manifest.schemaVersion == (expected["schema_version"] as? Int))
        #expect(manifest.product.id == (expected["product_id"] as? String))
        #expect(manifest.product.provenance.rawValue == (expected["provenance"] as? String))
        #expect(manifest.calls.count == (expected["call_count"] as? Int))

        let calls = try #require(expected["calls"] as? [String: Any])

        // write
        let expectedWrite = try #require(calls["write"] as? [String: Any])
        let write = try #require(manifest.calls["write"])
        #expect(write.tool == (expectedWrite["tool"] as? String))
        #expect(write.technique == (expectedWrite["technique"] as? [String]))
        #expect(write.unmatched == (expectedWrite["unmatched"] as? Bool))
        let expectedConstantArgs = (expectedWrite["constant_args"] as? [String: String]) ?? [:]
        #expect(write.constantArgs == expectedConstantArgs)

        // query
        let expectedQuery = try #require(calls["query"] as? [String: Any])
        let query = try #require(manifest.calls["query"])
        #expect(query.tool == (expectedQuery["tool"] as? String))
        #expect(query.technique == (expectedQuery["technique"] as? [String]))

        // dispatch table
        let table = manifest.resolveDispatchTable()
        let dispatchVec = try #require(expected["dispatch_table"] as? [String: Any])
        let dispatchQueryVec = try #require(dispatchVec["query"] as? [String: Any])
        let dq = try #require(table["query"])
        #expect(dq.toolName == (dispatchQueryVec["tool_name"] as? String))
        #expect(dq.provenance.rawValue == (dispatchQueryVec["provenance"] as? String))
    }

    @Test("Shipped mem0.json: Swift decode matches conformance vector")
    func mem0ManifestVector() throws {
        let data = try Data(contentsOf: manifestPath("mem0.json"))
        let manifest = try CapabilityManifest.decode(from: data)

        let json = try loadJSON(conformancePath("manifest_vectors.json"))
        let manifests = try #require(json["manifests"] as? [[String: Any]])
        let vec = try #require(manifests.first(where: { ($0["id"] as? String) == "mem0" }))
        let expected = try #require(vec["expected"] as? [String: Any])

        #expect(manifest.product.id == (expected["product_id"] as? String))
        #expect(manifest.product.provenance.rawValue == (expected["provenance"] as? String))
        #expect(manifest.calls.count == (expected["call_count"] as? Int))

        let calls = try #require(expected["calls"] as? [String: Any])
        let expectedWrite = try #require(calls["write"] as? [String: Any])
        let write = try #require(manifest.calls["write"])
        #expect(write.tool == (expectedWrite["tool"] as? String))
        #expect(write.technique == (expectedWrite["technique"] as? [String]))

        let expectedQuery = try #require(calls["query"] as? [String: Any])
        let query = try #require(manifest.calls["query"])
        #expect(query.tool == (expectedQuery["tool"] as? String))
        #expect(query.technique == (expectedQuery["technique"] as? [String]))
    }

    @Test("Shipped gbrain.json: Swift decode matches conformance vector")
    func gbrainManifestVector() throws {
        let data = try Data(contentsOf: manifestPath("gbrain.json"))
        let manifest = try CapabilityManifest.decode(from: data)

        let json = try loadJSON(conformancePath("manifest_vectors.json"))
        let manifests = try #require(json["manifests"] as? [[String: Any]])
        let vec = try #require(manifests.first(where: { ($0["id"] as? String) == "gbrain" }))
        let expected = try #require(vec["expected"] as? [String: Any])

        #expect(manifest.product.id == (expected["product_id"] as? String))
        #expect(manifest.product.provenance.rawValue == (expected["provenance"] as? String))
        #expect(manifest.calls.count == (expected["call_count"] as? Int))

        let calls = try #require(expected["calls"] as? [String: Any])
        let expectedThink = try #require(calls["think"] as? [String: Any])
        let think = try #require(manifest.calls["think"])
        #expect(think.tool == (expectedThink["tool"] as? String))
        #expect(think.unmatched == (expectedThink["unmatched"] as? Bool))
        #expect(think.technique == (expectedThink["technique"] as? [String]))
    }

    @Test("Manifest error cases: each error JSON produces the expected error variant")
    func manifestErrorCases() throws {
        let json = try loadJSON(conformancePath("manifest_vectors.json"))
        let errorCases = try #require(json["error_cases"] as? [[String: Any]])

        for c in errorCases {
            let id = c["id"] as? String ?? "(unknown)"
            let rawJSON = try #require(c["json"] as? String)
            let expectedError = try #require(c["expected_error"] as? String)
            let data = try #require(rawJSON.data(using: .utf8))

            do {
                _ = try CapabilityManifest.decode(from: data)
                Issue.record("error case '\(id)': expected \(expectedError) but decode succeeded")
            } catch let err as ManifestValidationError {
                switch (expectedError, err) {
                case ("unknownSchemaVersion", .unknownSchemaVersion): break
                case ("unknownProvenance", .unknownProvenance): break
                case ("unknownTechnique", .unknownTechnique): break
                case ("emptyTechniqueList", .emptyTechniqueList): break
                case ("requiredFieldMissing", .requiredFieldMissing): break
                default:
                    Issue.record("error case '\(id)': expected \(expectedError), got \(err)")
                }
            } catch {
                Issue.record("error case '\(id)': got unexpected error type \(error)")
            }
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
