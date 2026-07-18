import Foundation
import SubstrateML
import SubstrateTypes

/// Dataset column association-rules entry point — reuses the facet-matrix path
/// (MatrixO + SubstrateML mineAssociationRules) over user-supplied column-value rows.
///
/// This entry point is the dataset-targeted twin of the `AssociationRules` lens:
/// instead of projecting Drawer categorical facets (room, kind, channel, sensitivity)
/// into the co-occurrence matrix, it projects dataset column values. Each column
/// value is expressed as a "columnName:value" label — the same vocabulary pattern
/// as AssociationRules — enabling symmetric interpretation of the mined rules.
///
/// Design: columns ARE the facets. One row in the dataset maps to one transaction
/// in the association-rule sense. Each (column, value) pair contributes a presence
/// item in the MatrixO row. Rules then read as "columnA:X often co-occurs with
/// columnB:Y in the same row."
///
/// Null handling: callers must exclude null-valued columns from the row dictionary
/// before calling `run`. Null values have no natural label and contribute no item.
///
/// Label cap: up to 64 distinct "columnName:value" labels are indexed
/// (alphabetical sort order, matching AssociationRules overflow behavior).
/// If the distinct label count exceeds 64, `labelOverflow` is set and the
/// alphabetically-first 64 labels are kept.
///
/// Support/confidence semantics: identical to AssociationRules — the engine is
/// the same (`mineAssociationRules`). Thresholds are caller-supplied; zero
/// thresholds return all rules.
///
/// Rust peer: `run_dataset_associations` in `dataset_associations.rs`.
public enum DatasetAssociations {

    /// Output of the dataset association-rule mining.
    public struct Output: Sendable {
        /// Mined rules with "columnName:value" labels, in ascending packed
        /// (antecedent, consequent) label-index order (deterministic within a call).
        public let rules: [AssociationRuleResult]
        /// Number of rows the matrix was built from.
        public let rowCount: Int
        /// True if the distinct label count exceeded 64 and was capped.
        public let labelOverflow: Bool

        public init(rules: [AssociationRuleResult], rowCount: Int, labelOverflow: Bool) {
            self.rules = rules
            self.rowCount = rowCount
            self.labelOverflow = labelOverflow
        }
    }

    /// Run association-rule mining across categorical columns of one dataset.
    ///
    /// - Parameters:
    ///   - rows: Each row is a dictionary of columnName → value. Null values
    ///     must be excluded by the caller (missing keys contribute no label).
    ///   - thresholds: Minimum support and confidence gates for rule emission.
    ///     `MiningThresholds(minSupport: 0, minConfidence: 0)` returns all rules.
    /// - Returns: Mined rules with string labels and the five standard metrics.
    public static func run(
        rows: [[String: String]],
        thresholds: MiningThresholds
    ) -> Output {
        guard !rows.isEmpty else {
            return Output(rules: [], rowCount: 0, labelOverflow: false)
        }

        // 1. Build per-call sorted label vocabulary from all (column, value) pairs.
        var seen = Set<String>()
        for row in rows {
            for (col, val) in row {
                // Label format "columnName:value" mirrors AssociationRules' "axis:caseName"
                // vocabulary. This makes rules symmetric with the drawer-level lens.
                seen.insert("\(col):\(val)")
            }
        }
        let allLabels = seen.sorted()  // alphabetical for determinism, matching AssociationRules
        let labelOverflow = allLabels.count > maxFieldCount
        let labels = labelOverflow ? Array(allLabels.prefix(maxFieldCount)) : allLabels

        // 2. Build MatrixO: each row contributes presence items for its column labels.
        var matrix = MatrixO()
        for row in rows {
            var fieldValues: [(field: UInt8, value: UInt8)] = []
            for (col, val) in row {
                let label = "\(col):\(val)"
                // Linear search over ≤ 64 labels is fine (tiny set, same as AssociationRules).
                if let idx = labels.firstIndex(of: label) {
                    fieldValues.append((field: UInt8(idx), value: 1))
                }
            }
            matrix.applyRow(delta: 1, fieldValues: fieldValues)
        }

        // 3. Mine pairwise association rules (engine owns all metric computation).
        let rawRules = mineAssociationRules(
            matrix: matrix,
            activeRowCount: Int64(rows.count),
            thresholds: thresholds)

        // 4. Relabel packed item indices back to "columnName:value" strings.
        let results: [AssociationRuleResult] = rawRules.compactMap { rule in
            let ai = Int(rule.antecedent.field)
            let ci = Int(rule.consequent.field)
            guard ai < labels.count, ci < labels.count else { return nil }
            return AssociationRuleResult(
                antecedent: labels[ai],
                consequent: labels[ci],
                support: rule.support,
                confidence: rule.confidence,
                lift: rule.lift,
                conviction: rule.conviction,
                leverage: rule.leverage)
        }

        return Output(rules: results, rowCount: rows.count, labelOverflow: labelOverflow)
    }

    // MARK: - Private constants

    /// Capacity constant: MatrixO requires field < 64 (6-bit field index).
    /// Matches the cap in AssociationRules.
    private static let maxFieldCount = 64
}
