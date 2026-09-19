import Testing
import Foundation
@testable import mcp_benchmarker

// LMEBSpecMetricsTests.swift — conformance and unit tests for LMEBSpecMetrics.swift.
//
// Pins the Swift leg against conformance/lmeb-spec/metric_vectors.json.
// Both ports (Swift + Rust) must produce identical numbers to within 1e-9.
//
// Spec references: LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md §A1, §A3, §A4.

// MARK: - Fixture path helper

/// Resolves `benchmarks/conformance/lmeb-spec/<filename>` from this test file.
///   .../Tests/mcp-benchmarkerTests/LMEBSpecMetricsTests.swift
///     → mcp-benchmarkerTests/ (1st deletingLastPathComponent)
///     → Tests/               (2nd)
///     → benchmarks/           (3rd = package root)
///     → benchmarks/conformance/lmeb-spec/<filename>
private func lmebSpecConformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("conformance")
        .appendingPathComponent("lmeb-spec")
        .appendingPathComponent(filename)
}

private func loadLMEBSpecVectors(file: String = #filePath) throws -> [String: Any] {
    let url = lmebSpecConformancePath("metric_vectors.json", file: file)
    let data = try Data(contentsOf: url)
    let obj  = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else {
        throw NSError(domain: "LMEBSpecVectors", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected top-level JSON object"])
    }
    return dict
}

// MARK: - §A3 nDCG conformance

@Suite("LMEBSpec metrics: nDCG conformance vectors")
struct LMEBSpecNDCGConformanceTests {

    /// Runs every nDCG case in the conformance JSON against Swift's lmebSpecNDCG.
    @Test("All nDCG_cases: Swift leg matches expected within 1e-9")
    func allNDCGCases() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["ndcg_cases"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"] as? String ?? "(unknown)"
            let ranked   = (c["ranked_doc_ids"]  as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])
            let k        = c["k"] as? Int ?? 10
            let expected = try #require(c["ndcg"] as? Double, "case \(id) missing 'ndcg'")

            let got = lmebSpecNDCG(rankedDocIDs: ranked, relevantDocIDs: relevant, k: k)
            #expect(abs(got - expected) < 1e-9,
                    "nDCG@\(k) mismatch case '\(id)': got \(got), expected \(expected)")
        }
    }
}

// MARK: - §A3 AP conformance

@Suite("LMEBSpec metrics: AP conformance vectors")
struct LMEBSpecAPConformanceTests {

    @Test("All ap_cases: Swift leg matches expected within 1e-9")
    func allAPCases() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["ap_cases"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"] as? String ?? "(unknown)"
            let ranked   = (c["ranked_doc_ids"]  as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])
            let k        = c["k"] as? Int ?? 10
            let expected = try #require(c["ap"] as? Double, "case \(id) missing 'ap'")

            let got = lmebSpecAP(rankedDocIDs: ranked, relevantDocIDs: relevant, k: k)
            #expect(abs(got - expected) < 1e-9,
                    "AP@\(k) mismatch case '\(id)': got \(got), expected \(expected)")
        }
    }
}

// MARK: - §A3 Recall conformance

@Suite("LMEBSpec metrics: Recall conformance vectors")
struct LMEBSpecRecallConformanceTests {

    @Test("All recall_cases: Swift leg matches expected within 1e-9")
    func allRecallCases() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["recall_cases"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"] as? String ?? "(unknown)"
            let ranked   = (c["ranked_doc_ids"]  as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])

            let e1  = try #require(c["recall_at_1"]  as? Double, "case \(id) missing recall_at_1")
            let e5  = try #require(c["recall_at_5"]  as? Double, "case \(id) missing recall_at_5")
            let e10 = try #require(c["recall_at_10"] as? Double, "case \(id) missing recall_at_10")

            #expect(abs(lmebSpecRecall(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 1)  - e1)  < 1e-9,
                    "Recall@1 mismatch '\(id)'")
            #expect(abs(lmebSpecRecall(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 5)  - e5)  < 1e-9,
                    "Recall@5 mismatch '\(id)'")
            #expect(abs(lmebSpecRecall(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 10) - e10) < 1e-9,
                    "Recall@10 mismatch '\(id)'")
        }
    }
}

// MARK: - §A3 Precision conformance

@Suite("LMEBSpec metrics: Precision conformance vectors")
struct LMEBSpecPrecisionConformanceTests {

    @Test("All precision_cases: Swift leg matches expected within 1e-9")
    func allPrecisionCases() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["precision_cases"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"] as? String ?? "(unknown)"
            let ranked   = (c["ranked_doc_ids"]  as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])

            let e1  = try #require(c["precision_at_1"]  as? Double, "case \(id) missing precision_at_1")
            let e5  = try #require(c["precision_at_5"]  as? Double, "case \(id) missing precision_at_5")
            let e10 = try #require(c["precision_at_10"] as? Double, "case \(id) missing precision_at_10")

            #expect(abs(lmebSpecPrecision(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 1)  - e1)  < 1e-9,
                    "Precision@1 mismatch '\(id)'")
            #expect(abs(lmebSpecPrecision(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 5)  - e5)  < 1e-9,
                    "Precision@5 mismatch '\(id)'")
            #expect(abs(lmebSpecPrecision(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 10) - e10) < 1e-9,
                    "Precision@10 mismatch '\(id)'")
        }
    }
}

// MARK: - §A3 MRR conformance

@Suite("LMEBSpec metrics: MRR@k conformance vectors")
struct LMEBSpecMRRConformanceTests {

    @Test("All mrr_cases with mrr_at_k fields: Swift leg matches expected within 1e-9")
    func allMRRCases() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["mrr_cases"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"] as? String ?? "(unknown)"
            let ranked   = (c["ranked_doc_ids"]  as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])

            // Single-k case (mrr_beyond_k_cutoff)
            if let k = c["k"] as? Int, let expected = c["mrr"] as? Double {
                let got = lmebSpecMRR(rankedDocIDs: ranked, relevantDocIDs: relevant, k: k)
                #expect(abs(got - expected) < 1e-9, "MRR@\(k) mismatch '\(id)'")
                continue
            }

            // Multi-k case (mrr_at_1, mrr_at_5, mrr_at_10)
            if let e1  = c["mrr_at_1"]  as? Double,
               let e5  = c["mrr_at_5"]  as? Double,
               let e10 = c["mrr_at_10"] as? Double {
                #expect(abs(lmebSpecMRR(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 1)  - e1)  < 1e-9,
                        "MRR@1 mismatch '\(id)'")
                #expect(abs(lmebSpecMRR(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 5)  - e5)  < 1e-9,
                        "MRR@5 mismatch '\(id)'")
                #expect(abs(lmebSpecMRR(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 10) - e10) < 1e-9,
                        "MRR@10 mismatch '\(id)'")
            }
        }
    }
}

// MARK: - §A3 R_cap conformance (None propagation)

@Suite("LMEBSpec metrics: R_cap conformance vectors")
struct LMEBSpecRCapConformanceTests {

    /// Verifies R_cap@k with special attention to None when zero relevant docs (§A3).
    @Test("All rcap_cases: None propagation and values match metric.py semantics")
    func allRCapCases() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["rcap_cases"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"] as? String ?? "(unknown)"
            let ranked   = (c["ranked_doc_ids"]  as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])

            // rcap_at_k can be null (None) or a Double.
            let checkK = { (k: Int, jsonKey: String) in
                if c.keys.contains(jsonKey) {
                    let raw = c[jsonKey]
                    let got = lmebSpecRCap(rankedDocIDs: ranked, relevantDocIDs: relevant, k: k)
                    if raw is NSNull || raw == nil {
                        // Expected nil (zero relevant docs)
                        #expect(got == nil,
                                "R_cap@\(k) for '\(id)' expected nil, got \(String(describing: got))")
                    } else if let expected = raw as? Double {
                        #expect(got != nil,
                                "R_cap@\(k) for '\(id)' expected \(expected), got nil")
                        if let v = got {
                            // §A3: rounding to 5 decimals at aggregation; raw value within 1e-4
                            // (the rcap_three_relevant case uses rounded expected values).
                            #expect(abs(v - expected) < 1e-4,
                                    "R_cap@\(k) mismatch '\(id)': got \(v), expected \(expected)")
                        }
                    }
                }
            }

            checkK(1,  "rcap_at_1")
            checkK(5,  "rcap_at_5")
            checkK(10, "rcap_at_10")
            checkK(25, "rcap_at_25")
            checkK(50, "rcap_at_50")
        }
    }

    /// R_cap macro average ignores None (§A3, metric.py). All-None → None.
    @Test("rcap_macro_average_cases: None ignored in average; all-None → None")
    func rCapMacroAverageCases() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["rcap_macro_average_cases"] as? [[String: Any]])

        for c in cases {
            let id  = c["id"] as? String ?? "(unknown)"
            let raw = c["per_query_values"] as? [Any] ?? []
            let perQuery: [Double?] = raw.map { v in
                if v is NSNull { return nil }
                return v as? Double
            }
            let expectedRaw = c["expected_avg"]
            let expectedNil = (expectedRaw is NSNull || expectedRaw == nil)
            let expectedVal = expectedRaw as? Double

            // Macro average: ignore nil, mean of rest; all-nil → nil.
            let valid = perQuery.compactMap { $0 }
            let avg: Double? = valid.isEmpty ? nil : (valid.reduce(0, +) / Double(valid.count))
            let rounded: Double? = avg.map { (($0 * 1e5).rounded() / 1e5) }

            if expectedNil {
                #expect(rounded == nil,
                        "rcap_macro_avg '\(id)': expected nil, got \(String(describing: rounded))")
            } else if let ev = expectedVal {
                #expect(rounded != nil,
                        "rcap_macro_avg '\(id)': expected \(ev), got nil")
                if let rv = rounded {
                    #expect(abs(rv - ev) < 1e-5,
                            "rcap_macro_avg '\(id)': got \(rv), expected \(ev)")
                }
            }
        }
    }
}

// MARK: - §A3 Options conformance

@Suite("LMEBSpec metrics: evaluation options conformance")
struct LMEBSpecOptionsConformanceTests {

    /// Verifies skip_first_result filter (§A3).
    @Test("skip_first_result_cases: rank-1 drop matches expected metrics")
    func skipFirstResultCases() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["skip_first_result_cases"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"] as? String ?? "(unknown)"
            let ranked   = (c["ranked_doc_ids"] as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])
            let queryID  = c["query_id"] as? String ?? ""
            let opts     = LMEBSpecOptions(skipFirstResult: true, ignoreIdenticalIds: false)
            let filtered = lmebSpecApplyOptions(rankedDocIDs: ranked, queryID: queryID, options: opts)

            // Verify after_filter if present
            if let expectedFilter = c["after_filter"] as? [String] {
                #expect(filtered == expectedFilter,
                        "skip_first_result '\(id)' filter mismatch: got \(filtered), expected \(expectedFilter)")
            }

            if let eNDCG5 = c["ndcg_at_5"] as? Double {
                let v = lmebSpecNDCG(rankedDocIDs: filtered, relevantDocIDs: relevant, k: 5)
                #expect(abs(v - eNDCG5) < 1e-9, "nDCG@5 '\(id)': got \(v), expected \(eNDCG5)")
            }
            if let eRecall5 = c["recall_at_5"] as? Double {
                let v = lmebSpecRecall(rankedDocIDs: filtered, relevantDocIDs: relevant, k: 5)
                #expect(abs(v - eRecall5) < 1e-9, "Recall@5 '\(id)': got \(v)")
            }
            if let eRCap5Raw = c["rcap_at_5"] {
                let v = lmebSpecRCap(rankedDocIDs: filtered, relevantDocIDs: relevant, k: 5)
                if eRCap5Raw is NSNull {
                    #expect(v == nil, "R_cap@5 '\(id)' should be nil")
                } else if let e = eRCap5Raw as? Double {
                    #expect(v.map { abs($0 - e) < 1e-9 } ?? false, "R_cap@5 '\(id)': got \(String(describing: v))")
                }
            }
        }
    }

    /// Verifies ignore_identical_ids filter (§A3).
    @Test("ignore_identical_ids_cases: self-removal from ranked list matches expected metrics")
    func ignoreIdenticalIdsCases() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["ignore_identical_ids_cases"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"] as? String ?? "(unknown)"
            let ranked   = (c["ranked_doc_ids"]  as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])
            let queryID  = c["query_id"] as? String ?? ""
            let opts     = LMEBSpecOptions(skipFirstResult: false, ignoreIdenticalIds: true)
            let filtered = lmebSpecApplyOptions(rankedDocIDs: ranked, queryID: queryID, options: opts)

            if let expectedFilter = c["after_filter"] as? [String] {
                #expect(filtered == expectedFilter,
                        "ignore_ids '\(id)' filter: got \(filtered), expected \(expectedFilter)")
            }
            if let eNDCG1 = c["ndcg_at_1"] as? Double {
                let v = lmebSpecNDCG(rankedDocIDs: filtered, relevantDocIDs: relevant, k: 1)
                #expect(abs(v - eNDCG1) < 1e-9, "nDCG@1 '\(id)': got \(v), expected \(eNDCG1)")
            }
        }
    }
}

// MARK: - §A1/§A3 Two-level aggregation conformance

@Suite("LMEBSpec metrics: two-level aggregation conformance")
struct LMEBSpecAggregationConformanceTests {

    /// Verifies the two-level aggregation (subset macro mean → task mean) from the conformance JSON.
    @Test("aggregation_cases: per-subset mean and task mean match expected nDCG@10 values")
    func aggregationTwoLevel() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["aggregation_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            guard let subsetDefs = c["subsets"] as? [[String: Any]] else { continue }

            var subsetMetrics: [LMEBSpecSubsetMetrics] = []

            for subsetDef in subsetDefs {
                let subsetName = subsetDef["subset_name"] as? String ?? ""
                let queryDefs  = subsetDef["queries"] as? [[String: Any]] ?? []

                let perQuery: [LMEBSpecQueryMetrics] = queryDefs.map { qd in
                    let ranked   = (qd["ranked_doc_ids"]   as? [String]) ?? []
                    let relevant = Set((qd["relevant_doc_ids"] as? [String]) ?? [])
                    let queryID  = qd["query_id"] as? String ?? ""
                    return lmebSpecPerQueryMetrics(
                        rankedDocIDs: ranked,
                        relevantDocIDs: relevant,
                        queryID: queryID
                    )
                }

                let sm = lmebSpecSubsetMetrics(queries: perQuery, subsetName: subsetName)
                subsetMetrics.append(sm)

                // Verify per-subset expected nDCG@10 if present.
                if let eNDCG10 = subsetDef["expected_ndcg_at_10"] as? Double {
                    let got = sm.ndcg[10] ?? -1.0
                    #expect(abs(got - eNDCG10) < 1e-9,
                            "subset '\(subsetName)' nDCG@10 in '\(id)': got \(got), expected \(eNDCG10)")
                }

                // Verify per-subset expected R_cap@5 if present (may be null).
                if subsetDef.keys.contains("expected_rcap_at_5") {
                    let rawRC = subsetDef["expected_rcap_at_5"]
                    let gotRC = sm.rCap[5]
                    if rawRC is NSNull || rawRC == nil {
                        let gotOpt = sm.rCap[5]
                        #expect(gotOpt == nil || gotOpt == Optional<Double>.none,
                                "subset '\(subsetName)' R_cap@5 in '\(id)' should be nil, got \(String(describing: gotOpt))")
                    } else if let ev = rawRC as? Double, let gv = gotRC {
                        #expect(gv.map { abs($0 - ev) < 1e-5 } ?? false,
                                "subset '\(subsetName)' R_cap@5 in '\(id)': got \(String(describing: gv)), expected \(ev)")
                    }
                }
            }

            let task = lmebSpecTaskMetrics(subsets: subsetMetrics)

            if let eTask10 = c["expected_task_ndcg_at_10"] as? Double {
                let got = task.ndcgAt10
                #expect(abs(got - eTask10) < 1e-9,
                        "task nDCG@10 in '\(id)': got \(got), expected \(eTask10)")
            }
            if let eTaskRC5Raw = c["expected_task_rcap_at_5"] {
                if eTaskRC5Raw is NSNull {
                    let got = task.rCap[5]
                    #expect(got == nil || got == Optional<Double>.none,
                            "task R_cap@5 in '\(id)' should be nil")
                } else if let ev = eTaskRC5Raw as? Double {
                    let got = task.rCap[5]
                    #expect(got?.map { abs($0 - ev) < 1e-5 } ?? false,
                            "task R_cap@5 in '\(id)': expected \(ev), got \(String(describing: got))")
                }
            }
        }
    }
}

// MARK: - §A4 Instruction constants conformance

@Suite("LMEBSpec metrics: §A4 instruction constants")
struct LMEBSpecInstructionConformanceTests {

    /// Verifies all six verbatim instruction strings match the conformance JSON (§A4).
    @Test("All six §A4 instruction strings are present and verbatim")
    func allSixInstructionStrings() throws {
        let json = try loadLMEBSpecVectors()
        let cases = try #require(json["instruction_cases"] as? [[String: Any]])
        let c = try #require(cases.first, "instruction_cases must have at least one entry")
        let expected = try #require(c["instructions"] as? [String: String])

        for (subset, instruction) in expected {
            let got = LMEBSubsetInstructions.bySubset[subset]
            #expect(got == instruction,
                    "Instruction for '\(subset)': got '\(String(describing: got))', expected '\(instruction)'")
        }

        // Also verify the enum has exactly the two settings.
        #expect(LMEBInstructionSetting.allCases.count == 2)
        #expect(LMEBInstructionSetting.withoutInstruction.rawValue == "without_instruction")
        #expect(LMEBInstructionSetting.withInstruction.rawValue    == "with_instruction")
    }
}

// MARK: - §A3 per-query metrics integration

@Suite("LMEBSpec metrics: per-query integration")
struct LMEBSpecPerQueryIntegrationTests {

    /// lmebSpecPerQueryMetrics covers all k values in lmebSpecKValues.
    @Test("Per-query metrics cover all canonical k values")
    func perQueryCoversAllKValues() {
        let ranked   = ["A", "B", "C"]
        let relevant = Set(["A"])
        let metrics  = lmebSpecPerQueryMetrics(
            rankedDocIDs: ranked,
            relevantDocIDs: relevant,
            queryID: "q1"
        )
        for k in lmebSpecKValues {
            #expect(metrics.ndcg[k]      != nil, "Missing nDCG@\(k)")
            #expect(metrics.ap[k]        != nil, "Missing AP@\(k)")
            #expect(metrics.recall[k]    != nil, "Missing Recall@\(k)")
            #expect(metrics.precision[k] != nil, "Missing Precision@\(k)")
            #expect(metrics.mrr[k]       != nil, "Missing MRR@\(k)")
            #expect(metrics.rCap[k]      != nil, "Missing R_cap@\(k) key")
        }
    }

    /// Empty subset returns zeroed metrics and no crash (§A1/§A3 edge case).
    @Test("Empty subset aggregation returns zeroed metrics without crash")
    func emptySubsetAggregation() {
        let sm = lmebSpecSubsetMetrics(queries: [], subsetName: "user_evidence")
        for k in lmebSpecKValues {
            #expect(sm.ndcg[k]   == 0.0, "Empty subset nDCG@\(k) must be 0.0")
            #expect(sm.map[k]    == 0.0)
            #expect(sm.recall[k] == 0.0)
        }
        let task = lmebSpecTaskMetrics(subsets: [sm])
        #expect(task.ndcgAt10 == 0.0)
    }

    /// lmebSpecKValues contains exactly [1, 5, 10, 25, 50] (§A1).
    @Test("lmebSpecKValues equals [1,5,10,25,50] per §A1")
    func kValuesAreCanonical() {
        #expect(lmebSpecKValues == [1, 5, 10, 25, 50])
    }
}
