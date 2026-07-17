import Testing
import Foundation
@testable import CognitionKit

/// DatasetCohesionTests — verifies the dataset column-value anomaly scorer.
///
/// The scorer is new math (not a reuse of the lexical Contradiction lens).
/// Tests validate: MAD robust z-score for numeric columns, information-theoretic
/// rarity for categorical columns, per-row score accumulation, scan cap, and
/// the fixture conformance case that both legs (Swift + Rust) verify against.
@Suite("DatasetCohesionTests")
struct DatasetCohesionTests {

    // DCH-1: empty rows yields empty output.
    @Test("empty rows yields empty output")
    func emptyRowsYieldsEmptyOutput() {
        let output = DatasetCohesion.run(rows: [])
        #expect(output.topAnomalies.isEmpty)
        #expect(output.rowsScored == 0)
    }

    // DCH-2: constant numeric column contributes zero to every row score.
    // MAD of a constant column = 0 → scaledMAD = 0 → all z-scores = 0.
    @Test("constant numeric column contributes zero anomaly signal")
    func constantNumericColumnContributesZeroSignal() {
        let rows: [[DatasetColumnValue]] = [
            [.numeric(5.0)],
            [.numeric(5.0)],
            [.numeric(5.0)],
        ]
        let output = DatasetCohesion.run(rows: rows)
        #expect(output.rowsScored == 3)
        for anomaly in output.topAnomalies {
            #expect(anomaly.score == 0.0, "constant column: every row score = 0")
        }
    }

    // DCH-3: outlier numeric row has highest score.
    //
    // Data: [1, 2, 3, 4, 5, 6, 7, 8, 9, 100]
    //   n=10, median=(5+6)/2=5.5
    //   MAD = median(|x-5.5|) = median([4.5,3.5,2.5,1.5,0.5,0.5,1.5,2.5,3.5,94.5])
    //       = (sorted[4]+sorted[5])/2 = (2.5+2.5)/2 = 2.5  (MAD > 0 ✓)
    //   scaledMAD = 1.4826 × 2.5 = 3.7065
    //   signal(100) = |100-5.5|/3.7065 = 94.5/3.7065 ≈ 25.5  (clear outlier)
    //   signal(9)   = |9-5.5|/3.7065  = 3.5/3.7065  ≈ 0.94
    // Row 9 (value=100) has the highest signal by far.
    @Test("numeric outlier row has highest score")
    func numericOutlierRowHasHighestScore() {
        let values: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 100]
        let rows: [[DatasetColumnValue]] = values.map { [.numeric($0)] }
        let output = DatasetCohesion.run(rows: rows, topN: 1)
        #expect(output.rowsScored == 10)
        // Row 9 (value=100, signal≈25.5) must be the top anomaly.
        let topRow = output.topAnomalies.first
        #expect(topRow?.rowIndex == 9,
                "the planted numeric outlier at index 9 must be the top anomaly")
        #expect((topRow?.score ?? 0) > 10.0,
                "outlier z-score ≈ 25.5; row score must clearly exceed 10")
    }

    // DCH-4: rare categorical value has higher anomaly than common.
    // "rare" appears once; "common" appears 9 times.
    // rarity("rare") = -log2(1/10) = log2(10) ≈ 3.32
    // rarity("common") = -log2(9/10) ≈ 0.152
    @Test("rare categorical value has higher anomaly signal than common")
    func rareCategoricalValueHigherAnomalyThanCommon() {
        var rows: [[DatasetColumnValue]] = Array(repeating: [.categorical("common")], count: 9)
        rows.append([.categorical("rare")])
        let output = DatasetCohesion.run(rows: rows, topN: 1)
        // The rare row (index 9) must have the highest score.
        #expect(output.topAnomalies.first?.rowIndex == 9,
                "the rare categorical at index 9 must be the top anomaly")
    }

    // DCH-5: null values contribute 0.0 to row score.
    // Row with all nulls should have score 0.0.
    @Test("null values contribute zero to row score")
    func nullValuesContributeZeroToRowScore() {
        // 8 normal rows + 1 mild outlier + 1 all-null row (index 9).
        var fullRows: [[DatasetColumnValue]] = []
        for _ in 0..<8 { fullRows.append([.numeric(10.0), .categorical("A")]) }
        fullRows.append([.numeric(50.0), .categorical("B")])  // mild outlier at index 8
        fullRows.append([.null, .null])                        // all-null row at index 9

        let output = DatasetCohesion.run(rows: fullRows, topN: 10)
        // With topN=10 and 10 rows, all rows appear in output.
        // The all-null row must have score exactly 0.0.
        let nullRow = output.topAnomalies.first(where: { $0.rowIndex == 9 })
        #expect(nullRow != nil, "all-null row at index 9 must appear in topN=10 output")
        #expect(nullRow?.score == 0.0, "all-null row must have zero score")
    }

    // DCH-6: scan cap honored — maxRows parameter limits scored rows.
    // 100 rows; maxRows=5 → rowsScored=5, topAnomalies only from first 5 rows.
    @Test("scan cap limits scored rows")
    func scanCapLimitsScoredRows() {
        let rows: [[DatasetColumnValue]] = (0..<100).map { _ in [.numeric(Double.random(in: 0...1))] }
        let output = DatasetCohesion.run(rows: rows, topN: 3, maxRows: 5)
        #expect(output.rowsScored == 5)
        for anomaly in output.topAnomalies {
            #expect(anomaly.rowIndex < 5, "all anomaly row indices must be < maxRows=5")
        }
    }

    // DCH-7: tie-breaking by rowIndex ascending.
    // All rows have identical values → all scores identical → rowIndex order.
    @Test("tie-breaking by row index ascending")
    func tieBrakingByRowIndexAscending() {
        // All rows identical: after sort, row 0 should be first.
        let rows: [[DatasetColumnValue]] = [
            [.categorical("X")],
            [.categorical("X")],
            [.categorical("X")],
        ]
        let output = DatasetCohesion.run(rows: rows, topN: 3)
        #expect(output.topAnomalies.count == 3)
        // All scores equal; row indices must be ascending (tie-break by index).
        let indices = output.topAnomalies.map(\.rowIndex)
        #expect(indices == [0, 1, 2], "tie-break must sort by rowIndex ascending")
    }

    // DCH-8: scanCap constant is 10_000.
    // This is a documented constant; test that it hasn't changed inadvertently.
    @Test("scanCap constant is 10,000")
    func scanCapConstantIs10000() {
        #expect(DatasetCohesion.scanCap == 10_000)
    }

    // DCH-9: fixture conformance — uses dataset_vectors.json to validate the
    // scorer against the hand-derived expected ordering.
    //
    // Fixture: 10 rows, 3 columns (score:numeric, category:categorical, label:categorical).
    // Planted outlier at row 9 (score=100, category="C", label="γάμα").
    //
    // Derivation (from fixture derivation note):
    //   Score column: median=6.0, MAD=4.0, scaledMAD=1.4826*4.0.
    //   Numeric signals: rows0-2=4/scaledMAD, rows3-5=0, rows6-8=4/scaledMAD, row9=94/scaledMAD.
    //   Category freqs: A=6/10, B=3/10, C=1/10.
    //   Label freqs: αλφα=6/10, βήτα=3/10, γάμα=1/10.
    //   Row score ordering: row9 >> rows6-8 > rows0-2 > rows3-5.
    @Test("fixture conformance: planted outlier at row 9 is top anomaly")
    func fixtureConformancePlantedOutlierIsTop() throws {
        let rows = try loadCohesionRows()

        let output = DatasetCohesion.run(rows: rows, topN: 10)
        #expect(output.rowsScored == 10)

        // Row 9 (planted outlier) must be the top anomaly.
        let top = output.topAnomalies.first
        #expect(top?.rowIndex == 9, "row 9 (score=100, C, γάμα) must be top anomaly")

        // Score ordering across groups (from derivation note):
        //   group1 = {9}: row9 score > group2 score
        //   group2 = {6,7,8}: rows6-8 scores all equal and > group3
        //   group3 = {0,1,2}: rows0-2 scores all equal and > group4
        //   group4 = {3,4,5}: rows3-5 scores all equal (lowest)
        let scores = Dictionary(uniqueKeysWithValues: output.topAnomalies.map { ($0.rowIndex, $0.score) })

        // Group scores must be non-nil for all 10 rows.
        for i in 0..<10 {
            #expect(scores[i] != nil, "row \(i) must have a score")
        }

        // Group 1 (row 9) > Group 2 (rows 6-8).
        let score9 = scores[9]!
        let score6 = scores[6]!
        #expect(score9 > score6, "row 9 score must exceed rows 6-8 score")

        // Group 2 (rows 6-8) are equal (same values).
        let score7 = scores[7]!
        let score8 = scores[8]!
        #expect(score6 == score7, "rows 6 and 7 must have equal score (same column values)")
        #expect(score7 == score8, "rows 7 and 8 must have equal score (same column values)")

        // Group 2 > Group 3 (rows 0-2).
        let score0 = scores[0]!
        #expect(score6 > score0, "rows 6-8 score must exceed rows 0-2 score")

        // Group 3 (rows 0-2) are equal.
        let score1 = scores[1]!
        let score2 = scores[2]!
        #expect(score0 == score1, "rows 0 and 1 must have equal score")
        #expect(score1 == score2, "rows 1 and 2 must have equal score")

        // Group 3 > Group 4 (rows 3-5).
        let score3 = scores[3]!
        #expect(score0 > score3, "rows 0-2 score must exceed rows 3-5 score")

        // Group 4 (rows 3-5) are equal.
        let score4 = scores[4]!
        let score5 = scores[5]!
        #expect(score3 == score4, "rows 3 and 4 must have equal score")
        #expect(score4 == score5, "rows 4 and 5 must have equal score")

        // Non-ASCII label column is exercised (γάμα, βήτα, αλφα):
        // The top anomaly (row 9, label="γάμα") score accounts for the γάμα rarity.
        // Its score must be > 2*log2(10) ≈ 6.64 (just the categorical rarity contribution).
        #expect(score9 > 2.0 * log2(10.0),
                "row 9 score must exceed 2*log2(10) from its two rare categorical values alone")
    }

    // DCH-10: numeric and categorical columns interact correctly — row score is
    // the sum of signals from each column independently.
    //
    // Dataset: 10 rows ensuring non-zero MAD for numeric column.
    //   Rows 0-2: numeric=3, categorical="A"
    //   Rows 3-5: numeric=7, categorical="A"   ← median zone
    //   Rows 6-7: numeric=10, categorical="A"
    //   Row 8:    numeric=3,  categorical="B"   ← rare category
    //   Row 9:    numeric=100, categorical="B"  ← extreme numeric + rare cat
    //
    // Score column (10 values): [3,3,3,7,7,7,10,10,3,100]
    //   sorted=[3,3,3,3,7,7,7,10,10,100], n=10
    //   median=(sorted[4]+sorted[5])/2=(7+7)/2=7.0
    //   devs: |3-7|=4(×4), |7-7|=0(×3), |10-7|=3(×2), |100-7|=93(×1)
    //   sorted devs=[0,0,0,3,3,4,4,4,4,93], MAD=(3+4)/2=3.5  (MAD>0 ✓)
    //   scaledMAD=1.4826*3.5=5.1891
    //   signal(3)=4/5.1891≈0.771, signal(7)=0, signal(10)=3/5.1891≈0.578, signal(100)≈17.9
    //
    // Cat freqs: A=9/10=0.9, B=1/10=0.1
    //   rarity(A)=-log2(0.9)≈0.152, rarity(B)=-log2(0.1)=log2(10)≈3.322
    //
    // Row scores: row9=17.9+3.322≈21.2, row8=0.771+3.322≈4.1,
    //             rows0-2=0.771+0.152≈0.923, rows6-7=0.578+0.152≈0.730,
    //             rows3-5=0+0.152=0.152
    // Ordering: row9 > row8 >> rows0-2 > rows6-7 > rows3-5
    @Test("numeric and categorical signals sum independently per row")
    func numericAndCategoricalSignalsSumIndependently() {
        let rows: [[DatasetColumnValue]] = [
            [.numeric(3.0),   .categorical("A")],   // row 0
            [.numeric(3.0),   .categorical("A")],   // row 1
            [.numeric(3.0),   .categorical("A")],   // row 2
            [.numeric(7.0),   .categorical("A")],   // row 3
            [.numeric(7.0),   .categorical("A")],   // row 4
            [.numeric(7.0),   .categorical("A")],   // row 5
            [.numeric(10.0),  .categorical("A")],   // row 6
            [.numeric(10.0),  .categorical("A")],   // row 7
            [.numeric(3.0),   .categorical("B")],   // row 8: same numeric as 0-2, rare cat
            [.numeric(100.0), .categorical("B")],   // row 9: extreme numeric + rare cat
        ]
        let output = DatasetCohesion.run(rows: rows, topN: 10)
        let scores = Dictionary(uniqueKeysWithValues: output.topAnomalies.map { ($0.rowIndex, $0.score) })

        let s9 = scores[9]!, s8 = scores[8]!, s0 = scores[0]!

        // Row 9 (extreme outlier numeric + rare cat) must be the top anomaly.
        #expect(s9 > s8, "row 9 (extreme+rare) must exceed row 8 (mild+rare)")
        // Row 8 (mild numeric + rare cat) must exceed row 0 (mild numeric + common cat)
        // because both have the same numeric signal but row 8 has much higher cat rarity.
        #expect(s8 > s0, "row 8 (rare cat) must exceed row 0 (common cat) for same numeric signal")

        // The top anomaly must be row 9.
        #expect(output.topAnomalies.first?.rowIndex == 9,
                "row 9 (extreme numeric + rare categorical) must be the top anomaly")
    }

    // MARK: - Helpers

    /// Load and convert the dataset_vectors.json cohesion fixture rows.
    ///
    /// The fixture rows are dicts {"score": Double, "category": String, "label": String}.
    /// Column order: [score (numeric), category (categorical), label (categorical)].
    private func loadCohesionRows() throws -> [[DatasetColumnValue]] {
        guard let url = Bundle.module.url(forResource: "Fixtures/dataset_vectors", withExtension: "json") else {
            throw DCHTestError.fixtureNotFound
        }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cohesion = json["datasetCohesion"] as! [String: Any]
        let rawRows = cohesion["rows"] as! [[String: Any]]
        return rawRows.map { row in
            let score = row["score"] as! Double
            let category = row["category"] as! String
            let label = row["label"] as! String
            // Column order: score, category, label (consistent across both legs).
            return [.numeric(score), .categorical(category), .categorical(label)]
        }
    }
}

private enum DCHTestError: Error {
    case fixtureNotFound
}
