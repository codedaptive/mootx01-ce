//! Pairwise association-rule mining over the co-occurrence matrix O
//! (cookbook § 6.3) — Rust port of the Swift `AssociationRuleEngine` /
//! `mineAssociationRules` in
//! `NeuronKit/Sources/NeuronKit/AssociationRuleMining.swift`. Per
//! CLAUDE.md neither port leads; both run identical math and are gated
//! against the same hand-computed in-code vectors (the
//! `MMRRank` / `mmr_rank.rs` conformance pattern).
//!
//! Pairwise-only, by the shape of `MatrixO`: `apply_row` iterates all
//! ordered (i, j) field pairs of a row INCLUDING i == j, so the
//! diagonal is retained — `O[(f,v),(f,v)]` is single-item support and
//! `O[(fi,vi),(fj,vj)]` is 2-itemset support. Enough for pairwise
//! rules; NOT enough for k>2 itemsets (those need row-replay).
//!
//! Contract points (verified against `substrate_types::matrix_o`):
//! single-item support comes from the retained DIAGONAL (`O[A,A]`),
//! not `MatrixF`; the diagonal is excluded when EMITTING rules (an
//! `A → A` self-rule has confidence ≡ 1 and carries no information).
//!
//! Metrics, with `N` = active_row_count (injected, never derived):
//!
//! ```text
//! support(A,B)    = O[A,B] / N
//! confidence(A→B) = O[A,B] / O[A,A]
//! lift            = (O[A,B] · N) / (O[A,A] · O[B,B])
//! leverage        = O[A,B]/N − (O[A,A]/N)(O[B,B]/N)
//! conviction      = (1 − O[B,B]/N) / (1 − confidence)   (+inf at confidence == 1)
//! ```
//!
//! Determinism: no clock, no randomness. Rules emit in ascending
//! packed `(antecedent, consequent)` key order — which is exactly the
//! canonical `entries()` order of `MatrixO` — reproduced bit-for-bit
//! across ports.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use substrate_types::MatrixO;

/// A single (field, value) item — one cell of a row's 6-bit field
/// assignment, the unit antecedents and consequents are made of.
///
/// Ordering is on the packed key `(field << 8) | value`, mirroring
/// `CooccurrenceKey`'s packed ordering so rule emission order is
/// fully specified and identical across the Swift and Rust ports.
/// (The derived lexicographic `Ord` over `(field, value)` is the
/// same total order as `packed()`; `packed()` is kept as the
/// documented basis.)
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Item {
    pub field: u8,
    pub value: u8,
}

impl Item {
    pub fn new(field: u8, value: u8) -> Self {
        Self { field, value }
    }

    /// Packed u16 ordering key.
    /// Layout (high → low): field:8 | value:8.
    #[inline]
    pub fn packed(&self) -> u16 {
        ((self.field as u16) << 8) | (self.value as u16)
    }
}

/// One mined pairwise rule `antecedent → consequent` with the five
/// standard metrics. `conviction` is `f64::INFINITY` when
/// confidence == 1 (the consequent always follows the antecedent).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct AssociationRule {
    pub antecedent: Item,
    pub consequent: Item,
    pub support: f64,
    pub confidence: f64,
    pub lift: f64,
    pub conviction: f64,
    pub leverage: f64,
}

/// Minimum-metric gates a candidate rule must clear to be emitted.
/// A rule passes when `support >= min_support` AND
/// `confidence >= min_confidence`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct MiningThresholds {
    pub min_support: f64,
    pub min_confidence: f64,
}

impl MiningThresholds {
    pub fn new(min_support: f64, min_confidence: f64) -> Self {
        Self {
            min_support,
            min_confidence,
        }
    }
}

/// Mines pairwise association rules from a co-occurrence matrix.
/// Mirrors the Swift `mineAssociationRules` / `AssociationRuleEngine.mine`.
///
/// Rules are emitted only for OBSERVED co-occurrences — the
/// off-diagonal cells `MatrixO` actually stores (the matrix drops
/// zero cells, so absent pairs have no observed support and yield no
/// rule regardless of thresholds).
///
/// - `matrix`: the co-occurrence matrix O. Read-only input; the
///   retained diagonal supplies single-item support.
/// - `active_row_count`: `N`, the number of active rows the matrix
///   was accumulated over. Injected by the caller — the engine never
///   derives it. `N <= 0` returns empty.
/// - `thresholds`: minimum support and confidence gates.
///
/// Returns rules sorted ascending on the packed
/// `(antecedent, consequent)` key. The pair is unique per rule, so
/// the order is total — no residual ties.
pub fn mine_association_rules(
    matrix: &MatrixO,
    active_row_count: i64,
    thresholds: MiningThresholds,
) -> Vec<AssociationRule> {
    // Two-pass over the same canonical scan, kept in one body so the
    // conformance-critical control flow (guard order, gate order,
    // emission order) reads top to bottom in both ports.
    // N <= 0: no population to measure support against.
    if active_row_count <= 0 {
        return Vec::new();
    }
    let n = active_row_count as f64;

    // Pass 1 — single-item support off the retained diagonal:
    // O[A,A] for every item the matrix has seen alone or with others.
    // (`apply_row` writes the diagonal on every row, so any item with
    // presence has a diagonal cell.)
    let mut single_support: HashMap<Item, i64> = HashMap::new();
    for (key, count) in matrix.entries() {
        if key.field_i == key.field_j && key.value_i == key.value_j {
            single_support.insert(Item::new(key.field_i, key.value_i), *count);
        }
    }

    // Pass 2 — emit rules from off-diagonal cells, in entry
    // (= packed-key) order.
    let mut rules: Vec<AssociationRule> = Vec::new();
    for (key, count) in matrix.entries() {
        let antecedent = Item::new(key.field_i, key.value_i);
        let consequent = Item::new(key.field_j, key.value_j);

        // The diagonal is support storage, not a rule: an A → A
        // self-rule has confidence ≡ 1 and is excluded.
        if antecedent == consequent {
            continue;
        }

        // O[A,A] == 0: the antecedent has no single-item support to
        // condition on. O[B,B] == 0: the consequent has no base rate
        // for lift/conviction. Either way, skip.
        let count_aa = match single_support.get(&antecedent) {
            Some(&c) if c > 0 => c,
            _ => continue,
        };
        let count_bb = match single_support.get(&consequent) {
            Some(&c) if c > 0 => c,
            _ => continue,
        };

        let count_ab = *count as f64;
        let support = count_ab / n;
        let confidence = count_ab / (count_aa as f64);

        // Threshold gates — below-threshold rules are dropped.
        if support < thresholds.min_support || confidence < thresholds.min_confidence {
            continue;
        }

        let lift = (count_ab * n) / ((count_aa as f64) * (count_bb as f64));
        let leverage = count_ab / n - ((count_aa as f64) / n) * ((count_bb as f64) / n);
        let conviction = if confidence == 1.0 {
            // The consequent never fails to follow the antecedent —
            // conviction's denominator is zero.
            f64::INFINITY
        } else {
            (1.0 - (count_bb as f64) / n) / (1.0 - confidence)
        };

        rules.push(AssociationRule {
            antecedent,
            consequent,
            support,
            confidence,
            lift,
            conviction,
            leverage,
        });
    }

    rules
}

#[cfg(test)]
mod tests {
    //! Conformance fixtures — mirror the Swift
    //! `AssociationRuleMiningTests` hand-computed vectors EXACTLY.
    //! (Fenced as text so the worked arithmetic is not run as a doctest.)
    //!
    //! ```text
    //! Items (packed key = field<<8 | value):
    //!   A = (field 0, value 1)  packed 0x0001
    //!   B = (field 5, value 3)  packed 0x0503
    //!   C = (field 5, value 4)  packed 0x0504
    //!
    //! Main fixture — N = 10 active rows:
    //!   4 rows {A, B}, 2 rows {A, C}, 2 rows {B}, 1 row {A}, 1 row {}
    //!   O[A,A] = 7   O[B,B] = 6   O[C,C] = 2
    //!   O[A,B] = O[B,A] = 4   O[A,C] = O[C,A] = 2   O[B,C] absent
    //!
    //! Rules at thresholds (0, 0), in emission order:
    //!   A→B: sup 4/10, conf 4/7, lift 40/42,
    //!        lev 4/10 − (7/10)(6/10), conv (1 − 6/10)/(1 − 4/7)
    //!   A→C: sup 2/10, conf 2/7, lift 20/14,
    //!        lev 2/10 − (7/10)(2/10), conv (1 − 2/10)/(1 − 2/7)
    //!   B→A: sup 4/10, conf 4/6, lift 40/42,
    //!        lev −0.02, conv (1 − 7/10)/(1 − 4/6)
    //!   C→A: sup 2/10, conf 1 → conv +inf, lift 20/14, lev 0.06
    //! ```
    use super::*;

    /// Documented float tolerance for metric comparisons — matches
    /// the Swift suite's 1e-12.
    const TOLERANCE: f64 = 1e-12;

    fn item_a() -> Item {
        Item::new(0, 1)
    }
    fn item_b() -> Item {
        Item::new(5, 3)
    }
    fn item_c() -> Item {
        Item::new(5, 4)
    }

    const ROW_A: &[(u8, u8)] = &[(0, 1)];
    const ROW_B: &[(u8, u8)] = &[(5, 3)];
    const ROW_AB: &[(u8, u8)] = &[(0, 1), (5, 3)];
    const ROW_AC: &[(u8, u8)] = &[(0, 1), (5, 4)];

    /// Accumulates rows into a MatrixO through the substrate's own
    /// update rule (delta +1 per row, all ordered pairs incl. diagonal).
    fn matrix(rows: &[&[(u8, u8)]]) -> MatrixO {
        let mut o = MatrixO::new();
        for row in rows {
            o.apply_row(1, row);
        }
        o
    }

    /// Main fixture: 4×{A,B}, 2×{A,C}, 2×{B}, 1×{A} — 9 populated
    /// rows; N = 10 counts one additional active row with no mined
    /// fields.
    fn main_matrix() -> MatrixO {
        matrix(&[
            ROW_AB, ROW_AB, ROW_AB, ROW_AB, ROW_AC, ROW_AC, ROW_B, ROW_B, ROW_A,
        ])
    }

    fn zero_thresholds() -> MiningThresholds {
        MiningThresholds::new(0.0, 0.0)
    }

    fn assert_close(actual: f64, expected: f64, label: &str) {
        if expected.is_infinite() {
            assert_eq!(actual, expected, "{label}");
        } else {
            assert!(
                (actual - expected).abs() < TOLERANCE,
                "{label}: actual {actual} expected {expected}"
            );
        }
    }

    // 1. Empty matrix.
    #[test]
    fn empty_matrix_yields_no_rules() {
        let out = mine_association_rules(&MatrixO::new(), 10, zero_thresholds());
        assert!(out.is_empty());
    }

    // 2. Single co-occurring pair — all five metrics.
    #[test]
    fn single_pair_all_five_metrics() {
        // N = 4: 2 rows {A,B}, 1 row {A}, 1 row {B}.
        //   O[A,A] = 3, O[B,B] = 3, O[A,B] = O[B,A] = 2.
        //   A→B (B→A symmetric): sup 2/4, conf 2/3, lift 8/9,
        //   lev 2/4 − (3/4)(3/4), conv (1 − 3/4)/(1 − 2/3).
        let o = matrix(&[ROW_AB, ROW_AB, ROW_A, ROW_B]);
        let out = mine_association_rules(&o, 4, zero_thresholds());

        assert_eq!(out.len(), 2);
        assert_eq!((out[0].antecedent, out[0].consequent), (item_a(), item_b()));
        assert_eq!((out[1].antecedent, out[1].consequent), (item_b(), item_a()));

        for rule in &out {
            assert_close(rule.support, 2.0 / 4.0, "support");
            assert_close(rule.confidence, 2.0 / 3.0, "confidence");
            assert_close(rule.lift, 8.0 / 9.0, "lift");
            assert_close(rule.leverage, 2.0 / 4.0 - (3.0 / 4.0) * (3.0 / 4.0), "leverage");
            assert_close(
                rule.conviction,
                (1.0 - 3.0 / 4.0) / (1.0 - 2.0 / 3.0),
                "conviction",
            );
        }
    }

    // 3. confidence == 1 → conviction == +inf.
    #[test]
    fn confidence_one_yields_infinite_conviction() {
        // Main fixture: C occurs in 2 rows, both with A → O[C,A] =
        // O[C,C] = 2, so confidence(C→A) = 1 exactly.
        let out = mine_association_rules(&main_matrix(), 10, zero_thresholds());
        let rule = out
            .iter()
            .find(|r| r.antecedent == item_c() && r.consequent == item_a())
            .expect("C→A rule present");
        assert_close(rule.confidence, 1.0, "confidence");
        assert_eq!(rule.conviction, f64::INFINITY);
        assert_close(rule.support, 2.0 / 10.0, "support");
        assert_close(rule.lift, 20.0 / 14.0, "lift");
        assert_close(
            rule.leverage,
            2.0 / 10.0 - (2.0 / 10.0) * (7.0 / 10.0),
            "leverage",
        );
    }

    // 4. Threshold gating.
    #[test]
    fn min_support_gates() {
        // support .4 (A↔B pair) passes 0.3; support .2 (A↔C) dropped.
        let out =
            mine_association_rules(&main_matrix(), 10, MiningThresholds::new(0.3, 0.0));
        let pairs: Vec<(Item, Item)> = out.iter().map(|r| (r.antecedent, r.consequent)).collect();
        assert_eq!(pairs, vec![(item_a(), item_b()), (item_b(), item_a())]);
    }

    #[test]
    fn min_confidence_gates() {
        // confidence: A→B 4/7 (drop), A→C 2/7 (drop),
        //             B→A 4/6 (pass), C→A 1.0 (pass).
        let out =
            mine_association_rules(&main_matrix(), 10, MiningThresholds::new(0.0, 0.6));
        let pairs: Vec<(Item, Item)> = out.iter().map(|r| (r.antecedent, r.consequent)).collect();
        assert_eq!(pairs, vec![(item_b(), item_a()), (item_c(), item_a())]);
    }

    // 5. N <= 0.
    #[test]
    fn zero_active_row_count_yields_no_rules() {
        let out = mine_association_rules(&main_matrix(), 0, zero_thresholds());
        assert!(out.is_empty());
    }

    #[test]
    fn negative_active_row_count_yields_no_rules() {
        let out = mine_association_rules(&main_matrix(), -5, zero_thresholds());
        assert!(out.is_empty());
    }

    // 6. Diagonal-only matrix.
    #[test]
    fn diagonal_only_yields_no_rules() {
        // One row with one item: O[A,A] = 1 is the only cell. The
        // diagonal stores support but is excluded from emission.
        let out = mine_association_rules(&matrix(&[ROW_A]), 1, zero_thresholds());
        assert!(out.is_empty());
    }

    // 7. Missing single-item support (engine guards).
    #[test]
    fn missing_antecedent_support_skips() {
        // O[A,B] exists but neither diagonal does (impossible via
        // apply_row; reachable through decay/expunge imbalance).
        use substrate_types::matrix_o::CooccurrenceKey;
        let mut o = MatrixO::new();
        o.increment(CooccurrenceKey::new(0, 1, 5, 3), 2);
        let out = mine_association_rules(&o, 10, zero_thresholds());
        assert!(out.is_empty());
    }

    #[test]
    fn missing_consequent_support_skips() {
        // O[A,B] and O[A,A] exist, O[B,B] does not → consequent guard.
        use substrate_types::matrix_o::CooccurrenceKey;
        let mut o = MatrixO::new();
        o.increment(CooccurrenceKey::new(0, 1, 0, 1), 2);
        o.increment(CooccurrenceKey::new(0, 1, 5, 3), 2);
        let out = mine_association_rules(&o, 10, zero_thresholds());
        assert!(out.is_empty());
    }

    // 8. Emission order — the conformance anchor.
    #[test]
    fn emission_order_is_packed_key_ascending() {
        // [A→B, A→C, B→A, C→A]: (0x0001→0x0503), (0x0001→0x0504),
        // (0x0503→0x0001), (0x0504→0x0001).
        let out = mine_association_rules(&main_matrix(), 10, zero_thresholds());
        let pairs: Vec<(Item, Item)> = out.iter().map(|r| (r.antecedent, r.consequent)).collect();
        assert_eq!(
            pairs,
            vec![
                (item_a(), item_b()),
                (item_a(), item_c()),
                (item_b(), item_a()),
                (item_c(), item_a()),
            ]
        );

        // Full metric sweep over the ordered result, against the
        // worked values in the module-test header.
        assert_close(out[0].support, 4.0 / 10.0, "A→B support");
        assert_close(out[0].confidence, 4.0 / 7.0, "A→B confidence");
        assert_close(out[0].lift, 40.0 / 42.0, "A→B lift");
        assert_close(
            out[0].leverage,
            4.0 / 10.0 - (7.0 / 10.0) * (6.0 / 10.0),
            "A→B leverage",
        );
        assert_close(
            out[0].conviction,
            (1.0 - 6.0 / 10.0) / (1.0 - 4.0 / 7.0),
            "A→B conviction",
        );

        assert_close(out[1].support, 2.0 / 10.0, "A→C support");
        assert_close(out[1].confidence, 2.0 / 7.0, "A→C confidence");
        assert_close(out[1].lift, 20.0 / 14.0, "A→C lift");
        assert_close(
            out[1].leverage,
            2.0 / 10.0 - (7.0 / 10.0) * (2.0 / 10.0),
            "A→C leverage",
        );
        assert_close(
            out[1].conviction,
            (1.0 - 2.0 / 10.0) / (1.0 - 2.0 / 7.0),
            "A→C conviction",
        );

        assert_close(out[2].support, 4.0 / 10.0, "B→A support");
        assert_close(out[2].confidence, 4.0 / 6.0, "B→A confidence");
        assert_close(out[2].lift, 40.0 / 42.0, "B→A lift");
        assert_close(
            out[2].leverage,
            4.0 / 10.0 - (6.0 / 10.0) * (7.0 / 10.0),
            "B→A leverage",
        );
        assert_close(
            out[2].conviction,
            (1.0 - 7.0 / 10.0) / (1.0 - 4.0 / 6.0),
            "B→A conviction",
        );

        assert_close(out[3].support, 2.0 / 10.0, "C→A support");
        assert_close(out[3].confidence, 1.0, "C→A confidence");
        assert_close(out[3].lift, 20.0 / 14.0, "C→A lift");
        assert_close(
            out[3].leverage,
            2.0 / 10.0 - (2.0 / 10.0) * (7.0 / 10.0),
            "C→A leverage",
        );
        assert_eq!(out[3].conviction, f64::INFINITY);
    }

    // 9. Determinism.
    #[test]
    fn two_runs_are_identical() {
        let first = mine_association_rules(&main_matrix(), 10, zero_thresholds());
        let second = mine_association_rules(&main_matrix(), 10, zero_thresholds());
        assert_eq!(first, second);
    }
}
