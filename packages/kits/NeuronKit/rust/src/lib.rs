//! NeuronKit, the algorithms layer of the MOOTx01 substrate.
//!
//! Hosts autonomic functions (the enrichment daemon, dreaming,
//! maintenance, standing-signals scheduler, SolverBandit,
//! audit-chain monitor) and reasoning functions (hybrid recall,
//! MMR diversification, ContextSynthesizer, branch derivation,
//! tournament scoring)
//! per NEURONKIT_SPEC_v0.85.md.
//!
//! First reasoning surface: the lattice-anchor inference path.
//! NeuronKit composes EideticLib's deterministic `lookup` and
//! wraps the result in a substrate-shaped LatticeAnchorInference
//! record that carries the provenance enrichment_status bit
//! transition per cookbook section 2.5. The linguistic pipeline
//! itself (tokenize, normalize, stem, gazetteer-match, classify,
//! resolve) lives in EideticLib and is the same code path on both
//! sides of the substrate boundary.
//!
//! Association-rule mining and bounded formal concept analysis live
//! in SubstrateML, not this crate. Use
//! `substrate_ml::association_rule_mining` and
//! `substrate_ml::formal_concept_analysis` for those types.
//!
//! Per DESIGN_CONSTRAINTS.md C-1, this crate takes NO external
//! ML runtime dependencies. Pure Rust source plus the eidetic-lib
//! dependency, whose CC-BY-SA reference data stays on the
//! outside of the substrate's compliance boundary by the
//! mere-aggregation doctrine.

pub mod anomaly_scan;
pub mod anticipation;
pub mod benchmark_live;
pub mod benchmark_scoring;
pub mod bias;
pub mod constellation;
pub mod context_synthesizer;
pub mod dreaming_cycle;
pub mod dreaming_decision;
pub mod estate_dreaming_reader;
pub mod estate_dreaming_sink;
pub mod estate_maintenance_reader;
pub mod estate_maintenance_sink;
pub mod drift;
pub mod hybrid_recall;
pub mod keystones;
pub mod latent_themes;
pub mod lattice_anchor;
pub mod maintenance_cycle;
pub mod maintenance_decision;
pub mod mind_overlap;
pub mod mmr_rank;
pub mod partial_recall;
pub mod scenario_profile;
pub mod spreading_activation;
pub mod structure_graph;
pub mod theme_weather;
pub mod tournament;
pub mod tournament_live;

pub use anomaly_scan::{anomalies, Anomaly};
pub use anticipation::{anticipate, ActionObservation, ActionPrediction};
pub use benchmark_live::{benchmark as benchmark_branch, BenchmarkReport};
pub use benchmark_scoring::{score as benchmark_score, BenchmarkScore};
pub use bias::{learned_preference, representation_bias, CategoryBias, PreferenceStrength};
pub use constellation::{constellations, Constellation};
pub use context_synthesizer::{synthesize, ContextDocument, DrawerRowMeta};
pub use dreaming_cycle::{
    tunnel_key, CoOccurrenceObservation, DreamingCycleReport, DreamingDaemon, DreamingPolicy,
    DreamingPolicyStore, DreamingProposalSink, DreamingSubstrateReader, InMemoryDreamingPolicyStore,
    ProposeFrameOut, RecallTraceItem, RecallTraceRewardSource, RewardSource, RewardSourceKind,
    TunnelLink,
};
pub use dreaming_decision::{
    candidate_key, contrastive_confidence, decide as dreaming_decide, EmittedCandidate,
    Observation, Outcome as DreamingOutcome,
};
/// Production adapter that binds `DreamingSubstrateReader` to a live
/// `EstateCoordinator`. Mirrors `EstateDreamingReader.swift`.
pub use estate_dreaming_reader::EstateDreamingReader;
/// Production adapter that binds `DreamingProposalSink` to a live
/// `DrawerStore`. Mirrors `EstateDreamingSink.swift`. Closes BRAIN-PROPOSE.
pub use estate_dreaming_sink::EstateDreamingSink;
/// Production adapter that binds `MaintenanceSubstrateReader` to a live
/// `EstateCoordinator`. Mirrors `EstateMaintenanceReader.swift`.
pub use estate_maintenance_reader::EstateMaintenanceReader;
/// Production adapter that binds `MaintenanceProposalSink` to a live
/// `DrawerStore`. Mirrors `EstateMaintenanceSink.swift`.
pub use estate_maintenance_sink::EstateMaintenanceSink;
pub use drift::{drift, DriftScore};
pub use hybrid_recall::{
    page_recall, rerank, shingle_similarity, shingles, DrawerRow, RecallFrameTuning, RecallPage,
};
pub use keystones::{keystones, Keystone};
pub use latent_themes::{latent_themes, LatentThemes, ThemeLoading};
pub use lattice_anchor::{
    AnchorConfidence, EnrichmentStatus, LatticeAnchorInference, LinguisticPipelineMode,
};
pub use maintenance_cycle::{
    InMemoryMaintenancePolicyStore, MaintenanceCycleReport, MaintenanceDaemon,
    MaintenanceDiaryEntry, MaintenancePolicy, MaintenancePolicyStore, MaintenanceProposalSink,
    MaintenanceScan, MaintenanceSubstrateReader,
    ProposeFrameOut as MaintenanceProposeFrameOut,
};
pub use maintenance_decision::{
    broken_tag, decide as maintenance_decide, AgedRow, AuditVerdict,
    Category as MaintenanceCategory, Decision as MaintenanceDecision, DriftRow,
    Inputs as MaintenanceInputs, Outcome as MaintenanceOutcome,
};
pub use mind_overlap::{dp_summary, summary_overlap};
pub use mmr_rank::{mmr_rank, mmr_select};
pub use partial_recall::{
    partial_recall, FingerprintBlock, BLOCK_CHANNEL, BLOCK_CONCEPT, BLOCK_STRUCTURE, BLOCK_TEMPORAL,
};
pub use scenario_profile::ScenarioProfile;
pub use spreading_activation::{spreading_activation, Activation};
pub use theme_weather::{recency_weight, theme_weather, CategoryMomentum};
pub use tournament::{bradley_terry, BradleyTerryScore, PairwiseOutcome, TournamentError};
pub use tournament_live::{
    rank_tournament, run_tournament, BranchScore, DisqualificationReason, DisqualifiedBranch,
    TournamentReport,
};

/// The NeuronKit crate version. Pinned with the substrate
/// schema version.
pub const VERSION: &str = "0.1.0";

/// The compile-time mode of the linguistic pipeline. Rust version
/// always uses the deterministic reference; the Apple
/// NaturalLanguage acceleration path is Swift-only per
/// MISSION_AE_02_APPLE_NL_ACCEL.md. Federation-disabled mode
/// does not apply to the Rust version.
pub const fn linguistic_pipeline_mode() -> LinguisticPipelineMode {
    LinguisticPipelineMode::DeterministicReference
}

/// Looks up the lattice anchor for the given drawer content and
/// packages it as a substrate-shaped `LatticeAnchorInference`
/// carrying the provenance bit transition the substrate should
/// apply. Composes `eidetic_lib::lookup`.
pub fn infer_lattice_anchor(content: &str) -> LatticeAnchorInference {
    let anchor = eidetic_lib::lookup(content);
    let status = if anchor.code.is_empty() {
        EnrichmentStatus::None
    } else if anchor.wikidata_qid.is_none() {
        EnrichmentStatus::QidPending
    } else {
        EnrichmentStatus::QidCompleted
    };
    LatticeAnchorInference {
        code: anchor.code,
        wikidata_qid: anchor.wikidata_qid,
        confidence: anchor.confidence,
        enrichment_status_bits: status.raw(),
        pipeline_mode: linguistic_pipeline_mode(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_pinned() {
        assert_eq!(VERSION, "0.1.0");
    }

    #[test]
    fn rust_port_is_always_deterministic_reference() {
        assert_eq!(
            linguistic_pipeline_mode(),
            LinguisticPipelineMode::DeterministicReference
        );
    }

    #[test]
    fn nonsense_term_produces_enrichment_status_none() {
        // Pure gibberish only — a single real dictionary word resolves
        // through the FDC encoder, so the fixture must contain no real
        // words. Mirrors the Swift NeuronKit fixture
        // (LatticeAnchorInferenceTests.swift) exactly.
        let inference = infer_lattice_anchor("zxcvqwertyasdfgh qwertyzxcvb");
        assert_eq!(inference.code, "");
        assert!(inference.wikidata_qid.is_none());
        assert_eq!(
            inference.enrichment_status_bits,
            EnrichmentStatus::None.raw()
        );
    }

    #[test]
    fn chemistry_term_produces_qid_completed_status() {
        // EideticLib resolves "chemistry" to an FDC code with a populated
        // Wikidata QID, so the enrichment status is QidCompleted. Parity
        // with the Swift NeuronKit assertion. The exact FDC code string is
        // LatticeLib's conformance concern (single-token encode parity is
        // tracked separately) — this test asserts the enrichment STATUS,
        // matching what the Swift port asserts.
        let inference = infer_lattice_anchor("chemistry");
        assert!(!inference.code.is_empty());
        assert!(inference.wikidata_qid.is_some());
        assert_eq!(
            inference.enrichment_status_bits,
            EnrichmentStatus::QidCompleted.raw()
        );
    }

    #[test]
    fn inference_carries_deterministic_reference_pipeline_mode() {
        let inference = infer_lattice_anchor("any term");
        assert_eq!(
            inference.pipeline_mode,
            LinguisticPipelineMode::DeterministicReference
        );
    }
}
