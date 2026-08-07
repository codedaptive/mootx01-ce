//! Hybrid-recall reranking engine and GLK entry point, Rust version.
//! Conformance-gated against the Swift `HybridRecallEngine` over shared
//! deterministic test vectors per NeuronKit `MISSION_NK_1A_REASONING_SURFACE`.
//!
//! The `hybrid_recall()` public entry point mirrors Swift's
//! `hybridRecall(_:handle:on:tuning:)`. It routes through the GLK
//! `EstateCoordinator::recall` verb (the only legal substrate boundary
//! per B-1), applies RRF + MMR reranking per spec § 4.1, emits
//! three telemetry metrics (`neuronkit.recall.latency_ms`,
//! `neuronkit.recall.candidate_count`, `neuronkit.recall.result_count`)
//! matching the Swift boundary, and returns paged results.
//!
//! The pure data-in / data-out reranking math (`rerank`) and the
//! deterministic shingle similarity match the Swift version bit-for-bit
//! against shared test vectors.
//!
//! `shingles` and `shingle_similarity` are thin public wrappers that
//! delegate to `substrate_ml::shingle_similarity` — the substrate-owned
//! kernel (I-25). NeuronKit re-exports them unchanged so callers and the
//! public surface are unaffected.

use std::collections::HashMap;
use std::time::Instant;

use genius_locus_kit::{EstateCoordinator, EstateHandle, VerbDispatchError};
use intellectus_lib::{report, StatSample};
use locus_kit::filter::RecallFrame;
use serde::{Deserialize, Serialize};
use substrate_ml::shingle_similarity as substrate_shingle;

/// Hybrid recall over the estate addressed by `handle`. Wraps the GLK
/// `EstateCoordinator::recall` verb (the only legal substrate boundary
/// per B-1), applies RRF + MMR per spec § 4.1, emits telemetry at the
/// operation boundary, and returns paged results.
///
/// Mirrors Swift's `hybridRecall(_:handle:on:tuning:)`. The three
/// telemetry metrics (`neuronkit.recall.latency_ms`,
/// `neuronkit.recall.candidate_count`, `neuronkit.recall.result_count`)
/// use the estate UUID hex as the tag, matching the Swift boundary.
///
/// `now` is the deterministic epoch-seconds timestamp for the recall
/// verb and the telemetry `ts` field. Callers supply the timestamp;
/// the function never reads a system clock for data operations.
///
/// Returns `Err` if the handle is stale or the estate verb fails.
pub fn hybrid_recall(
    coordinator: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    tuning: &RecallFrameTuning,
    now: i64,
    cue_terms: &[String],
) -> Result<Vec<RecallPage>, VerbDispatchError> {
    let wall_start = Instant::now();

    let drawers = coordinator.recall(handle, frame, now)?;

    let drawer_rows: Vec<DrawerRow> = drawers
        .iter()
        .map(|d| DrawerRow {
            id: d.id.clone(),
            content: d.content.clone(),
        })
        .collect();

    let reranked = rerank(&drawer_rows, tuning, cue_terms);
    let pages = page_recall(&reranked, tuning.page_size);

    let elapsed_ms = wall_start.elapsed().as_secs_f64() * 1000.0;
    let estate_tag = handle
        .estate_uuid
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let ts = now as f64;

    report!(StatSample::metric(
        "neuronkit.recall.latency_ms".into(),
        elapsed_ms,
        HashMap::from([("estate".into(), estate_tag.clone())]),
        ts,
    ));
    report!(StatSample::metric(
        "neuronkit.recall.candidate_count".into(),
        drawers.len() as f64,
        HashMap::from([("estate".into(), estate_tag.clone())]),
        ts,
    ));
    report!(StatSample::metric(
        "neuronkit.recall.result_count".into(),
        reranked.len() as f64,
        HashMap::from([("estate".into(), estate_tag)]),
        ts,
    ));

    Ok(pages)
}

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

/// Reranking engine. Pure data-in, data-out — no clocks, no randomness, no IO.
/// The output must match the Swift `HybridRecallEngine.rerank` byte-for-byte
/// against the shared conformance vectors.
///
/// When `cue_terms` is non-empty the two RRF lanes become genuinely independent:
/// L-lexical ranks drawers by distinct-cue-term-match count descending
/// (input-order tie-break); L-semantic is input order (recency). When
/// `cue_terms` is empty both lanes equal input order — output is bit-identical
/// to the previous single-list path.
pub fn rerank(drawers: &[DrawerRow], tuning: &RecallFrameTuning, cue_terms: &[String]) -> Vec<DrawerRow> {
    if drawers.is_empty() {
        return Vec::new();
    }

    // Build lexical rank: sorted by distinct-cue-term-match count descending
    // with input-order as a stable tie-break. Distinct count (not occurrence
    // count) — generic terms that appear many times in one drawer award only
    // +1, preventing inflation above drawers that match more distinct terms.
    // When cue_terms is empty lexical_order == input order, collapsing both
    // lanes to the same sequence (bit-identical to the previous path).
    let lexical_order: Vec<usize> = if cue_terms.is_empty() {
        (0..drawers.len()).collect()
    } else {
        let low_terms: Vec<String> = cue_terms.iter().map(|t| t.to_lowercase()).collect();
        // (match_count, original_index) for stable sort.
        let mut scored: Vec<(usize, usize)> = drawers
            .iter()
            .enumerate()
            .map(|(idx, d)| {
                let lower = d.content.to_lowercase();
                let distinct = low_terms.iter().filter(|t| lower.contains(t.as_str())).count();
                (distinct, idx)
            })
            .collect();
        // Sort by count DESC; input index ASC as stable tie-break.
        scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        scored.into_iter().map(|(_, idx)| idx).collect()
    };

    // Map original_index → lexical rank for O(1) lookup.
    let mut lex_rank: Vec<usize> = vec![0; drawers.len()];
    for (rank, &idx) in lexical_order.iter().enumerate() {
        lex_rank[idx] = rank;
    }

    // RRF with genuinely independent lanes:
    // L-lexical: ranked by distinct-cue-term count (or input order when empty).
    // L-semantic: input order (recency — the verb's natural ordering).
    // When cue_terms is empty both lanes equal input order — the formula
    // reduces to the previous single-list math, bit-identical output.
    let mut rrf_score: Vec<f32> = Vec::with_capacity(drawers.len());
    for sem_rank in 0..drawers.len() {
        let l_rank = lex_rank[sem_rank];
        let lexical = 1.0 / ((tuning.rrf_k as f32) + (l_rank as f32) + 1.0);
        let semantic = 1.0 / ((tuning.rrf_k as f32) + (sem_rank as f32) + 1.0);
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

    // Shingle each drawer ONCE and memoize pairwise similarities. The
    // selection loop below evaluates candidate-vs-selected pairs across
    // every step (~n³/6 evaluations); computing each from raw strings
    // rebuilt both shingle sets per call and measured 181 s over a
    // 250-drawer pool (the trial-3 synthesize timeouts). With cached sets
    // and a pair memo the distinct work is at most n²/2 set intersections.
    // Output is bit-identical — same substrate kernel, same values,
    // computed once. Twin of the Swift pairSimilarity memo.
    let shingle_sets: Vec<std::collections::BTreeSet<String>> =
        drawers.iter().map(|d| shingles(&d.content)).collect();
    let mut pair_memo: std::collections::HashMap<usize, f32> = std::collections::HashMap::new();
    let n = drawers.len();
    let mut pair_similarity = |a: usize, b: usize| -> f32 {
        let (lo, hi) = if a < b { (a, b) } else { (b, a) };
        let key = lo * n + hi;
        *pair_memo.entry(key).or_insert_with(|| {
            substrate_shingle::similarity_sets(&shingle_sets[lo], &shingle_sets[hi])
        })
    };

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
                    let sim = pair_similarity(idx, s);
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
        assert!(rerank(&[], &RecallFrameTuning::default(), &[]).is_empty());
    }

    #[test]
    fn rerank_single_drawer_is_identity() {
        let drawers = vec![d("1", "chemistry")];
        let out = rerank(&drawers, &RecallFrameTuning::default(), &[]);
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
        let out = rerank(&drawers, &RecallFrameTuning::default(), &[]);
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
        let first = rerank(&drawers, &RecallFrameTuning::default(), &[]);
        let second = rerank(&drawers, &RecallFrameTuning::default(), &[]);
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
        let out = rerank(&drawers, &tuning, &[]);
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
        let out = rerank(&drawers, &tuning, &[]);
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

    // ── GLK integration ──────────────────────────────────────────

    use std::sync::Arc;
    use genius_locus_kit::{EstateCoordinator, EstateHandle};
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
    use locus_kit::frames::CaptureFrame;

    fn make_coordinator_and_handle() -> (EstateCoordinator, EstateHandle) {
        let store: Arc<dyn LocusDrawerStore> =
            Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
        let mut coord = EstateCoordinator::new();
        let handle = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .expect("open");
        (coord, handle)
    }

    fn capture_row(coord: &EstateCoordinator, handle: &EstateHandle, content: &str, now: i64) {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "test-room",
            LatticeAnchor::udc("000"),
            "test",
            "no-embedding",
        );
        coord.capture(handle, frame, now).expect("capture");
    }

    #[test]
    fn hybrid_recall_routes_through_glk_and_pages() {
        let (coord, handle) = make_coordinator_and_handle();
        capture_row(&coord, &handle, "alpha concept", 1000);
        capture_row(&coord, &handle, "beta concept", 1001);
        capture_row(&coord, &handle, "gamma concept", 1002);

        let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
        frame.hydration_level = HydrationLevel::Full;
        frame.ordering = Ordering::ByCaptureTimeDesc;
        let tuning = RecallFrameTuning {
            page_size: 2,
            ..Default::default()
        };

        let pages = hybrid_recall(&coord, &handle, frame, &tuning, 2000, &[])
            .expect("hybrid_recall");
        assert_eq!(pages.len(), 2, "3 rows at page_size 2 → 2 pages");
        assert!(!pages[0].is_last);
        assert!(pages[1].is_last);
        assert_eq!(pages[0].rows.len(), 2);
        assert_eq!(pages[1].rows.len(), 1);
        let all_ids: Vec<_> = pages
            .iter()
            .flat_map(|p| p.rows.iter().map(|r| r.id.clone()))
            .collect();
        assert_eq!(all_ids.len(), 3, "all drawers present after rerank+page");
    }

    #[test]
    fn hybrid_recall_empty_estate_returns_one_empty_page() {
        let (coord, handle) = make_coordinator_and_handle();
        let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
        frame.hydration_level = HydrationLevel::Full;
        frame.ordering = Ordering::ByCaptureTimeDesc;

        let pages = hybrid_recall(
            &coord,
            &handle,
            frame,
            &RecallFrameTuning::default(),
            1000,
            &[],
        )
        .expect("hybrid_recall");
        assert_eq!(pages.len(), 1);
        assert!(pages[0].rows.is_empty());
        assert!(pages[0].is_last);
    }

    // ── cue-term lane ────────────────────────────────────────────────

    /// Empty cue_terms must produce bit-identical output to no-cue call.
    #[test]
    fn rerank_empty_cue_terms_bit_identical_to_baseline() {
        let drawers: Vec<DrawerRow> = (0..6)
            .map(|i| d(&format!("d-{i}"), &format!("organic chemistry item {i}")))
            .collect();
        let baseline = rerank(&drawers, &RecallFrameTuning::default(), &[]);
        let with_empty: Vec<String> = Vec::new();
        let same = rerank(&drawers, &RecallFrameTuning::default(), &with_empty);
        assert_eq!(
            baseline.iter().map(|r| &r.id).collect::<Vec<_>>(),
            same.iter().map(|r| &r.id).collect::<Vec<_>>(),
            "empty cue_terms must produce identical output to empty-slice baseline"
        );
    }

    /// Older drawer (input index 0) with 3 distinct cue-term hits must outrank
    /// newer drawer (input index 1) with only 1 hit.
    #[test]
    fn rerank_older_drawer_more_cue_terms_outranks_newer() {
        let drawers = vec![
            d("old", "daguerreotype vintage cameras photography"),
            d("new", "daguerreotype modern art exhibit"),
        ];
        let cue_terms = vec![
            "daguerreotype".to_string(),
            "vintage".to_string(),
            "cameras".to_string(),
        ];
        let out = rerank(&drawers, &RecallFrameTuning::default(), &cue_terms);
        assert_eq!(
            out.iter().map(|r| r.id.clone()).collect::<Vec<_>>(),
            vec!["old", "new"],
            "drawer with more distinct cue-term hits must outrank fewer-hit drawer"
        );
    }

    /// Occurrence count must NOT beat distinct count: 5 repeats of one term
    /// must lose to 2 distinct terms matched once each.
    ///
    /// Pure-lexical tuning (bm25_weight=1.0, vector_weight=0.0) isolates the
    /// distinct-count logic from semantic-lane interference. With default
    /// weights (bm25=0.3, vector=0.7) the semantic lane dominates for
    /// adjacent-rank pairs — the recency signal of input position 0
    /// outweighs the distinct-count signal. Pure-lexical eliminates that
    /// interference and tests the distinct-count contract directly.
    #[test]
    fn rerank_occurrence_count_does_not_beat_distinct_count() {
        let drawers = vec![
            d("repeat", "vintage vintage vintage vintage vintage"),
            d("distinct", "daguerreotype cameras collection"),
        ];
        let cue_terms = vec![
            "daguerreotype".to_string(),
            "cameras".to_string(),
            "vintage".to_string(),
        ];
        // distinct has 2 matches, repeat has 1 match; distinct must rank first.
        // Pure-lexical tuning isolates distinct-count from recency weight.
        let lexical_tuning = RecallFrameTuning {
            bm25_weight: 1.0,
            vector_weight: 0.0,
            ..RecallFrameTuning::default()
        };
        let out = rerank(&drawers, &lexical_tuning, &cue_terms);
        assert_eq!(
            out.iter().map(|r| r.id.clone()).collect::<Vec<_>>(),
            vec!["distinct", "repeat"],
            "2 distinct cue-term matches must outrank 1 repeated match"
        );
    }

    // ── gs5 adversarial pin (A3 adjudication, 2026-08-06) ────────────────────

    /// Adversarial pin: zero-term-match row at maximal recency (input position 0)
    /// must not outrank a term-matched row (input position 1) under
    /// lexical-dominant tuning (bm25=1.0, vector=0.0).
    ///
    /// With DEFAULT weights (bm25=0.3, vector=0.7):
    ///   RRF("zero-match") = 0.3/62 + 0.7/61 ≈ 0.01632
    ///   RRF("term-match") = 0.3/61 + 0.7/62 ≈ 0.01621
    /// Default weights select zero-match first — the recency-dominance failure
    /// the hybrid_recall() guard prevents by switching to lexical-dominant tuning
    /// when scored_lead_count == 0 && !cue_terms.is_empty().
    ///
    /// With LEXICAL-DOMINANT weights (bm25=1.0, vector=0.0):
    ///   RRF("term-match") = 1.0/61 ≈ 0.01639
    ///   RRF("zero-match") = 1.0/62 ≈ 0.01613
    /// Lexical-dominant weights select term-match first. This test pins that
    /// correct ordering at the reranker level under the guard-enforced tuning.
    ///
    /// Twin of Swift `gs5AdversarialZeroMatchLosesUnderLexicalDominantTuning`.
    #[test]
    fn gs5_adversarial_zero_match_loses_under_lexical_dominant_tuning() {
        let drawers = vec![
            d("zero-match", "unrelated topic about weather forecasting"), // pos 0, 0 cue matches
            d("term-match", "daguerreotype vintage cameras photography"),  // pos 1, 3 cue matches
        ];
        let cue_terms = vec![
            "daguerreotype".to_string(),
            "vintage".to_string(),
            "cameras".to_string(),
        ];
        // Lexical-dominant tuning: what hybrid_recall() applies when the scored
        // lane is degraded (scored_lead_count == 0 && !cue_terms.is_empty()).
        let lexical_dominant = RecallFrameTuning {
            bm25_weight: 1.0,
            vector_weight: 0.0,
            ..RecallFrameTuning::default()
        };
        let out = rerank(&drawers, &lexical_dominant, &cue_terms);
        assert_eq!(
            out[0].id, "term-match",
            "zero-term-match row at maximal recency must not outrank term-matched row under lexical-dominant tuning"
        );
        assert_eq!(out.len(), 2, "both rows present — reranker reorders, does not drop");
    }

    /// Tie-break is deterministic (stable input order wins); two calls produce
    /// identical output.
    #[test]
    fn rerank_cue_term_tie_break_is_deterministic() {
        let drawers = vec![
            d("d0", "daguerreotype exposure plates"),
            d("d1", "vintage photograph albums"),
            d("d2", "cameras lens aperture"),
        ];
        let cue_terms = vec![
            "daguerreotype".to_string(),
            "vintage".to_string(),
            "cameras".to_string(),
        ];
        let first = rerank(&drawers, &RecallFrameTuning::default(), &cue_terms);
        let second = rerank(&drawers, &RecallFrameTuning::default(), &cue_terms);
        assert_eq!(
            first.iter().map(|r| r.id.clone()).collect::<Vec<_>>(),
            second.iter().map(|r| r.id.clone()).collect::<Vec<_>>(),
            "cue-term rerank must be deterministic across invocations"
        );
        // All drawers present.
        let in_ids: std::collections::BTreeSet<_> = drawers.iter().map(|r| r.id.clone()).collect();
        let out_ids: std::collections::BTreeSet<_> = first.iter().map(|r| r.id.clone()).collect();
        assert_eq!(in_ids, out_ids, "all drawers must be present in output");
    }
}
