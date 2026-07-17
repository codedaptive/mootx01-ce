import Foundation

/// A typed column value for the dataset anomaly scorer.
///
/// The column kind (numeric vs categorical) is determined from the value itself,
/// not from separate schema metadata. All non-null values in a column are expected
/// to be the same kind (well-formed datasets); the scorer uses the first non-null
/// value to classify the column.
public enum DatasetColumnValue: Sendable, Equatable {
    /// A numeric (f64) column value.
    case numeric(Double)
    /// A categorical (string) column value.
    case categorical(String)
    /// A null (missing) column value.
    case null
}

/// Anomaly score for one row.
public struct RowAnomalyScore: Sendable, Equatable {
    /// Zero-based index of the row in the input array.
    public let rowIndex: Int
    /// Sum of per-column anomaly signals for this row. f64 throughout; never Float32.
    public let score: Double

    public init(rowIndex: Int, score: Double) {
        self.rowIndex = rowIndex
        self.score = score
    }
}

/// Output of the DatasetCohesion column-anomaly scorer.
public struct DatasetCohesionOutput: Sendable, Equatable {
    /// Top anomaly rows sorted by score descending. Ties are broken by row index
    /// ascending (lower row index ranks first among equal scores), giving
    /// deterministic output regardless of dictionary iteration order.
    public let topAnomalies: [RowAnomalyScore]
    /// Number of rows that were scored (min(input row count, maxRows)).
    public let rowsScored: Int

    public init(topAnomalies: [RowAnomalyScore], rowsScored: Int) {
        self.topAnomalies = topAnomalies
        self.rowsScored = rowsScored
    }
}

/// Column-value anomaly scorer for dataset rows.
///
/// This is a NEW computation — distinct from the lexical `Contradiction` lens
/// (which detects odd-one-out drawers by content shingle similarity). This scorer
/// operates over numeric and categorical column values of a single dataset using
/// robust statistics and information-theoretic rarity.
///
/// ## Algorithm
///
/// ### Numeric columns — robust z-score
///
///     anomaly_signal(x) = |x - median| / (1.4826 × MAD)
///
///   where MAD = median(|x_i - median(x)|).
///
///   The 1.4826 consistency factor is 1 / Φ⁻¹(0.75), where Φ is the standard
///   normal CDF. For a normally distributed variable, E[MAD] = σ/1.4826, so
///   scaled MAD ≈ σ. Using MAD rather than standard deviation makes the estimator
///   breakdown-point-robust: a single outlier cannot inflate the spread estimate
///   and mask other anomalies (50% breakdown point vs 0% for std dev).
///
///   When scaled MAD = 0 (zero-variation column: all non-null values identical),
///   all anomaly signals for that column are 0.0 — the column offers no
///   discrimination power.
///
/// ### Categorical columns — information-theoretic rarity
///
///     anomaly_signal(v) = -log₂(count(v) / total_non_null)
///
///   Rare values have high rarity (high anomaly signal). The uniform-rarity
///   bound is log₂(distinct_count). A value not seen during column statistics
///   (e.g. from rows beyond scanCap) gets signal 0.0.
///
/// ### Per-row score
///
///   score(row) = Σ_columns anomaly_signal(column_value_for_row)
///
///   Null values in a row contribute 0.0 to the row score (they are excluded
///   from per-column statistics and carry no anomaly signal).
///
/// ### Float discipline
///
/// All arithmetic uses Double (f64). No Float32 is used anywhere in this scorer.
/// Median, MAD, log2, division — all f64. This matches the Rust twin exactly.
///
/// Rust peer: `run_dataset_cohesion` in `dataset_cohesion.rs`.
public enum DatasetCohesion {

    /// Maximum rows processed per call.
    ///
    /// Rationale: the scorer performs O(rowsScored × columnCount) work.
    /// At 10,000 rows × 20 columns = 200,000 operations, the scorer completes
    /// well under 10 ms on Apple Silicon. Rows beyond this cap are silently
    /// skipped; the caller should pre-filter or sample when the dataset is larger.
    public static let scanCap: Int = 10_000

    /// Run the column-value anomaly scorer.
    ///
    /// - Parameters:
    ///   - rows: Rows to score. Each row is an array of column values. All rows
    ///     must have the same length (equal to the column count). Column indices
    ///     are implicit: `rows[i][j]` is the value of column j in row i.
    ///   - topN: Maximum number of anomaly rows to return. The actual count may
    ///     be less if `rows` is shorter.
    ///   - maxRows: Maximum rows to score. Rows at indices ≥ `maxRows` are
    ///     skipped. Defaults to `scanCap`.
    /// - Returns: Top-N anomaly rows (sorted score desc, row-index asc for ties)
    ///   and the count of rows that were scored.
    public static func run(
        rows: [[DatasetColumnValue]],
        topN: Int = 10,
        maxRows: Int = DatasetCohesion.scanCap
    ) -> DatasetCohesionOutput {
        let rowCount = min(rows.count, maxRows)
        guard rowCount > 0 else {
            return DatasetCohesionOutput(topAnomalies: [], rowsScored: 0)
        }

        let scoredRows = rows.prefix(rowCount)
        let columnCount = scoredRows.first?.count ?? 0
        guard columnCount > 0 else {
            return DatasetCohesionOutput(topAnomalies: [], rowsScored: rowCount)
        }

        // Build one anomaly-signal closure per column.
        // Each closure is derived from the column's non-null values (statistics
        // computed once over the scanned rows, then queried per cell).
        let columnSignals: [(DatasetColumnValue) -> Double] = (0..<columnCount).map { colIdx in
            let colValues = scoredRows.map { row -> DatasetColumnValue in
                colIdx < row.count ? row[colIdx] : .null
            }
            return makeAnomalySignal(for: colValues)
        }

        // Compute per-row scores.
        var rowScores: [RowAnomalyScore] = []
        rowScores.reserveCapacity(rowCount)
        for (rowIdx, row) in scoredRows.enumerated() {
            var score = 0.0
            for colIdx in 0..<columnCount {
                let val = colIdx < row.count ? row[colIdx] : .null
                // f64 accumulation; no intermediate Float32 cast.
                score += columnSignals[colIdx](val)
            }
            rowScores.append(RowAnomalyScore(rowIndex: rowIdx, score: score))
        }

        // Sort by score descending; tie-break by rowIndex ascending (deterministic).
        rowScores.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.rowIndex < b.rowIndex
        }
        let topAnomalies = Array(rowScores.prefix(topN))

        return DatasetCohesionOutput(topAnomalies: topAnomalies, rowsScored: rowCount)
    }

    // MARK: - Private: per-column signal factory

    /// Construct the anomaly-signal closure for a single column.
    ///
    /// Column kind is determined from the first non-null value. All subsequent
    /// non-null values are assumed to be the same kind (well-formed dataset).
    /// An all-null column returns a zero-signal closure.
    private static func makeAnomalySignal(
        for columnValues: [DatasetColumnValue]
    ) -> (DatasetColumnValue) -> Double {
        // Collect non-null values.
        let nonNull = columnValues.filter { if case .null = $0 { return false } else { return true } }
        guard !nonNull.isEmpty else {
            // All-null column: no anomaly signal can be derived.
            return { _ in 0.0 }
        }

        switch nonNull[0] {
        case .numeric:
            // Collect numeric values and build robust z-score signal.
            let values: [Double] = nonNull.compactMap {
                if case .numeric(let d) = $0 { return d } else { return nil }
            }
            return makeRobustZScoreSignal(values: values)

        case .categorical:
            // Collect categorical values and build rarity signal.
            let values: [String] = nonNull.compactMap {
                if case .categorical(let s) = $0 { return s } else { return nil }
            }
            return makeCategoricalRaritySignal(values: values)

        case .null:
            // Cannot occur here (nonNull[0] is guaranteed non-null), but Swift
            // requires exhaustive switches. Treat as no-signal column.
            return { _ in 0.0 }
        }
    }

    // MARK: - Private: numeric signal (robust z-score)

    /// Build a robust z-score anomaly signal closure for a numeric column.
    ///
    /// anomaly_signal(x) = |x - median| / (1.4826 × MAD)
    ///
    /// The 1.4826 constant is the consistency factor making MAD asymptotically
    /// consistent with the standard deviation under a normal distribution:
    ///   1.4826 ≈ 1 / Φ⁻¹(0.75)
    /// where Φ⁻¹ is the inverse standard normal CDF (quantile function).
    ///
    /// When scaledMAD = 0 (constant column), the closure returns 0.0 for every
    /// input — the column offers no discrimination between rows.
    private static func makeRobustZScoreSignal(values: [Double]) -> (DatasetColumnValue) -> Double {
        let med = median(values)
        let deviations = values.map { abs($0 - med) }
        let mad = median(deviations)

        // MAD consistency factor: 1 / Φ⁻¹(0.75) ≈ 1.4826 for normal distributions.
        // This makes scaled MAD an asymptotically consistent estimator of σ.
        let madScale = 1.4826
        let scaledMAD = madScale * mad

        if scaledMAD == 0.0 {
            // Zero-variation column: no row is distinguishable on this column.
            return { _ in 0.0 }
        }

        return { value -> Double in
            guard case .numeric(let v) = value else { return 0.0 }
            // Absolute value: direction is not surfaced; only magnitude matters.
            return abs(v - med) / scaledMAD
        }
    }

    // MARK: - Private: categorical signal (information-theoretic rarity)

    /// Build a categorical rarity signal closure.
    ///
    /// rarity(v) = -log₂(count(v) / total_non_null)
    ///
    /// Rare values (small frequency) yield high rarity (high anomaly signal).
    /// Common values yield low rarity. The uniform baseline is log₂(distinct_count)
    /// (if all values appeared equally often). This is the self-information of
    /// the value under the empirical distribution.
    ///
    /// Null values and values not seen during statistics collection return 0.0.
    private static func makeCategoricalRaritySignal(values: [String]) -> (DatasetColumnValue) -> Double {
        let total = Double(values.count)
        var freq: [String: Int] = [:]
        for v in values { freq[v, default: 0] += 1 }

        return { value -> Double in
            guard case .categorical(let s) = value else { return 0.0 }
            guard let count = freq[s] else {
                // Value not seen during column statistics (e.g. beyond scanCap).
                // Treat as non-anomalous rather than infinitely anomalous.
                return 0.0
            }
            let p = Double(count) / total
            // -log2(p) is the self-information (rarity) of this value.
            // Equivalent to log2(total / count).
            return -log2(p)
        }
    }

    // MARK: - Private: median

    /// Compute the median of a non-empty array of doubles.
    ///
    /// For even-length arrays: arithmetic mean of the two middle values.
    /// For odd-length arrays: the single middle value.
    /// The array is sorted internally; the caller's array is unchanged.
    ///
    /// All arithmetic is f64 (Double). No Float32 conversion.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 0 {
            // Even: average of the two middle values. Exact f64 arithmetic.
            return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        } else {
            // Odd: exact middle value — no arithmetic needed.
            return sorted[n / 2]
        }
    }
}
