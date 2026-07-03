// distilled_recall.rs — Rust mirror of CognitionKit/DistilledRecall.swift.
//
// Dense-tier recall recipe: searches the distilled memory tier using structural
// fingerprint Hamming NN, returns factoid prose + metadata. No embedding model
// inference required.
//
// run_distilled_recall() sequence (parity with Swift DistilledRecall.run):
//   1. DistillationPipeline::query_fingerprint → Fingerprint256 (Engram)
//   2. EstateCoordinator::find_nearest_distilled → Vec<VectorMatch>
//   3. Policy-enforcing coord.recall(frame) → factoid body map (secfix/punt-g2 part 2)
//   4. DistilledHeader::parse per match → DistilledMatch array
//   5. classify_distilled_discrimination(scores) → DistilledDiscriminationLevel
//
// Pool parameter: accepted for API parity with Swift, currently unused — the
// current implementation passes `limit` directly to find_nearest_distilled
// (mirroring the Swift comment "pool: current implementation passes limit
// directly to findNearestDistilled"). Pool semantic is documented as reserved
// for future coarse-then-fine re-ranking.
//
// Filter parameter: caller-supplied ARIA adjective filter composed into the
// RecallFrame (parity with Swift DistilledRecall.Input.filter). The frame's
// insert_defaults enforces SensitivityAtMost(Elevated) as a floor; the caller
// filter is composed on top of that floor — it can only be MORE restrictive,
// never less. Default is Filter::CurrentlyBelieve (matches Swift default
// .unconfirmed, which insert_defaults promotes to CurrentlyBelieve).
//
// DiscriminationLevel discrimination thresholds:
//   HIGH_MARGIN = 0.25  — topGap at which rank-1 is clearly the best match.
//   LOW_MARGIN  = 0.05  — topGap below which rank-1 is indistinguishable.
//   LOW_SPREAD  = 0.15  — spread below which the whole list is flat.
//
// Layer discipline B-1/B-2: one GLK find_nearest_distilled + one policy recall
// call (no raw store access). Read-only (B-6, I-6). Deterministic (now param).

use genius_locus_kit::coordinator::{EstateCoordinator, VerbDispatchError};
use genius_locus_kit::handle::EstateHandle;
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use neuron_kit::InjectionDepth;
use substrate_ml::distillation_pipeline::{DistilledHeader, DistillationPipeline};

// MARK: - Output types

/// How well the top distilled result separates from the rest of the ranked list.
///
/// Mirrors `DistilledDiscriminationLevel` in the Swift port. Defined locally
/// because AriaMcpKit is downstream of CognitionKit and cannot be imported here.
/// Thresholds: HIGH_MARGIN = 0.25, LOW_MARGIN = 0.05, LOW_SPREAD = 0.15.
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

/// One match from the distilled memory tier.
///
/// Mirrors `DistilledMatch` in the Swift port.
#[derive(Debug, Clone, PartialEq)]
pub struct DistilledMatch {
    /// Drawer UUID from the estate.
    pub id: String,
    /// Factoid prose — DIST header stripped.
    pub prose: String,
    /// Confidence score conf(F*) ∈ [0, 1].
    pub confidence: f32,
    /// Number of source memories M that produced this factoid.
    pub source_count: usize,
    /// Cluster SNR at distillation time.
    pub snr: f32,
    /// DeltaType string ("CONVERGENT" | "MONOTONE" | "STATIC") or None for absent/non-delta.
    pub delta_type: Option<String>,
    /// True when confidence ∈ [0.4, 0.7) — signals mid-confidence factoid.
    pub uncertain: bool,
    /// How much provenance context to inject alongside the factoid prose.
    /// conf >= 0.7 → FactoidOnly; [0.4, 0.7) → FactoidWithMeta; < 0.4 → FactoidWithProvenance.
    pub injection_depth: InjectionDepth,
}

// MARK: - Input / Output

/// Parameters for one distilled-recall search.
///
/// Mirrors `DistilledRecall.Input` in the Swift port.
#[derive(Debug, Clone)]
pub struct DistilledRecallInput {
    /// Query text — feature-extracted and fingerprinted at query time.
    pub query: String,
    /// Maximum factoids to return. Default 20 mirrors Swift default.
    pub limit: usize,
    /// Coarse candidate pool size — accepted for API parity; currently passes
    /// `limit` directly to find_nearest_distilled (mirrors Swift comment:
    /// "current implementation passes limit directly to findNearestDistilled").
    pub pool: usize,
    /// ARIA adjective filter applied during frame-aware hydration.
    ///
    /// Parity with Swift `DistilledRecall.Input.filter`. Composed into the
    /// RecallFrame passed to `coord.recall` so the caller's desired state
    /// constraint (unconfirmed, userConfirmed, currentlyBelieve, etc.) applies
    /// on top of the sensitivity ceiling enforced by `insert_defaults`.
    /// Default: `Filter::CurrentlyBelieve` — matches Swift's `.unconfirmed`
    /// default which insert_defaults promotes to currentlyBelieve.
    pub filter: Filter,
}

impl DistilledRecallInput {
    /// Build with defaults: limit=20, pool=max(limit*5, 50), filter=CurrentlyBelieve.
    ///
    /// Mirrors Swift `DistilledRecall.Input.init(query:filter:limit:pool:)` defaults.
    pub fn new(query: impl Into<String>) -> Self {
        let limit = 20;
        let pool = (limit * 5).max(50);
        DistilledRecallInput { query: query.into(), limit, pool, filter: Filter::CurrentlyBelieve }
    }

    /// Build with an explicit limit and default pool. Filter defaults to CurrentlyBelieve.
    pub fn with_limit(query: impl Into<String>, limit: usize) -> Self {
        let pool = (limit * 5).max(50);
        DistilledRecallInput { query: query.into(), limit, pool, filter: Filter::CurrentlyBelieve }
    }

    /// Build with an explicit filter. Limit and pool use defaults.
    pub fn with_filter(query: impl Into<String>, filter: Filter) -> Self {
        let limit = 20;
        let pool = (limit * 5).max(50);
        DistilledRecallInput { query: query.into(), limit, pool, filter }
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

/// Recall distilled factoids for `query` via Hamming NN.
///
/// Rust parity of `DistilledRecall.run(input:estate:kit:)` in the Swift port.
///
/// Steps:
///   1. Feature-extract the query into a structural fingerprint using
///      `DistillationPipeline::default_extractor` — no embedding model inference.
///   2. Dispatch to `EstateCoordinator::find_nearest_distilled`.
///   3. Policy-enforcing by-ids hydration of the NN matches → factoid body map
///      (SensitivityAtMost(Elevated), no capture-time window).
///   4. Parse `DistilledHeader` per match, build `DistilledMatch` array.
///   5. Classify discrimination over confidence scores.
///
/// Empty result is valid — returns `DistilledDiscriminationLevel::Single` with
/// an empty match list. No panic on zero matches.
///
/// # Errors
///
/// Returns `VerbDispatchError` for stale handles or VectorStore I/O errors.
/// Item-level parse failures (absent DIST header) are silently skipped — parity
/// with Swift `guard let header = DistilledHeader.parse(body)`.
pub fn run_distilled_recall(
    input: &DistilledRecallInput,
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    // Accepted for API/caller parity. The by-ids hydration path (step 3) is scoped to
    // the NN match ids and needs no current-clock token; liveness/state filtering is
    // driven by the frame's default chain, not a wall-clock argument.
    _now: i64,
) -> Result<DistilledRecallOutput, VerbDispatchError> {
    // 1. Feature-extract the query into a structural fingerprint.
    //    default_extractor is the capitalization-heuristic stub (deterministic,
    //    test-safe). Production callers may supply the HMM tagger when
    //    EideticLib is available — both ports will update together.
    let engram = DistillationPipeline::query_fingerprint(
        &input.query,
        DistillationPipeline::default_extractor,
    );

    // 2. Hamming NN over the "distillation-features-v1" lane only.
    //    pool is accepted for API parity; this implementation passes limit
    //    directly (mirrors Swift's current implementation comment).
    let matches = coord.find_nearest_distilled(handle, &engram, input.limit)?;

    if matches.is_empty() {
        return Ok(DistilledRecallOutput {
            matches: vec![],
            discrimination: DistilledDiscriminationLevel::Single,
        });
    }

    // 3. Hydrate the NN match ids through the bounded, policy-enforcing by-ids path.
    //
    //    Parity with Swift DistilledRecall.run step 3:
    //      `kit.hydrate(estate, ids: matches.map(\.itemID),
    //                   matchingFrame: RecallFrame(filterChain: [input.filter],
    //                                              hydrationLevel: .full))`
    //    Swift hydrates the explicit NN candidate ids; the frame's filter chain routes
    //    through BitmapEvaluator::insert_defaults and enforces the
    //    SensitivityAtMost(Elevated) ceiling (ADR-007 Decision 2 / VK-TIER-01).
    //    Restricted and secret factoids are excluded before their body reaches the MCP
    //    boundary — secfix/punt-g2 part 2.
    //
    //    get_drawers_matching_frame is scoped to the ids slice (the NN candidate set),
    //    so there is NO capture-time recall window: an older admissible factoid is
    //    hydrated whenever its id is among the NN matches, independent of estate size.
    //    The earlier coord.recall(frame.limit = pool) approach returned only the newest
    //    `pool` admissible drawers by capture-time-desc and intersected that with the
    //    match ids — on estates with more admissible currently-believe rows than `pool`
    //    (default max(limit*5, 50)), an NN match older than that window silently
    //    disappeared, degrading recall integrity/availability. The id-scoped hydration
    //    path (identical to Recollect steps 1 and 4) removes the window entirely.
    //    secfix/ce-distill-recall-window.
    //
    //    `input.filter` is the caller's ARIA adjective filter, composed into the
    //    RecallFrame alongside the sensitivity ceiling. insert_defaults enforces
    //    SensitivityAtMost(Elevated) as a non-negotiable floor; the caller filter
    //    applies on top (can only be MORE restrictive, never less).
    //
    //    HydrationLevel::Full is required so that drawer.content is populated for
    //    DIST header parsing. Parity: Swift kit.hydrate uses hydrationLevel: .full.
    //    Without Full, content is empty at Structured level and DistilledHeader::parse
    //    returns None for all rows, making every hit a spurious miss.
    //
    //    No .limit is set: the call is bounded by the ids slice, not a full-estate
    //    scan (parity with Recollect steps 1/4). B-1 compliant — no raw store access.
    let match_id_list: Vec<String> = matches.iter().map(|m| m.item_id.clone()).collect();
    let mut frame = RecallFrame::new(vec![input.filter.clone()]);
    frame.hydration_level = HydrationLevel::Full;
    let policy_drawers = coord
        .get_drawers_matching_frame(handle, &match_id_list, &frame)
        .unwrap_or_default();
    let match_ids: std::collections::HashSet<&str> =
        matches.iter().map(|m| m.item_id.as_str()).collect();
    let factoid_map: std::collections::HashMap<&str, &locus_kit::drawer::Drawer> = policy_drawers
        .iter()
        .filter(|d| match_ids.contains(d.id.as_str()))
        .map(|d| (d.id.as_str(), d))
        .collect();

    // 4. Parse DIST header per match, build DistilledMatch array.
    //    Drawers absent from the map or lacking a DIST header are silently
    //    skipped (parity with Swift `guard let header = DistilledHeader.parse(body)`).
    let mut distilled_matches: Vec<DistilledMatch> = Vec::new();
    for m in &matches {
        let Some(drawer) = factoid_map.get(m.item_id.as_str()) else { continue };
        let Some(header) = DistilledHeader::parse(&drawer.content) else { continue };
        let injection_depth = injection_depth_from_confidence(header.confidence);
        distilled_matches.push(DistilledMatch {
            id: drawer.id.clone(),
            prose: header.prose.clone(),
            confidence: header.confidence,
            source_count: header.source_count,
            snr: header.snr,
            delta_type: header.delta_type.map(|dt| dt.as_str().to_owned()),
            uncertain: header.uncertain,
            injection_depth,
        });
    }

    // 5. Discrimination over confidence scores.
    let scores: Vec<f64> = distilled_matches.iter().map(|m| m.confidence as f64).collect();
    let discrimination = classify_distilled_discrimination(&scores);

    Ok(DistilledRecallOutput { matches: distilled_matches, discrimination })
}

// MARK: - Helpers

/// Derive injection depth from a confidence score.
///
/// Thresholds match Swift's `InjectionDepth` (Dn1 conformance):
///   conf >= 0.7  → FactoidOnly
///   conf ∈ [0.4, 0.7) → FactoidWithMeta
///   conf < 0.4   → FactoidWithProvenance
fn injection_depth_from_confidence(confidence: f32) -> InjectionDepth {
    if confidence >= 0.7 {
        InjectionDepth::FactoidOnly
    } else if confidence >= 0.4 {
        InjectionDepth::FactoidWithMeta
    } else {
        InjectionDepth::FactoidWithProvenance
    }
}

/// Classify how well confidence scores separate the top distilled match.
///
/// Mirrors `classifyDistilledDiscrimination` in the Swift port.
///
/// Thresholds:
///   HIGH_MARGIN = 0.25 — topGap at which rank-1 is clearly the best match.
///   LOW_MARGIN  = 0.05 — topGap below which rank-1 is indistinguishable.
///   LOW_SPREAD  = 0.15 — spread below which the whole list is flat.
///   EPS         = 1e-9 — prevents division by zero on all-zero score vectors.
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
        DistilledDiscriminationLevel::High
    } else if top_gap < 0.05 && spread < 0.15 {
        DistilledDiscriminationLevel::Low
    } else {
        DistilledDiscriminationLevel::Medium
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    // CK-DR-1 (Rust): classify_distilled_discrimination with fewer than 2 scores returns Single.
    #[test]
    fn ck_dr1_single_score_is_single() {
        assert_eq!(
            classify_distilled_discrimination(&[]),
            DistilledDiscriminationLevel::Single
        );
        assert_eq!(
            classify_distilled_discrimination(&[0.9]),
            DistilledDiscriminationLevel::Single
        );
    }

    // CK-DR-2 (Rust): top_gap >= 0.25 returns High.
    #[test]
    fn ck_dr2_large_gap_is_high() {
        // s0=1.0, s1=0.5: topGap = (1.0 - 0.5) / 1.0 = 0.5 >= 0.25 → High.
        assert_eq!(
            classify_distilled_discrimination(&[1.0, 0.5]),
            DistilledDiscriminationLevel::High
        );
    }

    // CK-DR-3 (Rust): topGap < 0.05 and spread < 0.15 returns Low.
    #[test]
    fn ck_dr3_flat_list_is_low() {
        // All scores near 0.9: topGap ≈ 0.01, spread ≈ 0.02 → Low.
        assert_eq!(
            classify_distilled_discrimination(&[0.91, 0.90, 0.90]),
            DistilledDiscriminationLevel::Low
        );
    }

    // CK-DR-4 (Rust): between the two extremes returns Medium.
    #[test]
    fn ck_dr4_partial_separation_is_medium() {
        // s0=1.0, s1=0.9: topGap = 0.1 — above LOW_MARGIN but below HIGH_MARGIN → Medium.
        assert_eq!(
            classify_distilled_discrimination(&[1.0, 0.9, 0.5]),
            DistilledDiscriminationLevel::Medium
        );
    }

    // CK-DR-5 (Rust): run_distilled_recall on an estate with no VectorStore returns
    //                  VerbDispatchError (NotSupportedByEstate), not a panic.
    #[test]
    fn ck_dr5_no_vector_store_returns_error() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
                        estate_types::OwnerCredentials};

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        let input = DistilledRecallInput::new("test query");
        // No VectorStore registered → find_nearest_distilled raises NotSupportedByEstate.
        let result = run_distilled_recall(&input, &coord, &handle, NOW);
        assert!(result.is_err(), "missing VectorStore must return Err, not Ok");
    }

    // CK-DR-6 (Rust): header parsing round-trips — a known DIST header string
    //                  produces the expected DistilledMatch fields.
    #[test]
    fn ck_dr6_dist_header_parse_fields() {
        let content = "[DIST|conf=0.80|src=4|snr=2.5] The cat sat on the mat.";
        let header = DistilledHeader::parse(content).expect("parse must succeed");
        assert_eq!(header.confidence, 0.80);
        assert_eq!(header.source_count, 4);
        assert!((header.snr - 2.5).abs() < 0.001);
        assert_eq!(header.prose, "The cat sat on the mat.");
        assert!(!header.uncertain, "conf=0.80 is not uncertain");
        // injection_depth from confidence 0.80 → FactoidOnly.
        assert_eq!(injection_depth_from_confidence(0.80), InjectionDepth::FactoidOnly);
    }

    // CK-DR-7 (Rust): injection depth thresholds match Swift's Dn1 conformance.
    #[test]
    fn ck_dr7_injection_depth_thresholds() {
        assert_eq!(injection_depth_from_confidence(0.70), InjectionDepth::FactoidOnly);
        assert_eq!(injection_depth_from_confidence(0.80), InjectionDepth::FactoidOnly);
        assert_eq!(injection_depth_from_confidence(0.69), InjectionDepth::FactoidWithMeta);
        assert_eq!(injection_depth_from_confidence(0.40), InjectionDepth::FactoidWithMeta);
        assert_eq!(injection_depth_from_confidence(0.39), InjectionDepth::FactoidWithProvenance);
        assert_eq!(injection_depth_from_confidence(0.00), InjectionDepth::FactoidWithProvenance);
    }

    // CK-DR-8 (Rust): DistilledRecallInput defaults match Swift defaults.
    //                  Verifies limit/pool calculations and filter default.
    #[test]
    fn ck_dr8_input_defaults() {
        use locus_kit::filter::Filter;

        let input = DistilledRecallInput::new("hello");
        assert_eq!(input.limit, 20);
        assert_eq!(input.pool, 100); // max(20*5, 50) = 100
        assert_eq!(input.filter, Filter::CurrentlyBelieve, "default filter must be CurrentlyBelieve");
        let input2 = DistilledRecallInput::with_limit("hello", 5);
        assert_eq!(input2.limit, 5);
        assert_eq!(input2.pool, 50); // max(5*5, 50) = 50
        assert_eq!(input2.filter, Filter::CurrentlyBelieve, "with_limit default filter must be CurrentlyBelieve");
        // with_filter preserves explicit filter
        let input3 = DistilledRecallInput::with_filter("hello", Filter::UserConfirmed);
        assert_eq!(input3.filter, Filter::UserConfirmed, "with_filter must carry the explicit filter");
        assert_eq!(input3.limit, 20, "with_filter must use default limit");
    }

    // CK-DR-9 (Rust): run_distilled_recall applies the sensitivity ceiling from
    //                  BitmapEvaluator insert_defaults — secret/restricted factoids
    //                  must not appear in recall results.
    //
    // secfix/punt-g2 part 2: The sweep now propagates source sensitivity to the
    // factoid (T5 in GLK distill_segmentation_parity tests). This test verifies
    // the complementary read-path gate: a factoid with secret sensitivity is
    // excluded by run_distilled_recall's policy-enforcing recall path.
    //
    // Implementation note: run_distilled_recall hydrates the NN match ids through
    // coord.get_drawers_matching_frame(), which applies BitmapEvaluator::insert_defaults
    // (SensitivityAtMost(Elevated)) per id. A Secret factoid is above that ceiling and is
    // excluded. This test exercises the sensitivity gate through the full-estate recall
    // path (coord.recall shares the same insert_defaults chain) without a VectorStore,
    // confirming a secret factoid is absent from the admissible set the by-ids hydration
    // would draw from.
    #[test]
    fn ck_dr9_secret_factoid_excluded_by_sensitivity_gate() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{
            adjectives::AdjectiveSensitivity,
            drawer_operational::CaptureChannel,
            drawer_store::DrawerStore,
            drawer_store_inmemory::InMemoryDrawerStore,
            estate_types::{LatticeAnchor, OwnerCredentials},
            filter::{Filter, HydrationLevel, RecallFrame},
            frames::CaptureFrame,
        };

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        // Capture a factoid with secret sensitivity directly (simulating what
        // distill_items_sweep produces for a secret-tier source drawer after the
        // secfix/punt-g2 propagation fix). Use a DIST-header body so the row is
        // plausibly a distilled factoid, and secret sensitivity so it sits above
        // the SensitivityAtMost(Elevated) ceiling that policy recall enforces.
        let dist_content = "[DIST|conf=0.85|src=1|snr=3.0] Secret factoid prose.";
        let mut frame = CaptureFrame::new(
            dist_content,
            CaptureChannel::Actuator,
            "_distilled",
            LatticeAnchor::udc("001"),
            "distillation-daemon",
            "distillation-features-v1",
        );
        frame.sensitivity = AdjectiveSensitivity::Secret;
        // Capture and record the ID. Check by id in the recall result — checking
        // by content requires Full hydration, but using id is simpler and more robust.
        let secret_id = coord.capture(&handle, frame, NOW).expect("capture secret factoid").id;

        // Verify the policy-enforcing recall path (the same path run_distilled_recall
        // uses after secfix/punt-g2 part 2) excludes the secret factoid.
        // RecallFrame with CurrentlyBelieve triggers insert_defaults which adds
        // SensitivityAtMost(Elevated) — the secret factoid (Sensitivity::Secret)
        // must not pass. Checking by id is robust — no content hydration needed.
        let mut policy_frame = RecallFrame::new(vec![Filter::CurrentlyBelieve]);
        policy_frame.hydration_level = HydrationLevel::Full;
        let policy_drawers = coord
            .recall(&handle, policy_frame, NOW)
            .expect("recall must not fail");
        let has_secret_factoid = policy_drawers
            .iter()
            .any(|d| d.id == secret_id);
        assert!(
            !has_secret_factoid,
            "policy-enforcing recall must exclude secret-tier factoids; \
             secfix/punt-g2 part 2 is not enforcing the sensitivity ceiling"
        );
    }

    // CK-DR-10 (Rust): run_distilled_recall propagates input.filter into the
    //                   RecallFrame — a factoid excluded by the caller's filter
    //                   must not appear in the candidate pool.
    //
    // Parity with Swift DistilledRecall.run step 3, which uses
    //   `RecallFrame(filterChain: [input.filter])`.
    // The Rust path must compose input.filter identically.
    //
    // This test exercises the frame path directly (via coord.recall) because
    // run_distilled_recall requires a VectorStore for the NN step. We verify
    // that the same RecallFrame construction that run_distilled_recall uses
    // would exclude a UserConfirmed-only drawer from an unconfirmed estate.
    //
    // Specifically: capture a drawer that is NOT yet user-confirmed (default
    // state is Unconfirmed). Recall with Filter::UserConfirmed (the same filter
    // run_distilled_recall would thread through when the caller passes
    // `filter=userConfirmed`). The unconfirmed drawer must be absent.
    #[test]
    fn ck_dr10_caller_filter_is_applied_in_recall_frame() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{
            drawer_operational::CaptureChannel,
            drawer_store::DrawerStore,
            drawer_store_inmemory::InMemoryDrawerStore,
            estate_types::{LatticeAnchor, OwnerCredentials},
            filter::{Filter, HydrationLevel, RecallFrame},
            frames::CaptureFrame,
        };

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        // Capture an unconfirmed drawer (default state — no explicit UserConfirmed).
        let dist_content = "[DIST|conf=0.75|src=1|snr=2.0] Unconfirmed factoid prose.";
        let frame = CaptureFrame::new(
            dist_content,
            CaptureChannel::Actuator,
            "_distilled",
            LatticeAnchor::udc("001"),
            "distillation-daemon",
            "distillation-features-v1",
        );
        // Record the ID so we can verify presence/absence without relying on content
        // hydration level — checking by id is robust regardless of HydrationLevel.
        let factoid_id = coord.capture(&handle, frame, NOW).expect("capture unconfirmed factoid").id;

        // Recall with Filter::UserConfirmed — parity with `input.filter = UserConfirmed`
        // in run_distilled_recall. The unconfirmed factoid must be absent from results.
        // Filter::UserConfirmed is a provenance filter (confirmation >= UserConfirmed);
        // since no UserConfirmed mutation was applied, the freshly captured drawer must
        // be absent.
        let mut uc_frame = RecallFrame::new(vec![Filter::UserConfirmed]);
        uc_frame.hydration_level = HydrationLevel::Full;
        let user_confirmed_drawers = coord
            .recall(&handle, uc_frame, NOW)
            .expect("recall must not fail");
        let has_factoid = user_confirmed_drawers
            .iter()
            .any(|d| d.id == factoid_id);
        assert!(
            !has_factoid,
            "UserConfirmed filter must exclude unconfirmed distilled factoids; \
             input.filter is not being applied in the RecallFrame"
        );

        // Sanity check: recall with Filter::CurrentlyBelieve (the default) DOES include it,
        // confirming the drawer is live and the filter is actually doing the exclusion work.
        let mut cb_frame = RecallFrame::new(vec![Filter::CurrentlyBelieve]);
        cb_frame.hydration_level = HydrationLevel::Full;
        let cb_drawers = coord
            .recall(&handle, cb_frame, NOW)
            .expect("recall with CurrentlyBelieve must not fail");
        let has_factoid_in_cb = cb_drawers
            .iter()
            .any(|d| d.id == factoid_id);
        assert!(
            has_factoid_in_cb,
            "CurrentlyBelieve filter must include the unconfirmed factoid; \
             sanity check for CK-DR-10 failed — the drawer may not have captured correctly"
        );
    }

    // CK-DR-11 (Rust): the by-ids hydration path used by run_distilled_recall step 3
    //                   has NO capture-time recall window — an older admissible factoid
    //                   is hydrated even when many newer admissible rows exist.
    //
    // Regression for secfix/ce-distill-recall-window: the prior implementation called
    // coord.recall(frame.limit = pool) then intersected the newest-`pool` admissible
    // drawers (capture-time-desc) with the NN match ids. On an estate with more
    // admissible currently-believe rows than `pool`, an older NN-matched factoid fell
    // outside the window and silently disappeared. This test pins the exact behavioral
    // difference the fix depends on:
    //   - get_drawers_matching_frame(&[old_id]) hydrates the old factoid regardless of
    //     how many newer rows exist (the fixed path).
    //   - coord.recall(frame.limit = 50) excludes it once 50 newer rows crowd it out
    //     (the buggy path), proving the window was real and is now bypassed.
    #[test]
    fn ck_dr11_by_ids_hydration_has_no_capture_time_window() {
        use std::sync::Arc;
        use genius_locus_kit::coordinator::EstateCoordinator;
        use locus_kit::{
            drawer_operational::CaptureChannel,
            drawer_store::DrawerStore,
            drawer_store_inmemory::InMemoryDrawerStore,
            estate_types::{LatticeAnchor, OwnerCredentials},
            filter::{Filter, HydrationLevel, RecallFrame},
            frames::CaptureFrame,
        };

        const NOW: i64 = 1_700_000_000;
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(
            InMemoryDrawerStore::new(NOW, None).expect("store"),
        );
        let handle = coord
            .open(store, OwnerCredentials::new("test"), 0, i64::MAX)
            .expect("open");
        coord.seed_default_wings(&handle, NOW).expect("seed");

        // Capture the OLD admissible distilled factoid first (oldest capture time).
        let old_content = "[DIST|conf=0.85|src=1|snr=3.0] Old admissible factoid prose.";
        let old_frame = CaptureFrame::new(
            old_content,
            CaptureChannel::Actuator,
            "_distilled",
            LatticeAnchor::udc("001"),
            "distillation-daemon",
            "distillation-features-v1",
        );
        let old_id = coord.capture(&handle, old_frame, NOW).expect("capture old factoid").id;

        // Capture 60 NEWER admissible rows (> the default pool of 50), each with a
        // strictly later capture time so capture-time-desc ordering ranks them ahead
        // of the old factoid.
        for i in 1..=60_i64 {
            let content = format!("[DIST|conf=0.80|src=1|snr=2.0] Newer factoid {i}.");
            let frame = CaptureFrame::new(
                &content,
                CaptureChannel::Actuator,
                "_distilled",
                LatticeAnchor::udc("001"),
                "distillation-daemon",
                "distillation-features-v1",
            );
            coord.capture(&handle, frame, NOW + i).expect("capture newer factoid");
        }

        // Fixed path: hydrate the old factoid by id (the frame run_distilled_recall
        // builds). It must be present despite 60 newer rows — no window.
        let mut frame = RecallFrame::new(vec![Filter::CurrentlyBelieve]);
        frame.hydration_level = HydrationLevel::Full;
        let hydrated = coord
            .get_drawers_matching_frame(&handle, &[old_id.clone()], &frame)
            .expect("by-ids hydration must not fail");
        assert!(
            hydrated.iter().any(|d| d.id == old_id),
            "by-ids hydration must return the old admissible factoid regardless of \
             how many newer rows exist — the capture-time window must be gone"
        );

        // Buggy path (documented, not used): the old capture-time-windowed recall would
        // have dropped the old factoid once 50 newer admissible rows exist. Prove the
        // window was real so the fix is not a no-op.
        let mut windowed = RecallFrame::new(vec![Filter::CurrentlyBelieve]);
        windowed.hydration_level = HydrationLevel::Full;
        windowed.limit = Some(50);
        let newest_fifty = coord
            .recall(&handle, windowed, NOW + 60)
            .expect("windowed recall must not fail");
        assert!(
            !newest_fifty.iter().any(|d| d.id == old_id),
            "sanity: the newest-50 recall window must exclude the old factoid — if it \
             does not, this regression test no longer exercises the window it guards"
        );
    }
}
