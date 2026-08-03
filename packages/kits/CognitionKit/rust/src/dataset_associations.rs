//! Dataset column association-rules entry point — reuses the facet-matrix path
//! (MatrixO + SubstrateML mine_association_rules) over user-supplied column-value rows.
//!
//! Rust twin of `CognitionKit/Sources/CognitionKit/DatasetAssociations.swift`.
//!
//! This entry point is the dataset-targeted twin of `association_rules_recipe`:
//! instead of projecting Drawer categorical facets (room, kind, channel,
//! sensitivity) into the co-occurrence matrix, it projects dataset column
//! values. Each column value is expressed as a "columnName:value" label —
//! the same vocabulary pattern as `association_rules_recipe` — enabling
//! symmetric interpretation of the mined rules.
//!
//! ## Design
//! Columns ARE the facets. One row in the dataset maps to one transaction in
//! the association-rule sense. Each (column, value) pair contributes a
//! presence item in the MatrixO row. Rules then read as "columnA:X often
//! co-occurs with columnB:Y in the same row."
//!
//! ## Null handling
//! Callers must exclude null-valued columns from the row map before calling
//! `run_dataset_associations`. Null values have no natural label and
//! contribute no presence item.
//!
//! ## Label cap
//! Up to 64 distinct "columnName:value" labels are indexed (alphabetical sort
//! order, matching `association_rules_recipe` overflow behavior). If the
//! distinct label count exceeds 64, `label_overflow` is set and the
//! alphabetically-first 64 labels are kept.
//!
//! ## Support/confidence semantics
//! Identical to `association_rules_recipe` — the engine is the same
//! (`mine_association_rules`). Thresholds are caller-supplied; zero thresholds
//! return all rules.

use std::collections::{BTreeSet, HashMap};

use substrate_ml::association_rule_mining::{mine_association_rules, MiningThresholds};
use substrate_types::MatrixO;

use crate::association_rules_recipe::AssociationRuleResult;

/// Output of the dataset association-rule mining.
///
/// Mirrors Swift `DatasetAssociations.Output`.
#[derive(Debug, Clone, PartialEq)]
pub struct DatasetAssociationsOutput {
    /// Mined rules with "columnName:value" labels, in ascending packed
    /// (antecedent, consequent) label-index order (deterministic within a call).
    pub rules: Vec<AssociationRuleResult>,
    /// Number of rows the matrix was built from.
    pub row_count: usize,
    /// True if the distinct label count exceeded 64 and was capped.
    pub label_overflow: bool,
}

/// Capacity constant: MatrixO requires field < 64 (6-bit field index).
/// Matches the cap in `association_rules_recipe`.
const MAX_FIELD_COUNT: usize = 64;

/// Run association-rule mining across categorical columns of one dataset.
///
/// - `rows`: Each row is a map of columnName → value. Null values must be
///   excluded by the caller (missing keys contribute no label).
/// - `thresholds`: Minimum support and confidence gates for rule emission.
///   `MiningThresholds::new(0.0, 0.0)` returns all rules.
///
/// Mirrors Swift `DatasetAssociations.run(rows:thresholds:)`.
pub fn run_dataset_associations(
    rows: &[HashMap<String, String>],
    thresholds: MiningThresholds,
) -> DatasetAssociationsOutput {
    if rows.is_empty() {
        return DatasetAssociationsOutput {
            rules: vec![],
            row_count: 0,
            label_overflow: false,
        };
    }

    // 1. Build per-call sorted label vocabulary from all (column, value) pairs.
    let mut seen: BTreeSet<String> = BTreeSet::new();
    for row in rows {
        for (col, val) in row {
            // Label format "columnName:value" mirrors AssociationRules' "axis:caseName"
            // vocabulary. BTreeSet gives sorted iteration automatically.
            seen.insert(format!("{}:{}", col, val));
        }
    }
    let all_labels: Vec<String> = seen.into_iter().collect(); // BTreeSet is sorted
    let label_overflow = all_labels.len() > MAX_FIELD_COUNT;
    let labels: Vec<String> = if label_overflow {
        all_labels.into_iter().take(MAX_FIELD_COUNT).collect()
    } else {
        all_labels
    };

    // 2. Build MatrixO: each row contributes presence items for its column labels.
    let mut matrix = MatrixO::new();
    for row in rows {
        let mut field_values: Vec<(u8, u8)> = Vec::new();
        for (col, val) in row {
            let label = format!("{}:{}", col, val);
            // Linear search over ≤ 64 labels; same as association_rules_recipe.
            if let Some(idx) = labels.iter().position(|l| l == &label) {
                field_values.push((idx as u8, 1u8));
            }
        }
        matrix.apply_row(1, &field_values);
    }

    // 3. Mine pairwise association rules (engine owns all metric computation).
    let raw_rules = mine_association_rules(&matrix, rows.len() as i64, thresholds);

    // 4. Relabel packed item indices back to "columnName:value" strings.
    let rules: Vec<AssociationRuleResult> = raw_rules
        .into_iter()
        .filter_map(|rule| {
            let ai = rule.antecedent.field as usize;
            let ci = rule.consequent.field as usize;
            if ai < labels.len() && ci < labels.len() {
                Some(AssociationRuleResult {
                    antecedent: labels[ai].clone(),
                    consequent: labels[ci].clone(),
                    support: rule.support,
                    confidence: rule.confidence,
                    lift: rule.lift,
                    conviction: rule.conviction,
                    leverage: rule.leverage,
                    // Dataset rows are not drawers and carry no drawer
                    // identity — exemplars are an estate-mode concept.
                    exemplar_drawer_ids: vec![],
                })
            } else {
                None
            }
        })
        .collect();

    DatasetAssociationsOutput {
        rules,
        row_count: rows.len(),
        label_overflow,
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn zero_thresholds() -> MiningThresholds {
        MiningThresholds::new(0.0, 0.0)
    }

    // DSA-1 (Rust): empty rows produce no rules.
    #[test]
    fn empty_rows_produce_no_rules() {
        let out = run_dataset_associations(&[], zero_thresholds());
        assert!(out.rules.is_empty());
        assert_eq!(out.row_count, 0);
        assert!(!out.label_overflow);
    }

    // DSA-2 (Rust): perfectly co-occurring columns produce rules.
    #[test]
    fn perfectly_co_occurring_columns_produce_rules() {
        let rows = vec![
            [("color".to_string(), "red".to_string()),
             ("fruit".to_string(), "apple".to_string())].into_iter().collect(),
            [("color".to_string(), "red".to_string()),
             ("fruit".to_string(), "apple".to_string())].into_iter().collect(),
            [("color".to_string(), "blue".to_string()),
             ("fruit".to_string(), "blueberry".to_string())].into_iter().collect(),
            [("color".to_string(), "blue".to_string()),
             ("fruit".to_string(), "blueberry".to_string())].into_iter().collect(),
        ];
        let out = run_dataset_associations(&rows, zero_thresholds());
        assert!(!out.rules.is_empty(), "co-occurring columns must produce rules");
        assert_eq!(out.row_count, 4);
        let high_conf: Vec<_> = out.rules.iter().filter(|r| r.confidence >= 0.99).collect();
        assert!(!high_conf.is_empty(), "at least one rule with confidence=1.0");
    }

    // DSA-3 (Rust): label format is "columnName:value".
    #[test]
    fn labels_use_column_name_value_format() {
        let rows: Vec<HashMap<String, String>> = vec![
            [("color".to_string(), "red".to_string()),
             ("fruit".to_string(), "apple".to_string())].into_iter().collect(),
            [("color".to_string(), "blue".to_string()),
             ("fruit".to_string(), "blueberry".to_string())].into_iter().collect(),
        ];
        let out = run_dataset_associations(&rows, zero_thresholds());
        for rule in &out.rules {
            assert!(
                rule.antecedent.contains(':'),
                "antecedent '{}' must be 'columnName:value'",
                rule.antecedent
            );
            assert!(
                rule.consequent.contains(':'),
                "consequent '{}' must be 'columnName:value'",
                rule.consequent
            );
        }
    }

    // DSA-4 (Rust): label overflow flagged when distinct labels exceed 64.
    #[test]
    fn label_overflow_flagged_at_cap() {
        let rows: Vec<HashMap<String, String>> = (0..70)
            .map(|i| {
                [("id".to_string(), format!("item{i}")),
                 ("type".to_string(), "common".to_string())]
                    .into_iter()
                    .collect()
            })
            .collect();
        let out = run_dataset_associations(&rows, zero_thresholds());
        assert!(out.label_overflow, "70 unique id labels + 1 type label = 71 > 64");
        assert_eq!(out.row_count, 70);
    }

    // DSA-5 (Rust): high threshold filters low-support rules.
    #[test]
    fn high_threshold_filters_rules() {
        let rows: Vec<HashMap<String, String>> = vec![
            [("a".to_string(), "rare".to_string()),
             ("b".to_string(), "x".to_string())].into_iter().collect(),
            [("a".to_string(), "common".to_string()),
             ("b".to_string(), "x".to_string())].into_iter().collect(),
            [("a".to_string(), "common".to_string()),
             ("b".to_string(), "x".to_string())].into_iter().collect(),
            [("a".to_string(), "common".to_string()),
             ("b".to_string(), "x".to_string())].into_iter().collect(),
        ];
        let all = run_dataset_associations(&rows, zero_thresholds());
        let filtered = run_dataset_associations(&rows, MiningThresholds::new(0.9, 0.9));
        assert!(filtered.rules.len() <= all.rules.len());
    }

    // DSA-6 (Rust): determinism — same rows twice yields same output.
    #[test]
    fn deterministic_output_for_same_input() {
        let rows: Vec<HashMap<String, String>> = vec![
            [("x".to_string(), "1".to_string()),
             ("y".to_string(), "a".to_string())].into_iter().collect(),
            [("x".to_string(), "2".to_string()),
             ("y".to_string(), "b".to_string())].into_iter().collect(),
            [("x".to_string(), "1".to_string()),
             ("y".to_string(), "a".to_string())].into_iter().collect(),
        ];
        let out1 = run_dataset_associations(&rows, zero_thresholds());
        let out2 = run_dataset_associations(&rows, zero_thresholds());
        assert_eq!(out1.row_count, out2.row_count);
        assert_eq!(out1.label_overflow, out2.label_overflow);
        assert_eq!(out1.rules.len(), out2.rules.len());
        for (r1, r2) in out1.rules.iter().zip(out2.rules.iter()) {
            assert_eq!(r1.antecedent, r2.antecedent);
            assert_eq!(r1.consequent, r2.consequent);
        }
    }

    // DSA-7 (Rust): fixture conformance — 4-row dataset from dataset_vectors.json.
    // color:red↔fruit:apple and color:blue↔fruit:blueberry are perfect co-occurrences.
    #[test]
    fn fixture_conformance_four_row_dataset() {
        // Mirrors dataset_vectors.json "datasetAssociations" fixture.
        let rows: Vec<HashMap<String, String>> = vec![
            [("color".to_string(), "red".to_string()),
             ("fruit".to_string(), "apple".to_string())].into_iter().collect(),
            [("color".to_string(), "red".to_string()),
             ("fruit".to_string(), "apple".to_string())].into_iter().collect(),
            [("color".to_string(), "blue".to_string()),
             ("fruit".to_string(), "blueberry".to_string())].into_iter().collect(),
            [("color".to_string(), "blue".to_string()),
             ("fruit".to_string(), "blueberry".to_string())].into_iter().collect(),
        ];
        let expected_labels = ["color:blue", "color:red", "fruit:apple", "fruit:blueberry"];
        let out = run_dataset_associations(&rows, zero_thresholds());
        assert_eq!(out.row_count, 4);
        assert!(!out.label_overflow);
        // All rule labels must be in the expected vocabulary.
        for rule in &out.rules {
            assert!(
                expected_labels.contains(&rule.antecedent.as_str()),
                "unexpected antecedent label '{}'",
                rule.antecedent
            );
            assert!(
                expected_labels.contains(&rule.consequent.as_str()),
                "unexpected consequent label '{}'",
                rule.consequent
            );
        }
    }
}
