//! The per-column weight budget the UnionBest + MatrixAware weighted score
//! applies AFTER `signal:*` exclusion and redistribution. Twin of Swift
//! `RecallSignalBudget` (RecallDirector/RecallSignalBudget.swift); the
//! arithmetic, the summation order, and the vectors that pin it are shared.
//!
//! `RecallWeights::adaptive` hands the scoring loop a budget per column.
//! Before COL-1 a column that carried no signal still consumed its budget:
//! the term evaluated to `weight × 0` and the mass the optimizer assigned to
//! it was silently lost. Because the agreement bonus is a FIXED magnitude
//! (0.05) outside the normalised budget, every lost slice made that constant
//! relatively heavier. This type closes the loss: an EXCLUDED column drops
//! out of the budget and the budget it held is redistributed proportionally
//! over the columns that remain, so the included columns always sum to the
//! same total the optimizer assigned.
//!
//! ## Semantics of a `signal:*` weight `s` (see `RecallShape::SIGNAL_*`)
//!
//! - key absent, or `s == 1.0` — NEUTRAL. With every key neutral and no absent
//!   column the resolved budget is BYTE-IDENTICAL to `RecallWeights`
//!   (`total / total` is exactly 1.0; `1.0 × w × 1.0` is exactly `w`).
//! - `s == 0` — EXCLUDE. The column's budget leaves the included total and the
//!   remaining included columns are scaled by `total / included_total`.
//! - `s < 0` — SUPPRESS. The column is subtracted; it stays IN the included
//!   total, so suppression never triggers redistribution.
//! - other `s > 0` — SCALE. No redistribution either; only exclusion does.
//!
//! `signal:agreement` is the one key without a budget slice: the agreement
//! bonus is a fixed additive outside `RecallWeights`, so excluding it removes
//! the bonus and redistributes nothing (there is nothing to redistribute).
//!
//! The per-lane keys that predate this namespace (`locus`, `bm25`, `hamming`,
//! `dense`, `fieldFit`, `coOccurrence`, `temporal`, `graph`, `preference`) keep
//! their contract: they scale a term WITHOUT redistribution and compose
//! multiplicatively on top of this budget.

use std::collections::HashSet;

use crate::recall::RecallWeights;

/// The eight steerable columns, in the fixed order the budget sums them. The
/// order is load-bearing for cross-port byte-identity: both ports accumulate
/// `total` and `included_total` in this exact order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SignalColumn {
    /// The locus (bitmap-lane) column.
    Locus,
    /// The BM25 column.
    Bm25,
    /// The vector budget shared half/half by the Hamming and dense columns.
    Vector,
    /// The field-fit column.
    FieldFit,
    /// The matrix budget shared half/half by coOccurrence and temporal.
    Matrix,
    /// The graph column.
    Graph,
    /// The preference column (draws the same `weights.graph` slice as graph).
    Preference,
    /// The fixed signal-agreement bonus (no budget slice).
    Agreement,
}

impl SignalColumn {
    /// Every budgeted column in summation order (agreement is not budgeted).
    pub const BUDGETED: [SignalColumn; 7] = [
        SignalColumn::Locus,
        SignalColumn::Bm25,
        SignalColumn::Vector,
        SignalColumn::FieldFit,
        SignalColumn::Matrix,
        SignalColumn::Graph,
        SignalColumn::Preference,
    ];

    /// The `RecallShape` lane key that steers this column.
    pub fn lane_key(self) -> &'static str {
        match self {
            SignalColumn::Locus => "signal:locus",
            SignalColumn::Bm25 => "signal:bm25",
            SignalColumn::Vector => "signal:vector",
            SignalColumn::FieldFit => "signal:fieldFit",
            SignalColumn::Matrix => "signal:matrix",
            SignalColumn::Graph => "signal:graph",
            SignalColumn::Preference => "signal:preference",
            SignalColumn::Agreement => "signal:agreement",
        }
    }

    /// The stable short name used in logs and the explainer.
    pub fn name(self) -> &'static str {
        // The key without its `signal:` prefix.
        &self.lane_key()[7..]
    }
}

/// The resolved per-column budget. Field meanings mirror the Swift struct.
#[derive(Debug, Clone, PartialEq)]
pub struct RecallSignalBudget {
    /// Effective budget for the locus column.
    pub locus: f32,
    /// Effective budget for the BM25 column.
    pub bm25: f32,
    /// Effective budget shared by the Hamming and dense columns (half each).
    pub vector: f32,
    /// Effective budget for the field-fit column.
    pub field_fit: f32,
    /// Effective budget shared by the coOccurrence and temporal columns (half each).
    pub matrix: f32,
    /// Effective budget for the graph column.
    pub graph: f32,
    /// Effective budget for the preference column (drawn from `weights.graph`).
    pub preference: f32,
    /// Multiplier on the fixed agreement bonus: `1.0` neutral, `0` excluded,
    /// otherwise the caller's signed scale.
    pub agreement: f32,
    /// The redistribution factor ρ = `total / included_total` every included
    /// column's budget was multiplied by: exactly 1.0 when no column is
    /// excluded (and in the all-excluded case, where nothing was scaled),
    /// greater than 1.0 otherwise. `union_best_mmr_select` multiplies the MMR
    /// similarity term by ρ so the diversity penalty keeps its pre-exclusion
    /// weight against a relevance score that redistribution grew by ρ (COL-2;
    /// Swift `RecallSignalBudget.redistribution` twin).
    pub redistribution: f32,
    /// Columns excluded by a zero key or by absence. Scaled and suppressed
    /// columns are NOT excluded.
    pub excluded: HashSet<SignalColumn>,
}

impl RecallSignalBudget {
    /// Resolve the effective per-column budget.
    ///
    /// * `weights` — the adaptive weights step 8 produced.
    /// * `signal_weight` — resolver for a `signal:*` lane key (`1.0` when the
    ///   key is absent); the same resolver the per-lane keys use, so precedence
    ///   is identical.
    /// * `absent` — columns the coordinator found empty for this recall (an
    ///   empty signal store); excluded exactly as a zero key is.
    ///
    /// Byte-identical to `weights` when every key is neutral and `absent` is
    /// empty.
    pub fn resolve(
        weights: &RecallWeights,
        signal_weight: impl Fn(&str) -> f32,
        absent: &HashSet<SignalColumn>,
    ) -> RecallSignalBudget {
        // Adaptive budget per column, in summation order. Preference draws the
        // graph slice — the shared-budget rule the scoring loop always applied.
        let base: [(SignalColumn, f32); 7] = [
            (SignalColumn::Locus, weights.locus),
            (SignalColumn::Bm25, weights.bm25),
            (SignalColumn::Vector, weights.vector),
            (SignalColumn::FieldFit, weights.field_fit),
            (SignalColumn::Matrix, weights.matrix),
            (SignalColumn::Graph, weights.graph),
            (SignalColumn::Preference, weights.graph),
        ];
        let mut excluded: HashSet<SignalColumn> = HashSet::new();
        let mut total: f32 = 0.0;
        let mut included_total: f32 = 0.0;
        // Signed scale per budgeted column, indexed by position in `base`.
        let mut signed: [f32; 7] = [1.0; 7];
        for (i, (column, w)) in base.iter().enumerate() {
            let s = signal_weight(column.lane_key());
            total += *w;
            if s == 0.0 || absent.contains(column) {
                excluded.insert(*column);
                signed[i] = 0.0;
            } else {
                included_total += *w;
                signed[i] = s;
            }
        }
        // Redistribution factor. `total / included_total` is exactly 1.0 when
        // nothing is excluded (IEEE: x / x == 1.0 for finite non-zero x). When
        // EVERY budgeted column is excluded there is nothing to redistribute
        // to; the factor is 1.0 and every column reads 0.
        let factor: f32 = if included_total > 0.0 { total / included_total } else { 1.0 };
        // Effective budget per budgeted column, in `base` order. The excluded
        // check is done here, before the agreement key can extend the set.
        let mut effective: [f32; 7] = [0.0; 7];
        for (i, (column, w)) in base.iter().enumerate() {
            if !excluded.contains(column) {
                effective[i] = signed[i] * *w * factor;
            }
        }
        // Agreement has no adaptive slice: its weight is the signed scale itself.
        let agreement = if absent.contains(&SignalColumn::Agreement) {
            0.0
        } else {
            signal_weight(SignalColumn::Agreement.lane_key())
        };
        if agreement == 0.0 {
            excluded.insert(SignalColumn::Agreement);
        }
        RecallSignalBudget {
            locus: effective[0],
            bm25: effective[1],
            vector: effective[2],
            field_fit: effective[3],
            matrix: effective[4],
            graph: effective[5],
            preference: effective[6],
            agreement,
            redistribution: factor,
            excluded,
        }
    }
}
