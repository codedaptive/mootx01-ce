// distilled_recall.rs — Rust mirror of CognitionKit/DistilledRecall.swift.
//
// Dense-tier recall recipe: searches the distilled memory tier using structural
// fingerprint Hamming NN, returns factoid prose + metadata. No embedding model
// inference required.
//
// run_distilled_recall() sequence (parity with Swift DistilledRecall.run):
//   1. DistillationPipeline::query_fingerprint → Fingerprint256 (Engram)
//   2. EstateCoordinator::find_nearest_distilled → Vec<VectorMatch>
//   3. EstateCoordinator::all_drawers + local filter → factoid body map
//   4. DistilledHeader::parse per match → DistilledMatch array
//   5. classify_distilled_discrimination(scores) → DistilledDiscriminationLevel
//
// Pool parameter: accepted for API parity with Swift, currently unused — the
// current implementation passes `limit` directly to find_nearest_distilled
// (mirroring the Swift comment "pool: current implementation passes limit
// directly to findNearestDistilled"). Pool semantic is documented as reserved
// for future coarse-then-fine re-ranking.
//
// DiscriminationLevel discrimination thresholds:
//   HIGH_MARGIN = 0.25  — topGap at which rank-1 is clearly the best match.
//   LOW_MARGIN  = 0.05  — topGap below which rank-1 is indistinguishable.
//   LOW_SPREAD  = 0.15  — spread below which the whole list is flat.
//
// Layer discipline B-1/B-2: one GLK find_nearest_distilled + one all_drawers
// call (no raw store access). Read-only (B-6, I-6). Deterministic (no clock).

use genius_locus_kit::coordinator::{EstateCoordinator, VerbDispatchError};
use genius_locus_kit::handle::EstateHandle;
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
}

impl DistilledRecallInput {
    /// Build with defaults: limit=20, pool=max(limit*5, 50) — mirrors Swift.
    pub fn new(query: impl Into<String>) -> Self {
        let limit = 20;
        let pool = (limit * 5).max(50);
        DistilledRecallInput { query: query.into(), limit, pool }
    }

    /// Build with an explicit limit and default pool.
    pub fn with_limit(query: impl Into<String>, limit: usize) -> Self {
        let pool = (limit * 5).max(50);
        DistilledRecallInput { query: query.into(), limit, pool }
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
///   3. Hydrate matched drawers via `EstateCoordinator::all_drawers` + local filter.
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

    // 3. Hydrate matched drawers by reading all drawers and filtering by id.
    //    Apply the same tombstone exclusion used by normal recall (parity with
    //    the frame-aware hydrate path in Swift DistilledRecall). Tombstoned
    //    factoids must not reach the MCP boundary even if they matched the
    //    fingerprint NN query. B-1 compliant — no raw store access.
    let all_drawers = coord.all_drawers(handle).unwrap_or_default();
    let match_ids: std::collections::HashSet<&str> =
        matches.iter().map(|m| m.item_id.as_str()).collect();
    let factoid_map: std::collections::HashMap<&str, &locus_kit::drawer::Drawer> = all_drawers
        .iter()
        .filter(|d| match_ids.contains(d.id.as_str()) && d.tombstoned_at.is_none())
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
        let result = run_distilled_recall(&input, &coord, &handle);
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
    #[test]
    fn ck_dr8_input_defaults() {
        let input = DistilledRecallInput::new("hello");
        assert_eq!(input.limit, 20);
        assert_eq!(input.pool, 100); // max(20*5, 50) = 100
        let input2 = DistilledRecallInput::with_limit("hello", 5);
        assert_eq!(input2.limit, 5);
        assert_eq!(input2.pool, 50); // max(5*5, 50) = 50
    }
}
