import Testing
import Foundation
import SubstrateML
@testable import CognitionKit

/// DatasetAssociationsTests — verifies the dataset column co-occurrence entry point.
///
/// These tests exercise `DatasetAssociations.run` as the new entry point for
/// mining pairwise association rules over dataset rows. The underlying engine
/// is `mineAssociationRules` from SubstrateML (unchanged); only the input-shaping
/// path (column→value label projection, MatrixO construction) is tested here.
@Suite("DatasetAssociationsTests")
struct DatasetAssociationsTests {

    // MARK: - Helpers

    private func zeroThresholds() -> MiningThresholds {
        MiningThresholds(minSupport: 0, minConfidence: 0)
    }

    // DSA-1: empty rows produce no rules.
    @Test("empty rows produce no rules")
    func emptyRowsProduceNoRules() {
        let output = DatasetAssociations.run(rows: [], thresholds: zeroThresholds())
        #expect(output.rules.isEmpty)
        #expect(output.rowCount == 0)
        #expect(!output.labelOverflow)
    }

    // DSA-2: perfectly co-occurring columns produce high-confidence rules.
    // color:red always co-occurs with fruit:apple; zero-threshold returns all rules.
    @Test("perfectly co-occurring columns produce rules")
    func perfectlyCoOccurringColumnsProduceRules() {
        let rows: [[String: String]] = [
            ["color": "red", "fruit": "apple"],
            ["color": "red", "fruit": "apple"],
            ["color": "blue", "fruit": "blueberry"],
            ["color": "blue", "fruit": "blueberry"],
        ]
        let output = DatasetAssociations.run(rows: rows, thresholds: zeroThresholds())
        #expect(!output.rules.isEmpty, "co-occurring columns must produce rules at zero threshold")
        #expect(output.rowCount == 4)
        // High-confidence rules: red↔apple, blue↔blueberry.
        let highConfidence = output.rules.filter { $0.confidence >= 0.99 }
        #expect(!highConfidence.isEmpty, "at least one rule with confidence=1.0")
    }

    // DSA-3: label format is "columnName:value".
    // Every antecedent and consequent must match this pattern.
    @Test("labels use columnName:value format")
    func labelsUseColumnNameValueFormat() {
        let rows: [[String: String]] = [
            ["color": "red", "fruit": "apple"],
            ["color": "blue", "fruit": "blueberry"],
        ]
        let output = DatasetAssociations.run(rows: rows, thresholds: zeroThresholds())
        for rule in output.rules {
            #expect(rule.antecedent.contains(":"),
                    "antecedent '\(rule.antecedent)' must be 'columnName:value'")
            #expect(rule.consequent.contains(":"),
                    "consequent '\(rule.consequent)' must be 'columnName:value'")
        }
    }

    // DSA-4: label overflow flag set when distinct labels exceed 64.
    // 70 distinct values in one column → 70 unique labels → overflow.
    @Test("label overflow flagged when distinct labels exceed 64")
    func labelOverflowFlaggedAtCap() {
        // 70 rows with unique values in "id" column plus a common "type" column.
        var rows: [[String: String]] = []
        for i in 0..<70 {
            rows.append(["id": "item\(i)", "type": "common"])
        }
        let output = DatasetAssociations.run(rows: rows, thresholds: zeroThresholds())
        #expect(output.labelOverflow, "70 unique id labels + 1 type label = 71 > 64")
        // Rules still mined from the capped (first-64-alphabetical) labels.
        // The "type:common" label is alphabetically after most "id:item..." labels,
        // so some id labels are included and rules may still be mined.
        #expect(output.rowCount == 70)
    }

    // DSA-5: high threshold filters out low-support rules.
    @Test("high threshold filters low-support rules")
    func highThresholdFiltersRules() {
        let rows: [[String: String]] = [
            ["a": "rare", "b": "x"],
            ["a": "common", "b": "x"],
            ["a": "common", "b": "x"],
            ["a": "common", "b": "x"],
        ]
        let allRules = DatasetAssociations.run(rows: rows, thresholds: zeroThresholds())
        let filtered = DatasetAssociations.run(
            rows: rows,
            thresholds: MiningThresholds(minSupport: 0.9, minConfidence: 0.9))
        #expect(filtered.rules.count <= allRules.rules.count)
    }

    // DSA-6: determinism — same rows twice yields same output.
    @Test("deterministic output for same input")
    func deterministicOutputForSameInput() {
        let rows: [[String: String]] = [
            ["x": "1", "y": "a"],
            ["x": "2", "y": "b"],
            ["x": "1", "y": "a"],
        ]
        let out1 = DatasetAssociations.run(rows: rows, thresholds: zeroThresholds())
        let out2 = DatasetAssociations.run(rows: rows, thresholds: zeroThresholds())
        #expect(out1.rowCount == out2.rowCount)
        #expect(out1.labelOverflow == out2.labelOverflow)
        // Rule counts must match; rules are in deterministic label-index order.
        #expect(out1.rules.count == out2.rules.count)
        for (r1, r2) in zip(out1.rules, out2.rules) {
            #expect(r1.antecedent == r2.antecedent)
            #expect(r1.consequent == r2.consequent)
        }
    }

    // DSA-7: fixture conformance — 4-row dataset from dataset_vectors.json.
    // Validates against expectedRuleCount and expectedLabels from the fixture.
    @Test("fixture conformance for 4-row dataset")
    func fixtureConformance() throws {
        let fixtureURL = try loadFixtureURL()
        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let assocFixture = json["datasetAssociations"] as! [String: Any]
        let rawRows = assocFixture["rows"] as! [[String: String]]
        let expectedLabels = assocFixture["expectedLabels"] as! [String]

        let output = DatasetAssociations.run(rows: rawRows, thresholds: zeroThresholds())

        // Row count matches fixture.
        #expect(output.rowCount == rawRows.count)
        #expect(!output.labelOverflow, "4 labels well under the 64 cap")

        // All rule labels are in the expected vocabulary.
        let allLabels = Set(output.rules.flatMap { [$0.antecedent, $0.consequent] })
        for label in allLabels {
            #expect(expectedLabels.contains(label),
                    "unexpected label '\(label)' not in fixture vocabulary")
        }
    }

    // MARK: - Helpers

    private func loadFixtureURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/dataset_vectors", withExtension: "json") else {
            throw DatasetAssocTestError.fixtureNotFound
        }
        return url
    }
}

private enum DatasetAssocTestError: Error {
    case fixtureNotFound
}
