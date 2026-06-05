//! Standard Apriori algorithm over `RowAttributeView` rows —
//! Rust version of the Swift `AprioriMining` in
//! `SubstrateML/Sources/SubstrateML/AprioriMining.swift`.
//!
//! Per CLAUDE.md neither version leads; both run identical math and are
//! gated against the same conformance vectors encoded in
//! `docs/engineering/substrate_reference/test-harness/vectors/apriori_mining.json`
//! and in the inline tests below.
//!
//! `Item` is re-used from `association_rule_mining` — it is the shared
//! atom type for both engines.
//!
//! Algorithm outline (mirrors Swift):
//!   1. Convert each row to a HashSet<Item>.
//!   2. Find frequent 1-itemsets (support >= min_support).
//!   3. Join: generate size-k candidates from frequent (k-1)-itemsets
//!      that share a lexicographic prefix of length k-2 (Apriori join).
//!   4. Count candidate support with subset tests.
//!   5. Prune candidates below min_support.
//!   6. Repeat 3-5 until k > max_k or no new frequent itemsets.
//!   7. Extract rules from all frequent itemsets of size >= 2;
//!      each item can be the consequent.
//!   8. Filter by min_support, min_confidence, min_lift.
//!   9. Sort: lift DESC, confidence DESC, evidence_count DESC.

use std::collections::{HashMap, HashSet};

use crate::association_rule_mining::Item;

// MARK: - Public types

/// Minimum-metric gates for the Apriori engine.
///
/// `max_k` bounds the total itemset size (antecedent + consequent).
/// At `max_k = 2` (one antecedent item) the output is equivalent to
/// `mine_association_rules` on the same data. Minimum effective value
/// is 2; values below 2 are promoted.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AprioriThresholds {
    pub min_support: f64,
    pub min_confidence: f64,
    pub min_lift: f64,
    /// Maximum total itemset size (antecedent items + 1 consequent).
    pub max_k: usize,
}

impl AprioriThresholds {
    pub fn new(
        min_support: f64,
        min_confidence: f64,
        min_lift: f64,
        max_k: usize,
    ) -> Self {
        Self {
            min_support,
            min_confidence,
            min_lift,
            max_k: max_k.max(2),
        }
    }
}

/// One mined rule `antecedent → consequent` with five standard metrics
/// and a raw evidence count.
///
/// `antecedent` is sorted ascending on `Item`'s natural `(field, value)`
/// order (which is equivalent to packed-key order) for deterministic
/// equality and serialisation across versions.
///
/// `conviction` is `f64::INFINITY` when `confidence >= 1.0`.
#[derive(Debug, Clone, PartialEq)]
pub struct AprioriRule {
    pub antecedent: Vec<Item>,
    pub consequent: Item,
    pub support: f64,
    pub confidence: f64,
    pub lift: f64,
    pub conviction: f64,
    pub leverage: f64,
    /// Raw row count: rows containing the full antecedent ∪ consequent.
    pub evidence_count: usize,
}

// MARK: - Engine

/// Mines multi-antecedent association rules from row-replay data.
///
/// Mirrors `AprioriMining.mine(rows:thresholds:)` in Swift.  Pure function:
/// no estate, no clocks, no randomness.
///
/// - `rows`: each element is a sorted `Vec<Item>` representing one row's
///   categorical features (mirrors `RowAttributeView.attributes`).
/// - `thresholds`: min_support, min_confidence, min_lift, max_k gates.
///
/// Returns rules sorted by lift DESC, confidence DESC, evidence_count DESC.
pub fn mine_apriori_rules(
    rows: &[Vec<Item>],
    thresholds: &AprioriThresholds,
) -> Vec<AprioriRule> {
    if rows.is_empty() {
        return Vec::new();
    }

    let n = rows.len();
    let n_f64 = n as f64;

    // Convert each row to a HashSet<Item> for O(1) membership testing.
    let row_sets: Vec<HashSet<Item>> = rows
        .iter()
        .map(|row| row.iter().copied().collect())
        .collect();

    // --- Level 1: frequent single items ---

    let mut single_counts: HashMap<Item, usize> = HashMap::new();
    for row_set in &row_sets {
        for &item in row_set {
            *single_counts.entry(item).or_insert(0) += 1;
        }
    }

    // `all_frequent`: every frequent itemset → its row count.
    let mut all_frequent: HashMap<Vec<Item>, usize> = HashMap::new();
    let mut prev_level: Vec<Vec<Item>> = Vec::new();

    for (&item, &count) in &single_counts {
        let support = count as f64 / n_f64;
        if support >= thresholds.min_support {
            let key = vec![item];
            all_frequent.insert(key.clone(), count);
            prev_level.push(key);
        }
    }
    prev_level.sort();   // sort by Item's Ord (field, value) lexicographically

    // --- Levels 2..max_k: join, count, prune ---

    for _ in 2..=thresholds.max_k {
        if prev_level.is_empty() {
            break;
        }
        let candidates = apriori_join(&prev_level);
        if candidates.is_empty() {
            break;
        }

        let mut next_level: Vec<Vec<Item>> = Vec::new();
        for candidate in candidates {
            let candidate_set: HashSet<Item> = candidate.iter().copied().collect();
            let count = row_sets
                .iter()
                .filter(|rs| candidate_set.is_subset(rs))
                .count();
            let support = count as f64 / n_f64;
            if support >= thresholds.min_support {
                all_frequent.insert(candidate.clone(), count);
                next_level.push(candidate);
            }
        }
        next_level.sort();
        prev_level = next_level;
    }

    // --- Rule extraction ---
    //
    // Collect itemsets in canonical lexicographic order before iterating.
    // HashMap iteration order is not defined; sorting here makes rule
    // generation order deterministic regardless of Rust/Swift hash layout.

    let mut frequent_itemsets: Vec<&Vec<Item>> = all_frequent
        .keys()
        .filter(|k| k.len() >= 2)
        .collect();
    frequent_itemsets.sort();

    let mut rules: Vec<AprioriRule> = Vec::new();

    for itemset in frequent_itemsets {
        let ab_count = all_frequent[itemset];

        for consequent_idx in 0..itemset.len() {
            let consequent = itemset[consequent_idx];

            // Build antecedent (itemset without consequent, still sorted).
            let antecedent: Vec<Item> = itemset
                .iter()
                .enumerate()
                .filter_map(|(i, &it)| if i != consequent_idx { Some(it) } else { None })
                .collect();

            let a_count = match all_frequent.get(&antecedent) {
                Some(&c) if c > 0 => c,
                _ => continue,
            };

            let b_key = vec![consequent];
            let b_count = match all_frequent.get(&b_key) {
                Some(&c) if c > 0 => c,
                _ => continue,
            };

            let support = ab_count as f64 / n_f64;
            let confidence = ab_count as f64 / a_count as f64;
            // lift = P(A∪B) / (P(A) × P(B))
            let lift = (ab_count as f64 * n_f64)
                / (a_count as f64 * b_count as f64);

            if support < thresholds.min_support
                || confidence < thresholds.min_confidence
                || lift < thresholds.min_lift
            {
                continue;
            }

            let leverage = ab_count as f64 / n_f64
                - (a_count as f64 / n_f64) * (b_count as f64 / n_f64);
            let conviction = if confidence >= 1.0 {
                f64::INFINITY
            } else {
                (1.0 - b_count as f64 / n_f64) / (1.0 - confidence)
            };

            rules.push(AprioriRule {
                antecedent,
                consequent,
                support,
                confidence,
                lift,
                conviction,
                leverage,
                evidence_count: ab_count,
            });
        }
    }

    // Sort: lift DESC, confidence DESC, evidence_count DESC,
    // then lexicographic (antecedent ASC, consequent ASC).
    // The four-key total order guarantees identical output across runs
    // and across Swift/Rust dictionary implementations.
    rules.sort_by(|a, b| {
        b.lift
            .partial_cmp(&a.lift)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                b.confidence
                    .partial_cmp(&a.confidence)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| b.evidence_count.cmp(&a.evidence_count))
            .then_with(|| a.antecedent.cmp(&b.antecedent))
            .then_with(|| a.consequent.cmp(&b.consequent))
    });

    rules
}

// MARK: - Internal helpers

/// Apriori join step: produce size-k candidates from sorted (k-1)-itemsets.
///
/// Two (k-1)-itemsets join when they share the first k-2 items
/// (the prefix condition).  Since `level` is sorted, itemsets sharing
/// a prefix are adjacent — the O(n^2) scan is efficient in practice.
///
/// For k=2 (from 1-itemsets): all pairs combine (prefix of length 0
/// is vacuously shared).
fn apriori_join(level: &[Vec<Item>]) -> Vec<Vec<Item>> {
    if level.is_empty() {
        return Vec::new();
    }
    let prev_k = level[0].len();
    let prefix_len = if prev_k > 0 { prev_k - 1 } else { 0 };

    let mut candidates = Vec::new();
    for i in 0..level.len() {
        for j in (i + 1)..level.len() {
            let a = &level[i];
            let b = &level[j];

            // Shared-prefix condition.
            let shared = a[..prefix_len] == b[..prefix_len];

            if shared {
                // a and b differ only at position prev_k-1 (the last item).
                // Since level is sorted and i < j, a[prev_k-1] < b[prev_k-1].
                let mut candidate = a.clone();
                candidate.push(b[prev_k - 1]);
                candidates.push(candidate);
            }
        }
    }
    candidates
}

// MARK: - Inline conformance tests

#[cfg(test)]
mod tests {
    use super::*;

    const EPS: f64 = 1e-12;

    fn near(a: f64, b: f64) -> bool {
        (a - b).abs() < EPS
    }

    /// Helper: build a row as a sorted Vec<Item>.
    fn row(pairs: &[(u8, u8)]) -> Vec<Item> {
        let mut items: Vec<Item> = pairs.iter().map(|&(f, v)| Item::new(f, v)).collect();
        items.sort();
        items
    }

    // --- am-001 ---

    #[test]
    fn am_001_empty_rows_returns_empty_rules() {
        let thresholds = AprioriThresholds::new(0.5, 0.5, 1.0, 2);
        let rules = mine_apriori_rules(&[], &thresholds);
        assert!(rules.is_empty(), "expected no rules for empty input");
    }

    // --- am-002 ---
    //
    // Dataset (N=5):
    //   Rows 0-2: A=(0,1), B=(0,2)
    //   Row  3:   A=(0,1), C=(0,3)
    //   Row  4:   C=(0,3)
    //
    // With min_support=0.5:
    //   {A}: 4, {B}: 3, {C}: 2 (not frequent)
    //   {A,B}: 3 → two pairwise rules
    //
    // Expected (mirrors Swift am-002):
    //   B→A: conf=1.0, lift=1.25, conv=+inf, leverage=0.12, evidence=3
    //   A→B: conf=0.75, lift=1.25, conv=1.6,  leverage=0.12, evidence=3
    //   Sort: same lift + evidence → conf DESC: B→A first

    #[test]
    fn am_002_basic_pairwise_rules() {
        let rows = vec![
            row(&[(0, 1), (0, 2)]),
            row(&[(0, 1), (0, 2)]),
            row(&[(0, 1), (0, 2)]),
            row(&[(0, 1), (0, 3)]),
            row(&[(0, 3)]),
        ];
        let thresholds = AprioriThresholds::new(0.5, 0.5, 1.0, 2);
        let rules = mine_apriori_rules(&rows, &thresholds);

        assert_eq!(rules.len(), 2, "expected exactly 2 rules");

        // Rule 0: B=(0,2) → A=(0,1)
        let r0 = &rules[0];
        assert_eq!(r0.antecedent, vec![Item::new(0, 2)]);
        assert_eq!(r0.consequent, Item::new(0, 1));
        assert!(near(r0.support, 0.6),       "support mismatch: {}", r0.support);
        assert!(near(r0.confidence, 1.0),    "confidence mismatch: {}", r0.confidence);
        assert!(near(r0.lift, 1.25),         "lift mismatch: {}", r0.lift);
        assert!(near(r0.leverage, 0.12),     "leverage mismatch: {}", r0.leverage);
        assert!(r0.conviction.is_infinite(), "conviction should be +inf");
        assert_eq!(r0.evidence_count, 3);

        // Rule 1: A=(0,1) → B=(0,2)
        let r1 = &rules[1];
        assert_eq!(r1.antecedent, vec![Item::new(0, 1)]);
        assert_eq!(r1.consequent, Item::new(0, 2));
        assert!(near(r1.support, 0.6),    "support mismatch: {}", r1.support);
        assert!(near(r1.confidence, 0.75),"confidence mismatch: {}", r1.confidence);
        assert!(near(r1.lift, 1.25),      "lift mismatch: {}", r1.lift);
        assert!(near(r1.leverage, 0.12),  "leverage mismatch: {}", r1.leverage);
        assert!(near(r1.conviction, 1.6), "conviction mismatch: {}", r1.conviction);
        assert_eq!(r1.evidence_count, 3);
    }
}
