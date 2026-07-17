//! Dataset column-value anomaly scorer (DatasetCohesion) — new lens math.
//!
//! Rust twin of `CognitionKit/Sources/CognitionKit/DatasetCohesion.swift`.
//!
//! This is a NEW computation — distinct from the lexical `contradiction_recipe`
//! (which detects odd-one-out drawers by content shingle similarity). This
//! scorer operates over numeric and categorical column values of a single
//! dataset using robust statistics and information-theoretic rarity.
//!
//! ## Algorithm
//!
//! ### Numeric columns — robust z-score
//!
//! ```text
//! anomaly_signal(x) = |x - median| / (1.4826 × MAD)
//! ```
//!
//! where `MAD = median(|x_i - median(x)|)`.
//!
//! The 1.4826 consistency factor is `1 / Φ⁻¹(0.75)`, where Φ is the standard
//! normal CDF. For a normally distributed variable, `E[MAD] = σ/1.4826`, so
//! scaled MAD ≈ σ. Using MAD rather than standard deviation makes the estimator
//! breakdown-point-robust: a single outlier cannot inflate the spread estimate
//! and mask other anomalies (50% breakdown point vs 0% for std dev).
//!
//! When scaled MAD = 0 (zero-variation column: all non-null values identical),
//! all anomaly signals for that column are 0.0 — the column offers no
//! discrimination power.
//!
//! ### Categorical columns — information-theoretic rarity
//!
//! ```text
//! anomaly_signal(v) = -log2(count(v) / total_non_null)
//! ```
//!
//! Rare values have high rarity (high anomaly signal). A value not seen during
//! column statistics gets signal 0.0.
//!
//! ### Per-row score
//!
//! ```text
//! score(row) = Σ_columns anomaly_signal(column_value_for_row)
//! ```
//!
//! Null values in a row contribute 0.0 (excluded from column statistics and
//! carry no anomaly signal).
//!
//! ### Float discipline
//!
//! All arithmetic uses `f64`. No `f32` is used anywhere in this scorer.
//! Median, MAD, `f64::log2`, division — all f64. This matches the Swift twin.

use std::collections::HashMap;

/// A typed column value for the dataset anomaly scorer.
///
/// The column kind (numeric vs categorical) is determined from the value itself.
/// All non-null values in a column are expected to be the same kind (well-formed
/// dataset); the scorer uses the first non-null value to classify the column.
///
/// Mirrors Swift `DatasetColumnValue`.
#[derive(Debug, Clone, PartialEq)]
pub enum DatasetColumnValue {
    /// A numeric (f64) column value.
    Numeric(f64),
    /// A categorical (String) column value.
    Categorical(String),
    /// A null (missing) column value.
    Null,
}

/// Anomaly score for one row.
///
/// Mirrors Swift `RowAnomalyScore`.
#[derive(Debug, Clone, PartialEq)]
pub struct RowAnomalyScore {
    /// Zero-based index of the row in the input slice.
    pub row_index: usize,
    /// Sum of per-column anomaly signals for this row. f64 throughout.
    pub score: f64,
}

/// Output of the DatasetCohesion column-anomaly scorer.
///
/// Mirrors Swift `DatasetCohesionOutput`.
#[derive(Debug, Clone, PartialEq)]
pub struct DatasetCohesionOutput {
    /// Top anomaly rows sorted by score descending. Ties broken by `row_index`
    /// ascending (lower index ranks first among equal scores) for determinism.
    pub top_anomalies: Vec<RowAnomalyScore>,
    /// Number of rows that were scored (min(input row count, max_rows)).
    pub rows_scored: usize,
}

/// Maximum rows processed per call.
///
/// Rationale: the scorer performs O(rows_scored × column_count) work.
/// At 10,000 rows × 20 columns = 200,000 operations, the scorer completes
/// well under 10 ms on modern hardware. Rows beyond this cap are silently
/// skipped; the caller should pre-filter or sample for larger datasets.
///
/// Mirrors Swift `DatasetCohesion.scanCap`.
pub const SCAN_CAP: usize = 10_000;

/// Run the column-value anomaly scorer.
///
/// - `rows`: Rows to score. Each row is a slice of column values. All rows
///   should have the same length (equal to column count). Column indices are
///   implicit: `rows[i][j]` is the value of column j in row i.
/// - `top_n`: Maximum number of anomaly rows to return.
/// - `max_rows`: Maximum rows to score. Rows at indices ≥ `max_rows` are
///   skipped. Defaults to `SCAN_CAP` when called as `run_dataset_cohesion`.
///
/// Returns empty output if `rows` is empty.
///
/// Mirrors Swift `DatasetCohesion.run(rows:topN:maxRows:)`.
pub fn run_dataset_cohesion(
    rows: &[Vec<DatasetColumnValue>],
    top_n: usize,
    max_rows: usize,
) -> DatasetCohesionOutput {
    let row_count = rows.len().min(max_rows);
    if row_count == 0 {
        return DatasetCohesionOutput {
            top_anomalies: vec![],
            rows_scored: 0,
        };
    }

    let scored_rows = &rows[..row_count];
    let column_count = scored_rows.first().map(|r| r.len()).unwrap_or(0);
    if column_count == 0 {
        return DatasetCohesionOutput {
            top_anomalies: vec![],
            rows_scored: row_count,
        };
    }

    // Build one anomaly-signal closure per column.
    // Each closure captures the column statistics (median, MAD, freq map) and
    // maps DatasetColumnValue → f64 anomaly signal.
    let column_signals: Vec<Box<dyn Fn(&DatasetColumnValue) -> f64>> = (0..column_count)
        .map(|col_idx| {
            let col_values: Vec<&DatasetColumnValue> = scored_rows
                .iter()
                .map(|row| {
                    if col_idx < row.len() {
                        &row[col_idx]
                    } else {
                        // Row too short for this column index; treat as null.
                        // SAFETY: static reference to a null sentinel.
                        &DatasetColumnValue::Null
                    }
                })
                .collect();
            make_anomaly_signal(&col_values)
        })
        .collect();

    // Compute per-row scores. All arithmetic f64.
    let mut row_scores: Vec<RowAnomalyScore> = Vec::with_capacity(row_count);
    for (row_idx, row) in scored_rows.iter().enumerate() {
        let mut score = 0.0_f64;
        for col_idx in 0..column_count {
            let val = if col_idx < row.len() {
                &row[col_idx]
            } else {
                &DatasetColumnValue::Null
            };
            // f64 accumulation; no intermediate f32 cast.
            score += (column_signals[col_idx])(val);
        }
        row_scores.push(RowAnomalyScore { row_index: row_idx, score });
    }

    // Sort by score descending; tie-break by row_index ascending (deterministic).
    row_scores.sort_by(|a, b| {
        b.score.partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.row_index.cmp(&b.row_index))
    });
    row_scores.truncate(top_n);

    DatasetCohesionOutput {
        top_anomalies: row_scores,
        rows_scored: row_count,
    }
}

// MARK: - Private: per-column signal factory

/// Construct the anomaly-signal closure for a single column.
///
/// Column kind is determined from the first non-null value. All subsequent
/// non-null values are assumed to be the same kind (well-formed dataset).
/// An all-null column returns a zero-signal closure.
fn make_anomaly_signal(
    column_values: &[&DatasetColumnValue],
) -> Box<dyn Fn(&DatasetColumnValue) -> f64> {
    let non_null: Vec<&DatasetColumnValue> = column_values
        .iter()
        .filter(|v| !matches!(v, DatasetColumnValue::Null))
        .copied()
        .collect();

    if non_null.is_empty() {
        return Box::new(|_| 0.0);
    }

    match non_null[0] {
        DatasetColumnValue::Numeric(_) => {
            let values: Vec<f64> = non_null
                .iter()
                .filter_map(|v| if let DatasetColumnValue::Numeric(d) = v { Some(*d) } else { None })
                .collect();
            make_robust_z_score_signal(values)
        }
        DatasetColumnValue::Categorical(_) => {
            let values: Vec<String> = non_null
                .iter()
                .filter_map(|v| {
                    if let DatasetColumnValue::Categorical(s) = v {
                        Some(s.clone())
                    } else {
                        None
                    }
                })
                .collect();
            make_categorical_rarity_signal(values)
        }
        DatasetColumnValue::Null => Box::new(|_| 0.0),
    }
}

// MARK: - Private: numeric signal (robust z-score)

/// Build a robust z-score anomaly signal closure for a numeric column.
///
/// `anomaly_signal(x) = |x - median| / (1.4826 × MAD)`
///
/// The 1.4826 constant is the consistency factor making MAD asymptotically
/// consistent with the standard deviation under a normal distribution:
///   `1.4826 ≈ 1 / Φ⁻¹(0.75)`
/// where `Φ⁻¹` is the inverse standard normal CDF (quantile function).
///
/// When `scaled_mad = 0` (constant column), returns 0.0 for every input.
fn make_robust_z_score_signal(values: Vec<f64>) -> Box<dyn Fn(&DatasetColumnValue) -> f64> {
    let med = median_f64(&values);
    let deviations: Vec<f64> = values.iter().map(|&x| (x - med).abs()).collect();
    let mad = median_f64(&deviations);

    // MAD consistency factor: 1 / Φ⁻¹(0.75) ≈ 1.4826.
    let mad_scale = 1.4826_f64;
    let scaled_mad = mad_scale * mad;

    if scaled_mad == 0.0 {
        // Zero-variation: no row is distinguishable on this column.
        return Box::new(|_| 0.0);
    }

    Box::new(move |value: &DatasetColumnValue| match value {
        DatasetColumnValue::Numeric(v) => (v - med).abs() / scaled_mad,
        _ => 0.0,
    })
}

// MARK: - Private: categorical signal (rarity)

/// Build a categorical rarity signal closure.
///
/// `rarity(v) = -log2(count(v) / total_non_null)`
///
/// Rare values yield high rarity (high anomaly signal). Values not seen
/// during column statistics get signal 0.0.
fn make_categorical_rarity_signal(values: Vec<String>) -> Box<dyn Fn(&DatasetColumnValue) -> f64> {
    let total = values.len() as f64;
    let mut freq: HashMap<String, usize> = HashMap::new();
    for v in &values {
        *freq.entry(v.clone()).or_insert(0) += 1;
    }

    Box::new(move |value: &DatasetColumnValue| match value {
        DatasetColumnValue::Categorical(s) => {
            match freq.get(s) {
                Some(&count) => {
                    let p = count as f64 / total;
                    // -log2(p) is the self-information (rarity) of this value.
                    // Using f64::log2 — correctly rounded on ARM64 (same libm as Swift).
                    -p.log2()
                }
                None => 0.0, // unseen value: treat as non-anomalous
            }
        }
        _ => 0.0,
    })
}

// MARK: - Private: median

/// Compute the median of a non-empty f64 slice.
///
/// For even-length arrays: arithmetic mean of the two middle values (f64).
/// For odd-length arrays: the single middle value.
/// The slice is sorted into a local Vec; the caller's data is unchanged.
///
/// All arithmetic f64. No f32 conversion.
fn median_f64(values: &[f64]) -> f64 {
    debug_assert!(!values.is_empty(), "median called on empty slice");
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = sorted.len();
    if n % 2 == 0 {
        // Even: average of the two middle values. Exact f64 arithmetic.
        (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    } else {
        // Odd: exact middle value.
        sorted[n / 2]
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn cat(s: &str) -> DatasetColumnValue { DatasetColumnValue::Categorical(s.to_string()) }
    fn num(v: f64) -> DatasetColumnValue { DatasetColumnValue::Numeric(v) }
    fn null() -> DatasetColumnValue { DatasetColumnValue::Null }

    // DCH-1 (Rust): empty rows yields empty output.
    #[test]
    fn empty_rows_yields_empty_output() {
        let out = run_dataset_cohesion(&[], 10, SCAN_CAP);
        assert!(out.top_anomalies.is_empty());
        assert_eq!(out.rows_scored, 0);
    }

    // DCH-2 (Rust): constant numeric column contributes zero to every row score.
    #[test]
    fn constant_numeric_column_contributes_zero_signal() {
        let rows = vec![vec![num(5.0)], vec![num(5.0)], vec![num(5.0)]];
        let out = run_dataset_cohesion(&rows, 3, SCAN_CAP);
        assert_eq!(out.rows_scored, 3);
        for a in &out.top_anomalies {
            assert_eq!(a.score, 0.0, "constant column: every row score = 0");
        }
    }

    // DCH-3 (Rust): outlier numeric row has highest score.
    // Values: [1,2,3,4,5,6,7,8,9,100], median=5.5, MAD=2.5, scaledMAD=3.7065.
    // signal(100)=94.5/3.7065≈25.5; row 9 is the clear outlier.
    #[test]
    fn numeric_outlier_row_has_highest_score() {
        let values: Vec<f64> = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 100.0];
        let rows: Vec<Vec<DatasetColumnValue>> = values.iter().map(|&v| vec![num(v)]).collect();
        let out = run_dataset_cohesion(&rows, 1, SCAN_CAP);
        assert_eq!(out.rows_scored, 10);
        let top = out.top_anomalies.first().expect("must have one result");
        assert_eq!(top.row_index, 9, "planted outlier at index 9 must be top anomaly");
        assert!(top.score > 10.0, "outlier z-score ≈ 25.5; score must exceed 10");
    }

    // DCH-4 (Rust): rare categorical value has higher anomaly than common.
    #[test]
    fn rare_categorical_value_higher_anomaly_than_common() {
        let mut rows: Vec<Vec<DatasetColumnValue>> = (0..9).map(|_| vec![cat("common")]).collect();
        rows.push(vec![cat("rare")]);
        let out = run_dataset_cohesion(&rows, 1, SCAN_CAP);
        assert_eq!(
            out.top_anomalies.first().map(|a| a.row_index),
            Some(9),
            "the rare categorical at index 9 must be the top anomaly"
        );
    }

    // DCH-5 (Rust): null values contribute 0.0 to row score.
    #[test]
    fn null_values_contribute_zero_to_row_score() {
        let mut rows: Vec<Vec<DatasetColumnValue>> = (0..8).map(|_| vec![num(10.0), cat("A")]).collect();
        rows.push(vec![num(50.0), cat("B")]);  // mild outlier at index 8
        rows.push(vec![null(), null()]);         // all-null row at index 9
        let out = run_dataset_cohesion(&rows, 10, SCAN_CAP);
        let null_row = out.top_anomalies.iter().find(|a| a.row_index == 9);
        assert!(null_row.is_some(), "all-null row at index 9 must appear in top_n=10");
        assert_eq!(null_row.unwrap().score, 0.0, "all-null row must have zero score");
    }

    // DCH-6 (Rust): scan cap limits scored rows.
    #[test]
    fn scan_cap_limits_scored_rows() {
        let rows: Vec<Vec<DatasetColumnValue>> = (0..100)
            .map(|i| vec![num(i as f64)])
            .collect();
        let out = run_dataset_cohesion(&rows, 3, 5);
        assert_eq!(out.rows_scored, 5);
        for a in &out.top_anomalies {
            assert!(a.row_index < 5, "all row indices must be < max_rows=5");
        }
    }

    // DCH-7 (Rust): tie-breaking by row_index ascending.
    #[test]
    fn tie_breaking_by_row_index_ascending() {
        let rows = vec![
            vec![cat("X")],
            vec![cat("X")],
            vec![cat("X")],
        ];
        let out = run_dataset_cohesion(&rows, 3, SCAN_CAP);
        assert_eq!(out.top_anomalies.len(), 3);
        let indices: Vec<usize> = out.top_anomalies.iter().map(|a| a.row_index).collect();
        assert_eq!(indices, vec![0, 1, 2], "tie-break must sort by row_index ascending");
    }

    // DCH-8 (Rust): SCAN_CAP constant is 10,000.
    #[test]
    fn scan_cap_constant_is_10000() {
        assert_eq!(SCAN_CAP, 10_000);
    }

    // DCH-9 (Rust): fixture conformance — planted outlier at row 9 is top anomaly.
    //
    // Fixture from dataset_vectors.json (same input as Swift DCH-9):
    //   Rows 0-2: numeric=2.0, cat="A", label="αλφα"
    //   Rows 3-5: numeric=6.0, cat="A", label="αλφα"
    //   Rows 6-8: numeric=10.0, cat="B", label="βήτα"
    //   Row 9:   numeric=100.0, cat="C", label="γάμα"  ← planted outlier
    //
    // Score column: median=6.0, MAD=4.0, scaledMAD=1.4826*4.0.
    // Category/label freqs: A/αλφα=6/10=0.6, B/βήτα=3/10=0.3, C/γάμα=1/10=0.1.
    // Row score ordering: row9 >> rows6-8 > rows0-2 > rows3-5.
    //
    // Non-ASCII labels ("αλφα", "βήτα", "γάμα") exercise byte-order discipline:
    // their rarity signals must be computed correctly via f64::log2 on their
    // frequency as UTF-8 strings.
    #[test]
    fn fixture_conformance_planted_outlier_is_top() {
        let rows = fixture_rows();
        let out = run_dataset_cohesion(&rows, 10, SCAN_CAP);
        assert_eq!(out.rows_scored, 10);

        // Row 9 must be the top anomaly.
        let top = out.top_anomalies.first().expect("must have anomalies");
        assert_eq!(top.row_index, 9, "row 9 (score=100, C, γάμα) must be top anomaly");

        // Build score lookup.
        let mut scores = vec![0.0_f64; 10];
        for a in &out.top_anomalies {
            scores[a.row_index] = a.score;
        }

        // Score ordering (from derivation comment above):
        //   row9 > rows6-8 > rows0-2 > rows3-5
        assert!(scores[9] > scores[6], "row 9 must exceed rows 6-8");
        assert_eq!(scores[6], scores[7], "rows 6 and 7 must be equal");
        assert_eq!(scores[7], scores[8], "rows 7 and 8 must be equal");
        assert!(scores[6] > scores[0], "rows 6-8 must exceed rows 0-2");
        assert_eq!(scores[0], scores[1], "rows 0 and 1 must be equal");
        assert_eq!(scores[1], scores[2], "rows 1 and 2 must be equal");
        assert!(scores[0] > scores[3], "rows 0-2 must exceed rows 3-5");
        assert_eq!(scores[3], scores[4], "rows 3 and 4 must be equal");
        assert_eq!(scores[4], scores[5], "rows 4 and 5 must be equal");

        // Row 9 score must exceed 2*log2(10) from its two rare categorical values alone.
        // (2 * log2(10) ≈ 6.64; the numeric signal adds further.)
        assert!(
            scores[9] > 2.0 * 10.0_f64.log2(),
            "row 9 score {} must exceed 2*log2(10) ≈ {:.4}",
            scores[9],
            2.0 * 10.0_f64.log2()
        );
    }

    // DCH-10 (Rust): numeric and categorical signals sum independently.
    // Same derivation as Swift DCH-10.
    #[test]
    fn numeric_and_categorical_signals_sum_independently() {
        let rows: Vec<Vec<DatasetColumnValue>> = vec![
            vec![num(3.0),   cat("A")],  // row 0
            vec![num(3.0),   cat("A")],  // row 1
            vec![num(3.0),   cat("A")],  // row 2
            vec![num(7.0),   cat("A")],  // row 3
            vec![num(7.0),   cat("A")],  // row 4
            vec![num(7.0),   cat("A")],  // row 5
            vec![num(10.0),  cat("A")],  // row 6
            vec![num(10.0),  cat("A")],  // row 7
            vec![num(3.0),   cat("B")],  // row 8: same numeric as 0-2, rare cat
            vec![num(100.0), cat("B")],  // row 9: extreme numeric + rare cat
        ];
        let out = run_dataset_cohesion(&rows, 10, SCAN_CAP);
        let mut scores = vec![0.0_f64; 10];
        for a in &out.top_anomalies {
            scores[a.row_index] = a.score;
        }
        assert!(scores[9] > scores[8], "row 9 (extreme+rare) > row 8 (mild+rare)");
        assert!(scores[8] > scores[0], "row 8 (rare cat) > row 0 (common cat) for same numeric");
        assert_eq!(
            out.top_anomalies.first().map(|a| a.row_index),
            Some(9),
            "row 9 must be top anomaly"
        );
    }

    // MARK: - Helpers

    /// Build the 10-row fixture matching dataset_vectors.json cohesion rows.
    /// Column order: [score (Numeric), category (Categorical), label (Categorical)].
    fn fixture_rows() -> Vec<Vec<DatasetColumnValue>> {
        vec![
            vec![num(2.0),   cat("A"), cat("αλφα")],
            vec![num(2.0),   cat("A"), cat("αλφα")],
            vec![num(2.0),   cat("A"), cat("αλφα")],
            vec![num(6.0),   cat("A"), cat("αλφα")],
            vec![num(6.0),   cat("A"), cat("αλφα")],
            vec![num(6.0),   cat("A"), cat("αλφα")],
            vec![num(10.0),  cat("B"), cat("βήτα")],
            vec![num(10.0),  cat("B"), cat("βήτα")],
            vec![num(10.0),  cat("B"), cat("βήτα")],
            vec![num(100.0), cat("C"), cat("γάμα")],
        ]
    }
}
