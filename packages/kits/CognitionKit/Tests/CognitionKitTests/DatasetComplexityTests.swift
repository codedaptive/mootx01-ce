import Testing
import Foundation
import NeuronKit
@testable import CognitionKit

/// DatasetComplexityTests — verifies the dataset column entropy entry point.
///
/// These tests exercise `DatasetComplexity.runColumn` as the new entry point
/// for column-level Shannon entropy and mutual information. The underlying math
/// is NeuronKit.complexity (unchanged); only the input-shaping path is tested here.
@Suite("DatasetComplexityTests")
struct DatasetComplexityTests {

    // DSC-1: entropy of a single-value column is 0.0.
    // H(constant distribution) = 0 — zero uncertainty, zero entropy.
    @Test("single-value column has zero entropy")
    func singleValueColumnHasZeroEntropy() {
        let column: [String?] = ["A", "A", "A", "A"]
        let output = DatasetComplexity.runColumn(columnA: column)
        #expect(output.result.entropyA == 0.0)
        #expect(output.nonNullCount == 4)
        #expect(output.nullCount == 0)
    }

    // DSC-2: entropy of a two-value uniform column is 1.0 bit.
    // H([0.5, 0.5]) = 1.0 bit by definition of Shannon entropy in bits.
    @Test("uniform two-value column has entropy 1.0 bit")
    func uniformTwoValueColumnHasEntropyOneBit() {
        let column: [String?] = ["A", "A", "B", "B"]  // p(A)=0.5, p(B)=0.5
        let output = DatasetComplexity.runColumn(columnA: column)
        // 1.0 bit is the exact Float32 result for a uniform binary distribution.
        #expect(output.result.entropyA == 1.0)
        #expect(output.nonNullCount == 4)
        #expect(output.nullCount == 0)
    }

    // DSC-3: null values are excluded from entropy; nullCount is correct.
    // Fixture: ["A", null, "A", "A", "A", "A", "B", "B", "B", "C"]
    // Non-null: 9 values; null: 1 value.
    @Test("null values excluded from entropy; nullCount reported separately")
    func nullValuesExcludedFromEntropy() {
        let column: [String?] = ["A", nil, "A", "A", "A", "A", "B", "B", "B", "C"]
        let output = DatasetComplexity.runColumn(columnA: column)
        #expect(output.nonNullCount == 9)
        #expect(output.nullCount == 1)
        // Entropy of non-uniform distribution must be > 0.
        #expect(output.result.entropyA > 0.0)
    }

    // DSC-4: all-null column yields entropy 0.0 (B-8 total-over-edge-input).
    @Test("all-null column yields zero entropy (B-8)")
    func allNullColumnYieldsZeroEntropy() {
        let column: [String?] = [nil, nil, nil]
        let output = DatasetComplexity.runColumn(columnA: column)
        #expect(output.result.entropyA == 0.0)
        #expect(output.nonNullCount == 0)
        #expect(output.nullCount == 3)
    }

    // DSC-5: empty column yields entropy 0.0 (B-8).
    @Test("empty column yields zero entropy (B-8)")
    func emptyColumnYieldsZeroEntropy() {
        let column: [String?] = []
        let output = DatasetComplexity.runColumn(columnA: column)
        #expect(output.result.entropyA == 0.0)
        #expect(output.nonNullCount == 0)
        #expect(output.nullCount == 0)
    }

    // DSC-6: mutual information is present when columnB is supplied.
    // Two perfectly correlated columns must yield positive MI.
    @Test("mutual information is present when columnB supplied")
    func mutualInformationPresentWithTwoColumns() {
        // columnA and columnB are perfectly correlated.
        let columnA: [String?] = ["X", "X", "Y", "Y"]
        let columnB: [String?] = ["1", "1", "2", "2"]
        let output = DatasetComplexity.runColumn(columnA: columnA, columnB: columnB)
        #expect(output.result.entropyB != nil, "entropyB must be present for columnB")
        #expect(output.result.mutualInformation != nil, "MI must be present for columnB")
        // Perfectly correlated columns: MI = H(A) = H(B) = 1.0 bit.
        if let mi = output.result.mutualInformation {
            #expect(mi > 0.0, "MI must be positive for correlated columns")
        }
    }

    // DSC-7: null rows excluded from MI; nullCount reflects jointly-null rows.
    // Row where columnA is null but columnB is non-null: excluded from MI.
    @Test("jointly-null rows excluded from MI computation")
    func jointlyNullRowsExcludedFromMI() {
        let columnA: [String?] = ["X", nil, "Y", "Y"]  // row 1 is null
        let columnB: [String?] = ["1", "1", "2", "2"]  // row 1 non-null
        let output = DatasetComplexity.runColumn(columnA: columnA, columnB: columnB)
        // Row 1 is excluded because columnA is nil there.
        #expect(output.nonNullCount == 3)
        #expect(output.nullCount == 1)
    }

    // DSC-8: determinism — same input twice yields same output.
    @Test("deterministic output for same input")
    func deterministicOutputForSameInput() {
        let column: [String?] = ["A", "A", "B", "C", "B", "A", nil]
        let out1 = DatasetComplexity.runColumn(columnA: column)
        let out2 = DatasetComplexity.runColumn(columnA: column)
        #expect(out1 == out2)
    }

    // DSC-9: fixture conformance — entropy is non-trivial for a non-uniform
    // 3-class distribution. Validates against the dataset_vectors.json fixture.
    //
    // Fixture: category column from dataset_vectors.json = ["A"×6, "B"×3, "C"×1]
    // Expected entropy H(p_A=0.6, p_B=0.3, p_C=0.1) ≈ 1.295 bits (f32 tolerance 1e-3).
    // Derivation: H = -0.6*log2(0.6) - 0.3*log2(0.3) - 0.1*log2(0.1)
    //               = 0.6*0.7370 + 0.3*1.7370 + 0.1*3.3219 ≈ 1.2955
    @Test("fixture entropy matches hand-derived value for 3-class distribution")
    func fixtureEntropyMatchesHandDerived() throws {
        // Load fixture rows.
        let fixtureURL = try fixtureURL()
        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cohesion = json["datasetCohesion"] as! [String: Any]
        let rows = cohesion["rows"] as! [[String: Any]]

        // Extract category column.
        let categoryColumn: [String?] = rows.map { $0["category"] as? String }

        let output = DatasetComplexity.runColumn(columnA: categoryColumn)

        // Entropy must be positive (non-uniform distribution).
        #expect(output.result.entropyA > 0.0)
        #expect(output.nonNullCount == 10)
        #expect(output.nullCount == 0)

        // Entropy ≈ 1.295 bits. Float32 tolerance 2e-3 (two decimal places).
        // Derivation: H = -0.6*log2(0.6) - 0.3*log2(0.3) - 0.1*log2(0.1) ≈ 1.2955 bits.
        let expectedEntropyApprox: Float32 = 1.2955
        #expect(abs(output.result.entropyA - expectedEntropyApprox) < 2e-3,
                "entropy \(output.result.entropyA) should be near \(expectedEntropyApprox) bits")
    }

    // MARK: - Helpers

    private func fixtureURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/dataset_vectors", withExtension: "json") else {
            throw DatasetTestError.fixtureNotFound("Fixtures/dataset_vectors.json")
        }
        return url
    }
}

private enum DatasetTestError: Error {
    case fixtureNotFound(String)
}
