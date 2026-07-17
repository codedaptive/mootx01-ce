import Foundation
import NeuronKit

/// Dataset column entropy entry point — reuses the existing field-entropy path
/// (NeuronKit.complexity) over user-supplied column value arrays.
///
/// This entry point is the dataset-targeted twin of the `Complexity` lens:
/// instead of deriving count distributions from recalled Drawer fields, it
/// accepts raw column value arrays supplied by the tool layer (which fetches
/// them from DatasetStore). The underlying math — NeuronKit.complexity,
/// Float32 counts, Shannon entropy, optional mutual information — is unchanged.
///
/// Null handling: nil values in `columnA`/`columnB` are EXCLUDED from the
/// entropy computation and counted separately in `nullCount`. For the
/// two-column (mutual information) case, rows where EITHER column is nil are
/// excluded from both distributions (only jointly non-null pairs contribute).
///
/// Tie-breaking / determinism: distinct values with equal count are sorted
/// alphabetically before building the count array, matching the discipline in
/// `Complexity.distribution`. Entropy is a function of the probability
/// distribution, not the labeling, so alphabetical bin order does not affect
/// the entropy value — but it does make the joint matrix deterministic, which
/// is required for reproducible mutual-information computation.
///
/// Rust peer: `run_dataset_column_entropy` in `dataset_complexity.rs`.
public enum DatasetComplexity {

    /// Output of a single- or two-column entropy computation.
    public struct ColumnEntropyOutput: Sendable, Equatable {
        /// Entropy (and optional mutual information) from NeuronKit.complexity.
        /// entropyA is the entropy of columnA. entropyB and mutualInformation
        /// are non-nil only when columnB was supplied.
        public let result: ComplexityResult
        /// Number of non-null values included in the entropy computation.
        /// For the two-column case this is the count of rows where BOTH
        /// columns are non-null.
        public let nonNullCount: Int
        /// Number of values (rows) excluded because at least one column was nil.
        public let nullCount: Int

        public init(result: ComplexityResult, nonNullCount: Int, nullCount: Int) {
            self.result = result
            self.nonNullCount = nonNullCount
            self.nullCount = nullCount
        }
    }

    /// Compute Shannon entropy of a column's value distribution, and optionally
    /// mutual information between two columns.
    ///
    /// - Parameters:
    ///   - columnA: String values for the first column. nil entries are nulls.
    ///   - columnB: Optional second column; when non-nil, mutual information
    ///     between columnA and columnB is computed over jointly non-null rows.
    /// - Returns: Entropy output wrapping the NeuronKit ComplexityResult.
    ///   Empty (all-null) input yields entropyA = 0.0 (B-8).
    public static func runColumn(
        columnA: [String?],
        columnB: [String?]? = nil
    ) -> ColumnEntropyOutput {
        if let b = columnB {
            return runTwoColumn(columnA: columnA, columnB: b)
        } else {
            return runSingleColumn(columnA: columnA)
        }
    }

    // MARK: - Private helpers

    private static func runSingleColumn(columnA: [String?]) -> ColumnEntropyOutput {
        let nullCount = columnA.filter { $0 == nil }.count
        let nonNull = columnA.compactMap { $0 }
        let (counts, _) = frequencyCounts(from: nonNull)
        let result = NeuronKit.complexity(countsA: counts, countsB: nil, joint: nil)
        return ColumnEntropyOutput(result: result, nonNullCount: nonNull.count, nullCount: nullCount)
    }

    private static func runTwoColumn(columnA: [String?], columnB: [String?]) -> ColumnEntropyOutput {
        // Only rows where BOTH columns are non-null contribute.
        var pairsA: [String] = []
        var pairsB: [String] = []
        var nullCount = 0
        for (av, bv) in zip(columnA, columnB) {
            if let a = av, let b = bv {
                pairsA.append(a)
                pairsB.append(b)
            } else {
                nullCount += 1
            }
        }
        let (countsA, keysA) = frequencyCounts(from: pairsA)
        let (countsB, keysB) = frequencyCounts(from: pairsB)
        let joint = buildJointMatrix(pairsA: pairsA, pairsB: pairsB, keysA: keysA, keysB: keysB)
        let result = NeuronKit.complexity(countsA: countsA, countsB: countsB, joint: joint)
        return ColumnEntropyOutput(result: result, nonNullCount: pairsA.count, nullCount: nullCount)
    }

    /// Build a sorted frequency count array from a string value array.
    ///
    /// Returns (counts, keys) where keys is sorted alphabetically so bin order
    /// is deterministic — matching the sorted-vocabulary discipline in Complexity.
    private static func frequencyCounts(from values: [String]) -> ([Float32], [String]) {
        var freq: [String: Int] = [:]
        for v in values {
            freq[v, default: 0] += 1
        }
        // Sort keys alphabetically for deterministic bin ordering.
        let keys = freq.keys.sorted()
        return (keys.map { Float32(freq[$0]!) }, keys)
    }

    /// Build a joint count matrix for mutual information.
    ///
    /// joint[i][j] = count of rows where columnA=keysA[i] AND columnB=keysB[j].
    /// Keys are the alphabetically sorted distinct values of each column,
    /// matching frequencyCounts ordering.
    private static func buildJointMatrix(
        pairsA: [String],
        pairsB: [String],
        keysA: [String],
        keysB: [String]
    ) -> [[Float32]] {
        let idxA = Dictionary(uniqueKeysWithValues: keysA.enumerated().map { ($1, $0) })
        let idxB = Dictionary(uniqueKeysWithValues: keysB.enumerated().map { ($1, $0) })
        var matrix = [[Float32]](
            repeating: [Float32](repeating: 0, count: keysB.count),
            count: keysA.count)
        for (va, vb) in zip(pairsA, pairsB) {
            if let ia = idxA[va], let ib = idxB[vb] {
                matrix[ia][ib] += 1
            }
        }
        return matrix
    }
}
