//! Dataset column entropy entry point — reuses the existing field-entropy path
//! (neuron_kit::complexity) over user-supplied column value slices.
//!
//! Rust twin of `CognitionKit/Sources/CognitionKit/DatasetComplexity.swift`.
//!
//! This entry point is the dataset-targeted twin of the `complexity_recipe`:
//! instead of deriving count distributions from recalled Drawer fields, it
//! accepts raw column value slices supplied by the tool layer (which fetches
//! them from DatasetStore). The underlying math — `neuron_kit::complexity`,
//! f32 counts, Shannon entropy, optional mutual information — is unchanged.
//!
//! ## Null handling
//! `None` values in `column_a` / `column_b` are EXCLUDED from the entropy
//! computation and counted separately in `null_count`. For the two-column
//! (mutual information) case, rows where EITHER column is `None` are excluded
//! from both distributions (only jointly non-null pairs contribute).
//!
//! ## Tie-breaking / determinism
//! Distinct values with equal count are sorted alphabetically before building
//! the count array, matching the discipline in `distribution()` in
//! `complexity_recipe.rs`. Entropy is a function of the probability
//! distribution, not the labeling; alphabetical bin order does not affect the
//! entropy value — but it does make the joint matrix deterministic, which is
//! required for reproducible mutual-information computation.

use std::collections::HashMap;

use neuron_kit::{complexity, ComplexityResult};

/// Output of a single- or two-column entropy computation.
#[derive(Debug, Clone, PartialEq)]
pub struct ColumnEntropyOutput {
    /// Entropy (and optional mutual information) from `neuron_kit::complexity`.
    /// `result.entropy_a` is the entropy of `column_a`. `result.entropy_b` and
    /// `result.mutual_information` are `Some` only when `column_b` was supplied.
    pub result: ComplexityResult,
    /// Number of non-null values included in the entropy computation.
    /// For the two-column case this is the count of rows where BOTH columns
    /// are non-null.
    pub non_null_count: usize,
    /// Number of values (rows) excluded because at least one column was `None`.
    pub null_count: usize,
}

/// Compute Shannon entropy of a column's value distribution, and optionally
/// mutual information between two columns.
///
/// - `column_a`: String values for the first column. `None` entries are nulls.
/// - `column_b`: Optional second column; when `Some`, mutual information
///   between `column_a` and `column_b` is computed over jointly non-null rows.
///
/// Empty (all-null) input yields `entropy_a = 0.0` (B-8).
///
/// Mirrors Swift `DatasetComplexity.runColumn(columnA:columnB:)`.
pub fn run_dataset_column_entropy<'a>(
    column_a: &[Option<&'a str>],
    column_b: Option<&[Option<&'a str>]>,
) -> ColumnEntropyOutput {
    match column_b {
        Some(b) => run_two_column(column_a, b),
        None => run_single_column(column_a),
    }
}

// MARK: - Private helpers

fn run_single_column(column_a: &[Option<&str>]) -> ColumnEntropyOutput {
    let null_count = column_a.iter().filter(|v| v.is_none()).count();
    let non_null: Vec<&str> = column_a.iter().filter_map(|v| *v).collect();
    let (counts, _) = frequency_counts(&non_null);
    let result = complexity(&counts, None, None);
    ColumnEntropyOutput {
        result,
        non_null_count: non_null.len(),
        null_count,
    }
}

fn run_two_column<'a>(column_a: &[Option<&'a str>], column_b: &[Option<&'a str>]) -> ColumnEntropyOutput {
    // Only rows where BOTH columns are non-null contribute.
    let mut pairs_a: Vec<&str> = Vec::new();
    let mut pairs_b: Vec<&str> = Vec::new();
    let mut null_count = 0usize;
    for (av, bv) in column_a.iter().zip(column_b.iter()) {
        match (av, bv) {
            (Some(a), Some(b)) => {
                pairs_a.push(a);
                pairs_b.push(b);
            }
            _ => null_count += 1,
        }
    }
    let (counts_a, keys_a) = frequency_counts(&pairs_a);
    let (counts_b, keys_b) = frequency_counts(&pairs_b);
    let joint = build_joint_matrix(&pairs_a, &pairs_b, &keys_a, &keys_b);
    let result = complexity(&counts_a, Some(&counts_b), Some(&joint));
    ColumnEntropyOutput {
        result,
        non_null_count: pairs_a.len(),
        null_count,
    }
}

/// Build a sorted frequency count array from a string slice.
///
/// Returns `(counts, keys)` where `keys` is sorted alphabetically so bin
/// order is deterministic — matching the sorted-vocabulary discipline in
/// `complexity_recipe::distribution`.
fn frequency_counts(values: &[&str]) -> (Vec<f32>, Vec<String>) {
    let mut freq: HashMap<String, usize> = HashMap::new();
    for &v in values {
        *freq.entry(v.to_owned()).or_insert(0) += 1;
    }
    let mut keys: Vec<String> = freq.keys().cloned().collect();
    keys.sort();  // alphabetical for determinism
    let counts = keys.iter().map(|k| freq[k] as f32).collect();
    (counts, keys)
}

/// Build a joint count matrix for mutual information.
///
/// `joint[i][j]` = count of rows where `column_a == keys_a[i]` AND
/// `column_b == keys_b[j]`. Keys are the alphabetically sorted distinct
/// values of each column, matching `frequency_counts` ordering.
fn build_joint_matrix(
    pairs_a: &[&str],
    pairs_b: &[&str],
    keys_a: &[String],
    keys_b: &[String],
) -> Vec<Vec<f32>> {
    let idx_a: HashMap<&str, usize> = keys_a.iter().enumerate().map(|(i, k)| (k.as_str(), i)).collect();
    let idx_b: HashMap<&str, usize> = keys_b.iter().enumerate().map(|(i, k)| (k.as_str(), i)).collect();
    let mut matrix = vec![vec![0.0f32; keys_b.len()]; keys_a.len()];
    for (&va, &vb) in pairs_a.iter().zip(pairs_b.iter()) {
        if let (Some(&ia), Some(&ib)) = (idx_a.get(va), idx_b.get(vb)) {
            matrix[ia][ib] += 1.0;
        }
    }
    matrix
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    // DSC-1 (Rust): single-value column has zero entropy.
    #[test]
    fn single_value_column_has_zero_entropy() {
        let col: Vec<Option<&str>> = vec![Some("A"), Some("A"), Some("A"), Some("A")];
        let out = run_dataset_column_entropy(&col, None);
        assert_eq!(out.result.entropy_a, 0.0);
        assert_eq!(out.non_null_count, 4);
        assert_eq!(out.null_count, 0);
    }

    // DSC-2 (Rust): uniform two-value column has entropy 1.0 bit.
    #[test]
    fn uniform_two_value_column_has_entropy_one_bit() {
        let col: Vec<Option<&str>> = vec![Some("A"), Some("A"), Some("B"), Some("B")];
        let out = run_dataset_column_entropy(&col, None);
        assert_eq!(out.result.entropy_a, 1.0);
        assert_eq!(out.non_null_count, 4);
        assert_eq!(out.null_count, 0);
    }

    // DSC-3 (Rust): null values excluded; null_count correct.
    #[test]
    fn null_values_excluded_from_entropy() {
        let col: Vec<Option<&str>> = vec![
            Some("A"), None, Some("A"), Some("A"), Some("A"), Some("A"),
            Some("B"), Some("B"), Some("B"), Some("C"),
        ];
        let out = run_dataset_column_entropy(&col, None);
        assert_eq!(out.non_null_count, 9);
        assert_eq!(out.null_count, 1);
        assert!(out.result.entropy_a > 0.0, "non-uniform distribution must have entropy > 0");
    }

    // DSC-4 (Rust): all-null column yields entropy 0.0 (B-8).
    #[test]
    fn all_null_column_yields_zero_entropy() {
        let col: Vec<Option<&str>> = vec![None, None, None];
        let out = run_dataset_column_entropy(&col, None);
        assert_eq!(out.result.entropy_a, 0.0);
        assert_eq!(out.non_null_count, 0);
        assert_eq!(out.null_count, 3);
    }

    // DSC-5 (Rust): empty column yields entropy 0.0 (B-8).
    #[test]
    fn empty_column_yields_zero_entropy() {
        let out = run_dataset_column_entropy(&[], None);
        assert_eq!(out.result.entropy_a, 0.0);
        assert_eq!(out.non_null_count, 0);
    }

    // DSC-6 (Rust): mutual information present when column_b supplied.
    #[test]
    fn mutual_information_present_with_two_columns() {
        let col_a: Vec<Option<&str>> = vec![Some("X"), Some("X"), Some("Y"), Some("Y")];
        let col_b: Vec<Option<&str>> = vec![Some("1"), Some("1"), Some("2"), Some("2")];
        let out = run_dataset_column_entropy(&col_a, Some(&col_b));
        assert!(out.result.entropy_b.is_some(), "entropy_b must be present for column_b");
        assert!(out.result.mutual_information.is_some(), "MI must be present for column_b");
        if let Some(mi) = out.result.mutual_information {
            assert!(mi > 0.0, "MI must be positive for perfectly correlated columns");
        }
    }

    // DSC-7 (Rust): jointly-null rows excluded from MI.
    #[test]
    fn jointly_null_rows_excluded_from_mi() {
        let col_a: Vec<Option<&str>> = vec![Some("X"), None, Some("Y"), Some("Y")];
        let col_b: Vec<Option<&str>> = vec![Some("1"), Some("1"), Some("2"), Some("2")];
        let out = run_dataset_column_entropy(&col_a, Some(&col_b));
        assert_eq!(out.non_null_count, 3);
        assert_eq!(out.null_count, 1);
    }

    // DSC-8 (Rust): determinism — same input twice yields same output.
    #[test]
    fn deterministic_output_for_same_input() {
        let col: Vec<Option<&str>> = vec![
            Some("A"), Some("A"), Some("B"), Some("C"), Some("B"), Some("A"), None,
        ];
        let out1 = run_dataset_column_entropy(&col, None);
        let out2 = run_dataset_column_entropy(&col, None);
        assert_eq!(out1.result.entropy_a, out2.result.entropy_a);
        assert_eq!(out1.non_null_count, out2.non_null_count);
    }

    // DSC-9 (Rust): fixture conformance — entropy ≈ 1.295 bits for the
    // 3-class distribution in dataset_vectors.json (A×6, B×3, C×1 per 10 rows).
    // Derivation: H = -0.6*log2(0.6) - 0.3*log2(0.3) - 0.1*log2(0.1) ≈ 1.2955 bits.
    // NeuronKit.complexity uses f32 counts; tolerance 2e-3.
    #[test]
    fn fixture_entropy_matches_hand_derived_three_class() {
        // Category column from dataset_vectors.json: A×6, B×3, C×1.
        let col: Vec<Option<&str>> = vec![
            Some("A"), Some("A"), Some("A"), Some("A"), Some("A"), Some("A"),
            Some("B"), Some("B"), Some("B"),
            Some("C"),
        ];
        let out = run_dataset_column_entropy(&col, None);
        assert!(out.result.entropy_a > 0.0);
        assert_eq!(out.non_null_count, 10);
        // H(0.6, 0.3, 0.1) ≈ 1.2955 bits. Tolerance 2e-3 (f32 arithmetic).
        let expected: f32 = 1.2955;
        assert!(
            (out.result.entropy_a - expected).abs() < 2e-3,
            "entropy {} should be near {} bits",
            out.result.entropy_a,
            expected
        );
    }
}
