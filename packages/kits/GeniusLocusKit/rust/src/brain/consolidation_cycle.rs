//! Wave-2 true consolidation (SPEC_CONSOLIDATION_VAGUE_RECALL §3, §5) —
//! configuration and report types. The sweep itself lives on
//! `EstateCoordinator` (coordinator.rs), mirroring Swift
//! `GeniusLocusKit.consolidationSweep` / `ConsolidationCycle.swift`.
//!
//! Covenant invariants (§3.3/§6): constituents are NEVER superseded and
//! never leave the index — the evaluator tier filter is the only exclusion
//! mechanism; consolidation runs only from maintenance windows (D9), never
//! inline with capture, and every sweep is bounded.

/// Tunables for one consolidation sweep. Every value traces to a ratified
/// spec knob; placeholders are the ratified placeholders (D2/D7/D9) and are
/// expected to be tuned from aged-estate distributions before GA.
/// Mirrors Swift `ConsolidationConfig`.
#[derive(Debug, Clone)]
pub struct ConsolidationConfig {
    /// D1/D2: capture-age gate in seconds — younger items never consolidate.
    pub minimum_age_seconds: i64,
    /// D1/D3: recall-quiet gate in seconds — items recalled within the
    /// window are hot and never consolidate. Clock = RecallTraceItem rows;
    /// trace ABSENCE reads as not-recently-recalled (the ratified
    /// semantics; the 30-day prune bounds the lookback).
    pub recall_quiet_seconds: i64,
    /// D4: Hamming ceiling. `None` derives per sweep from the measured
    /// pairwise distribution of the candidate sample (p10) — the spec
    /// forbids a blind a-priori radius; the shipped default is the
    /// DERIVATION, not a number.
    pub hamming_ceiling: Option<u32>,
    /// D5: minimum cluster size. Ratified at 3.
    pub minimum_cluster_size: usize,
    /// D7: clusters larger than this merge existing distillates instead of
    /// combining originals.
    pub large_cluster_fallback: usize,
    /// D8: vague-level cap. Ratified at 2.
    pub vague_level_cap: u8,
    /// D9: bounded sweep — max pool candidates examined per window.
    pub max_candidates_per_sweep: usize,
    /// Near-pair probe width per candidate.
    pub neighbor_probe_limit: usize,
}

impl Default for ConsolidationConfig {
    fn default() -> Self {
        ConsolidationConfig {
            minimum_age_seconds: 90 * 86_400,  // D2 placeholder X=90d
            recall_quiet_seconds: 30 * 86_400, // D2 placeholder Y=30d
            hamming_ceiling: None,             // D4: derive per sweep
            minimum_cluster_size: 3,           // D5 ratified
            large_cluster_fallback: 20,        // D7 placeholder
            vague_level_cap: 2,                // D8 ratified
            max_candidates_per_sweep: 500,     // D9 bound (placeholder)
            neighbor_probe_limit: 8,
        }
    }
}

/// What one consolidation sweep did (§3.2 acts + §5.1 fold-ins) and the D10
/// drift evidence it observed. Mirrors Swift `ConsolidationSweepReport`.
///
/// `repaired_items` counts vague drawers whose sensitivity tier was promoted
/// by the repair-sweep prologue (§D.6 #4). A positive count means the estate
/// contained pre-existing under-tiered vague rows that were corrected before
/// the candidate pool was built. Zero on a correctly-stamped estate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConsolidationSweepReport {
    pub new_vague_items: usize,
    pub fold_ins: usize,
    pub fold_in_rejections: usize,
    /// Count of vague drawers whose sensitivity was promoted by the repair
    /// prologue (§D.6 #4 — piggyback, no separate sweep verb). Zero on a
    /// correctly-stamped estate; positive on an estate that was consolidated
    /// before sensitivity inheritance was deployed.
    pub repaired_items: usize,
}

impl ConsolidationSweepReport {
    pub fn total_acts(&self) -> usize {
        self.new_vague_items + self.fold_ins
    }
}

/// Result of the two-hop vague recall (§4.4). Mirrors Swift
/// `VagueRecallResult`.
#[derive(Debug, Clone)]
pub struct VagueRecallResult {
    /// Hop-1 hits: ACTIVE vague items in lane-proximity order.
    pub vague_hits: Vec<locus_kit::drawer::Drawer>,
    /// Hop-2 answer set: hydrated constituents, bounded by K per hit and M
    /// total (D12).
    pub constituents: Vec<locus_kit::drawer::Drawer>,
}

/// Pipeline-version tag for subjects the consolidation daemon writes on
/// vague items. Deliberately NOT `ai-v1`: these subjects are deterministic
/// first-line caps, not AI-authored assertions, and the distinct tag lets a
/// future miniLLM regeneration sweep target exactly this producer via
/// `count_missing_subject(pipeline_version)`. Twin of Swift
/// `GeniusLocusKit.consolidationSubjectPipeline`.
pub const CONSOLIDATION_SUBJECT_PIPELINE: &str = "consolidation-v1";

/// Deterministic subject for a vague item: the rendering's first non-empty
/// line, character-capped to the store contract. Never returns empty for
/// the renderings `compose_and_distill` produces (it rejects all-blank
/// clusters). Twin of Swift `GeniusLocusKit.vagueSubject(from:)`.
pub fn vague_subject(rendering: &str) -> String {
    let first_line = rendering
        .lines()
        .find(|l| !l.is_empty())
        .unwrap_or(rendering);
    first_line
        .chars()
        .take(locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT)
        .collect()
}
