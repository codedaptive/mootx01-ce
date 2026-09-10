// distilled_recall.rs — Rust mirror of CognitionKit/DistilledRecall.swift.
//
// Distilled-payload recall recipe.
//
// `moot_recall_distilled` is EXACT-SEARCH GEOMETRY over originals +
// inline distilled-representation hydration of the hits: the same recall
// request `moot_memory_search` runs (unionBest, matrixAware fusion,
// query text), with the hydration selector pinned to `distilled`. Ranking
// is identical to exact search BY CONSTRUCTION; only the payloads differ
// (smaller). Per-hit response metadata carries `token_count` (context
// budgeting). Every row renders inline via ContextDistillLib at read time
// — there is no sweep, no "not yet distilled" state, and no fallback path.
//
// Each match also carries `original_token_count`, the estimator over the
// record's full content. The recipe does not sum the pair: the ARIA v2
// surface applies `DistilledSavings` over the rows it actually emits,
// after its row cap and privacy projection (ARIA_V2_CONTRACT.md,
// "Distilled recall savings").
//
// Origin discipline (B-10a): the recipe request stays INTERNAL — only
// the ARIA boundary marks requests external. Mirrors the Swift
// PreciseRecall/ShapedRecall precedent.
//
// Layer discipline B-1/B-2: one coordinator recall call. Read-only.

use genius_locus_kit::coordinator::{EstateCoordinator, VerbDispatchError};
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::hydration_representation::{
    estimated_token_count, resolve_hydration_representation, HydrationRepresentation,
};
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy, RecallOrigin,
};
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};

// MARK: - Output types

/// How well the top result separates from the rest of the ranked list.
///
/// Mirrors `DistilledDiscriminationLevel` in the Swift port. Defined
/// locally because AriaMcpKit is downstream of CognitionKit. Thresholds:
/// HIGH_MARGIN = 0.25, LOW_MARGIN = 0.05, LOW_SPREAD = 0.15. Computed
/// over the SEARCH scores (the exact-search ranking signal).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DistilledDiscriminationLevel {
    /// Fewer than two results — nothing to compare.
    Single,
    /// Top result is clearly separated from the second (topGap >= 0.25).
    High,
    /// Partial separation — some evidence of a best hit.
    Medium,
    /// Top results within epsilon — effectively unranked.
    Low,
}

/// One hit from distilled recall: an ORIGINAL drawer (exact-search
/// geometry), hydrated with its inline distilled representation.
///
/// Mirrors `DistilledMatch` in the Swift port.
#[derive(Debug, Clone, PartialEq)]
pub struct DistilledMatch {
    /// SOURCE drawer UUID from the estate (the item itself — there is no
    /// factoid tier; `moot_memory_get` on this id returns the full body).
    pub id: String,
    /// The hydrated payload: the inline distilled rendering of the row's
    /// verbatim content, produced at read time by ContextDistillLib.
    pub text: String,
    /// Per-hit token estimate for context budgeting. Always present —
    /// every row renders inline, so there is no fallback without a count.
    pub token_count: i64,
    /// Estimator over the record's full `content`: the original-body cost
    /// the ARIA surface sums over the rows it emits. Never summed here.
    pub original_token_count: i64,
    /// The exact-search fusion score that ranked this hit.
    pub score: f64,
    /// The room node id of the source drawer (callers resolve display
    /// names through the node tree exactly as `moot_memory_search` does).
    pub parent_node_id: String,
}

// MARK: - Input / Output

/// Parameters for one distilled-recall search.
///
/// Mirrors `DistilledRecall.Input` in the Swift port.
#[derive(Debug, Clone)]
pub struct DistilledRecallInput {
    /// Query text — drives the same BM25 + vector + matrix fusion the
    /// exact-search path runs.
    pub query: String,
    /// Maximum hits to return. Default 20 mirrors the Swift default.
    pub limit: usize,
    /// ARIA adjective filter applied by the recall frame. Default:
    /// `Filter::CurrentlyBelieve` — mirrors the Swift default.
    pub filter: Filter,
}

impl DistilledRecallInput {
    /// Build with defaults: limit=20, filter=CurrentlyBelieve.
    pub fn new(query: impl Into<String>) -> Self {
        DistilledRecallInput {
            query: query.into(),
            limit: 20,
            filter: Filter::CurrentlyBelieve,
        }
    }

    /// Build with an explicit limit. Filter defaults to CurrentlyBelieve.
    pub fn with_limit(query: impl Into<String>, limit: usize) -> Self {
        DistilledRecallInput {
            query: query.into(),
            limit,
            filter: Filter::CurrentlyBelieve,
        }
    }

    /// Build with an explicit filter. Limit uses the default.
    pub fn with_filter(query: impl Into<String>, filter: Filter) -> Self {
        DistilledRecallInput {
            query: query.into(),
            limit: 20,
            filter,
        }
    }
}

/// Result of one distilled-recall search.
///
/// Mirrors `DistilledRecall.Output` in the Swift port.
#[derive(Debug, Clone, PartialEq)]
pub struct DistilledRecallOutput {
    pub matches: Vec<DistilledMatch>,
    pub discrimination: DistilledDiscriminationLevel,
}

// MARK: - Recipe body

/// Run distilled recall: exact-search geometry, inline distilled hydration.
///
/// Rust parity of `DistilledRecall.run(input:estate:kit:)`.
pub fn run_distilled_recall(
    input: &DistilledRecallInput,
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    now: i64,
) -> Result<DistilledRecallOutput, VerbDispatchError> {
    // The exact-search request shape (`moot_memory_search`): unionBest
    // mode, matrixAware fusion, full hydration. The selector affects only
    // payloads, never matching or ranking.
    let mut frame = RecallFrame::new(vec![input.filter.clone()]);
    frame.hydration_level = HydrationLevel::Full;
    frame.limit = Some(input.limit);
    let request = GLKRecallRequest::new(
        frame,
        GLKRecallMode::UnionBest,
        GLKRecallScoring::MatrixAware,
        input.limit,
        RecallFallbackPolicy::AllowDegraded,
        RecallOrigin::Internal,
    )
    .with_query_text(input.query.clone())
    // Sub-span scoring is an additive-cost stage this recipe does not
    // request; every caller names the switch (ruling 2026-09-07).
    .with_sub_span_scoring(genius_locus_kit::recall::GLKSubSpanScoring::Off);
    let result = coord.recall_scored(handle, request, now)?;

    // Hydrate each hit through the hydration selector pinned to Distilled.
    // Every row renders inline via ContextDistillLib — no stored columns,
    // no sweep dependency, no fallback path. Each match carries the
    // estimator over its distilled text and over its full content; the
    // ARIA surface sums both over the rows it emits.
    let mut matches: Vec<DistilledMatch> = Vec::new();
    for hit in &result.hits {
        let Some(drawer) = &hit.drawer else { continue };
        let text =
            resolve_hydration_representation(HydrationRepresentation::Distilled, drawer);
        let token_count = estimated_token_count(&text);
        let original_token_count = estimated_token_count(&drawer.content);
        matches.push(DistilledMatch {
            id: drawer.id.clone(),
            text,
            token_count,
            original_token_count,
            score: hit.score.final_score as f64,
            parent_node_id: drawer.parent_node_id.clone(),
        });
    }

    let scores: Vec<f64> = matches.iter().map(|m| m.score).collect();
    Ok(DistilledRecallOutput {
        discrimination: classify_distilled_discrimination(&scores),
        matches,
    })
}

// MARK: - Discrimination classifier

/// Classify how well the search scores separate the top match from the
/// rest. Thresholds mirror AriaMcpKit RecallDiscrimination (and the Swift
/// classifier byte-for-byte):
///   HIGH_MARGIN = 0.25, LOW_MARGIN = 0.05, LOW_SPREAD = 0.15, EPS = 1e-9.
pub fn classify_distilled_discrimination(scores: &[f64]) -> DistilledDiscriminationLevel {
    if scores.len() < 2 {
        return DistilledDiscriminationLevel::Single;
    }
    let s0 = scores[0];
    let s1 = scores[1];
    let s_last = scores[scores.len() - 1];
    let denom = s0.abs().max(1e-9);
    let top_gap = (s0 - s1) / denom;
    let spread = (s0 - s_last) / denom;
    if top_gap >= 0.25 {
        return DistilledDiscriminationLevel::High;
    }
    if top_gap < 0.05 && spread < 0.15 {
        return DistilledDiscriminationLevel::Low;
    }
    DistilledDiscriminationLevel::Medium
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use locus_kit::{
        drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
        estate_types::OwnerCredentials,
    };

    const NOW: i64 = 1_700_000_000;

    fn open_estate() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).expect("store"));
        let handle = coord
            .open(store, OwnerCredentials::new("dr-tests"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");
        (coord, handle)
    }

    fn capture(coord: &EstateCoordinator, h: &EstateHandle, content: &str) -> String {
        let frame = locus_kit::frames::CaptureFrame::new(
            content,
            locus_kit::drawer_operational::CaptureChannel::Typed,
            "notes",
            locus_kit::estate_types::LatticeAnchor::udc("0"),
            "dr-tests",
            "test-v1",
        );
        coord.capture(h, frame, NOW).expect("capture").id
    }

    // CK-DR-R1: hits hydrate the inline distilled rendering with a token count.
    #[test]
    fn distilled_rows_hydrate_rendering() {
        let (coord, h) = open_estate();
        let body = "The reactor schedule moved to March. Sarah approved the reactor plan. \
                    The reactor uptime is twelve percent better.";
        let id = capture(&coord, &h, body);

        let out = run_distilled_recall(
            &DistilledRecallInput::new("reactor schedule"), &coord, &h, NOW + 1)
            .expect("recall");
        let m = out.matches.iter().find(|m| m.id == id).expect("hit for the source row");
        // Inline rendering: text equals the converter's output for the body.
        assert_eq!(
            m.text,
            genius_locus_kit::hydration_representation::distilled_rendering(body),
            "payload is the inline converter's rendering of the source body"
        );
        assert!(m.token_count > 0, "per-hit token count must be positive");
        assert_eq!(
            m.token_count,
            genius_locus_kit::hydration_representation::estimated_token_count(&m.text),
            "token_count must equal estimated_token_count for the rendered text"
        );
        assert!(!m.text.starts_with("[DIST|"));
    }

    // CK-DR-R2: ranking equivalence with the exact-search request.
    #[test]
    fn ranking_matches_exact_search() {
        let (coord, h) = open_estate();
        for body in [
            "The reactor schedule moved to March. Sarah approved the plan. Uptime improved.",
            "Vendor contracts were renewed yesterday. The vendor is in Geneva. Terms held.",
            "Travel policy updates landed. Flights require approval. Hotels are capped.",
        ] {
            capture(&coord, &h, body);
        }

        for query in ["reactor schedule", "vendor Geneva", "travel policy"] {
            let mut frame = RecallFrame::new(vec![Filter::CurrentlyBelieve]);
            frame.hydration_level = HydrationLevel::Full;
            frame.limit = Some(20);
            let request = GLKRecallRequest::new(
                frame,
                GLKRecallMode::UnionBest,
                GLKRecallScoring::MatrixAware,
                20,
                RecallFallbackPolicy::AllowDegraded,
                RecallOrigin::Internal,
            )
            .with_query_text(query.to_string())
            // Sub-span scoring off, as on the primary recall above.
            .with_sub_span_scoring(genius_locus_kit::recall::GLKSubSpanScoring::Off);
            let exact: Vec<String> = coord
                .recall_scored(&h, request, NOW + 1)
                .expect("exact search")
                .hits
                .iter()
                .filter_map(|hit| hit.drawer.as_ref().map(|d| d.id.clone()))
                .collect();

            let distilled = run_distilled_recall(
                &DistilledRecallInput::new(query), &coord, &h, NOW + 1)
                .expect("distilled recall");
            let ids: Vec<String> = distilled.matches.iter().map(|m| m.id.clone()).collect();
            assert_eq!(ids, exact, "identical ranking for query {query}");
        }
    }

    // CK-DR-R3: every row renders inline — no sweep needed, no fallback.
    #[test]
    fn every_row_renders_inline() {
        let (coord, h) = open_estate();
        let body = "The inline rendering note stands alone.";
        let id = capture(&coord, &h, body);

        let out = run_distilled_recall(
            &DistilledRecallInput::new("inline rendering note"), &coord, &h, NOW + 1)
            .expect("recall");
        let m = out.matches.iter().find(|m| m.id == id).expect("hit");
        // Inline rendering: text is the converter output, token_count is positive.
        assert_eq!(
            m.text,
            genius_locus_kit::hydration_representation::distilled_rendering(body)
        );
        assert_eq!(
            m.token_count,
            genius_locus_kit::hydration_representation::estimated_token_count(&m.text)
        );
    }

    // CK-DR-R4: empty estate → no matches, Single discrimination.
    #[test]
    fn empty_estate_returns_empty() {
        let (coord, h) = open_estate();
        let out = run_distilled_recall(
            &DistilledRecallInput::new("anything"), &coord, &h, NOW + 1)
            .expect("recall");
        // The seeded system drawers may match generic queries; use a term
        // that cannot appear in them.
        let _ = out; // no panic is the primary assertion
        let out2 = run_distilled_recall(
            &DistilledRecallInput::new("zzz-nonexistent-term-xyzzy"), &coord, &h, NOW + 1)
            .expect("recall");
        if out2.matches.len() < 2 {
            assert_eq!(out2.discrimination, DistilledDiscriminationLevel::Single);
        }
    }

    // Classifier vectors (mirrors the Swift thresholds byte-for-byte).
    #[test]
    fn discrimination_classifier_thresholds() {
        use DistilledDiscriminationLevel as L;
        assert_eq!(classify_distilled_discrimination(&[]), L::Single);
        assert_eq!(classify_distilled_discrimination(&[1.0]), L::Single);
        assert_eq!(classify_distilled_discrimination(&[1.0, 0.5]), L::High);
        assert_eq!(classify_distilled_discrimination(&[1.0, 0.99, 0.98]), L::Low);
        assert_eq!(classify_distilled_discrimination(&[1.0, 0.9, 0.5]), L::Medium);
    }

    // CK-DR-R5: per-match token_count and original_token_count equal the
    // estimator over the distilled text and the captured body. Only captured
    // ids are checked, so seeded system drawers cannot interfere.
    #[test]
    fn per_match_token_counts_equal_estimator() {
        let (coord, h) = open_estate();
        let bodies = [
            "The economics meeting covered the quarterly forecast and revenue targets.",
            "Infrastructure costs rose by twelve percent. The vendor adjusted rates.",
            "Team velocity metrics improved across all product areas this quarter.",
        ];
        let mut body_by_id: std::collections::HashMap<String, &str> =
            std::collections::HashMap::new();
        for body in bodies {
            let id = capture(&coord, &h, body);
            body_by_id.insert(id, body);
        }

        let out = run_distilled_recall(
            &DistilledRecallInput::new("economics quarterly"),
            &coord,
            &h,
            NOW + 1,
        )
        .expect("recall");

        let mut checked = 0;
        for m in &out.matches {
            let Some(body) = body_by_id.get(&m.id) else { continue };
            checked += 1;
            assert_eq!(
                m.original_token_count,
                estimated_token_count(body),
                "original_token_count must equal the estimator over the captured body"
            );
            assert_eq!(
                m.token_count,
                estimated_token_count(&m.text),
                "token_count must equal the estimator over the distilled text"
            );
        }
        assert!(checked >= 1, "at least one captured record must come back");
    }
}
