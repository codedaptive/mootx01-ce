//! THE ABLATION GRID — the named set of reduction compositions the gauntlet
//! ranks. Rust port of
//! `NeuronKit/Sources/NeuronKit/Reduction/CompositionGrid.swift`.
//!
//! This is an ABLATION, not a tournament: every composition is kept (a
//! non-winner serves other recall needs). None is pre-judged; the gauntlet
//! ranks them. The grid is data — each entry is a `ReductionComposition` value.
//!
//! The name set, term sets, weights, and `mmr_lambda` values are byte-identical
//! to the Swift grid. The grid-sync conformance test
//! (`tests/composition_grid_sync.rs`) asserts every name in the SHARED fixture
//! `tools/mcp-benchmarker/conformance/composition-grid.json` exists here, in
//! the fixture's order — so a divergence between the Swift grid, the Rust grid,
//! and the benchmarker's column list fails tests in BOTH languages.

use crate::reduction_composition::{ReductionComposition, WeightedSignal};
use crate::reduction_signals::ReductionSignal::{
    Assembly, Bm25, Dense, Hamming, Lattice, Matrix, Mmr, TemporalState, TemporalText, Text,
    TokenExact, Vector,
};

/// The default composition name (the current text-only precise reduce).
pub const DEFAULT_NAME: &str = "text";

/// Every composition in the grid, in a stable enumeration order — identical to
/// Swift `NeuronKit.CompositionGrid.all`. Single-signal compositions isolate one
/// signal's contribution; combined and weighted-all compositions test
/// interactions.
pub fn all() -> Vec<ReductionComposition> {
    vec![
        // --- single-signal isolations ---
        ReductionComposition::new("text", vec![WeightedSignal::new(Text)]),
        ReductionComposition::new("hamming", vec![WeightedSignal::new(Hamming)]),
        ReductionComposition::new("matrix", vec![WeightedSignal::new(Matrix)]),
        ReductionComposition::new("lattice", vec![WeightedSignal::new(Lattice)]),
        ReductionComposition::new("tokenExact", vec![WeightedSignal::new(TokenExact)]),
        ReductionComposition::new("bm25", vec![WeightedSignal::new(Bm25)]),
        ReductionComposition::new("vector", vec![WeightedSignal::new(Vector)]),
        // --- pairwise / combination compositions ---
        ReductionComposition::new(
            "hamming+tokenExact",
            vec![WeightedSignal::new(Hamming), WeightedSignal::new(TokenExact)],
        ),
        ReductionComposition::new(
            "hamming+text",
            vec![WeightedSignal::new(Hamming), WeightedSignal::new(Text)],
        ),
        ReductionComposition::new(
            "text+matrix",
            vec![WeightedSignal::new(Text), WeightedSignal::new(Matrix)],
        ),
        ReductionComposition::new(
            "lattice+hamming",
            vec![WeightedSignal::new(Lattice), WeightedSignal::new(Hamming)],
        ),
        ReductionComposition::new(
            "text+tokenExact",
            vec![WeightedSignal::new(Text), WeightedSignal::new(TokenExact)],
        ),
        // --- diversity-aware composition ---
        ReductionComposition::with_lambda(
            "text+mmr",
            vec![WeightedSignal::new(Text), WeightedSignal::new(Mmr)],
            0.7,
        ),
        // --- T3 temporal: current-over-superseded ---
        ReductionComposition::new("temporalState", vec![WeightedSignal::new(TemporalState)]),
        ReductionComposition::new("temporalText", vec![WeightedSignal::new(TemporalText)]),
        ReductionComposition::new(
            "temporal",
            vec![
                WeightedSignal::new(TemporalState),
                WeightedSignal::new(TemporalText),
            ],
        ),
        ReductionComposition::new(
            "text+temporal",
            vec![
                WeightedSignal::weighted(Text, 1.0),
                WeightedSignal::weighted(TemporalText, 0.8),
                WeightedSignal::weighted(TemporalState, 0.4),
            ],
        ),
        // --- T4 split-fact assembly ---
        ReductionComposition::new(
            "text+assembly",
            vec![WeightedSignal::new(Text), WeightedSignal::new(Assembly)],
        ),
        ReductionComposition::new(
            "tokenExact+assembly",
            vec![WeightedSignal::new(TokenExact), WeightedSignal::new(Assembly)],
        ),
        // --- T5 association: matrix co-occurrence ---
        ReductionComposition::new(
            "matrix-weighted",
            vec![
                WeightedSignal::weighted(Text, 1.0),
                WeightedSignal::weighted(Matrix, 0.8),
            ],
        ),
        ReductionComposition::new(
            "matrix+hamming",
            vec![WeightedSignal::new(Matrix), WeightedSignal::new(Hamming)],
        ),
        // --- T2 / T5 semantic: the TRUE dense float lane (Lane D) ---
        // dense leads at full weight; text is a light tie-breaker only.
        ReductionComposition::new(
            "dense-fused",
            vec![
                WeightedSignal::weighted(Dense, 1.0),
                WeightedSignal::weighted(Text, 0.3),
            ],
        ),
        // --- weighted-all: every PER-CANDIDATE signal, weighted ---
        ReductionComposition::new(
            "weighted-all",
            vec![
                WeightedSignal::weighted(Text, 1.0),
                WeightedSignal::weighted(TokenExact, 0.8),
                WeightedSignal::weighted(Hamming, 0.5),
                WeightedSignal::weighted(Dense, 0.5),
                WeightedSignal::weighted(Matrix, 0.3),
                WeightedSignal::weighted(Vector, 0.3),
                WeightedSignal::weighted(TemporalText, 0.3),
                WeightedSignal::weighted(TemporalState, 0.2),
                WeightedSignal::weighted(Lattice, 0.2),
                WeightedSignal::weighted(Bm25, 0.2),
            ],
        ),
    ]
}

/// All composition names in grid order (the gauntlet column ids).
pub fn names() -> Vec<String> {
    all().into_iter().map(|c| c.name).collect()
}

/// Look up a composition by name. Returns the default (`text`) when the name is
/// unknown or `None`, so a caller passing a bad name degrades to the current
/// behavior rather than failing. Mirrors Swift `CompositionGrid.named(_:)`.
pub fn named(name: Option<&str>) -> ReductionComposition {
    match name {
        None => by_name(DEFAULT_NAME),
        Some(n) => by_name(n),
    }
}

/// True when `name` is a known composition in the grid. Used by the ARIA
/// boundary to fail closed on an unknown composition arg (the Rust side's
/// fail-closed validation; the recipe's `named` still degrades to `text`).
pub fn is_known(name: &str) -> bool {
    all().iter().any(|c| c.name == name)
}

fn by_name(name: &str) -> ReductionComposition {
    let grid = all();
    grid.iter()
        .find(|c| c.name == name)
        .cloned()
        .unwrap_or_else(|| {
            grid.iter()
                .find(|c| c.name == DEFAULT_NAME)
                .cloned()
                .expect("the grid always contains the default composition")
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_text_and_first() {
        assert_eq!(DEFAULT_NAME, "text");
        assert_eq!(all()[0].name, "text");
    }

    #[test]
    fn named_unknown_falls_back_to_text() {
        assert_eq!(named(Some("no-such-composition")).name, "text");
        assert_eq!(named(None).name, "text");
    }

    #[test]
    fn no_duplicate_names() {
        let mut names = names();
        names.sort();
        let before = names.len();
        names.dedup();
        assert_eq!(before, names.len(), "duplicate composition names in grid");
    }

    #[test]
    fn dense_fused_terms_match_swift() {
        let c = named(Some("dense-fused"));
        assert_eq!(c.terms.len(), 2);
        assert_eq!(c.terms[0].signal, Dense);
        assert_eq!(c.terms[0].weight, 1.0);
        assert_eq!(c.terms[1].signal, Text);
        assert_eq!(c.terms[1].weight, 0.3);
    }

    #[test]
    fn text_mmr_lambda_is_default() {
        assert_eq!(named(Some("text+mmr")).mmr_lambda, 0.7);
    }

    #[test]
    fn text_temporal_weights_match_swift() {
        let c = named(Some("text+temporal"));
        assert_eq!(c.terms.len(), 3);
        assert_eq!(c.terms[0].weight, 1.0); // text
        assert_eq!(c.terms[1].weight, 0.8); // temporalText
        assert_eq!(c.terms[2].weight, 0.4); // temporalState
    }

    #[test]
    fn is_known_recognizes_grid_names() {
        assert!(is_known("dense-fused"));
        assert!(is_known("text"));
        assert!(!is_known("bogus"));
    }
}
