//! Hybrid-recall reranking engine, Rust version. Conformance-gated
//! against the Swift `HybridRecallEngine` over shared deterministic
//! test vectors per NeuronKit `MISSION_NK_1A_REASONING_SURFACE`.
//!
//! The Rust version intentionally does NOT host a `hybrid_recall(...)`
//! async entry point analogous to Swift's. The estate handle and the
//! GeniusLocusKit verb surface are Swift-only today; the Rust side
//! exposes the pure data-in / data-out reranking math
//! (`HybridRecallEngine::rerank`) and the deterministic shingle
//! similarity, both of which must match the Swift version bit-for-bit
//! against shared test vectors. The day the substrate gains a Rust
//! verb surface, the public entry point lands here as a thin wrapper
//! over the same engine.
//!
//! `shingles` and `shingle_similarity` are thin public wrappers that
//! delegate to `substrate_ml::shingle_similarity` — the substrate-owned
//! kernel (I-25). NeuronKit re-exports them unchanged so callers and the
//! public surface are unaffected.

use serde::{Deserialize, Serialize};
use substrate_ml::shingle_similarity as substrate_shingle;

/// Mirror of `LocusKit.Drawer` reduced to the fields the reranking
/// engine consumes. The Rust version is conformance-gated against the
/// Swift engine over shared vectors of this shape; full
/// `LocusKit.Drawer` round-trip lives in the LocusKit Rust version.
#[derive(Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct DrawerRow {
    pub id: String,
    pub content: String,
}

/// Tuning knobs identical to Swift's `RecallFrameTuning`. Spec
/// defaults: `bm25_weight = 0.3`, `vector_weight = 0.7`, `rrf_k = 60`,
/// `mmr_lambda = 0.7`, `page_size = 50`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RecallFrameTuning {
    pub bm25_weight: f32,
    pub vector_weight: f32,
    pub rrf_k: i32,
    pub mmr_lambda: f32,
    pub page_size: i32,
}

impl RecallFrameTuning {
    /// Spec-default tuning. Matches Swift `RecallFrameTuning.default`.
    pub const fn default_tuning() -> Self {
        Self {
            bm25_weight: 0.3,
            vector_weight: 0.7,
            rrf_k: 60,
            mmr_lambda: 0.7,
            page_size: 50,
        }
    }
}

impl Default for RecallFrameTuning {
    fn default() -> Self {
        Self::default_tuning()
    }
}

/// One page of reranked drawers. Carries `rows`, zero-based
/// `page_index`, and `is_last`. Empty result emits one final page so
/// callers see a uniform iteration without special-casing the
/// zero-row outcome.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecallPage {
    pub rows: Vec<DrawerRow>,
    pub page_index: i32,
    pub is_last: bool,
}

/// Page a reranked sequence using the spec § 4.1 paging rule. Pure
/// helper; identical math to Swift's `RecallStream` iterator.
pub fn page_recall(rows: &[DrawerRow], page_size: i32) -> Vec<RecallPage> {
    // Page size below 1 would loop forever / emit zero-progress
    // pages. Clamp to keep the invariant that every page either makes
    // progress or is the last.
    let size = page_size.max(1) as usize;
    if rows.is_empty() {
        return vec![RecallPage {
            rows: vec![],
            page_index: 0,
            is_last: true,
        }];
    }
    let mut pages = Vec::new();
    let mut offset = 0usize;
    let mut idx = 0i32;
    while offset < rows.len() {
        let end = (offset + size).min(rows.len());
        let slice = rows[offset..end].to_vec();
        let is_last = end >= rows.len();
        pages.push(RecallPage {
            rows: slice,
            page_index: idx,
            is_last,
        });
        offset = end;
        idx += 1;
    }
    pages
}

/// Reranking engine. Pure data-in, data-out — no clocks, no
/// randomness, no IO. The output must match the Swift
/// `HybridRecallEngine.rerank` byte-for-byte against the shared
/// conformance vectors.
pub fn rerank(drawers: &[DrawerRow], tuning: &RecallFrameTuning) -> Vec<DrawerRow> {
    if drawers.is_empty() {
        return Vec::new();
    }

    // RRF over the single fused list returned by the verb. Today L₁
    // and L₂ collapse to the same ordering (the GLK verb returns one
    // ranked array); the math still runs so the day the surface
    // widens, only the fan-in changes. See the Swift file header for
    // the full reasoning.
    let mut rrf_score: Vec<f32> = Vec::with_capacity(drawers.len());
    for idx in 0..drawers.len() {
        let denom = (tuning.rrf_k as f32) + (idx as f32) + 1.0;
        let lexical = 1.0 / denom;
        let semantic = 1.0 / denom;
        rrf_score.push(tuning.bm25_weight * lexical + tuning.vector_weight * semantic);
    }

    // Normalise RRF into [0, 1]. Fall back to 0.5 when every value is
    // equal (single-row or degenerate input).
    let max_rrf = rrf_score.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let min_rrf = rrf_score.iter().copied().fold(f32::INFINITY, f32::min);
    let range = max_rrf - min_rrf;
    let relevance = |idx: usize| -> f32 {
        if range > 0.0 {
            (rrf_score[idx] - min_rrf) / range
        } else {
            0.5
        }
    };

    let lambda = tuning.mmr_lambda;
    let mut remaining: Vec<bool> = vec![true; drawers.len()];
    let mut selected: Vec<usize> = Vec::with_capacity(drawers.len());

    while selected.len() < drawers.len() {
        let mut best_idx: isize = -1;
        let mut best_score = f32::NEG_INFINITY;
        // Iterate in stable input order so ties break deterministically
        // — bit-identical against the Swift version.
        for (idx, alive) in remaining.iter().enumerate() {
            if !alive {
                continue;
            }
            let rel = relevance(idx);
            let max_sim = if selected.is_empty() {
                0.0
            } else {
                let mut m: f32 = 0.0;
                for &s in &selected {
                    let sim = shingle_similarity(&drawers[idx].content, &drawers[s].content);
                    if sim > m {
                        m = sim;
                    }
                }
                m
            };
            let score = lambda * rel - (1.0 - lambda) * max_sim;
            if score > best_score {
                best_score = score;
                best_idx = idx as isize;
            }
        }
        let chosen = best_idx as usize;
        remaining[chosen] = false;
        selected.push(chosen);
    }

    selected.into_iter().map(|i| drawers[i].clone()).collect()
}

/// 3-character lowercase shingle set.
///
/// Delegates to `substrate_ml::shingle_similarity::shingles` — the
/// substrate-owned kernel (I-25). One implementation per substrate
/// atomic; NeuronKit re-exports this function for callers that already
/// import `neuron_kit` directly.
pub fn shingles(s: &str) -> std::collections::BTreeSet<String> {
    substrate_shingle::shingles(s)
}

/// Deterministic Jaccard similarity over 3-character lowercase shingles.
///
/// Delegates to `substrate_ml::shingle_similarity::similarity` — the
/// substrate-owned kernel (I-25). Bit-identical to the Swift
/// `HybridRecallEngine.shingleSimilarity` via the shared conformance gate
/// (CRC 0x8a5d8888, 32-case cross-port vector). NeuronKit re-exports this
/// function so callers are unaffected.
pub fn shingle_similarity(a: &str, b: &str) -> f32 {
    substrate_shingle::similarity(a, b)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(id: &str, content: &str) -> DrawerRow {
        DrawerRow {
            id: id.to_string(),
            content: content.to_string(),
        }
    }

    // shingles

    #[test]
    fn shingles_empty_for_empty_input() {
        assert!(shingles("").is_empty());
    }

    #[test]
    fn shingles_short_input_returns_whole_string() {
        assert_eq!(
            shingles("ab"),
            ["ab"].iter().map(|s| s.to_string()).collect()
        );
        assert_eq!(
            shingles("AB"),
            ["ab"].iter().map(|s| s.to_string()).collect()
        );
    }

    #[test]
    fn shingles_windows_are_three_char_lowercased() {
        let expected: std::collections::BTreeSet<String> = ["cat", "atd", "tdo", "dog"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(shingles("catdog"), expected);
    }

    // delegation assertion — shingles and shingle_similarity are thin
    // wrappers; the substrate provider must produce identical results.

    #[test]
    fn shingle_similarity_delegates_to_substrate() {
        let pairs: &[(&str, &str)] = &[
            ("organic chemistry", "organic chemistry"),
            ("abcdef", "ghijkl"),
            ("the quick brown fox", "the quick brown foxx"),
            ("", "catdog"),
            ("ab", "bc"),
        ];
        for &(a, b) in pairs {
            let engine = shingle_similarity(a, b);
            let substrate = substrate_shingle::similarity(a, b);
            assert!(
                (engine - substrate).abs() < 1e-9,
                "mismatch for ({}, {}): engine={} substrate={}",
                a, b, engine, substrate
            );
        }
    }

    // shingle_similarity

    #[test]
    fn shingle_similarity_identical_is_one() {
        let s = shingle_similarity("organic chemistry", "organic chemistry");
        assert!((s - 1.0).abs() < 1e-6);
    }

    #[test]
    fn shingle_similarity_disjoint_is_zero() {
        let s = shingle_similarity("abcdef", "ghijkl");
        assert!(s.abs() < 1e-6);
    }

    #[test]
    fn shingle_similarity_symmetric() {
        let ab = shingle_similarity(
            "the organic chemistry of carbon",
            "carbon-based organic compounds",
        );
        let ba = shingle_similarity(
            "carbon-based organic compounds",
            "the organic chemistry of carbon",
        );
        assert!((ab - ba).abs() < 1e-6);
    }

    // rerank

    #[test]
    fn rerank_empty_is_empty() {
        assert!(rerank(&[], &RecallFrameTuning::default()).is_empty());
    }

    #[test]
    fn rerank_single_drawer_is_identity() {
        let drawers = vec![d("1", "chemistry")];
        let out = rerank(&drawers, &RecallFrameTuning::default());
        assert_eq!(
            out.iter().map(|r| r.id.clone()).collect::<Vec<_>>(),
            vec!["1"]
        );
    }

    #[test]
    fn rerank_preserves_all_input_drawers() {
        let drawers: Vec<DrawerRow> = (1..=5)
            .map(|i| d(&format!("{}", i), &format!("drawer body number {}", i)))
            .collect();
        let out = rerank(&drawers, &RecallFrameTuning::default());
        let in_ids: std::collections::BTreeSet<_> = drawers.iter().map(|r| r.id.clone()).collect();
        let out_ids: std::collections::BTreeSet<_> = out.iter().map(|r| r.id.clone()).collect();
        assert_eq!(in_ids, out_ids);
        assert_eq!(out.len(), drawers.len());
    }

    #[test]
    fn rerank_deterministic_across_invocations() {
        let drawers: Vec<DrawerRow> = (0..7)
            .map(|i| {
                d(
                    &format!("row-{}", i),
                    &format!("alpha beta gamma item {}", i),
                )
            })
            .collect();
        let first = rerank(&drawers, &RecallFrameTuning::default());
        let second = rerank(&drawers, &RecallFrameTuning::default());
        let first_ids: Vec<_> = first.iter().map(|r| r.id.clone()).collect();
        let second_ids: Vec<_> = second.iter().map(|r| r.id.clone()).collect();
        assert_eq!(first_ids, second_ids);
    }

    #[test]
    fn rerank_with_lambda_one_is_relevance_only_ordering() {
        let drawers: Vec<DrawerRow> = (0..4)
            .map(|i| d(&format!("id-{}", i), &format!("content {}", i)))
            .collect();
        let tuning = RecallFrameTuning {
            mmr_lambda: 1.0,
            ..Default::default()
        };
        let out = rerank(&drawers, &tuning);
        let out_ids: Vec<_> = out.iter().map(|r| r.id.clone()).collect();
        let in_ids: Vec<_> = drawers.iter().map(|r| r.id.clone()).collect();
        assert_eq!(out_ids, in_ids);
    }

    #[test]
    fn rerank_with_lambda_zero_favours_diversity() {
        let drawers = vec![
            d("near-1", "the quick brown fox"),
            d("near-2", "the quick brown foxx"),
            d("far", "zzz yyy xxx www"),
        ];
        let tuning = RecallFrameTuning {
            mmr_lambda: 0.0,
            ..Default::default()
        };
        let out = rerank(&drawers, &tuning);
        let ids: Vec<_> = out.iter().map(|r| r.id.clone()).collect();
        assert_eq!(ids, vec!["near-1", "far", "near-2"]);
    }

    // paging

    #[test]
    fn empty_stream_emits_one_final_page() {
        let pages = page_recall(&[], 50);
        assert_eq!(pages.len(), 1);
        assert!(pages[0].rows.is_empty());
        assert!(pages[0].is_last);
        assert_eq!(pages[0].page_index, 0);
    }

    #[test]
    fn paging_honours_page_size() {
        let rows: Vec<DrawerRow> = (0..25)
            .map(|i| d(&format!("{}", i), &format!("row {}", i)))
            .collect();
        let pages = page_recall(&rows, 10);
        assert_eq!(pages.len(), 3);
        assert_eq!(pages[0].rows.len(), 10);
        assert_eq!(pages[1].rows.len(), 10);
        assert_eq!(pages[2].rows.len(), 5);
        assert!(!pages[0].is_last);
        assert!(!pages[1].is_last);
        assert!(pages[2].is_last);
        assert_eq!(
            pages.iter().map(|p| p.page_index).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
    }

    #[test]
    fn paging_clamps_non_positive_page_size() {
        let rows: Vec<DrawerRow> = (0..3)
            .map(|i| d(&format!("{}", i), &format!("row {}", i)))
            .collect();
        let pages = page_recall(&rows, 0);
        assert_eq!(pages.len(), 3);
    }
}
